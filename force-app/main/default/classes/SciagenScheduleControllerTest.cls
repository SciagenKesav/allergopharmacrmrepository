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

        Product__c product = new Product__c(Product_Code__c = 'T-SSCT-1', Name = 'Schedule Test Product', Brand_Name__c = 'Emrok', Division__c = 'Cardiology');
        insert product;

        Custom_List__c customList = new Custom_List__c(List_Name__c = 'Schedule Test List');
        insert customList;
        insert new Custom_List_Member__c(List__c = customList.Id, HCP__c = hcp.Id);

        // PlannedCallScheduleGuard rejects Sunday/outside-business-hours calls,
        // so "now" can't be used blindly -- it must land within the ±1 day
        // window getMyPlannedCallsReturnsOnlyInRangeRowsForTheOwningUser
        // expects AND be a real weekday business-hours moment. Of any 3
        // consecutive days at most 1 is a Sunday, so today/yesterday/tomorrow
        // always has a safe pick.
        Datetime safeInRangeCall = nearestNonSundayAt(0, 11);

        insert new List<Planned_Call__c>{
            new Planned_Call__c(
                HCP__c = hcp.Id, HCO__c = hco.Id, Call_DateTime__c = safeInRangeCall,
                Duration_Min__c = 45, Call_Type__c = 'Detailing', Status__c = 'Planned', Product__c = product.Id
            ),
            new Planned_Call__c(
                HCO__c = hco.Id, Call_DateTime__c = nearestNonSundayAt(-30, 11),
                Duration_Min__c = 30, Call_Type__c = 'Visit', Status__c = 'Completed'
            )
        };
    }

    private static Datetime nearestNonSundayAt(Integer dayOffset, Integer hour) {
        Date d = Date.today().addDays(dayOffset);
        Datetime candidate = Datetime.newInstance(d, Time.newInstance(hour, 0, 0, 0));
        if (candidate.format('EEEE') == 'Sunday') {
            d = d.addDays(1);
        }
        return Datetime.newInstance(d, Time.newInstance(hour, 0, 0, 0));
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

    @isTest
    static void getMyPlannedCallsReturnsOnlyInRangeRowsForTheOwningUser() {
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
    }

    @isTest
    static void getOpenPlannedCallsReturnsCallsWithoutAResultingReport() {
        Sciagen_Account__c hcp = [SELECT Id FROM Sciagen_Account__c WHERE Type__c = 'HCP' LIMIT 1];
        Call_Visit_Report__c cvr = new Call_Visit_Report__c(
            HCP__c = hcp.Id, Visit_Date__c = Date.today(), Call_Type__c = 'Detailing', Record_Status__c = 'Draft'
        );
        insert cvr;
        Planned_Call__c withReport = [SELECT Id FROM Planned_Call__c WHERE HCP__c = :hcp.Id LIMIT 1];
        withReport.Resulting_CVR__c = cvr.Id;
        update withReport;

        Test.startTest();
        List<SciagenScheduleController.OpenPlannedCallItem> items = SciagenScheduleController.getOpenPlannedCalls();
        Test.stopTest();

        for (SciagenScheduleController.OpenPlannedCallItem item : items) {
            System.assertNotEquals(withReport.Id, item.id, 'A planned call that already has a Resulting_CVR__c must not be offered as "open"');
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

    @isTest
    static void aWalkInReportWithNoPlannedCallAppearsAsACompletedReportOnlyItem() {
        Sciagen_Account__c hcp = [SELECT Id FROM Sciagen_Account__c WHERE Type__c = 'HCP' LIMIT 1];
        Call_Visit_Report__c walkIn = new Call_Visit_Report__c(
            HCP__c = hcp.Id, Visit_Date__c = Date.today(), Call_Type__c = 'Detailing', Record_Status__c = 'Submitted'
        );
        insert walkIn;

        Test.startTest();
        List<SciagenScheduleController.PlannedCallItem> items =
            SciagenScheduleController.getMyPlannedCalls(Date.today().addDays(-1), Date.today().addDays(1));
        Test.stopTest();

        SciagenScheduleController.PlannedCallItem found;
        for (SciagenScheduleController.PlannedCallItem i : items) {
            if (i.id == walkIn.Id) found = i;
        }
        System.assertNotEquals(null, found, 'A report with no planned call must be listed on the schedule');
        System.assertEquals(true, found.isReportOnly);
        System.assertEquals('Completed', found.status);
        System.assertEquals(walkIn.Id, found.resultingCVRId, 'The row must carry the report id so it can be opened');
        System.assertEquals(true, found.isLocked, 'A submitted report is locked');
        System.assertEquals('Dr. Schedule Test', found.hcpName);
    }

    @isTest
    static void aReportThatCameFromAPlannedCallIsNotListedTwice() {
        Sciagen_Account__c hcp = [SELECT Id FROM Sciagen_Account__c WHERE Type__c = 'HCP' LIMIT 1];
        Planned_Call__c source = [SELECT Id FROM Planned_Call__c WHERE HCP__c = :hcp.Id LIMIT 1];
        Call_Visit_Report__c fromPlan = new Call_Visit_Report__c(
            HCP__c = hcp.Id, Visit_Date__c = Date.today(), Call_Type__c = 'Detailing', Record_Status__c = 'Draft',
            Source_Planned_Call__c = source.Id
        );
        insert fromPlan;

        Test.startTest();
        List<SciagenScheduleController.PlannedCallItem> items =
            SciagenScheduleController.getMyPlannedCalls(Date.today().addDays(-1), Date.today().addDays(1));
        Test.stopTest();

        for (SciagenScheduleController.PlannedCallItem i : items) {
            System.assertNotEquals(fromPlan.Id, i.id, 'A report tied to a planned call is represented by that call, not as its own row');
            if (i.id == source.Id) {
                System.assertEquals(false, i.isReportOnly);
                System.assertEquals(fromPlan.Id, i.resultingCVRId, 'The planned call now points at its report (CVRPlannedCallLink trigger)');
            }
        }
    }

    // MARK: - Manager viewing a KAM's schedule

    @isTest
    static void isManagerOrHasManagerRoleIsFalseForAPlainKeyAccountManager() {
        // A System Administrator (View All Data) now counts as able to view KAM schedules,
        // so the "not a manager" case is a KAM with no manager-named role.
        Profile kamProfile = [SELECT Id FROM Profile WHERE Name = 'Key Account Manager' LIMIT 1];
        User kam = testUser('Schedule', 'PlainKam', kamProfile.Id);
        insert kam;
        System.runAs(kam) {
            System.assertEquals(false, SciagenScheduleController.isManagerOrHasManagerRole(),
                'A KAM is not on the Manager profile, has no manager-named role and no View All Data');
        }
    }

    @isTest
    static void isManagerOrHasManagerRoleIsTrueForAManagerProfileUser() {
        Profile managerProfile = [SELECT Id FROM Profile WHERE Name = 'Manager' LIMIT 1];
        User manager = testUser('Schedule', 'Manager', managerProfile.Id);
        insert manager;

        System.runAs(manager) {
            System.assertEquals(true, SciagenScheduleController.isManagerOrHasManagerRole());
        }
    }

    @isTest
    static void isManagerOrHasManagerRoleIsTrueForANonManagerProfileUserWithARegionManagerRole() {
        Profile kamProfile = [SELECT Id FROM Profile WHERE Name = 'Key Account Manager' LIMIT 1];
        UserRole regionManagerRole = [SELECT Id FROM UserRole WHERE Name = 'North Region Manager' LIMIT 1];
        User kamWithManagerRole = testUser('Schedule', 'RoleManager', kamProfile.Id);
        kamWithManagerRole.UserRoleId = regionManagerRole.Id;
        insert kamWithManagerRole;

        System.runAs(kamWithManagerRole) {
            System.assertEquals(true, SciagenScheduleController.isManagerOrHasManagerRole(),
                'A KAM-profile user in a "North Region Manager" role should still count as a manager for this feature');
        }
    }

    @isTest
    static void getKamUsersInMyTerritoryReturnsOnlyKamsInTheManagersTerritoryScope() {
        Territory__c parent = new Territory__c(Name = 'Schedule Zone', Territory_Code__c = 'SCHZ', Type__c = 'Region');
        insert parent;
        Territory__c child = new Territory__c(Name = 'Schedule Zone Child', Territory_Code__c = 'SCHZC', Type__c = 'Territory', Parent_Territory__c = parent.Id);
        insert child;
        Territory__c unrelated = new Territory__c(Name = 'Schedule Unrelated', Territory_Code__c = 'SCHU', Type__c = 'Territory');
        insert unrelated;

        Profile managerProfile = [SELECT Id FROM Profile WHERE Name = 'Manager' LIMIT 1];
        Profile kamProfile = [SELECT Id FROM Profile WHERE Name = 'Key Account Manager' LIMIT 1];
        User manager = testUser('Schedule', 'ManagerTwo', managerProfile.Id);
        User kamInScope = testUser('Schedule', 'KamInScope', kamProfile.Id);
        User kamOutOfScope = testUser('Schedule', 'KamOutOfScope', kamProfile.Id);
        insert new List<User>{ manager, kamInScope, kamOutOfScope };

        insert new List<User_Territory__c>{
            new User_Territory__c(User__c = manager.Id, Territory__c = parent.Id, Is_Primary__c = true),
            new User_Territory__c(User__c = kamInScope.Id, Territory__c = child.Id, Is_Primary__c = true),
            new User_Territory__c(User__c = kamOutOfScope.Id, Territory__c = unrelated.Id, Is_Primary__c = true)
        };

        List<SciagenScheduleController.KamUserOption> options;
        System.runAs(manager) {
            options = SciagenScheduleController.getKamUsersInMyTerritory();
        }

        System.assertEquals(1, options.size(), 'Only the KAM in the managers territory (or its descendants) should be returned');
        System.assertEquals(kamInScope.Id, options[0].id);
        System.assertEquals('Schedule Zone Child', options[0].territoryName);
    }

    @isTest
    static void getPlannedCallsForUserLetsAManagerViewAnInScopeKamsSchedule() {
        Sciagen_Account__c hcp = new Sciagen_Account__c(
            Type__c = 'HCP', Name = 'Dr. Manager View Test', Prefix__c = 'Dr.', First_Name__c = 'Manager',
            Last_Name__c = 'ViewTest', Specialty__c = 'Cardiology', HCP_Type__c = 'Physician'
        );
        insert hcp;

        Territory__c parent = new Territory__c(Name = 'Schedule View Zone', Territory_Code__c = 'SVZ', Type__c = 'Region');
        insert parent;
        Territory__c child = new Territory__c(Name = 'Schedule View Zone Child', Territory_Code__c = 'SVZC', Type__c = 'Territory', Parent_Territory__c = parent.Id);
        insert child;
        insert new Account_Territory__c(Name = 'Assignment', Account__c = hcp.Id, Territory__c = child.Id);

        Profile managerProfile = [SELECT Id FROM Profile WHERE Name = 'Manager' LIMIT 1];
        Profile kamProfile = [SELECT Id FROM Profile WHERE Name = 'Key Account Manager' LIMIT 1];
        User manager = testUser('Schedule', 'ViewManager', managerProfile.Id);
        User kam = testUser('Schedule', 'ViewKam', kamProfile.Id);
        // User and PermissionSetAssignment are setup objects; Apex forbids mixing them with
        // non-setup DML (accounts, territories) in one transaction, so each setup insert runs
        // inside its own System.runAs block.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new List<User>{ manager, kam };
        }
        insert new User_Territory__c(User__c = manager.Id, Territory__c = parent.Id, Is_Primary__c = true);
        insert new User_Territory__c(User__c = kam.Id, Territory__c = child.Id, Is_Primary__c = true);

        // Manager and Key Account Manager are both Salesforce Platform-license profiles,
        // which grant no object access at all until a permission set is assigned -- same
        // reasoning as RoleHierarchySharingTest borrowing the app's own mobile permission
        // set to give test users a normal working baseline, same as any real rep/manager.
        PermissionSet mobileAccess = [SELECT Id FROM PermissionSet WHERE Name = 'Sciagen_Mobile_App_Access' LIMIT 1];
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new List<PermissionSetAssignment>{
                new PermissionSetAssignment(AssigneeId = manager.Id, PermissionSetId = mobileAccess.Id),
                new PermissionSetAssignment(AssigneeId = kam.Id, PermissionSetId = mobileAccess.Id)
            };
        }

        Planned_Call__c call;
        System.runAs(kam) {
            call = new Planned_Call__c(
                HCP__c = hcp.Id, Call_DateTime__c = nearestNonSundayAt(0, 11),
                Duration_Min__c = 30, Call_Type__c = 'Detailing', Status__c = 'Planned'
            );
            insert call;
        }

        List<SciagenScheduleController.PlannedCallItem> items;
        System.runAs(manager) {
            Test.startTest();
            items = SciagenScheduleController.getPlannedCallsForUser(Date.today().addDays(-1), Date.today().addDays(1), kam.Id);
            Test.stopTest();
        }

        System.assertEquals(1, items.size(), 'The manager should see the in-scope KAM\'s planned call');
        System.assertEquals(call.Id, items[0].id);
    }

    @isTest
    static void getPlannedCallsForUserThrowsWhenTheRunningUserIsNotAManager() {
        Id someOtherUserId = UserInfo.getUserId(); // captured before runAs -- guaranteed different from otherKam
        Profile kamProfile = [SELECT Id FROM Profile WHERE Name = 'Key Account Manager' LIMIT 1];
        User otherKam = testUser('Schedule', 'NotAManager', kamProfile.Id);
        insert otherKam;

        System.runAs(otherKam) {
            try {
                SciagenScheduleController.getPlannedCallsForUser(Date.today(), Date.today(), someOtherUserId);
                System.assert(false, 'Expected an exception -- a non-manager cannot view another user\'s schedule');
            } catch (AuraHandledException e) {
                // expected
            }
        }
    }

    @isTest
    static void getPlannedCallsForUserThrowsWhenTheTargetKamIsOutsideTheManagersTerritory() {
        Territory__c managerTerritory = new Territory__c(Name = 'Schedule Guard Zone', Territory_Code__c = 'SGZ', Type__c = 'Region');
        insert managerTerritory;
        Territory__c otherTerritory = new Territory__c(Name = 'Schedule Guard Other', Territory_Code__c = 'SGO', Type__c = 'Territory');
        insert otherTerritory;

        Profile managerProfile = [SELECT Id FROM Profile WHERE Name = 'Manager' LIMIT 1];
        Profile kamProfile = [SELECT Id FROM Profile WHERE Name = 'Key Account Manager' LIMIT 1];
        User manager = testUser('Schedule', 'GuardManager', managerProfile.Id);
        User outOfScopeKam = testUser('Schedule', 'GuardKam', kamProfile.Id);
        insert new List<User>{ manager, outOfScopeKam };
        insert new User_Territory__c(User__c = manager.Id, Territory__c = managerTerritory.Id, Is_Primary__c = true);
        insert new User_Territory__c(User__c = outOfScopeKam.Id, Territory__c = otherTerritory.Id, Is_Primary__c = true);

        System.runAs(manager) {
            try {
                SciagenScheduleController.getPlannedCallsForUser(Date.today(), Date.today(), outOfScopeKam.Id);
                System.assert(false, 'Expected an exception -- the KAM is outside the manager\'s territory scope');
            } catch (AuraHandledException e) {
                // expected
            }
        }
    }

    @isTest
    static void systemAdministratorCanPickAnyKamAndViewTheirSchedule() {
        Profile kamProfile = [SELECT Id FROM Profile WHERE Name = 'Key Account Manager' LIMIT 1];
        User kam = testUser('Admin', 'ViewKam', kamProfile.Id);
        User kamNoTerritory = testUser('Admin', 'ViewKamNoTerr', kamProfile.Id);
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new List<User>{ kam, kamNoTerritory };
        }
        Territory__c terr = new Territory__c(Name = 'Admin View Zone', Territory_Code__c = 'AVZ', Type__c = 'Territory');
        insert terr;
        insert new User_Territory__c(User__c = kam.Id, Territory__c = terr.Id, Is_Primary__c = true);

        // The test runs as a System Administrator (View All Data) with no territory of their own.
        System.assertEquals(true, SciagenScheduleController.isManagerOrHasManagerRole());
        Boolean found = false;
        for (SciagenScheduleController.KamUserOption o : SciagenScheduleController.getKamUsersInMyTerritory()) {
            if (o.id == kam.Id) found = true;
        }
        System.assert(found, 'An administrator must be able to pick any KAM');
        Boolean foundNoTerritory = false;
        for (SciagenScheduleController.KamUserOption o : SciagenScheduleController.getKamUsersInMyTerritory()) {
            if (o.id == kamNoTerritory.Id) foundNoTerritory = true;
        }
        System.assert(foundNoTerritory, 'A KAM with no territory assigned yet must still be listed for an administrator');
        // And the cross-user read is authorised for that KAM.
        SciagenScheduleController.getPlannedCallsForUser(Date.today().addDays(-1), Date.today().addDays(1), kam.Id);
    }
}