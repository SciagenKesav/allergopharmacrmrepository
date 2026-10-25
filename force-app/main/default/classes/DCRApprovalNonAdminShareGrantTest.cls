/**
 * Reproduces the real production bug reported against DCR Review: a non-admin approver (a
 * Manager, same as any real KAM/steward) approving a "New HCP" DCR whose submitter is
 * assigned to a territory that the approver is ALSO assigned to. That overlap is exactly
 * what makes TerritorySharingService attempt to grant the approver a Manual share on the
 * brand-new Sciagen_Account__c from inside the same nested trigger chain the approval
 * itself runs in, which throws INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY.
 *
 * AccessLevel.SYSTEM_MODE alone does NOT fix this — confirmed empirically, including with
 * this test run completely in isolation. That error isn't a CRUD/FLS/sharing-rule check;
 * it's the sharing engine not having settled visibility yet for a parent record inserted
 * earlier in the same transaction, and neither `without sharing` nor SYSTEM_MODE covers it.
 * The actual fix is DeferredShareInsertQueueable: TerritorySharingService/
 * DCRTerritorySharingService/RCPAAuditTerritorySharingService now retry that specific
 * failure in a later transaction instead of throwing. Test.startTest()/stopTest() around
 * the approval call below flushes that queued job before the assertions run.
 */
@isTest
private class DCRApprovalNonAdminShareGrantTest {

    @isTest
    static void approvingNewHCP_asNonAdminApprover_doesNotThrowOnShareGrant() {
        Sciagen_Account__c hco = new Sciagen_Account__c(Name = 'Share Grant Test HCO', Type__c = 'HCO');
        insert hco;

        Territory__c territory = new Territory__c(Name = 'Share Grant Territory', Territory_Code__c = 'SGT', Type__c = 'Territory');
        insert territory;
        // Links the HCO to the territory so DCRTerritorySharingService can derive DCR
        // sharing for the approver through Related_HCO__c -> Territory -> User_Territory__c
        // — the same path that makes a real DCR visible/actionable to a KAM in production.
        insert new Account_Territory__c(Name = 'Test Link', Account__c = hco.Id, Territory__c = territory.Id);

        Profile managerProfile = [SELECT Id FROM Profile WHERE Name = 'Manager' LIMIT 1];
        User submitter = testUser('ShareGrant', 'Submitter', managerProfile.Id);
        User approver = testUser('ShareGrant', 'Approver', managerProfile.Id);
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new List<User>{ submitter, approver };
            insert new List<User_Territory__c>{
                new User_Territory__c(User__c = submitter.Id, Territory__c = territory.Id, Is_Primary__c = true),
                new User_Territory__c(User__c = approver.Id, Territory__c = territory.Id, Is_Primary__c = true)
            };
            insert new PermissionSetAssignment(AssigneeId = approver.Id, PermissionSetId = [
                SELECT Id FROM PermissionSet WHERE Name = 'Sciagen_Data_Steward' LIMIT 1
            ].Id);
        }

        Map<String, String> fields = new Map<String, String>{ 'firstName' => 'Share', 'lastName' => 'Grant' };
        Data_Change_Request__c dcr = new Data_Change_Request__c(
            Type__c = 'New HCP', Status__c = 'Pending Approval', Subject_Name__c = 'Dr. Share Grant',
            Related_HCO__c = hco.Id, Fields_Payload__c = JSON.serialize(fields),
            Submitted_By__c = submitter.Id, Submitted_At__c = Datetime.now()
        );
        insert dcr;

        System.runAs(approver) {
            Test.startTest();
            DCRReviewController.approveDCR(dcr.Id, null);
            Test.stopTest();
        }

        dcr = [SELECT Status__c, Subject_Account__c FROM Data_Change_Request__c WHERE Id = :dcr.Id];
        System.assertEquals('Approved', dcr.Status__c);

        List<Sciagen_Account__Share> shares = [
            SELECT UserOrGroupId FROM Sciagen_Account__Share
            WHERE ParentId = :dcr.Subject_Account__c AND RowCause = 'Manual'
        ];
        Set<Id> sharedWith = new Set<Id>();
        for (Sciagen_Account__Share s : shares) sharedWith.add(s.UserOrGroupId);
        System.assert(sharedWith.contains(approver.Id), 'The approver, sharing the submitter\'s territory, should have been granted a Manual share on the new account');
    }

    private static User testUser(String firstName, String lastName, Id profileId) {
        String uniq = firstName.toLowerCase() + '.' + lastName.toLowerCase() + '.' + Datetime.now().getTime();
        return new User(
            FirstName = firstName, LastName = lastName,
            Email = uniq + '@sciagen.invalid', Username = uniq + '@sciagen.invalid',
            Alias = firstName.left(1).toLowerCase() + lastName.left(4).toLowerCase(),
            TimeZoneSidKey = 'Asia/Kolkata', LocaleSidKey = 'en_IN',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', ProfileId = profileId
        );
    }
}