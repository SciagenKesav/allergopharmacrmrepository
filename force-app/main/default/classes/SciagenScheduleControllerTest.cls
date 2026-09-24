@isTest
private class SciagenScheduleControllerTest {

    @testSetup
    static void setup() {
        Sciagen_Account__c hcp = new Sciagen_Account__c(
            Type__c = 'HCP', Name = 'Dr. Schedule Test', Prefix__c = 'Dr.', First_Name__c = 'Schedule',
            Last_Name__c = 'Test', Specialty__c = 'Cardiology', HCP_Type__c = 'Physician'
        );
        Sciagen_Account__c hco = new Sciagen_Account__c(
            Type__c = 'HCO', Name = 'Schedule Test Hospital', HCO_Type__c = 'Hospital', Speciality__c = 'Other',
            Geolocation__Latitude__s = 28.6, Geolocation__Longitude__s = 77.2
        );
        insert new List<Sciagen_Account__c>{ hcp, hco };

        Territory__c territory = new Territory__c(Name = 'Schedule Test Territory', Territory_Code__c = 'STT', Type__c = 'Territory');
        insert territory;
        insert new Account_Territory__c(Name = 'Assignment', Account__c = hcp.Id, Territory__c = territory.Id);

        Product__c product = new Product__c(Name = 'Schedule Test Product', Brand_Name__c = 'Emrok', Division__c = 'Cardiology');
        insert product;

        Custom_List__c customList = new Custom_List__c(List_Name__c = 'Schedule Test List');
        insert customList;
        insert new Custom_List_Member__c(List__c = customList.Id, HCP__c = hcp.Id);

        // Fixed at 11 AM rather than Datetime.now() — office hours
        // (PlannedCallOfficeHoursValidator) would otherwise randomly reject
        // this insert depending on what time of day the test happens to run.
        Time safeTime = Time.newInstance(11, 0, 0, 0);
        insert new List<Planned_Call__c>{
            new Planned_Call__c(
                HCP__c = hcp.Id, HCO__c = hco.Id, Call_DateTime__c = Datetime.newInstance(Date.today(), safeTime),
                Duration_Min__c = 45, Call_Type__c = 'Detailing', Status__c = 'Planned', Product__c = product.Id
            ),
            new Planned_Call__c(
                HCO__c = hco.Id, Call_DateTime__c = Datetime.newInstance(Date.today().addDays(-30), safeTime),
                Duration_Min__c = 30, Call_Type__c = 'Visit', Status__c = 'Completed'
            )
        };
    }

    @isTest
    static void getMyPlannedCallsReturnsOnlyInRangeRows() {
        Sciagen_Account__c hcp = [SELECT Id FROM Sciagen_Account__c WHERE Type__c = 'HCP' LIMIT 1];
        Sciagen_Account__c hco = [SELECT Id FROM Sciagen_Account__c WHERE Type__c = 'HCO' LIMIT 1];

        Test.startTest();
        List<SciagenScheduleController.PlannedCallItem> items =
            SciagenScheduleController.getMyPlannedCalls(Date.today().addDays(-1), Date.today().addDays(1));
        Test.stopTest();

        System.assertEquals(1, items.size(), 'Only the in-range call should be returned, not the one 30 days ago');
        SciagenScheduleController.PlannedCallItem item = items[0];
        System.assertEquals(hcp.Id, item.hcpId);
        System.assertEquals('Dr. Schedule Test', item.hcpName);
        System.assertEquals('Cardiology', item.specialty);
        System.assertEquals('Schedule Test Territory', item.hcpTerritory);
        System.assertEquals(hco.Id, item.hcoId);
        System.assertEquals('Schedule Test Hospital', item.hcoName);
        System.assertEquals(28.6, item.latitude);
        System.assertEquals(77.2, item.longitude);
        System.assertEquals(45, item.durationMin);
        System.assertEquals('Detailing', item.callType);
        System.assertEquals('Planned', item.status);
        System.assertEquals('Schedule Test Product', item.productName);
        System.assertEquals(UserInfo.getUserId(), item.ownerId);
        System.assertEquals(true, item.isMine, 'The running user created this call, so isMine must be true');
    }

    /// Integration-level proof (PlannedCallTerritorySharingServiceTest covers
    /// the raw sharing computation) that a teammate assigned to the same
    /// territory as the call's HCP actually gets it back from
    /// getMyPlannedCalls() — not just their own calls.
    @isTest
    static void getMyPlannedCallsIncludesATeammatesCallInTheSameTerritory() {
        Sciagen_Account__c hcp = [SELECT Id FROM Sciagen_Account__c WHERE Type__c = 'HCP' LIMIT 1];
        Planned_Call__c teammateCall = [SELECT Id FROM Planned_Call__c WHERE HCP__c = :hcp.Id LIMIT 1];

        Profile standardProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String uniq = 'schedule.teammate.' + Datetime.now().getTime();
        User teammate = new User(
            FirstName = 'Schedule', LastName = 'Teammate',
            Email = uniq + '@sciagen.invalid', Username = uniq + '@sciagen.invalid',
            Alias = 'schtm', TimeZoneSidKey = 'Asia/Kolkata', LocaleSidKey = 'en_IN',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', ProfileId = standardProfile.Id
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert teammate;
            PermissionSet mobileAccess = [SELECT Id FROM PermissionSet WHERE Name = 'Sciagen_Mobile_App_Access' LIMIT 1];
            insert new PermissionSetAssignment(AssigneeId = teammate.Id, PermissionSetId = mobileAccess.Id);
        }
        Territory__c territory = [SELECT Id FROM Territory__c WHERE Name = 'Schedule Test Territory' LIMIT 1];
        insert new User_Territory__c(User__c = teammate.Id, Territory__c = territory.Id);

        System.runAs(teammate) {
            Test.startTest();
            List<SciagenScheduleController.PlannedCallItem> items =
                SciagenScheduleController.getMyPlannedCalls(Date.today().addDays(-1), Date.today().addDays(1));
            Test.stopTest();

            System.assertEquals(1, items.size(), 'The teammate must see the in-range call for their shared territory');
            System.assertEquals(teammateCall.Id, items[0].id);
            System.assertEquals(false, items[0].isMine, 'The call belongs to the other user, not the running one');
            System.assertNotEquals(null, items[0].ownerName, 'ownerName should identify whose call this is');
        }
    }

    @isTest
    static void getCustomListMemberIdsReturnsOnlyThatListsHCPs() {
        Sciagen_Account__c hcp = [SELECT Id FROM Sciagen_Account__c WHERE Type__c = 'HCP' LIMIT 1];
        Custom_List__c customList = [SELECT Id FROM Custom_List__c LIMIT 1];

        Test.startTest();
        List<Id> memberIds = SciagenScheduleController.getCustomListMemberIds(customList.Id);
        Test.stopTest();

        System.assertEquals(1, memberIds.size());
        System.assertEquals(hcp.Id, memberIds[0]);
    }
}