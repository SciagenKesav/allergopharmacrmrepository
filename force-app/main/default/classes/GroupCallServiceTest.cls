@isTest
private class GroupCallServiceTest {

    private static User rep() { return SciagenTestUsers.mobileRep('grprep'); }

    private static Sciagen_Account__c doctor(User rep, String name) {
        Sciagen_Account__c d;
        System.runAs(rep) { d = SampleTestData.doctor(name); }
        return d;
    }

    private static Call_Visit_Report__c call(User rep, Sciagen_Account__c hcp, String status) {
        Call_Visit_Report__c c;
        System.runAs(rep) {
            c = new Call_Visit_Report__c(HCP__c = hcp.Id, Visit_Date__c = Date.today(), Start_Time__c = Datetime.now(),
                End_Time__c = Datetime.now().addMinutes(20), Activity_Type__c = 'In-person', Call_Type__c = 'Detailing',
                Call_Status__c = 'Completed', Record_Status__c = status, Discussion_Summary__c = 'Group CME discussion.');
            insert c;
        }
        return c;
    }

    /** What the iPad pushes: one CVR_Attendee__c per HCP, the primary HCP included. */
    private static List<CVR_Attendee__c> attend(User rep, Call_Visit_Report__c c, List<Sciagen_Account__c> hcps) {
        List<CVR_Attendee__c> rows = new List<CVR_Attendee__c>();
        for (Sciagen_Account__c h : hcps) rows.add(new CVR_Attendee__c(CVR__c = c.Id, HCP__c = h.Id));
        System.runAs(rep) { insert rows; }
        return rows;
    }

    private static List<Call_Visit_Report__c> attendeeCalls(Id groupCallId) {
        return [SELECT Id, HCP__c, OwnerId, Parent_Call__c, Is_Group_Call__c, Group_Attendee_Count__c, Record_Status__c,
                       Visit_Date__c, Start_Time__c, End_Time__c, Activity_Type__c, Call_Type__c, Call_Status__c,
                       Discussion_Summary__c, Next_Visit_Date__c, Source_Planned_Call__c
                FROM Call_Visit_Report__c WHERE Parent_Call__c = :groupCallId ORDER BY HCP__r.Name];
    }

    private static String dmlError(User u, SObject row, Boolean isDelete) {
        String error;
        System.runAs(u) {
            try { if (isDelete) delete row; else update row; } catch (DmlException e) { error = e.getDmlMessage(0); }
        }
        return error;
    }

    @isTest static void addingAttendeesCreatesAnIndividualCallForEach() {
        User r = rep();
        Sciagen_Account__c a = doctor(r, 'Dr Grp A'), b = doctor(r, 'Dr Grp B'), c = doctor(r, 'Dr Grp C');
        Call_Visit_Report__c g = call(r, a, 'Saved');
        Test.startTest();
        List<CVR_Attendee__c> rows = attend(r, g, new List<Sciagen_Account__c>{ a, b, c });
        Test.stopTest();

        Call_Visit_Report__c groupCall = [SELECT Is_Group_Call__c, Group_Attendee_Count__c, Parent_Call__c FROM Call_Visit_Report__c WHERE Id = :g.Id];
        System.assertEquals(true, groupCall.Is_Group_Call__c);
        System.assertEquals(3, groupCall.Group_Attendee_Count__c);
        System.assertEquals(null, groupCall.Parent_Call__c);

        List<Call_Visit_Report__c> children = attendeeCalls(g.Id);
        System.assertEquals(2, children.size(), 'one call per attendee other than the primary HCP');
        System.assertEquals(b.Id, children[0].HCP__c);
        System.assertEquals(c.Id, children[1].HCP__c);
        for (Call_Visit_Report__c ch : children) {
            System.assertEquals(true, ch.Is_Group_Call__c);
            System.assertEquals(3, ch.Group_Attendee_Count__c);
            System.assertEquals(r.Id, ch.OwnerId, 'the rep owns the attendee calls');
            System.assertEquals('Saved', ch.Record_Status__c);
            System.assertEquals(Date.today(), ch.Visit_Date__c);
            System.assertEquals('In-person', ch.Activity_Type__c);
            System.assertEquals('Detailing', ch.Call_Type__c);
            System.assertEquals('Completed', ch.Call_Status__c);
            System.assertEquals('Group CME discussion.', ch.Discussion_Summary__c);
        }

        Map<Id, Id> childByHcp = new Map<Id, Id>();
        for (CVR_Attendee__c row : [SELECT HCP__c, Child_Call__c FROM CVR_Attendee__c WHERE CVR__c = :g.Id]) childByHcp.put(row.HCP__c, row.Child_Call__c);
        System.assertEquals(null, childByHcp.get(a.Id), 'the primary HCP has the group call itself');
        System.assertEquals(children[0].Id, childByHcp.get(b.Id));
        System.assertEquals(children[1].Id, childByHcp.get(c.Id));

        // The rep sees the attendee calls (they own them).
        System.runAs(r) {
            System.assertEquals(2, [SELECT COUNT() FROM Call_Visit_Report__c WHERE Parent_Call__c = :g.Id WITH USER_MODE]);
        }
    }

