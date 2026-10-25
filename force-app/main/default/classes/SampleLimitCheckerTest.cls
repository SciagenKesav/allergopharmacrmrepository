@isTest
private class SampleLimitCheckerTest {

    @isTest
    static void financialYearRunsAprilToMarch() {
        System.assertEquals('2026-27', SampleLimitChecker.financialYear(Date.newInstance(2026, 4, 1)));
        System.assertEquals('2026-27', SampleLimitChecker.financialYear(Date.newInstance(2027, 3, 31)));
        System.assertEquals('2025-26', SampleLimitChecker.financialYear(Date.newInstance(2026, 3, 31)));
        System.assertEquals('2099-00', SampleLimitChecker.financialYear(Date.newInstance(2099, 6, 1)));
    }

    @isTest
    static void periodsAreCalculatedTheIndianWay() {
        Date d = Date.newInstance(2026, 9, 20);      // a Sunday in Q2 of FY 2026-27
        SampleLimitChecker.Period fy = SampleLimitChecker.periodFor('Financial_Year', d);
        System.assertEquals(Date.newInstance(2026, 4, 1), fy.startDate);
        System.assertEquals(Date.newInstance(2027, 4, 1), fy.endDate);
        SampleLimitChecker.Period q = SampleLimitChecker.periodFor('Quarterly', d);
        System.assertEquals(Date.newInstance(2026, 7, 1), q.startDate);
        System.assertEquals(Date.newInstance(2026, 10, 1), q.endDate);
        System.assertEquals(Date.newInstance(2027, 1, 1), SampleLimitChecker.periodFor('Quarterly', Date.newInstance(2027, 2, 10)).startDate);
        System.assertEquals(Date.newInstance(2026, 9, 1), SampleLimitChecker.periodFor('Monthly', d).startDate);
        System.assertEquals(Date.newInstance(2026, 9, 14), SampleLimitChecker.periodFor('Weekly', d).startDate, 'weeks start on Monday');
        System.assertEquals(Date.newInstance(2026, 8, 21), SampleLimitChecker.periodFor('Rolling_30', d).startDate);
        System.assertEquals(null, SampleLimitChecker.periodFor('Lifetime', d).startDate);
    }

    @isTest
    static void ucpmpTwelvePackLimitBlocksTheThirteenth() {
        SampleLimitSeeder.seedDefaults();
        Product__c p = SampleTestData.product('Cap SKU');
        Sciagen_Account__c d = SampleTestData.doctor('Dr Cap');
        Sample_Lot__c l = SampleTestData.lot(p, 'CAP-1', 100, 200);
        SampleTestData.given(p, l, d, 10);
        SampleLimitChecker.LimitCheckResult ok = SampleLimitChecker.checkLimits(UserInfo.getUserId(), d.Id, p.Id, 2, null);
        System.assertEquals(true, ok.allowed);
        System.assertEquals('Warning', ok.status, '12/12 is inside the limit but past the 80% warning line');
        SampleLimitChecker.LimitCheckResult over = SampleLimitChecker.checkLimits(UserInfo.getUserId(), d.Id, p.Id, 3, null);
        System.assertEquals(false, over.allowed);
        System.assertEquals('Blocked', over.status);
        System.assert(over.blockers[0].contains('Cannot distribute more'), over.blockers[0]);
        System.assert(over.blockers[0].contains('UCPMP 2024 Clause 5.1(ii)(b)'));
        System.assertEquals(false, over.overrideable, 'regulatory limits can not be overridden');
    }

    @isTest
    static void softLimitWarnsAndAsksForAReason() {
        SampleLimitSeeder.seedDefaults();
        Product__c p = SampleTestData.product('Soft SKU');
        Sciagen_Account__c d = SampleTestData.doctor('Dr Soft');
        SampleTestData.lot(p, 'SOFT-1', 100, 200);
        SampleLimitChecker.LimitCheckResult r = SampleLimitChecker.checkLimits(UserInfo.getUserId(), d.Id, p.Id, 3, null, 4, 4);
        System.assertEquals(true, r.allowed, 'the company per-call limit is soft');
        System.assertEquals(true, r.needsReason);
        System.assertEquals(true, r.overrideable);
        System.assert(r.warnings[0].contains('Give a reason'), r.warnings[0]);
    }

