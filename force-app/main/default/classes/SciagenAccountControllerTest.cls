@isTest
private class SciagenAccountControllerTest {

    @testSetup
    static void setup() {
        Sciagen_Account__c hcp = new Sciagen_Account__c(
            Type__c = 'HCP', Name = 'Dr. Anita Rao', Prefix__c = 'Dr.', First_Name__c = 'Anita', Last_Name__c = 'Rao',
            Specialty__c = 'Cardiology', HCP_Type__c = 'Physician', Phone__c = '9000000000',
            Email__c = 'anita.rao@example.com', License_Number__c = 'LIC-VERIFY', Licensing_Body__c = 'MCI',
            External_Ids__c = '{"MCI":"MCI-9001","NPI":"1000000001"}'
        );
        Sciagen_Account__c hco = new Sciagen_Account__c(
            Type__c = 'HCO', Name = 'Verify Test Hospital', HCO_Type__c = 'Hospital', Speciality__c = 'Other',
            Billing_Street__c = '1 Verify St', Billing_City__c = 'New Delhi', Billing_State__c = 'Delhi',
            Billing_Country__c = 'India', Billing_Postal_Code__c = '110001', Phone__c = '9111111111',
            Email__c = 'verify@testhospital.example.com', Website__c = 'https://verify.example.com'
        );
        Sciagen_Account__c hcp2 = new Sciagen_Account__c(
            Type__c = 'HCP', Name = 'Dr. Bhavna Iyer', Prefix__c = 'Dr.', First_Name__c = 'Bhavna', Last_Name__c = 'Iyer',
            Specialty__c = 'Oncology', HCP_Type__c = 'Consultant', Phone__c = '9000000002',
            Email__c = 'bhavna.iyer@example.com', Billing_City__c = 'Mumbai', Emerging_Expert__c = true
        );
        insert new List<Sciagen_Account__c>{ hcp, hco, hcp2 };

        Territory__c territory = new Territory__c(Name = 'North Delhi', Territory_Code__c = 'ND', Type__c = 'Territory');
        insert territory;
        insert new Account_Territory__c(Name = 'Assignment', Account__c = hcp.Id, Territory__c = territory.Id);

        insert new Affiliation__c(Name = 'Affiliation', HCP__c = hcp.Id, HCO__c = hco.Id);

        insert new Segmentation__c(
            Name = 'Segmentation - Dr. Anita Rao', HCP__c = hcp.Id, Classification__c = 'A',
            Tier__c = 'Gold', Priority__c = 'Priority 1', Potential__c = 'High', Is_KOL__c = true
        );

        insert new Publication__c(
            Name = 'Publication 1', HCP__c = hcp.Id, Title__c = 'Outcomes in Cardiology',
            PMID__c = '12345678', Publication_Date__c = '2026-01-15', Citations__c = 12,
            Publication_Type__c = 'Journal Article', Link__c = 'https://pubmed.example.com/12345678',
            Coauthors__c = 'Dr. Bhavna Iyer', Mesh_Terms__c = 'Cardiology'
        );
        insert new Congress_Event__c(
            Name = 'Congress', HCP__c = hcp.Id, Event_Name__c = 'CardioCon 2026',
            Start_Date__c = '2026-02-01', End_Date__c = '2026-02-03', Location__c = 'Mumbai', Role__c = 'Speaker',
            Organized_By__c = 'Cardiological Society', Topic__c = 'Interventional Cardiology', Link__c = 'https://cardiocon.example.com'
        );
        insert new Clinical_Trial__c(
            Name = 'Trial', HCP__c = hcp.Id, Title__c = 'A Study of Cardiac Outcomes',
            Registry_Id__c = 'NCT00000001', Registry__c = 'ClinicalTrials.gov', Phase__c = 'Phase III', Sponsor__c = 'Test Sponsor',
            Study_Type__c = 'Interventional', Condition__c = 'Coronary Artery Disease',
            Start_Date__c = '2025-06-01', Completion_Date__c = '2027-06-01',
            Locations__c = 'AIIMS Delhi', Endpoints__c = 'Major adverse cardiac events'
        );

        insert new Call_Visit_Report__c(
            HCP__c = hcp.Id, Visit_Date__c = Date.newInstance(2026, 1, 10), Call_Type__c = 'Detailing',
            Record_Status__c = 'Submitted', Rep__c = 'Verify Rep', Discussion_Summary__c = 'Discussed dosing.'
        );

        insert new Data_Change_Request__c(
            Subject_Account__c = hcp.Id, Subject_Name__c = 'Dr. Anita Rao', Type__c = 'Edit HCP',
            Status__c = 'Pending Approval', Summary__c = 'Update phone number.', Submitted_By__c = 'Verify Rep',
            Submitted_At__c = Datetime.newInstance(2026, 1, 12, 9, 0, 0)
        );

        insert new Office_Window__c(
            HCP__c = hcp.Id, HCO__c = hco.Id, Day__c = 'Mon', Window__c = '9:00 - 11:00 AM', Preference__c = 'Best'
        );
    }

