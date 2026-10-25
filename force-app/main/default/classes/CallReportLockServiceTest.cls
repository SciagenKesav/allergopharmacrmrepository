@isTest
private class CallReportLockServiceTest {

    private static User rep() { return SciagenTestUsers.mobileRep('lockrep'); }

    private static Call_Visit_Report__c submitted(User rep, Sciagen_Account__c hcp) {
        Call_Visit_Report__c c;
        System.runAs(rep) {
            c = new Call_Visit_Report__c(HCP__c = hcp.Id, Visit_Date__c = Date.today(), Start_Time__c = Datetime.now(),
                Call_Type__c = 'Detailing', Call_Status__c = 'Completed', Record_Status__c = 'Submitted',
                Discussion_Summary__c = 'Discussed efficacy.', Check_In_Distance_M__c = 12.5);
            insert c;
        }
        return c;
    }

    private static Sciagen_Account__c doctor(User rep, String name) {
        Sciagen_Account__c d;
        System.runAs(rep) { d = SampleTestData.doctor(name); }
        return d;
    }

    private static String tryUpdate(User u, Call_Visit_Report__c c) {
        String error;
        System.runAs(u) {
            try { update c; } catch (DmlException e) { error = e.getDmlMessage(0); }
        }
        return error;
    }

    @isTest static void repCannotEditOrReopenASubmittedCall() {
        User r = rep();
        Call_Visit_Report__c c = submitted(r, doctor(r, 'Dr Lock A'));
        String error = tryUpdate(r, new Call_Visit_Report__c(Id = c.Id, Discussion_Summary__c = 'Rewritten after the fact.'));
        System.assertNotEquals(null, error, 'business field edit must be blocked');
        System.assert(error.contains('Discussion_Summary__c'), error);
        error = tryUpdate(r, new Call_Visit_Report__c(Id = c.Id, Visit_Date__c = Date.today().addDays(-3)));
        System.assertNotEquals(null, error);
        error = tryUpdate(r, new Call_Visit_Report__c(Id = c.Id, Record_Status__c = 'Saved'));
        System.assertNotEquals(null, error, 'status regression must be blocked');
        String deleteError;
        System.runAs(r) {
            try { delete new Call_Visit_Report__c(Id = c.Id); } catch (DmlException e) { deleteError = e.getDmlMessage(0); }
        }
        System.assertNotEquals(null, deleteError, 'a submitted call can not be deleted');
        Call_Visit_Report__c after = [SELECT Record_Status__c, Discussion_Summary__c FROM Call_Visit_Report__c WHERE Id = :c.Id];
        System.assertEquals('Submitted', after.Record_Status__c);
        System.assertEquals('Discussed efficacy.', after.Discussion_Summary__c);
    }

    @isTest static void identicalResaveFromTheIPadPasses() {
        User r = rep();
        Call_Visit_Report__c c = submitted(r, doctor(r, 'Dr Lock B'));
        Call_Visit_Report__c stored = [SELECT Id, HCP__c, Visit_Date__c, Start_Time__c, Call_Type__c, Record_Status__c, Discussion_Summary__c
                                       FROM Call_Visit_Report__c WHERE Id = :c.Id];
        // Same values, number sent with extra precision, blank vs null text.
        stored.Check_In_Distance_M__c = 12.5000001;
        stored.Pre_Call_Notes__c = '';
        System.assertEquals(null, tryUpdate(r, stored));
    }

    @isTest static void caseOnlyTextChangeIsStillAChange() {
        User r = rep();
        Call_Visit_Report__c c = submitted(r, doctor(r, 'Dr Lock C'));
        System.assertNotEquals(null, tryUpdate(r, new Call_Visit_Report__c(Id = c.Id, Discussion_Summary__c = 'DISCUSSED EFFICACY.')));
    }

