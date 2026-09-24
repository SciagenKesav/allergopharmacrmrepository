@isTest
private class SupportTest {

    @testSetup
    static void users() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User manager = user(p, 'mgr', null);
        insert manager;
        User repA = user(p, 'repa', manager.Id);
        User repB = user(p, 'repb', manager.Id);
        User agent = user(p, 'agnt', null);
        insert new List<User>{ repA, repB, agent };
        Id mobile = [SELECT Id FROM PermissionSet WHERE Name = 'Sciagen_Mobile_App_Access'].Id;
        Id agentSet = [SELECT Id FROM PermissionSet WHERE Name = 'Sciagen_Support_Agent'].Id;
        insert new List<PermissionSetAssignment>{
            new PermissionSetAssignment(AssigneeId = manager.Id, PermissionSetId = mobile),
            new PermissionSetAssignment(AssigneeId = repA.Id, PermissionSetId = mobile),
            new PermissionSetAssignment(AssigneeId = repB.Id, PermissionSetId = mobile),
            new PermissionSetAssignment(AssigneeId = agent.Id, PermissionSetId = mobile),
            new PermissionSetAssignment(AssigneeId = agent.Id, PermissionSetId = agentSet)
        };
    }

    private static User user(Profile p, String key, Id managerId) {
        return new User(FirstName = 'Support', LastName = 'Test ' + key, Alias = key, Email = key + '.support@sciagen-test.invalid',
            Username = key + '.support@sciagen-new-dev.invalid', TimeZoneSidKey = 'Asia/Kolkata', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', ProfileId = p.Id, IsActive = true, ManagerId = managerId);
    }

    private static User u(String key) { return [SELECT Id, ManagerId FROM User WHERE Username = :(key + '.support@sciagen-new-dev.invalid')]; }

    private static Id raise(User rep, String subject) {
        Id out;
        System.runAs(rep) { out = SupportController.createRequest(subject, 'Details for ' + subject, 'Sync Problem', 'Normal', null, null); }
        return out;
    }

    private static Support_Request__c load(Id id) {
        return [SELECT Id, Name, Status__c, Is_Open__c, Awaiting__c, Requester__c, OwnerId, Manager__c, Assigned_To__c, Comment_Count__c, Attachment_Count__c,
                       SLA_Due_At__c, First_Response_At__c, Resolved_At__c, Closed_At__c, Reopen_Count__c, Resolution_Type__c, Unlock_Outcome__c,
                       Requester_Last_Read_At__c, Last_Support_Comment_At__c, Priority__c
                FROM Support_Request__c WHERE Id = :id];
    }

    // ------------------------------------------------------------------ raising a request

    @isTest
    static void raisingARequestStampsOwnerManagerAndTargets() {
        User repA = u('repa'), manager = u('mgr'), repB = u('repb');
        Id id = raise(repA, 'Sync keeps failing');
        Support_Request__c r = load(id);
        System.assertEquals(repA.Id, r.Requester__c);
        System.assertEquals(repA.Id, r.OwnerId);
        System.assertEquals(manager.Id, r.Manager__c);
        System.assertEquals('New', r.Status__c);
        System.assertEquals(true, r.Is_Open__c);
        System.assertEquals('Support', r.Awaiting__c);
        System.assert(r.SLA_Due_At__c > Datetime.now().addHours(20));
        System.assertEquals(1, [SELECT COUNT() FROM Support_Comment__c WHERE Support_Request__c = :id AND Kind__c = 'Event']);

        System.runAs(manager) { System.assertEquals(1, [SELECT COUNT() FROM Support_Request__c WHERE Id = :id], 'the copied manager can see it'); }
        System.runAs(repB) { System.assertEquals(0, [SELECT COUNT() FROM Support_Request__c WHERE Id = :id], 'another rep cannot'); }
    }

    @isTest
    static void aRetriedCreateWithTheSameClientIdMakesOneRequest() {
        User repA = u('repa');
        Id a, b;
        System.runAs(repA) {
            a = SupportController.createRequest('Once', 'x', 'Other', 'Low', null, 'client-1');
            b = SupportController.createRequest('Once', 'x', 'Other', 'Low', null, 'client-1');
        }
        System.assertEquals(a, b);
        System.assertEquals(1, [SELECT COUNT() FROM Support_Request__c WHERE Client_Id__c = 'client-1']);
    }

    @isTest
    static void repsHitADailyLimit() {
        insert new Support_Setting__c(SetupOwnerId = UserInfo.getOrganizationId(), Max_Requests_Per_Day__c = 2);
        SupportConfig.reset();
        User repA = u('repa');
        raise(repA, 'One');
        raise(repA, 'Two');
        String error;
        System.runAs(repA) {
            try { SupportController.createRequest('Three', 'x', 'Other', 'Normal', null, null); } catch (AuraHandledException e) { error = e.getMessage(); }
        }
        System.assertNotEquals(null, error);
    }

    @isTest
    static void bulkInsertStaysWithinLimits() {
        insert new Support_Setting__c(SetupOwnerId = UserInfo.getOrganizationId(), Max_Requests_Per_Day__c = 1000);
        SupportConfig.reset();
        User repA = u('repa');
        List<Support_Request__c> many = new List<Support_Request__c>();
        for (Integer i = 0; i < 150; i++) many.add(new Support_Request__c(Subject__c = 'Bulk ' + i, Category__c = 'Other', Priority__c = 'Normal'));
        System.runAs(repA) {
            Test.startTest();
            insert many;
            Test.stopTest();
        }
        System.assertEquals(150, [SELECT COUNT() FROM Support_Request__c WHERE Requester__c = :repA.Id]);
    }

    // ------------------------------------------------------------------ what a rep may change

    @isTest
    static void aRepCanMarkReadAndCancelButNotEditAnythingElse() {
        User repA = u('repa');
        Id id = raise(repA, 'Guard');
        String error;
        System.runAs(repA) {
            try { update new Support_Request__c(Id = id, Priority__c = 'Urgent'); } catch (DmlException e) { error = e.getMessage(); }
            System.assertNotEquals(null, error, 'priority is not the rep\'s to change');
            error = null;
            try { update new Support_Request__c(Id = id, Assigned_To__c = UserInfo.getUserId()); } catch (DmlException e) { error = e.getMessage(); }
            System.assertNotEquals(null, error);
            SupportController.markRead(id);
            SupportController.cancelRequest(id);
        }
        Support_Request__c r = load(id);
        System.assertEquals('Cancelled', r.Status__c);
        System.assertEquals(false, r.Is_Open__c);
        System.assertNotEquals(null, r.Closed_At__c);
    }

    @isTest
    static void theManagerCannotChangeARequestButCanReply() {
        User repA = u('repa'), manager = u('mgr');
        Id id = raise(repA, 'CC me');
        String error;
        System.runAs(manager) {
            try { update new Support_Request__c(Id = id, Status__c = 'Closed'); } catch (DmlException e) { error = e.getMessage(); }
            System.assertNotEquals(null, error);
            SupportController.addMessage(id, 'Please look at this one first.', null);
        }
        Support_Comment__c c = [SELECT Author_Role__c FROM Support_Comment__c WHERE Support_Request__c = :id AND Kind__c = 'Message'];
        System.assertEquals('Manager', c.Author_Role__c);
    }

    // ------------------------------------------------------------------ the conversation

    @isTest
    static void aConversationMovesTheRequestBetweenSupportAndTheRep() {
        User repA = u('repa'), agent = u('agnt');
        Id id = raise(repA, 'Two way');
        SupportRequestService.updateInternally(new List<Support_Request__c>{ new Support_Request__c(Id = id, Requester_Last_Read_At__c = Datetime.now().addMinutes(-5)) }, true);
        System.runAs(agent) { SupportConsoleController.reply(id, 'Which iPad and when did it start?', 'Waiting on Rep', null, null); }
        Support_Request__c r = load(id);
        System.assertEquals('Waiting on Rep', r.Status__c);
        System.assertEquals('Requester', r.Awaiting__c);
        System.assertNotEquals(null, r.First_Response_At__c);
        System.assertEquals(agent.Id, r.Assigned_To__c);

        System.runAs(repA) {
            SupportListService.ListPage p = SupportController.listRequests(new SupportListService.Filter());
            System.assertEquals(true, p.rows[0].unreadForRequester, 'a new reply is unread');
            SupportController.markRead(id);
            System.assertEquals(false, SupportController.listRequests(new SupportListService.Filter()).rows[0].unreadForRequester);
            SupportController.addMessage(id, 'iPad Air, since Monday.', 'c-1');
        }
        r = load(id);
        System.assertEquals('Open', r.Status__c, 'a rep reply puts it back with support');
        System.assertEquals('Support', r.Awaiting__c);
        System.assertEquals(2, r.Comment_Count__c);
    }

    @isTest
    static void resolvingAndReopeningWithinTheWindow() {
        User repA = u('repa'), agent = u('agnt');
        Id id = raise(repA, 'Resolve me');
        System.runAs(agent) { SupportConsoleController.reply(id, 'Fixed on our side.', 'Resolved', 'Fixed', null); }
        Support_Request__c r = load(id);
        System.assertEquals('Resolved', r.Status__c);
        System.assertEquals(false, r.Is_Open__c);
        System.assertEquals('Fixed', r.Resolution_Type__c);
        System.assertNotEquals(null, r.Resolved_At__c);

        System.runAs(repA) {
            SupportListService.Detail d = SupportController.getRequest(id);
            System.assertEquals(true, d.canReply);
            System.assertEquals(true, d.canReopen);
            SupportController.addMessage(id, 'Still happening.', null);
        }
        r = load(id);
        System.assertEquals('Open', r.Status__c);
        System.assertEquals(1, r.Reopen_Count__c);
        System.assertEquals(null, r.Resolved_At__c);
    }

    @isTest
    static void aRepCannotReplyToARequestClosedLongAgo() {
        User repA = u('repa'), agent = u('agnt');
        Id id = raise(repA, 'Old');
        System.runAs(agent) { SupportConsoleController.reply(id, 'Done.', 'Closed', 'Answered', null); }
        SupportRequestService.updateInternally(new List<Support_Request__c>{ new Support_Request__c(Id = id, Closed_At__c = Datetime.now().addDays(-40), Resolved_At__c = Datetime.now().addDays(-40)) }, true);
        String error;
        System.runAs(repA) {
            try { SupportController.addMessage(id, 'Hello?', null); } catch (AuraHandledException e) { error = e.getMessage(); }
            System.assertEquals(false, SupportController.getRequest(id).canReply);
        }
        System.assertNotEquals(null, error);
    }

    @isTest
    static void systemLinesAreNotTypedByPeople() {
        User repA = u('repa');
        Id id = raise(repA, 'Spoof');
        System.runAs(repA) {
            insert new Support_Comment__c(Support_Request__c = id, Body__c = 'I am system', Kind__c = 'Event', Author_Role__c = 'System');
        }
        Support_Comment__c c = [SELECT Kind__c, Author_Role__c FROM Support_Comment__c WHERE Support_Request__c = :id AND Author__c = :repA.Id AND Kind__c = 'Message'];
        System.assertEquals('Message', c.Kind__c);
        System.assertEquals('Requester', c.Author_Role__c);
    }

    // ------------------------------------------------------------------ unlocking a call

    private static Call_Visit_Report__c submittedCall(User rep) {
        Call_Visit_Report__c call;
        System.runAs(rep) {
            Sciagen_Account__c hcp = SampleTestData.doctor('Dr Unlock ' + rep.Id);
            call = SampleTestData.call(hcp, 'Submitted');
        }
        return call;
    }

    @isTest
    static void unlockingASubmittedCallLetsTheRepEditAndResubmit() {
        User repA = u('repa'), agent = u('agnt');
        Call_Visit_Report__c call = submittedCall(repA);
        Id id;
        System.runAs(repA) { id = SupportController.createRequest('Wrong product', 'Please unlock', 'Unlock Submitted Call', 'High', call.Id, null); }
        System.assert(load(id).Id != null);
        System.assertEquals(true, [SELECT Call_Summary__c FROM Support_Request__c WHERE Id = :id].Call_Summary__c.startsWith('Dr Unlock'));

        System.runAs(repA) {
            String error;
            try { SupportConsoleController.unlockCall(id, null); } catch (AuraHandledException e) { error = e.getMessage(); }
            System.assertNotEquals(null, error, 'reps cannot unlock');
            error = null;
            try { SupportController.createRequest('Again', 'x', 'Unlock Submitted Call', 'Normal', call.Id, null); } catch (AuraHandledException e) { error = e.getMessage(); }
            System.assertNotEquals(null, error, 'one open unlock request per call');
        }

        System.runAs(agent) { SupportConsoleController.unlockCall(id, null); }
        Call_Visit_Report__c after = [SELECT Record_Status__c, Unlocked_By__c, Unlock_Count__c, Unlock_Request__c FROM Call_Visit_Report__c WHERE Id = :call.Id];
        System.assertEquals('Saved', after.Record_Status__c);
        System.assertEquals(agent.Id, after.Unlocked_By__c);
        System.assertEquals(1, after.Unlock_Count__c);
        Support_Request__c r = load(id);
        System.assertEquals('Waiting on Rep', r.Status__c);
        System.assertEquals('Unlocked', r.Unlock_Outcome__c);

        System.runAs(repA) { update new Call_Visit_Report__c(Id = call.Id, Record_Status__c = 'Submitted'); }
        r = load(id);
        System.assertEquals('Resolved', r.Status__c, 'submitting again resolves the request');
        System.assertEquals('Unlocked', r.Resolution_Type__c);
    }

    @isTest
    static void aRepCannotAskToUnlockSomeoneElsesCallOrAnOpenOne() {
        User repA = u('repa'), repB = u('repb');
        Call_Visit_Report__c bCall = submittedCall(repB);
        String error;
        System.runAs(repA) {
            try { SupportController.createRequest('Not mine', 'x', 'Unlock Submitted Call', 'Normal', bCall.Id, null); } catch (AuraHandledException e) { error = e.getMessage(); }
            System.assertNotEquals(null, error);
            error = null;
            try { SupportController.createRequest('No call', 'x', 'Unlock Submitted Call', 'Normal', null, null); } catch (AuraHandledException e) { error = e.getMessage(); }
            System.assertNotEquals(null, error);
        }
    }

    @isTest
    static void decliningAnUnlockNeedsAReasonAndClosesTheRequest() {
        User repA = u('repa'), agent = u('agnt');
        Call_Visit_Report__c call = submittedCall(repA);
        Id id;
        System.runAs(repA) { id = SupportController.createRequest('Unlock', 'x', 'Unlock Submitted Call', 'Normal', call.Id, null); }
        System.runAs(agent) {
            String error;
            try { SupportConsoleController.declineUnlock(id, ' '); } catch (AuraHandledException e) { error = e.getMessage(); }
            System.assertNotEquals(null, error);
            SupportConsoleController.declineUnlock(id, 'Past the monthly cut-off.');
        }
        Support_Request__c r = load(id);
        System.assertEquals('Resolved', r.Status__c);
        System.assertEquals('Declined', r.Unlock_Outcome__c);
        System.assertEquals('Submitted', [SELECT Record_Status__c FROM Call_Visit_Report__c WHERE Id = :call.Id].Record_Status__c);
    }

    // ------------------------------------------------------------------ the tracker

    @isTest
    static void theTrackerPagesWithoutRepeatsAndFilters() {
        User repA = u('repa'), agent = u('agnt');
        insert new Support_Setting__c(SetupOwnerId = UserInfo.getOrganizationId(), Max_Requests_Per_Day__c = 100);
        SupportConfig.reset();
        for (Integer i = 0; i < 7; i++) raise(repA, 'Tracker item ' + i);
        Set<Id> seen = new Set<Id>();
        System.runAs(agent) {
            SupportListService.Filter f = new SupportListService.Filter();
            f.view = 'unassigned';
            f.pageSize = 3;
            SupportListService.ListPage p = SupportConsoleController.listRequests(f);
            System.assertEquals(7, p.total);
            Integer pages = 0;
            while (true) {
                pages++;
                for (SupportListService.Row row : p.rows) System.assert(seen.add(row.id), 'no request appears twice');
                if (!p.hasMore) break;
                f.cursorAt = p.nextAt;
                f.cursorId = p.nextId;
                p = SupportConsoleController.listRequests(f);
            }
            System.assertEquals(3, pages);
            System.assertEquals(7, seen.size());

            SupportListService.Filter t = new SupportListService.Filter();
            t.text = 'item 4';
            System.assertEquals(1, SupportConsoleController.listRequests(t).rows.size());
            SupportListService.Filter m = new SupportListService.Filter();
            m.view = 'mine';
            System.assertEquals(0, SupportConsoleController.listRequests(m).rows.size());
            SupportConsoleController.Board b = SupportConsoleController.getBoard();
            System.assertEquals(7, b.open);
            System.assertEquals(7, b.unassigned);
            System.assertEquals(7, b.openedToday);
        }
    }

    @isTest
    static void bulkAssignAndStatusReportPerRow() {
        User repA = u('repa'), agent = u('agnt');
        Id a = raise(repA, 'A');
        Id b = raise(repA, 'B');
        System.runAs(agent) {
            List<SupportConsoleController.RowResult> res = SupportConsoleController.assign(new List<Id>{ a, b }, agent.Id);
            System.assertEquals(2, res.size());
            System.assertEquals(true, res[0].ok);
            res = SupportConsoleController.setStatus(new List<Id>{ a }, 'Resolved', 'Answered');
            System.assertEquals(true, res[0].ok);
            SupportConsoleController.setPriority(new List<Id>{ b }, 'Urgent');
        }
        System.assertEquals('Open', load(b).Status__c, 'assigning a new request opens it');
        System.assertEquals('Urgent', load(b).Priority__c);
        System.assertEquals('Resolved', load(a).Status__c);
    }

    @isTest
    static void theConsoleIsForAgentsOnly() {
        User repA = u('repa');
        String error;
        System.runAs(repA) {
            try { SupportConsoleController.getBoard(); } catch (AuraHandledException e) { error = e.getMessage(); }
        }
        System.assertNotEquals(null, error);
    }

    @isTest
    static void autoAssignGivesTheRequestToTheLeastLoadedAgent() {
        insert new Support_Setting__c(SetupOwnerId = UserInfo.getOrganizationId(), Auto_Assign__c = true);
        SupportConfig.reset();
        User repA = u('repa'), agent = u('agnt');
        Id id = raise(repA, 'Auto');
        System.assert(SupportAssignmentService.agents().containsKey(load(id).Assigned_To__c), 'given to one of the support agents');
        System.assertEquals('Open', load(id).Status__c);
    }

    // ------------------------------------------------------------------ files

    @isTest
    static void filesAreCountedAndOnlyAllowedTypesAreAccepted() {
        User repA = u('repa');
        Id id = raise(repA, 'Screenshot');
        Id commentId;
        System.runAs(repA) {
            commentId = SupportController.addMessage(id, 'See the screenshot', null);
            SupportController.uploadFile(commentId, 'screen.png', EncodingUtil.base64Encode(Blob.valueOf('png-bytes')));
            String error;
            try { SupportController.uploadFile(commentId, 'virus.exe', EncodingUtil.base64Encode(Blob.valueOf('x'))); } catch (AuraHandledException e) { error = e.getMessage(); }
            System.assertNotEquals(null, error);
            error = null;
            try { insert new ContentVersion(Title = 'bad', PathOnClient = 'bad.exe', VersionData = Blob.valueOf('x'), FirstPublishLocationId = id); } catch (DmlException e) { error = e.getMessage(); }
            System.assertNotEquals(null, error);
        }
        System.assertEquals(1, [SELECT Attachment_Count__c FROM Support_Comment__c WHERE Id = :commentId].Attachment_Count__c);
        System.assertEquals(1, load(id).Attachment_Count__c);
        System.runAs(repA) {
            SupportListService.Detail d = SupportController.getRequest(id);
            Integer files = 0;
            for (SupportListService.Message m : d.messages) files += m.attachments.size();
            System.assertEquals(1, files);
        }
    }

    // ------------------------------------------------------------------ hygiene

    @isTest
    static void staleRequestsCloseThemselves() {
        User repA = u('repa'), agent = u('agnt');
        Id resolved = raise(repA, 'Resolved long ago');
        Id waiting = raise(repA, 'Nobody answered');
        Id fresh = raise(repA, 'Still fresh');
        System.runAs(agent) {
            SupportConsoleController.reply(resolved, 'Done.', 'Resolved', 'Fixed', null);
            SupportConsoleController.reply(waiting, 'Any update?', 'Waiting on Rep', null, null);
        }
        SupportRequestService.updateInternally(new List<Support_Request__c>{
            new Support_Request__c(Id = resolved, Resolved_At__c = Datetime.now().addDays(-10)),
            new Support_Request__c(Id = waiting, Last_Activity_At__c = Datetime.now().addDays(-20))
        }, true);
        Test.startTest();
        Database.executeBatch(new SupportAutoCloseBatch(), 200);
        Test.stopTest();
        System.assertEquals('Closed', load(resolved).Status__c);
        System.assertEquals('Closed', load(waiting).Status__c);
        System.assertEquals('No Response', load(waiting).Resolution_Type__c);
        System.assertEquals('New', load(fresh).Status__c);
    }

    @isTest
    static void theAutoCloseJobCanBeScheduled() {
        Test.startTest();
        Id job = SupportAutoCloseBatch.schedule();
        Test.stopTest();
        System.assertNotEquals(null, job);
    }

    @isTest
    static void contextTellsTheScreenWhoIsWho() {
        User repA = u('repa'), manager = u('mgr'), agent = u('agnt');
        raise(repA, 'Team item');
        System.runAs(manager) {
            SupportController.Context c = SupportController.getContext();
            System.assertEquals(true, c.hasTeam);
            System.assertEquals(false, c.isAgent);
            System.assert(c.categories.contains('Unlock Submitted Call'));
            SupportListService.Filter team = new SupportListService.Filter();
            team.scope = 'team';
            System.assertEquals(1, SupportController.listRequests(team).rows.size());
        }
        System.runAs(agent) {
            System.assertEquals(true, SupportController.getContext().isAgent);
            SupportConsoleController.ConsoleContext cc = SupportConsoleController.getContext();
            System.assertEquals(true, cc.canUnlock);
            Set<Id> agentIds = new Set<Id>();
            for (SupportConsoleController.AgentOption a : cc.agents) agentIds.add(a.id);
            System.assert(agentIds.contains(agent.Id));
        }
    }

    /** Exactly what the iPad selects and writes, as a rep with only the app permission set. */
    @isTest
    static void theIpadContractWorksForARepWithTheAppPermissionSet() {
        User repA = u('repa'), manager = u('mgr'), agent = u('agnt');
        Id id;
        System.runAs(repA) {
            Support_Request__c r = new Support_Request__c(Subject__c = 'From the iPad', Description__c = 'It broke', Category__c = 'App Issue', Priority__c = 'High',
                Device_Info__c = 'iPad Air - iPadOS 18 - app 1.4 (37)', Source__c = 'iPad', Client_Id__c = 'ipad-req-1');
            Database.upsert(r, Support_Request__c.Client_Id__c, AccessLevel.USER_MODE);
            id = r.Id;
            Support_Comment__c c = new Support_Comment__c(Support_Request__c = id, Body__c = 'More detail', Sent_Via__c = 'iPad', Client_Id__c = 'ipad-c-1');
            Database.upsert(c, Support_Comment__c.Client_Id__c, AccessLevel.USER_MODE);
            Database.update(new Support_Request__c(Id = id, Requester_Last_Read_At__c = Datetime.now()), AccessLevel.USER_MODE);
            Database.update(new Support_Request__c(Id = id, Status__c = 'Cancelled'), AccessLevel.USER_MODE);
        }
        System.runAs(repA) {
            List<Support_Request__c> mine = [
                SELECT Id, Name, Subject__c, Category__c, Priority__c, Status__c, Is_Open__c, Awaiting__c, Assigned_To__r.Name, Manager__r.Name, Call_Visit_Report__c,
                       Call_Summary__c, Comment_Count__c, Attachment_Count__c, Last_Activity_At__c, Last_Support_Comment_At__c, Requester_Last_Read_At__c,
                       Resolution_Type__c, Unlock_Outcome__c, CreatedDate, Client_Id__c, Requester__c, Requester__r.Name
                FROM Support_Request__c WHERE Requester__c = :repA.Id AND (Is_Open__c = true OR Last_Activity_At__c >= LAST_N_DAYS:90)
                WITH USER_MODE ORDER BY Last_Activity_At__c DESC LIMIT 100
            ];
            System.assertEquals(1, mine.size());
            System.assertEquals('Cancelled', mine[0].Status__c);
            System.assertEquals(manager.Id, [SELECT Manager__c FROM Support_Request__c WHERE Id = :id WITH USER_MODE].Manager__c);
            List<Support_Comment__c> thread = [
                SELECT Id, Body__c, Author__c, Author__r.Name, Author_Role__c, Kind__c, Sent_Via__c, Attachment_Count__c, CreatedDate
                FROM Support_Comment__c WHERE Support_Request__c = :id WITH USER_MODE ORDER BY CreatedDate ASC LIMIT 500
            ];
            System.assert(thread.size() >= 2);
            List<ContentDocumentLink> files = [SELECT LinkedEntityId, ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :id];
            System.assertEquals(0, files.size());
        }
        System.runAs(manager) {
            List<Support_Request__c> team = [SELECT Id FROM Support_Request__c WHERE Manager__c = :manager.Id AND Requester__c != :manager.Id WITH USER_MODE];
            System.assertEquals(1, team.size());
        }
    }
}