    @isTest
    static void testSearchAccountsMatchesByName() {
        Test.startTest();
        List<SciagenAccountController.AccountSummary> results = SciagenAccountController.searchAccounts('Rao', null, null, null, null, null, null, null, null, null, null);
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Expected exactly one account matching "Rao"');
        System.assertEquals('Dr. Anita Rao', results[0].name);
        System.assertEquals('HCP', results[0].type);
        System.assertEquals('North Delhi', results[0].territory);
    }

    @isTest
    static void testSearchAccountsFilteredByType() {
        Test.startTest();
        List<SciagenAccountController.AccountSummary> hcpResults = SciagenAccountController.searchAccounts('', 'HCP', null, null, null, null, null, null, null, null, null);
        List<SciagenAccountController.AccountSummary> hcoResults = SciagenAccountController.searchAccounts('', 'HCO', null, null, null, null, null, null, null, null, null);
        Test.stopTest();

        System.assertEquals(2, hcpResults.size());
        System.assertEquals('HCP', hcpResults[0].type);
        System.assertEquals(1, hcoResults.size());
        System.assertEquals('HCO', hcoResults[0].type);
    }

    @isTest
    static void testSearchAccountsFilteredByTerritory() {
        Test.startTest();
        List<SciagenAccountController.AccountSummary> results = SciagenAccountController.searchAccounts('', null, 'North Delhi', null, null, null, null, null, null, null, null);
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Only the HCP has a territory assignment');
        System.assertEquals('Dr. Anita Rao', results[0].name);
    }

    @isTest
    static void testSearchAccountsNoMatchReturnsEmpty() {
        Test.startTest();
        List<SciagenAccountController.AccountSummary> results = SciagenAccountController.searchAccounts('NoSuchAccount', null, null, null, null, null, null, null, null, null, null);
        Test.stopTest();

        System.assertEquals(0, results.size());
    }