    @isTest static void supportUnlockFlowReopensAndResubmitRelocks() {
        User r = rep();
        User agent = SciagenTestUsers.rep('lockagt', new List<String>{ 'Sciagen_Mobile_App_Access', 'Sciagen_Support_Agent' });
        Call_Visit_Report__c c = submitted(r, doctor(r, 'Dr Lock D'));
        Id requestId;
        System.runAs(r) { requestId = SupportController.createRequest('Wrong product', 'Please unlock', 'Unlock Submitted Call', 'High', c.Id, null); }
        Test.startTest();
        System.runAs(agent) { SupportConsoleController.unlockCall(requestId, null); }
        Test.stopTest();
        Call_Visit_Report__c after = [SELECT Record_Status__c, Unlock_Count__c FROM Call_Visit_Report__c WHERE Id = :c.Id];
        System.assertEquals('Saved', after.Record_Status__c);
        System.assertEquals(1, after.Unlock_Count__c);
        // Saved: the rep corrects and resubmits.
        System.assertEquals(null, tryUpdate(r, new Call_Visit_Report__c(Id = c.Id, Discussion_Summary__c = 'Corrected.')));
        System.assertEquals(null, tryUpdate(r, new Call_Visit_Report__c(Id = c.Id, Record_Status__c = 'Submitted')));
        // Locked again.
        System.assertNotEquals(null, tryUpdate(r, new Call_Visit_Report__c(Id = c.Id, Discussion_Summary__c = 'Again.')));
    }

