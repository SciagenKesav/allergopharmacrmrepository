@isTest
private class SampleEligibilityServiceTest {

    static SampleEligibilityService.Request request(Sciagen_Account__c d, Product__c p, Integer qty) {
        SampleEligibilityService.Request r = new SampleEligibilityService.Request();
        r.repUserId = UserInfo.getUserId();
        r.hcpAccountId = d.Id;
        r.productId = p.Id;
        r.quantity = qty;
        return r;
    }

    @isTest
    static void aVerifiedDoctorWithStockIsEligibleAndTheSoonestExpiringLotIsChosen() {
        Product__c p = SampleTestData.product('FEFO SKU');
        Sciagen_Account__c d = SampleTestData.doctor('Dr Fefo');
        Sample_Lot__c later = SampleTestData.lot(p, 'LATE', 20, 300);
        Sample_Lot__c sooner = SampleTestData.lot(p, 'SOON', 20, 90);
        SampleEligibilityService.Result r = SampleEligibilityService.check(request(d, p, 2));
        System.assertEquals('Eligible', r.status);
        System.assertEquals(sooner.Id, r.lotId, 'first expiry first out');
        System.assertEquals('SOON', r.lotNumber);
        System.assertEquals(true, r.requiresSignature);
    }

    @isTest
    static void lotWithTooLittleStockIsSkippedForOneThatCoversTheQuantity() {
        Product__c p = SampleTestData.product('Cover SKU');
        Sciagen_Account__c d = SampleTestData.doctor('Dr Cover');
        SampleTestData.lot(p, 'TINY', 1, 60);
        Sample_Lot__c big = SampleTestData.lot(p, 'BIG', 20, 200);
        System.assertEquals(big.Id, SampleEligibilityService.check(request(d, p, 3)).lotId);
    }

    @isTest
    static void licenceProblemsBlock() {
        Product__c p = SampleTestData.product('Licence SKU');
        SampleTestData.lot(p, 'L-1', 20, 200);
        Sciagen_Account__c unverified = SampleTestData.doctor('Dr Unverified');
        unverified.License_Verification_Status__c = 'Unverified';
        update unverified;
        SampleEligibilityService.Result r1 = SampleEligibilityService.check(request(unverified, p, 1));
        System.assertEquals('Blocked', r1.status);
        System.assert(r1.message.contains('unverified'), r1.message);

        Sciagen_Account__c expired = SampleTestData.doctor('Dr Expired');
        expired.License_Expiry_Date__c = Date.today().addDays(-1);
        update expired;
        System.assert(SampleEligibilityService.check(request(expired, p, 1)).message.contains('expired'));

        Sciagen_Account__c nurse = SampleTestData.doctor('Dr Not Prescriber');
        nurse.Can_Prescribe__c = false;
        update nurse;
        System.assert(SampleEligibilityService.check(request(nurse, p, 1)).message.contains('not qualified'));

        Product__c noCheck = SampleTestData.product('No Licence Check SKU');
        noCheck.Requires_License_Validation__c = false;
        update noCheck;
        SampleTestData.lot(noCheck, 'L-2', 20, 200);
        System.assertNotEquals('Blocked', SampleEligibilityService.check(request(unverified, noCheck, 1)).status);
    }

    @isTest
    static void restrictedAndNonSampleProductsAreBlocked() {
        Sciagen_Account__c d = SampleTestData.doctor('Dr Restrict');
        Product__c restricted = new Product__c(Name = 'Sleep SKU', Product_Code__c = 'SMP-SLEEP', Level__c = 'SKU', Is_Sample_Product__c = true, Sample_Unit_Value_INR__c = 5,
            Is_Restricted__c = true, Restriction_Reason__c = 'Hypnotic_Sedative_Tranquillizer', Max_Packs_Per_HCP_Per_Year__c = 0);
        insert restricted;
        SampleEligibilityService.Result r = SampleEligibilityService.check(request(d, restricted, 1));
        System.assertEquals('Blocked', r.status);
        System.assert(r.message.contains('Clause 5.1(ii)(f)'), r.message);
        Product__c detailOnly = new Product__c(Name = 'Detail SKU', Product_Code__c = 'SMP-DETAIL', Level__c = 'SKU');
        insert detailOnly;
        System.assert(SampleEligibilityService.check(request(d, detailOnly, 1)).message.contains('not set up as a sample product'));
    }