    @isTest
    static void testGetAccountDetailForHCPIncludesRelatedRecords() {
        Sciagen_Account__c hcp = [SELECT Id FROM Sciagen_Account__c WHERE Name = 'Dr. Anita Rao' LIMIT 1];

        Test.startTest();
        SciagenAccountController.AccountDetail detail = SciagenAccountController.getAccountDetail(hcp.Id);
        Test.stopTest();

        System.assertEquals('Dr. Anita Rao', detail.name);
        System.assertEquals('HCP', detail.type);
        System.assertEquals('North Delhi', detail.territory);
        System.assertNotEquals(null, detail.segmentation, 'HCP should have segmentation info');
        System.assertEquals('Gold', detail.segmentation.tier);
        System.assertEquals(1, detail.affiliations.size());
        System.assertEquals('Verify Test Hospital', detail.affiliations[0].name);
        System.assertEquals('HCO', detail.affiliations[0].type);
        System.assertEquals('9111111111', detail.affiliations[0].phone, 'Affiliation preview should carry the HCO\'s phone');
        System.assertEquals('New Delhi', detail.affiliations[0].city);
        System.assertEquals('https://verify.example.com', detail.affiliations[0].website);

        System.assertEquals(1, detail.publications.size());
        System.assertEquals('Outcomes in Cardiology', detail.publications[0].title);
        System.assertEquals('Journal Article', detail.publications[0].publicationType);
        System.assertEquals('https://pubmed.example.com/12345678', detail.publications[0].link);
        System.assertEquals('Dr. Bhavna Iyer', detail.publications[0].coauthors);
        System.assertEquals('Cardiology', detail.publications[0].meshTerms);

        System.assertEquals(1, detail.congressEvents.size());
        System.assertEquals('CardioCon 2026', detail.congressEvents[0].eventName);
        System.assertEquals('Cardiological Society', detail.congressEvents[0].organizedBy);
        System.assertEquals('Interventional Cardiology', detail.congressEvents[0].topic);

        System.assertEquals(1, detail.clinicalTrials.size());
        System.assertEquals('A Study of Cardiac Outcomes', detail.clinicalTrials[0].title);
        System.assertEquals('Interventional', detail.clinicalTrials[0].studyType);
        System.assertEquals('Coronary Artery Disease', detail.clinicalTrials[0].condition);
        System.assertEquals('AIIMS Delhi', detail.clinicalTrials[0].locations);

        System.assertEquals(1, detail.callVisitReports.size());
        System.assertEquals('Detailing', detail.callVisitReports[0].callType);
        System.assertEquals('Submitted', detail.callVisitReports[0].status);
        System.assertNotEquals(null, detail.lastVisit, 'lastVisit should be set from the CVR');
        System.assertNotEquals(null, detail.lastModified);
        System.assertEquals('MCI-9001', detail.externalIds.get('MCI'));
        System.assertEquals('1000000001', detail.externalIds.get('NPI'));

        System.assertEquals(1, detail.dataChangeRequests.size());
        System.assertEquals('Edit HCP', detail.dataChangeRequests[0].type);
        System.assertEquals('Pending Approval', detail.dataChangeRequests[0].status);

        System.assertEquals(1, detail.officeWindows.size());
        System.assertEquals('Mon', detail.officeWindows[0].day);
        System.assertEquals('9:00 - 11:00 AM', detail.officeWindows[0].timeWindow);
        System.assertEquals('Best', detail.officeWindows[0].preference);
        System.assertEquals('Verify Test Hospital', detail.officeWindows[0].hcoName);

        System.assertEquals(2, detail.timeline.size(), 'Expected one CVR entry and one DCR entry in the timeline');
        System.assertEquals('DCR', detail.timeline[0].kind, 'The DCR (Jan 12) is more recent than the CVR (Jan 10)');
        System.assertEquals('CVR', detail.timeline[1].kind);
    }

    @isTest
    static void testGetAccountDetailForHCOIncludesAffiliatedHCPs() {
        Sciagen_Account__c hco = [SELECT Id FROM Sciagen_Account__c WHERE Type__c = 'HCO' LIMIT 1];

        Test.startTest();
        SciagenAccountController.AccountDetail detail = SciagenAccountController.getAccountDetail(hco.Id);
        Test.stopTest();

        System.assertEquals('Verify Test Hospital', detail.name);
        System.assertEquals('HCO', detail.type);
        System.assertEquals(null, detail.segmentation, 'HCO should not have segmentation info');
        System.assertEquals(1, detail.affiliations.size());
        System.assertEquals('Dr. Anita Rao', detail.affiliations[0].name);
        System.assertEquals('HCP', detail.affiliations[0].type);
        System.assertEquals('9000000000', detail.affiliations[0].phone, 'Affiliation preview should carry the HCP\'s phone');
        System.assertEquals(0, detail.publications.size());
    }

    @isTest
    static void testGetAccountHierarchyReturnsParentChildrenAndAffiliatedHCPs() {
        Sciagen_Account__c hco = [SELECT Id FROM Sciagen_Account__c WHERE Type__c = 'HCO' LIMIT 1];
        Sciagen_Account__c parentHco = new Sciagen_Account__c(
            Type__c = 'HCO', Name = 'Verify Parent Health Group', HCO_Type__c = 'Hospital', Speciality__c = 'Other'
        );
        insert parentHco;
        hco.Parent_Account__c = parentHco.Id;
        update hco;

        Test.startTest();
        SciagenAccountController.HierarchyInfo childInfo = SciagenAccountController.getAccountHierarchy(hco.Id);
        SciagenAccountController.HierarchyInfo parentInfo = SciagenAccountController.getAccountHierarchy(parentHco.Id);
        Test.stopTest();

        System.assertEquals('Verify Test Hospital', childInfo.selfName);
        System.assertNotEquals(null, childInfo.parent, 'Should resolve the parent breadcrumb');
        System.assertEquals('Verify Parent Health Group', childInfo.parent.name);
        System.assertEquals(0, childInfo.children.size());
        System.assertEquals(1, childInfo.affiliatedHCPs.size());
        System.assertEquals('Dr. Anita Rao', childInfo.affiliatedHCPs[0].name);

        System.assertEquals('Verify Parent Health Group', parentInfo.selfName);
        System.assertEquals(null, parentInfo.parent, 'Top-level account should have no parent');
        System.assertEquals(1, parentInfo.children.size());
        System.assertEquals('Verify Test Hospital', parentInfo.children[0].name);
        System.assertEquals(0, parentInfo.affiliatedHCPs.size());
    }