    @isTest static void automationFieldsStayWritable() {
        User r = rep();
        Sciagen_Account__c hcp = doctor(r, 'Dr Lock E');
        Call_Visit_Report__c c;
        Test.startTest();
        System.runAs(r) {
            c = new Call_Visit_Report__c(HCP__c = hcp.Id, Visit_Date__c = Date.today(), Start_Time__c = Datetime.now(),
                Call_Type__c = 'Detailing', Call_Status__c = 'Completed', Record_Status__c = 'Submitted',
                Next_Visit_Date__c = SciagenTestTime.nextBusinessSlot().date());
            insert c;
        }
        Test.stopTest();
        // CVRNextVisitPlannedCallService links the follow-up call on a submitted report, as the rep.
        Call_Visit_Report__c after = [SELECT Next_Visit_Planned_Call__c FROM Call_Visit_Report__c WHERE Id = :c.Id];
        System.assertNotEquals(null, after.Next_Visit_Planned_Call__c, 'follow-up call link must still be written');
        // Owner transfer and account-plan link are allowed.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            update new Call_Visit_Report__c(Id = c.Id, OwnerId = UserInfo.getUserId());
        }
        System.assertEquals(UserInfo.getUserId(), [SELECT OwnerId FROM Call_Visit_Report__c WHERE Id = :c.Id].OwnerId);
    }

    @isTest static void staleMergedHcpIdOnResaveIsRedirectedNotBlocked() {
        User r = rep();
        Sciagen_Account__c winner = doctor(r, 'Dr Lock Winner');
        Sciagen_Account__c loser = doctor(r, 'Dr Lock Loser');
        Sciagen_Account__c other = doctor(r, 'Dr Lock Other');
        Call_Visit_Report__c c = submitted(r, winner);
        update new Sciagen_Account__c(Id = loser.Id, Is_Merged__c = true, Merged_Into__c = winner.Id);
        // The iPad still holds the loser's id and re-sends it.
        System.assertEquals(null, tryUpdate(r, new Call_Visit_Report__c(Id = c.Id, HCP__c = loser.Id)));
        System.assertEquals(winner.Id, [SELECT HCP__c FROM Call_Visit_Report__c WHERE Id = :c.Id].HCP__c);
        // Re-pointing to an unrelated doctor is a real change.
        System.assertNotEquals(null, tryUpdate(r, new Call_Visit_Report__c(Id = c.Id, HCP__c = other.Id)));
    }

    @isTest static void mergeMovesSubmittedCallsEvenForANonAdminSteward() {
        User r = rep();
        User steward = SciagenTestUsers.rep('lockstw', new List<String>{ 'Sciagen_Mobile_App_Access', 'Sciagen_Data_Steward' });
        Sciagen_Account__c winner = doctor(r, 'Dr Merge Winner');
        Sciagen_Account__c loser = doctor(r, 'Dr Merge Loser');
        Call_Visit_Report__c c = submitted(r, loser);
        System.runAs(steward) { DuplicateMergeService.mergeRecords(winner.Id, loser.Id, null, 'Manual', null, null); }
        System.assertEquals(winner.Id, [SELECT HCP__c FROM Call_Visit_Report__c WHERE Id = :c.Id].HCP__c);
    }

    @isTest static void modifyAllDataUserCanCorrectASubmittedCall() {
        User r = rep();
        Call_Visit_Report__c c = submitted(r, doctor(r, 'Dr Lock F'));
        User admin = SciagenTestUsers.make('lockadm', 'System Administrator', null, null);
        System.assertEquals(null, tryUpdate(admin, new Call_Visit_Report__c(Id = c.Id, Discussion_Summary__c = 'Admin data fix.')));
        System.assertEquals('Admin data fix.', [SELECT Discussion_Summary__c FROM Call_Visit_Report__c WHERE Id = :c.Id].Discussion_Summary__c);
    }

    @isTest static void childrenAreEditableOnADraftButLockedOnceSubmitted() {
        User r = rep();
        Sciagen_Account__c hcp = doctor(r, 'Dr Lock Kids');
        Sciagen_Account__c attendee = doctor(r, 'Dr Lock Attendee');
        Id kmId;
        System.runAs(r) {
            Call_Visit_Report__c c = new Call_Visit_Report__c(HCP__c = hcp.Id, Visit_Date__c = Date.today(), Start_Time__c = Datetime.now(),
                Call_Type__c = 'Detailing', Call_Status__c = 'Completed', Record_Status__c = 'Draft');
            insert c;
            Key_Message__c km = new Key_Message__c(CVR__c = c.Id, Message__c = 'Efficacy');
            Key_Message__c km2 = new Key_Message__c(CVR__c = c.Id, Message__c = 'Dosing');
            Promo_Drop__c promo = new Promo_Drop__c(CVR__c = c.Id, Item__c = 'Pen', Qty__c = 1);
            CVR_Attendee__c att = new CVR_Attendee__c(CVR__c = c.Id, HCP__c = attendee.Id);
            CVR_Internal_Attendee__c colleague = new CVR_Internal_Attendee__c(CVR__c = c.Id, User__c = UserInfo.getUserId());
            insert new List<SObject>{ km, km2, promo, att, colleague };
            kmId = km.Id;

            // Draft: the iPad edits and deletes children after a save.
            km.Message__c = 'Efficacy and safety';
            update km;
            delete km2;
            promo.Qty__c = 2;
            update promo;

            update new Call_Visit_Report__c(Id = c.Id, Record_Status__c = 'Submitted');

            // Submitted: identical re-save passes, a real change or a delete does not.
            update new Key_Message__c(Id = km.Id, Message__c = 'Efficacy and safety');
            System.assertEquals(false, Database.update(new Key_Message__c(Id = km.Id, Message__c = 'Changed later'), false).isSuccess());
            System.assertEquals(false, Database.delete(km.Id, false).isSuccess());
            System.assertEquals(false, Database.update(new Promo_Drop__c(Id = promo.Id, Qty__c = 5), false).isSuccess());
            System.assertEquals(false, Database.delete(promo.Id, false).isSuccess());
            System.assertEquals(false, Database.delete(att.Id, false).isSuccess());
            System.assertEquals(false, Database.delete(colleague.Id, false).isSuccess());
            // The submit locks key messages (automation field) and the iPad still pushes children after the report.
            System.assert(Database.update(new Key_Message__c(Id = km.Id, Locked__c = true), false).isSuccess());
            System.assert(Database.insert(new Key_Message__c(CVR__c = c.Id, Message__c = 'Pushed after submit'), false).isSuccess());
        }
        System.assertEquals('Efficacy and safety', [SELECT Message__c FROM Key_Message__c WHERE Id = :kmId].Message__c, 'the submitted key message is unchanged');
    }
}