    @isTest static void singleHcpCallIsNotAGroupCall() {
        User r = rep();
        Sciagen_Account__c a = doctor(r, 'Dr Solo');
        Call_Visit_Report__c g = call(r, a, 'Saved');
        attend(r, g, new List<Sciagen_Account__c>{ a });
        System.assertEquals(false, [SELECT Is_Group_Call__c FROM Call_Visit_Report__c WHERE Id = :g.Id].Is_Group_Call__c);
        System.assertEquals(0, attendeeCalls(g.Id).size());
    }

    @isTest static void groupCallChangesAndSubmitFlowDownAndAttendeeCallsAreLocked() {
        User r = rep();
        Sciagen_Account__c a = doctor(r, 'Dr Grp D'), b = doctor(r, 'Dr Grp E');
        Call_Visit_Report__c g = call(r, a, 'Saved');
        attend(r, g, new List<Sciagen_Account__c>{ a, b });

        Test.startTest();
        System.assertEquals(null, dmlError(r, new Call_Visit_Report__c(Id = g.Id, Discussion_Summary__c = 'Updated.',
            Activity_Type__c = 'Video', Record_Status__c = 'Submitted'), false));
        Test.stopTest();

        Call_Visit_Report__c child = attendeeCalls(g.Id)[0];
        System.assertEquals('Submitted', child.Record_Status__c);
        System.assertEquals('Updated.', child.Discussion_Summary__c);
        System.assertEquals('Video', child.Activity_Type__c);

        String error = dmlError(r, new Call_Visit_Report__c(Id = child.Id, Discussion_Summary__c = 'Edited directly'), false);
        System.assertNotEquals(null, error, 'an attendee call follows its group call only');
        error = dmlError(r, new Call_Visit_Report__c(Id = child.Id), true);
        System.assertNotEquals(null, error, 'an attendee call can not be deleted on its own');
        System.assertEquals(1, attendeeCalls(g.Id).size());
    }

    @isTest static void attendeeCallIsGuardedEvenBeforeSubmit() {
        User r = rep();
        Sciagen_Account__c a = doctor(r, 'Dr Grp F'), b = doctor(r, 'Dr Grp G');
        Call_Visit_Report__c g = call(r, a, 'Saved');
        attend(r, g, new List<Sciagen_Account__c>{ a, b });
        Call_Visit_Report__c child = attendeeCalls(g.Id)[0];
        String error = dmlError(r, new Call_Visit_Report__c(Id = child.Id, Visit_Date__c = Date.today().addDays(-1)), false);
        System.assert(error != null && error.contains('group call'), error);
        error = dmlError(r, new Call_Visit_Report__c(Id = child.Id, Parent_Call__c = null), false);
        System.assertNotEquals(null, error, 'the group link can not be cut');
    }