    @isTest
    static void noStockExpiredAndColdChainBreachBlockAndExpirySoonWarns() {
        Sciagen_Account__c d = SampleTestData.doctor('Dr Stock');
        Product__c none = SampleTestData.product('No Stock SKU');
        System.assert(SampleEligibilityService.check(request(d, none, 1)).message.contains('no active lot'));

        Product__c soon = SampleTestData.product('Soon SKU');
        SampleTestData.lot(soon, 'SOON-1', 20, 10);
        SampleEligibilityService.Result w = SampleEligibilityService.check(request(d, soon, 1));
        System.assertEquals('Warning', w.status);
        System.assert(w.message.contains('expires'), w.message);

        Product__c cold = SampleTestData.product('Cold Eligibility SKU');
        cold.Requires_Cold_Chain__c = true;
        update cold;
        Sample_Lot__c breached = SampleTestData.lot(cold, 'COLD-1', 20, 200);
        breached.Cold_Chain_Status__c = 'Breach';
        update breached;
        System.assert(SampleEligibilityService.check(request(d, cold, 1)).message.contains('Cold chain breach'));

        Product__c few = SampleTestData.product('Few SKU');
        SampleTestData.lot(few, 'FEW-1', 2, 200);
        SampleEligibilityService.Result f = SampleEligibilityService.check(request(d, few, 5));
        System.assertEquals('Warning', f.status);
        System.assert(f.message.contains('Only 2 packs'), f.message);
    }

    @isTest
    static void controlledSubstanceNeedsAScheduleLicenceOnTheDoctor() {
        Product__c c = SampleTestData.product('Controlled Elig SKU');
        c.Is_Controlled_Substance__c = true;
        c.Controlled_Substance_Schedule__c = 'H1';
        update c;
        SampleTestData.lot(c, 'CT-1', 20, 200);
        Sciagen_Account__c d = SampleTestData.doctor('Dr Controlled');
        System.assert(SampleEligibilityService.check(request(d, c, 1)).message.contains('drug-schedule licence'));
        d.Controlled_Substance_License__c = 'CDL-42';
        update d;
        System.assertNotEquals('Blocked', SampleEligibilityService.check(request(d, c, 1)).status);
    }

    @isTest
    static void sampleOptInIsAWarningUnlessConfiguredAsAHardBlock() {
        Product__c p = SampleTestData.product('OptIn SKU');
        SampleTestData.lot(p, 'OI-1', 20, 200);
        Sciagen_Account__c d = SampleTestData.doctor('Dr OptIn');
        System.assertEquals('Eligible', SampleEligibilityService.check(request(d, p, 1)).status, 'not required by default');
        insert new UCPMP_Tenant_Config__c(SetupOwnerId = UserInfo.getOrganizationId(), Require_Sample_Opt_In__c = true, Sample_Opt_In_Hard_Block__c = false,
            UCPMP_Compliance_Enabled__c = true, Enforce_Sample_Rules__c = true);
        SampleEligibilityService.Result w = SampleEligibilityService.check(request(d, p, 1));
        System.assertEquals('Warning', w.status);
        System.assert(w.message.contains('opt-in'), w.message);
        insert new Consent__c(HCP__c = d.Id, Consent_Purpose__c = 'Sample_Opt_In', Sample_Opt_In_Valid_Until__c = Date.today().addMonths(6));
        System.assertEquals('Eligible', SampleEligibilityService.check(request(d, p, 1)).status);
        UCPMP_Tenant_Config__c cfg = UCPMP_Tenant_Config__c.getOrgDefaults();
        delete [SELECT Id FROM Consent__c];
        cfg.Sample_Opt_In_Hard_Block__c = true;
        update cfg;
        System.assertEquals('Blocked', SampleEligibilityService.check(request(d, p, 1)).status);
    }
}