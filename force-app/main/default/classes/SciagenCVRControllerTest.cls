@isTest
private class SciagenCVRControllerTest {

    @testSetup
    static void setup() {
        Sciagen_Account__c hcp = new Sciagen_Account__c(
            Type__c = 'HCP', Name = 'Dr. CVR Test', Prefix__c = 'Dr.', First_Name__c = 'CVR',
            Last_Name__c = 'Test', Specialty__c = 'Cardiology', HCP_Type__c = 'Physician',
            Can_Prescribe__c = true, License_Number__c = 'MCI-CVR-1', License_Verification_Status__c = 'Verified', License_Expiry_Date__c = Date.today().addYears(2)
        );
        Sciagen_Account__c hco = new Sciagen_Account__c(
            Type__c = 'HCO', Name = 'CVR Test Hospital', HCO_Type__c = 'Hospital', Speciality__c = 'Other'
        );
        insert new List<Sciagen_Account__c>{ hcp, hco };

        Territory__c territory = new Territory__c(Name = 'CVR Test Territory', Territory_Code__c = 'CTT', Type__c = 'Territory');
        insert territory;
        insert new Account_Territory__c(Name = 'Assignment', Account__c = hcp.Id, Territory__c = territory.Id);

        Call_Visit_Report__c inRange = new Call_Visit_Report__c(
            HCP__c = hcp.Id, HCO__c = hco.Id, Visit_Date__c = Date.today(),
            Call_Type__c = 'Detailing', Call_Status__c = 'Completed', Record_Status__c = 'Draft',
            Territory__c = territory.Id
        );
        Call_Visit_Report__c outOfRange = new Call_Visit_Report__c(
            HCP__c = hcp.Id, Visit_Date__c = Date.today().addDays(-30),
            Call_Type__c = 'Visit', Call_Status__c = 'Completed', Record_Status__c = 'Submitted'
        );
        insert new List<Call_Visit_Report__c>{ inRange, outOfRange };

        insert new Key_Message__c(
            CVR__c = inRange.Id, Message__c = 'Discussed efficacy data', Description__c = 'Positive response',
            Product__c = 'Emrok', Reaction__c = 'Positive', Locked__c = false
        );
        insert new Promo_Drop__c(CVR__c = inRange.Id, Item__c = 'Branded pen', Qty__c = 10);
        Product__c product = new Product__c(Product_Code__c = 'T-SCVRCT-1', Name = 'Emrok', Brand_Name__c = 'Emrok', Division__c = 'Cardiology', Is_Sample_Product__c = true, Requires_Signature__c = false, Sample_Unit_Value_INR__c = 10, Pack_Size__c = 4);
        insert product;
        SampleTestData.lot(product, 'CVR-LOT-1', 50, 200);
        insert new Sample_Drop__c(CVR__c = inRange.Id, Product__c = product.Id, Qty__c = 5);
        insert new CVR_Attendee__c(CVR__c = inRange.Id, HCP__c = hcp.Id);
        insert new CVR_Internal_Attendee__c(CVR__c = inRange.Id, User__c = UserInfo.getUserId());
        // Inserted out of order: the payload must come back by Priority__c.
        insert new List<CVR_Detail_Priority__c>{
            new CVR_Detail_Priority__c(CVR__c = inRange.Id, Product_Name__c = 'Glaritus', Priority__c = 2, Source__c = 'Manual'),
            new CVR_Detail_Priority__c(CVR__c = inRange.Id, Product__c = product.Id, Product_Name__c = 'Emrok', Priority__c = 1,
                Source__c = 'CLM', Time_Spent_Sec__c = 95, Slides_Shown__c = 4)
        };
    }

    @isTest
    static void getMyCallReportsReturnsOnlyInRangeRowsForTheOwningUser() {
        Sciagen_Account__c hcp = [SELECT Id FROM Sciagen_Account__c WHERE Type__c = 'HCP' LIMIT 1];
        Sciagen_Account__c hco = [SELECT Id FROM Sciagen_Account__c WHERE Type__c = 'HCO' LIMIT 1];

        Test.startTest();
        List<SciagenCVRController.CVRListItem> items = SciagenCVRController.getMyCallReports(
            Date.today().addDays(-1), Date.today().addDays(1), null
        );
        Test.stopTest();

        System.assertEquals(1, items.size(), 'Only the in-range CVR should be returned, not the one 30 days ago');
        SciagenCVRController.CVRListItem item = items[0];
        System.assertEquals(hcp.Id, item.hcpId);
        System.assertEquals('Dr. CVR Test', item.hcpName);
        System.assertEquals(hco.Id, item.hcoId);
        System.assertEquals('CVR Test Hospital', item.hcoName);
        System.assertEquals('Detailing', item.callType);
        System.assertEquals('Draft', item.recordStatus);
        System.assertEquals('CVR Test Territory', item.territoryName);
    }