    @isTest static void submittedGroupCallPushedBeforeItsAttendees() {
        // The iPad PATCHes the (already Submitted) report first, then inserts its attendees.
        User r = rep();
        Sciagen_Account__c a = doctor(r, 'Dr Grp H'), b = doctor(r, 'Dr Grp I');
        Call_Visit_Report__c g = call(r, a, 'Submitted');
        Test.startTest();
        attend(r, g, new List<Sciagen_Account__c>{ a, b });
        Test.stopTest();
        List<Call_Visit_Report__c> children = attendeeCalls(g.Id);
        System.assertEquals(1, children.size());
        System.assertEquals('Submitted', children[0].Record_Status__c);
        System.assertEquals(true, [SELECT Is_Group_Call__c FROM Call_Visit_Report__c WHERE Id = :g.Id].Is_Group_Call__c,
            'flagging a submitted group call is automation, not a rep edit');
        // An identical re-save of the submitted group call (iPad retry) still passes.
        System.assertEquals(null, dmlError(r, new Call_Visit_Report__c(Id = g.Id, Discussion_Summary__c = 'Group CME discussion.'), false));
    }

    @isTest static void removingAnAttendeeRemovesTheirCall() {
        User r = rep();
        Sciagen_Account__c a = doctor(r, 'Dr Grp J'), b = doctor(r, 'Dr Grp K'), c = doctor(r, 'Dr Grp L');
        Call_Visit_Report__c g = call(r, a, 'Saved');
        List<CVR_Attendee__c> rows = attend(r, g, new List<Sciagen_Account__c>{ a, b, c });
        Test.startTest();
        System.runAs(r) { delete rows[2]; }
        System.assertEquals(1, attendeeCalls(g.Id).size());
        System.assertEquals(2, [SELECT Group_Attendee_Count__c FROM Call_Visit_Report__c WHERE Id = :g.Id].Group_Attendee_Count__c);
        System.runAs(r) { delete rows[1]; }
        Test.stopTest();
        System.assertEquals(0, attendeeCalls(g.Id).size());
        Call_Visit_Report__c after = [SELECT Is_Group_Call__c, Group_Attendee_Count__c FROM Call_Visit_Report__c WHERE Id = :g.Id];
        System.assertEquals(false, after.Is_Group_Call__c, 'back to an ordinary one-to-one call');
        System.assertEquals(null, after.Group_Attendee_Count__c);
    }

    @isTest static void changingAnAttendeeRepointsTheirCall() {
        User r = rep();
        Sciagen_Account__c a = doctor(r, 'Dr Grp M'), b = doctor(r, 'Dr Grp N'), c = doctor(r, 'Dr Grp O');
        Call_Visit_Report__c g = call(r, a, 'Saved');
        List<CVR_Attendee__c> rows = attend(r, g, new List<Sciagen_Account__c>{ a, b });
        Test.startTest();
        System.runAs(r) { update new CVR_Attendee__c(Id = rows[1].Id, HCP__c = c.Id); }
        Test.stopTest();
        List<Call_Visit_Report__c> children = attendeeCalls(g.Id);
        System.assertEquals(1, children.size());
        System.assertEquals(c.Id, children[0].HCP__c);
    }

    @isTest static void deletingAGroupCallRemovesItsAttendeeCalls() {
        User r = rep();
        Sciagen_Account__c a = doctor(r, 'Dr Grp P'), b = doctor(r, 'Dr Grp Q');
        Call_Visit_Report__c g = call(r, a, 'Saved');
        attend(r, g, new List<Sciagen_Account__c>{ a, b });
        System.assertEquals(1, attendeeCalls(g.Id).size());
        Test.startTest();
        System.assertEquals(null, dmlError(r, new Call_Visit_Report__c(Id = g.Id), true));
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM Call_Visit_Report__c WHERE HCP__c = :b.Id]);
    }

    @isTest static void followUpAndPlanStayOnTheGroupCall() {
        User r = rep();
        Sciagen_Account__c a = doctor(r, 'Dr Grp R'), b = doctor(r, 'Dr Grp S');
        Call_Visit_Report__c g = call(r, a, 'Saved');
        attend(r, g, new List<Sciagen_Account__c>{ a, b });
        Call_Visit_Report__c child = attendeeCalls(g.Id)[0];
        System.assertEquals(null, child.Next_Visit_Date__c);
        System.assertEquals(null, child.Source_Planned_Call__c, 'plan vs actual counts the group call once');
    }
}