    @isTest
    static void testGetTerritoryOptionsReturnsAllTerritories() {
        Test.startTest();
        List<String> options = SciagenAccountController.getTerritoryOptions();
        Test.stopTest();

        System.assertEquals(1, options.size());
        System.assertEquals('North Delhi', options[0]);
    }

    @isTest
    static void testSearchAccountsSortByNameDescending() {
        Test.startTest();
        List<SciagenAccountController.AccountSummary> results =
            SciagenAccountController.searchAccounts('', 'HCP', null, null, null, null, null, null, 'Name', false, null);
        Test.stopTest();

        System.assertEquals(2, results.size());
        System.assertEquals('Dr. Bhavna Iyer', results[0].name, 'Descending by name should put Iyer before Rao');
        System.assertEquals('Dr. Anita Rao', results[1].name);
    }

    @isTest
    static void testSearchAccountsKolOnlyFilter() {
        Test.startTest();
        List<SciagenAccountController.AccountSummary> results =
            SciagenAccountController.searchAccounts('', 'HCP', null, null, null, null, true, null, null, null, null);
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Only Dr. Anita Rao is a KOL');
        System.assertEquals('Dr. Anita Rao', results[0].name);
        System.assertEquals(true, results[0].isKOL);
    }

    @isTest
    static void testSearchAccountsEmergingOnlyFilter() {
        Test.startTest();
        List<SciagenAccountController.AccountSummary> results =
            SciagenAccountController.searchAccounts('', 'HCP', null, null, null, null, null, true, null, null, null);
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Only Dr. Bhavna Iyer is an emerging expert');
        System.assertEquals('Dr. Bhavna Iyer', results[0].name);
        System.assertEquals(true, results[0].isEmergingExpert);
    }

    @isTest
    static void testSearchAccountsCityFilter() {
        Test.startTest();
        List<SciagenAccountController.AccountSummary> results =
            SciagenAccountController.searchAccounts('', 'HCP', null, null, null, 'Mumbai', null, null, null, null, null);
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals('Dr. Bhavna Iyer', results[0].name);
    }

    @isTest
    static void testGetSpecialtyAndHCOTypeOptionsReturnActivePicklistValues() {
        Test.startTest();
        List<String> specialties = SciagenAccountController.getSpecialtyOptions();
        List<String> hcoTypes = SciagenAccountController.getHCOTypeOptions();
        Test.stopTest();

        System.assert(specialties.contains('Cardiology'), 'Expected the Specialty picklist to include Cardiology');
        System.assert(hcoTypes.contains('Hospital'), 'Expected the HCO Type picklist to include Hospital');
    }

    @isTest
    static void testSaveViewCreateUpdateAndDelete() {
        Test.startTest();
        Id viewId = SciagenAccountController.saveView(null, 'My HCPs', '{"typeFilter":"HCP"}', 'Name', true, 'List');
        List<SciagenAccountController.SavedViewItem> afterCreate = SciagenAccountController.getSavedViews();

        SciagenAccountController.saveView(viewId, 'My HCPs (Updated)', '{"typeFilter":"HCP"}', 'City', false, 'Table');
        List<SciagenAccountController.SavedViewItem> afterUpdate = SciagenAccountController.getSavedViews();

        SciagenAccountController.deleteSavedView(viewId);
        List<SciagenAccountController.SavedViewItem> afterDelete = SciagenAccountController.getSavedViews();
        Test.stopTest();

        System.assertEquals(1, afterCreate.size());
        System.assertEquals('My HCPs', afterCreate[0].viewName);

        System.assertEquals(1, afterUpdate.size());
        System.assertEquals('My HCPs (Updated)', afterUpdate[0].viewName);
        System.assertEquals('City', afterUpdate[0].sortField);
        System.assertEquals(false, afterUpdate[0].sortAscending);

        System.assertEquals(0, afterDelete.size());
    }