    @isTest
    static void getCVRDetailReturnsHeaderAndAllChildLists() {
        Call_Visit_Report__c cvr = [SELECT Id FROM Call_Visit_Report__c WHERE Record_Status__c = 'Draft' LIMIT 1];

        Test.startTest();
        SciagenCVRController.CVRDetail detail = SciagenCVRController.getCVRDetail(cvr.Id);
        Test.stopTest();

        System.assertEquals('Dr. CVR Test', detail.hcpName);
        System.assertEquals('CVR Test Hospital', detail.hcoName);
        System.assertEquals('Detailing', detail.callType);
        System.assertEquals('CVR Test Territory', detail.territoryName);

        System.assertEquals(1, detail.keyMessages.size());
        System.assertEquals('Discussed efficacy data', detail.keyMessages[0].message);
        System.assertEquals('Positive', detail.keyMessages[0].reaction);
        System.assertEquals(false, detail.keyMessages[0].locked);

        System.assertEquals(1, detail.promoDrops.size());
        System.assertEquals('Branded pen', detail.promoDrops[0].item);
        System.assertEquals(10, detail.promoDrops[0].qty);

        System.assertEquals(1, detail.sampleDrops.size());
        System.assertEquals('Emrok', detail.sampleDrops[0].productName);
        System.assertEquals(5, detail.sampleDrops[0].qty);

        System.assertEquals(1, detail.attendees.size());
        System.assertEquals('Dr. CVR Test', detail.attendees[0].hcpName);

        System.assertEquals(1, detail.internalAttendees.size());
        System.assertEquals(UserInfo.getUserId(), detail.internalAttendees[0].userId);

        System.assertEquals(2, detail.detailPriorities.size());
        System.assertEquals('Emrok', detail.detailPriorities[0].productName);
        System.assertEquals(1, detail.detailPriorities[0].priority);
        System.assertEquals('CLM', detail.detailPriorities[0].source);
        System.assertEquals(95, detail.detailPriorities[0].timeSpentSec);
        System.assertEquals(4, detail.detailPriorities[0].slidesShown);
        System.assertNotEquals(null, detail.detailPriorities[0].productId);
        System.assertEquals('Glaritus', detail.detailPriorities[1].productName);
        System.assertEquals('Manual', detail.detailPriorities[1].source);
        System.assertEquals(null, detail.detailPriorities[1].productId);
    }

    @isTest
    static void submitCallReportLocksKeyMessagesAndSetsSubmittedStatus() {
        Call_Visit_Report__c cvr = [SELECT Id FROM Call_Visit_Report__c WHERE Record_Status__c = 'Draft' LIMIT 1];

        Test.startTest();
        SciagenCVRController.submitCallReport(cvr.Id);
        Test.stopTest();

        Call_Visit_Report__c updated = [SELECT Record_Status__c FROM Call_Visit_Report__c WHERE Id = :cvr.Id];
        System.assertEquals('Submitted', updated.Record_Status__c);

        List<Key_Message__c> keyMessages = [SELECT Locked__c FROM Key_Message__c WHERE CVR__c = :cvr.Id];
        System.assertEquals(1, keyMessages.size());
        System.assertEquals(true, keyMessages[0].Locked__c);
    }

    @isTest
    static void submitCallReportRejectsWhenNoAttendees() {
        Sciagen_Account__c hcp = [SELECT Id FROM Sciagen_Account__c WHERE Type__c = 'HCP' LIMIT 1];
        Call_Visit_Report__c cvr = new Call_Visit_Report__c(
            HCP__c = hcp.Id, Visit_Date__c = Date.today(), Call_Type__c = 'Detailing', Record_Status__c = 'Draft'
        );
        insert cvr;

        Test.startTest();
        try {
            SciagenCVRController.submitCallReport(cvr.Id);
            System.assert(false, 'Expected submitting a CVR with no attendees to be rejected');
        } catch (AuraHandledException e) {
            // AuraHandledException scrubs its message by default outside the
            // throwing context, but Record_Status__c staying 'Draft' below is
            // the real proof the submit was actually blocked.
        }
        Test.stopTest();

        Call_Visit_Report__c unchanged = [SELECT Record_Status__c FROM Call_Visit_Report__c WHERE Id = :cvr.Id];
        System.assertEquals('Draft', unchanged.Record_Status__c, 'Status must not change when the submit is rejected');
    }
}