    @isTest
    static void increaseAndExemptOverridesApplyToCompanyLimitsOnly() {
        SampleLimitSeeder.seedDefaults();
        Product__c p = SampleTestData.product('Override SKU');
        Sciagen_Account__c d = SampleTestData.doctor('Dr Override');
        Sample_Lot__c l = SampleTestData.lot(p, 'OV-1', 100, 200);
        Sample_Limit__c perCall = [SELECT Id FROM Sample_Limit__c WHERE Limit_Scope__c = 'Per_Call'];
        System.assertEquals(true, SampleLimitChecker.checkLimits(UserInfo.getUserId(), d.Id, p.Id, 8, null).needsReason);
        // Activating an override needs Manage_Sample_Inventory.
        SampleAccess.testIsManager = true;
        insert new Sample_Limit_Override__c(Sample_Limit__c = perCall.Id, Override_Type__c = 'Increase', Override_Value__c = 10, Target_Account__c = d.Id,
            Reason__c = 'Launch event', Status__c = 'Active');
        insert new Sample_Limit_Override__c(Sample_Limit__c = perCall.Id, Override_Type__c = 'Exempt', Target_Account__c = d.Id, Reason__c = 'Trial site', Status__c = 'Active');
        SampleLimitChecker.LimitCheckResult raised = SampleLimitChecker.checkLimits(UserInfo.getUserId(), d.Id, p.Id, 8, null);
        System.assertEquals(false, raised.needsReason, 'the limit is now 10 for this doctor');
        System.assertEquals(false, SampleLimitChecker.checkLimits(UserInfo.getUserId(), d.Id, p.Id, 50, null).needsReason);

        Sample_Limit__c reg = [SELECT Id FROM Sample_Limit__c WHERE Is_Regulatory__c = true LIMIT 1];
        Database.SaveResult s = Database.insert(new Sample_Limit_Override__c(Sample_Limit__c = reg.Id, Override_Type__c = 'Exempt', Target_Account__c = d.Id, Reason__c = 'x', Status__c = 'Active'), false);
        System.assert(!s.isSuccess(), 'UCPMP limits can not be overridden');
    }

    @isTest
    static void overridesNeedAManagerToBecomeActiveAndExpireByDate() {
        SampleLimitSeeder.seedDefaults();
        Sciagen_Account__c d = SampleTestData.doctor('Dr Dates');
        Product__c p = SampleTestData.product('Dates SKU');
        Sample_Limit__c perCall = [SELECT Id FROM Sample_Limit__c WHERE Limit_Scope__c = 'Per_Call'];
        // Activating an override needs Manage_Sample_Inventory.
        SampleAccess.testIsManager = true;
        Sample_Limit_Override__c old = new Sample_Limit_Override__c(Sample_Limit__c = perCall.Id, Override_Type__c = 'Exempt', Target_Account__c = d.Id, Reason__c = 'past',
            Status__c = 'Active', Valid_From__c = Date.today().addDays(-30), Valid_To__c = Date.today().addDays(-1));
        insert old;
        System.assertEquals(true, SampleLimitChecker.checkLimits(UserInfo.getUserId(), d.Id, p.Id, 8, null).needsReason, 'an expired override does nothing');
        Sample_Limit_Override__c req = new Sample_Limit_Override__c(Sample_Limit__c = perCall.Id, Override_Type__c = 'Exempt', Target_Account__c = d.Id, Reason__c = 'now', Status__c = 'Pending');
        insert req;
        System.assertEquals(true, SampleLimitChecker.checkLimits(UserInfo.getUserId(), d.Id, p.Id, 8, null).needsReason, 'a pending request does nothing');
        req.Status__c = 'Active';
        update req;
        System.assertEquals(UserInfo.getUserId(), [SELECT Approved_By__c FROM Sample_Limit_Override__c WHERE Id = :req.Id].Approved_By__c);
        System.assertEquals(false, SampleLimitChecker.checkLimits(UserInfo.getUserId(), d.Id, p.Id, 8, null).needsReason);
    }