    @isTest
    static void testCustomListCreateAndAddAccountsIsIdempotent() {
        Sciagen_Account__c hcp = [SELECT Id FROM Sciagen_Account__c WHERE Name = 'Dr. Anita Rao' LIMIT 1];

        Test.startTest();
        Id listId = SciagenAccountController.createCustomList('Priority Follow-ups');
        SciagenAccountController.addAccountsToList(listId, new List<Id>{ hcp.Id });
        SciagenAccountController.addAccountsToList(listId, new List<Id>{ hcp.Id }); // re-add: must not duplicate
        Test.stopTest();

        List<Custom_List_Member__c> members = [SELECT Id FROM Custom_List_Member__c WHERE List__c = :listId];
        System.assertEquals(1, members.size(), 'Adding the same account twice should not create duplicate memberships');

        List<SciagenAccountController.CustomListItem> lists = SciagenAccountController.getCustomLists();
        System.assertEquals(1, lists.size());
        System.assertEquals('Priority Follow-ups', lists[0].listName);
    }

    @isTest
    static void testBusinessAdminSavedViewsAreVisibleToOtherUsersButPrivateOnesArentAdminUnaffected() {
        Profile businessAdmin = [SELECT Id FROM Profile WHERE Name = 'Business Admin' LIMIT 1];
        Profile standardUser = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User admin = new User(FirstName = 'Ops', LastName = 'Admin SavedViewTest', Alias = 'opsad', Email = 'ops.admin.savedview@sciagen-test.invalid',
            Username = 'ops.admin.savedview@sciagen-new-dev.invalid', TimeZoneSidKey = 'Asia/Kolkata', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', ProfileId = businessAdmin.Id, IsActive = true);
        User rep = new User(FirstName = 'Field', LastName = 'Rep SavedViewTest', Alias = 'fldrp', Email = 'field.rep.savedview@sciagen-test.invalid',
            Username = 'field.rep.savedview@sciagen-new-dev.invalid', TimeZoneSidKey = 'Asia/Kolkata', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', ProfileId = standardUser.Id, IsActive = true);
        insert new List<User>{ admin, rep };
        Id mobileAccessId = [SELECT Id FROM PermissionSet WHERE Name = 'Sciagen_Mobile_App_Access'].Id;
        insert new List<PermissionSetAssignment>{
            new PermissionSetAssignment(AssigneeId = admin.Id, PermissionSetId = mobileAccessId),
            new PermissionSetAssignment(AssigneeId = rep.Id, PermissionSetId = mobileAccessId)
        };

        System.runAs(admin) {
            SciagenAccountController.saveView(null, 'Org Standard - Cardiology', '{"specialties":["Cardiology"]}', 'Name', true, 'List');
        }
        System.assertEquals(1, [SELECT COUNT() FROM Saved_Filter__c WHERE Owner.Profile.Name = 'Business Admin'],
            'sanity check: the view should be owned by the Business Admin test user before checking who else can see it');
        List<SciagenAccountController.SavedViewItem> repViewsBeforeOwn;
        System.runAs(rep) {
            repViewsBeforeOwn = SciagenAccountController.getSavedViews();
            SciagenAccountController.saveView(null, 'My Personal Shortlist', '{"specialties":["Oncology"]}', 'Name', true, 'List');
        }

        Test.startTest();
        List<SciagenAccountController.SavedViewItem> repViewsAfterOwn;
        System.runAs(rep) {
            repViewsAfterOwn = SciagenAccountController.getSavedViews();
        }
        List<SciagenAccountController.SavedViewItem> adminViews;
        System.runAs(admin) {
            adminViews = SciagenAccountController.getSavedViews();
        }
        Test.stopTest();

        System.assertEquals(1, repViewsBeforeOwn.size(), 'The rep should already see the Business Admin\'s shared view even before creating their own');
        System.assertEquals('Org Standard - Cardiology', repViewsBeforeOwn[0].viewName);

        System.assertEquals(2, repViewsAfterOwn.size(), 'The rep should see both the admin\'s shared view and their own');
        Set<String> repViewNames = new Set<String>();
        for (SciagenAccountController.SavedViewItem item : repViewsAfterOwn) { repViewNames.add(item.viewName); }
        System.assert(repViewNames.contains('Org Standard - Cardiology'));
        System.assert(repViewNames.contains('My Personal Shortlist'));

        System.assertEquals(1, adminViews.size(), 'The admin should not see the rep\'s private saved view');
        System.assertEquals('Org Standard - Cardiology', adminViews[0].viewName);
    }
}