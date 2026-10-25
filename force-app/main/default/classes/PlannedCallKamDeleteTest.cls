@isTest
private class PlannedCallKamDeleteTest {

    private static User kamUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Key Account Manager' LIMIT 1];
        User u = new User(FirstName = 'Kam', LastName = 'DeleteGuardTest', Alias = 'kamdg', Email = 'kam.deleteguard@sciagen-test.invalid',
            Username = 'kam.deleteguard@sciagen-new-dev.invalid', TimeZoneSidKey = 'Asia/Kolkata', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', ProfileId = p.Id, IsActive = true);
        insert u;
        return u;
    }

    @isTest
    static void kamCannotDeleteACompletedCall() {
        Sciagen_Account__c hcp = new Sciagen_Account__c(Name = 'Dr. Kam Delete Test', Type__c = 'HCP');
        insert hcp;
        User kam = kamUser();
        insert new Sciagen_Account__Share(ParentId = hcp.Id, UserOrGroupId = kam.Id, AccessLevel = 'Edit', RowCause = 'Manual');

        Planned_Call__c done = new Planned_Call__c(HCP__c = hcp.Id, Call_Type__c = 'Detailing',
            Call_DateTime__c = SciagenTestTime.nextBusinessSlot(), Status__c = 'Completed');
        Database.DeleteResult blocked;
        System.runAs(kam) {
            insert done; // owned by the KAM, so only the guard (not sharing) can stop the delete
            blocked = Database.delete(done.Id, false);
        }
        System.assert(!blocked.isSuccess(), 'A KAM must not be able to delete a Completed call');
        System.assert(blocked.getErrors()[0].getMessage().contains('completed call'),
            'Expected the completed-call message, got: ' + blocked.getErrors()[0].getMessage());
        System.assertEquals(1, [SELECT COUNT() FROM Planned_Call__c WHERE Id = :done.Id]);

        // Admin (non-KAM) is unaffected by this rule.
        delete done;
        System.assertEquals(0, [SELECT COUNT() FROM Planned_Call__c WHERE Id = :done.Id]);
    }
}