    @isTest
    static void regulatoryLimitsAreProtected() {
        SampleLimitSeeder.seedDefaults();
        Sample_Limit__c reg = [SELECT Id, Limit_Quantity__c FROM Sample_Limit__c WHERE Limit_Scope__c = 'HCP_Product' AND Is_Regulatory__c = true];
        System.assert(!Database.delete(reg, false).isSuccess(), 'can not delete');
        reg.Limit_Quantity__c = 20;
        System.assert(!Database.update(reg, false).isSuccess(), 'can not raise');
        reg.Limit_Quantity__c = 6;
        reg.Hard_Block__c = false;
        System.assert(!Database.update(reg, false).isSuccess(), 'can not soften');
        reg.Hard_Block__c = true;
        reg.Is_Active__c = false;
        System.assert(!Database.update(reg, false).isSuccess(), 'can not switch off');
        reg.Is_Active__c = true;
        System.assert(Database.update(reg, false).isSuccess(), 'a stricter limit is allowed');
        Sample_Limit__c company = [SELECT Id FROM Sample_Limit__c WHERE Limit_Scope__c = 'Per_Call'];
        System.assert(Database.delete(company, false).isSuccess(), 'company limits can be deleted');
    }

    @isTest
    static void seedingIsRepeatable() {
        Integer first = SampleLimitSeeder.seedDefaults();
        System.assert(first >= 4);
        System.assertEquals(0, SampleLimitSeeder.seedDefaults());
    }

    @isTest
    static void repMonthlyAndProductGlobalScopesCountTheRightTransactions() {
        Product__c p = SampleTestData.product('Scope SKU');
        Sciagen_Account__c d = SampleTestData.doctor('Dr Scope');
        Sciagen_Account__c d2 = SampleTestData.doctor('Dr Scope Two');
        Sample_Lot__c l = SampleTestData.lot(p, 'SC-1', 100, 200);
        SampleTestData.given(p, l, d, 5);
        SampleTestData.given(p, l, d2, 7);
        insert new List<Sample_Limit__c>{
            new Sample_Limit__c(Name = 'rep month', Limit_Scope__c = 'Rep_Product', Product__c = p.Id, Limit_Quantity__c = 14, Limit_Period__c = 'Monthly', Hard_Block__c = true),
            new Sample_Limit__c(Name = 'global', Limit_Scope__c = 'Product_Global', Product__c = p.Id, Limit_Quantity__c = 30, Limit_Period__c = 'Lifetime', Hard_Block__c = true),
            new Sample_Limit__c(Name = 'doctor all', Limit_Scope__c = 'HCP_All', Limit_Quantity__c = 6, Limit_Period__c = 'Rolling_30', Hard_Block__c = true)
        };
        SampleLimitChecker.LimitCheckResult r = SampleLimitChecker.checkLimits(UserInfo.getUserId(), d.Id, p.Id, 3, null);
        Map<String, SampleLimitChecker.LimitCheck> byName = new Map<String, SampleLimitChecker.LimitCheck>();
        for (SampleLimitChecker.LimitCheck c : r.checks) byName.put(c.name, c);
        System.assertEquals(12, byName.get('rep month').used, 'the rep gave 12 in total this month');
        System.assertEquals('BLOCKED', byName.get('rep month').status);
        System.assertEquals(12, byName.get('global').used);
        System.assertEquals('OK', byName.get('global').status, '12 + 3 is well inside 30');
        System.assertEquals(5, byName.get('doctor all').used, 'only this doctor');
        System.assertEquals('BLOCKED', byName.get('doctor all').status, '5 + 3 = 8 is past 6, a hard block');
    }
}