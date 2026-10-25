@isTest
private class ReportsServiceTest {
    private static Territory__c terr;

    private static Sciagen_Account__c hcp(String n) {
        Sciagen_Account__c a = new Sciagen_Account__c(Name = n, Type__c = 'HCP', Specialty__c = 'Cardiology', Billing_City__c = 'Delhi');
        insert a;
        insert new Account_Territory__c(Account__c = a.Id, Territory__c = terr.Id);
        return a;
    }
    private static Datetime at(Date d, Integer h) { return Datetime.newInstance(d.year(), d.month(), d.day(), h, 0, 0); }
    private static Planned_Call__c plan(Id h, Date d, String status, Boolean evt, String origin) {
        Planned_Call__c p = new Planned_Call__c(HCP__c = h, Call_DateTime__c = at(d, 12), Status__c = status, Is_Event__c = evt, Origin__c = origin);
        insert p; return p;
    }
    private static Call_Visit_Report__c cvr(Id h, Date d, String st, Id planId) {
        Call_Visit_Report__c c = new Call_Visit_Report__c(HCP__c = h, Visit_Date__c = d, Record_Status__c = st, Source_Planned_Call__c = planId);
        insert c; return c;
    }
    private static ReportsService.HcpRow row(List<ReportsService.HcpRow> rs, Id id) {
        for (ReportsService.HcpRow r : rs) if (r.id == id) return r; return null;
    }
    static void setupTerr() {
        Territory__c t = new Territory__c(Name = 'RPT Terr', Territory_Code__c = 'RPT1', Type__c = 'Territory'); insert t;
        insert new User_Territory__c(User__c = UserInfo.getUserId(), Territory__c = t.Id);
    }
    private static void init() { terr = [SELECT Id FROM Territory__c WHERE Territory_Code__c = 'RPT1']; }
    private static Date td() { return Date.today(); }

    // 1 + 4: eligibility of plans, missed rules
    @isTest static void plansEligibilityAndMissed() {
        init(); Sciagen_Account__c h = hcp('Dr. Plan');
        Date y = td().addDays(-1);
        plan(h.Id, y, 'Planned', false, 'Planned');           // counts, missed
        plan(h.Id, y, 'Planned', true, 'Planned');            // event: no
        plan(h.Id, y, 'Planned', false, 'Call log');          // call log: no
        plan(h.Id, y, 'Cancelled', false, 'Planned');         // cancelled: no
        plan(h.Id, td(), 'Planned', false, 'Planned');        // today: counts, not missed
        ReportsService.HcpRow r = row(ReportsService.buildRows(td().addDays(-3), td(), null), h.Id);
        System.assertEquals(2, r.planned); System.assertEquals(1, r.missed);
    }
    // 2 + 3: group call, draft, plan linked
    @isTest static void groupCallDraftAndLinkedPlan() {
        init(); Sciagen_Account__c a = hcp('Dr. A'), b = hcp('Dr. B'), c = hcp('Dr. C');
        Date y = td().addDays(-1);
        Call_Visit_Report__c g = cvr(a.Id, y, 'Submitted', null);
        insert new List<CVR_Attendee__c>{ new CVR_Attendee__c(CVR__c = g.Id, HCP__c = a.Id), new CVR_Attendee__c(CVR__c = g.Id, HCP__c = b.Id), new CVR_Attendee__c(CVR__c = g.Id, HCP__c = c.Id) };
        Planned_Call__c p = plan(b.Id, y, 'Planned', false, 'Planned');
        cvr(b.Id, y, 'Draft', p.Id);
        Test.startTest();
        List<ReportsService.HcpRow> rs = ReportsService.buildRows(td().addDays(-3), td(), null);
        System.assertEquals(1, row(rs, a.Id).completed, 'primary+attendee counted once');
        System.assertEquals(1, row(rs, c.Id).completed);
        System.assertEquals(1, row(rs, b.Id).completed); System.assertEquals(1, row(rs, b.Id).draft);
        System.assertEquals(0, row(rs, b.Id).missed, 'draft report stops plan being missed');
    }
    // 5: achievement and coverage
    @isTest static void percentages() {
        System.assertEquals(125, ReportsService.achievement(5, 4));
        System.assertEquals(0, ReportsService.achievement(5, 0));
        System.assertEquals(100, ReportsService.pct(7, 5));
        System.assertEquals(0, ReportsService.pct(1, 0));
    }
    // 6: tier + consent
    @isTest static void tierAndConsent() {
        init(); Sciagen_Account__c n = hcp('Dr. None'), e = hcp('Dr. Exp'), ok = hcp('Dr. Ok'), g = hcp('Dr. Gold');
        insert new Segmentation__c(HCP__c = g.Id, Classification__c = 'V3');
        insert new Consent__c(HCP__c = e.Id, Signed__c = true, Captured_At__c = Datetime.now().addYears(-3).addDays(-1));
        insert new Consent__c(HCP__c = ok.Id, Signed__c = true, Captured_At__c = Datetime.now().addDays(-5));
        Test.startTest();
        List<ReportsService.HcpRow> rs = ReportsService.buildRows(td().addDays(-3), td(), null);
        System.assertEquals('Unclassified', row(rs, n.Id).tier); System.assertEquals('Pending', row(rs, n.Id).consent);
        System.assertEquals('Expired', row(rs, e.Id).consent); System.assertEquals('Captured', row(rs, ok.Id).consent);
        System.assertEquals('V3', row(rs, g.Id).tier);
    }
    // 7 + 8: reports over a seeded doctor (data built once in setup; two reports per test to respect SOQL limits)
    @TestSetup static void reportData() {
        setupTerr();
        Territory__c t = [SELECT Id FROM Territory__c WHERE Territory_Code__c = 'RPT1'];
        Sciagen_Account__c h = new Sciagen_Account__c(Name = 'Dr. Rep', Type__c = 'HCP', Specialty__c = 'Cardiology', Billing_City__c = 'Delhi'); insert h;
        insert new Account_Territory__c(Account__c = h.Id, Territory__c = t.Id);
        insert new Segmentation__c(HCP__c = h.Id, Classification__c = 'V3');
        Product__c pr = new Product__c(Name = 'Emrok 200', Product_Code__c = 'RPT-P', Level__c = 'SKU', Active__c = true, Is_Detail_Product__c = true); insert pr;
        Date y = Date.today().addDays(-1);
        Planned_Call__c p = new Planned_Call__c(HCP__c = h.Id, Call_DateTime__c = at(y, 12), Status__c = 'Planned', Is_Event__c = false, Origin__c = 'Planned'); insert p;
        Call_Visit_Report__c c = new Call_Visit_Report__c(HCP__c = h.Id, Visit_Date__c = y, Record_Status__c = 'Submitted', Source_Planned_Call__c = p.Id); insert c;
        insert new CVR_Detail_Priority__c(CVR__c = c.Id, Product__c = pr.Id, Product_Name__c = 'Emrok 200', Priority__c = 1);
        Email_Template__c tp = new Email_Template__c(Name = 'T1', Template_Name__c = 'Welcome', Subject__c = 'Hi'); insert tp;
        Sent_Email__c se = new Sent_Email__c(HCP__c = h.Id, Folder__c = 'Sent', Template__c = tp.Id, Status__c = 'Failed', Subject__c = 'Hi'); insert se;
    }
    private static Map<String, Object> prm() {
        return new Map<String, Object>{'startDate' => String.valueOf(td().addDays(-6)), 'endDate' => String.valueOf(td()), 'periodName' => 'Custom', 'segments' => new List<Object>{'V3'}};
    }
    private static void run(List<String> keys) {
        for (String k : keys) System.assertEquals(1, ReportsService.getReport(k, prm()).doctorCount, k);
    }
    @isTest static void reportsA() { run(new List<String>{'performance', 'coverage'}); }
    @isTest static void reportsB() { run(new List<String>{'frequency', 'missed'}); }
    @isTest static void reportsC() { run(new List<String>{'segment', 'specialty'}); }
    @isTest static void reportsD() { run(new List<String>{'consent', 'product'}); }
    @isTest static void reportsE() { run(new List<String>{'email', 'omni'}); }
    @isTest static void filtersChangeResults() {
        Map<String, Object> p = prm(); p.put('segments', new List<Object>{'V2'});
        System.assertEquals(0, ReportsService.getReport('performance', p).doctorCount, 'filters change results');
    }
    @isTest static void coverageGroupingAndDelta() {
        Map<String, Object> p2 = new Map<String, Object>{'startDate' => String.valueOf(td().addDays(-6)), 'endDate' => String.valueOf(td()), 'groupBy' => 'Specialty', 'search' => 'rep'};
        ReportsService.ReportResult cov = ReportsService.getReport('coverage', p2);
        System.assertEquals('1 / 1', cov.kpis[1].value);
    }
    @isTest static void deltaVsPriorPeriod() {
        Map<String, Object> p2 = new Map<String, Object>{'startDate' => String.valueOf(td().addDays(-6)), 'endDate' => String.valueOf(td()), 'search' => 'rep'};
        ReportsService.ReportResult perf = ReportsService.getReport('performance', p2);
        System.assertEquals('+100 pts', perf.kpis[2].delta, 'prior period had 0% coverage');
    }
    @isTest static void hcpDetail() {
        Sciagen_Account__c h = [SELECT Id FROM Sciagen_Account__c WHERE Name = 'Dr. Rep'];
        Map<String, Object> p2 = new Map<String, Object>{'startDate' => String.valueOf(td().addDays(-6)), 'endDate' => String.valueOf(td())};
        ReportsService.HcpDetail d = ReportsService.getHcpDetail(h.Id, td().addDays(-6), td(), null, null);
        System.assertEquals(1, d.calls.size(), 'calls'); System.assertEquals(1, d.plans.size(), 'plans'); System.assertEquals(1, d.emails.size(), 'emails');
    }
    @isTest static void groupDoctorsAndOptions() {
        Map<String, Object> p2 = new Map<String, Object>{'startDate' => String.valueOf(td().addDays(-6)), 'endDate' => String.valueOf(td())};
        System.assertEquals(1, ReportsService.groupDoctors(p2, 'ProductAny', 'Emrok 200').size());
        System.assert(ReportsService.getFilterOptions(td().addDays(-6), td(), null, null).products.contains('Emrok 200'));
    }
    @isTest static void emptySamples() {
        Map<String, Object> p2 = new Map<String, Object>{'startDate' => String.valueOf(td().addDays(-6)), 'endDate' => String.valueOf(td())};
        System.assertEquals('0', ReportsService.getSamples(p2).kpis[0].value);
    }
    @isTest static void controllerWrappers() {
        String j = JSON.serialize(new Map<String, Object>{'startDate' => String.valueOf(td().addDays(-6)), 'endDate' => String.valueOf(td())});
        ReportsController.getReport('performance', j);
    }
    @isTest static void controllerWrappers2() {
        String j = JSON.serialize(new Map<String, Object>{'startDate' => String.valueOf(td().addDays(-6)), 'endDate' => String.valueOf(td())});
        ReportsController.getFilterOptions(String.valueOf(td()), String.valueOf(td()), null, null);
        ReportsController.getGroupDoctors(j, 'Segment', 'V3');
    }
    @isTest static void libraryHeadlines() {
        Map<String, String> m = ReportsController.getLibrary(String.valueOf(td().addDays(-6)), String.valueOf(td()), null, null, null);
        System.assertEquals(10, m.size()); System.assertEquals('100%', m.get('coverage'));
    }
    @isTest static void controllerScopeOptions() {
        System.assertNotEquals(null, ReportsController.getScopeOptions());
    }
    @isTest static void controllerWrappers3() {
        String j = JSON.serialize(new Map<String, Object>{'startDate' => String.valueOf(td().addDays(-6)), 'endDate' => String.valueOf(td())});
        ReportsController.getSamples(j);
    }
    // samples: packs on a Submitted report are summed per product and per doctor
    @isTest static void samplesOnSubmittedReports() {
        init();
        SampleLimitSeeder.seedDefaults();
        Product__c p = SampleTestData.product('Rpt Sample SKU');
        Sciagen_Account__c d = SampleTestData.doctor('Dr Rpt Sample');
        insert new Account_Territory__c(Account__c = d.Id, Territory__c = terr.Id);
        SampleTestData.lot(p, 'RPT-1', 20, 200);
        Call_Visit_Report__c call = SampleTestData.call(d, 'Draft');
        insert new Sample_Drop__c(Name = 'Sample Drop', CVR__c = call.Id, Product__c = p.Id, Qty__c = 3);
        call.Record_Status__c = 'Submitted'; call.Signature_Captured__c = true; call.Signature_Image__c = '069000000000001AAA';
        call.Signature_Captured_At__c = System.now(); call.Signature_GPS__Latitude__s = 28.61; call.Signature_GPS__Longitude__s = 77.20; call.Signee_Name__c = 'Dr Rpt Sample';
        update call;
        Test.startTest();
        Map<String, Object> prm = new Map<String, Object>{'startDate' => String.valueOf(td().addDays(-2)), 'endDate' => String.valueOf(td())};
        ReportsService.ReportResult r = ReportsService.getSamples(prm);
        System.assertEquals('3', r.kpis[0].value);
        System.assertEquals('3', r.tables[0].rows[0].get('qty'));
        System.assertEquals(3, row(ReportsService.buildRows(td().addDays(-2), td(), null), d.Id).samples);
    }
    // 9: sales
    @isTest static void salesStockistTargetAndTerritoryTargetIgnored() {
        init();
        Product__c p1 = new Product__c(Name = 'S1', Product_Code__c = 'RS1', Level__c = 'SKU', Active__c = true, Unit_Value_Per_Strip__c = 10, Brand_Name__c = 'B1');
        Product__c p2 = new Product__c(Name = 'S2', Product_Code__c = 'RS2', Level__c = 'SKU', Active__c = true, Unit_Value_Per_Strip__c = 20, Brand_Name__c = 'B2');
        insert new List<Product__c>{ p1, p2 };
        Sciagen_Account__c s1 = new Sciagen_Account__c(Name = 'Stk 1', Type__c = 'HCO'), s2 = new Sciagen_Account__c(Name = 'Stk 2', Type__c = 'HCO');
        insert new List<Sciagen_Account__c>{ s1, s2 };
        insert new List<Sales_Transaction__c>{
            new Sales_Transaction__c(Period__c = '2026-09', Product__c = p1.Id, Stockist__c = s1.Id, Primary_Units__c = 10, Secondary_Units__c = 5, Sales_Key__c = 'sk1'),
            new Sales_Transaction__c(Period__c = '2026-09', Product__c = p2.Id, Stockist__c = s2.Id, Primary_Units__c = 5, Secondary_Units__c = 5, Sales_Key__c = 'sk2')};
        insert new List<Sales_Target__c>{
            new Sales_Target__c(Period__c = '2026-09', Product__c = p1.Id, Target_Units__c = 10, Target_Key__c = 'k1'),
            new Sales_Target__c(Period__c = '2026-09', Product__c = p2.Id, Target_Units__c = 10, Target_Key__c = 'k2'),
            new Sales_Target__c(Period__c = '2026-09', Product__c = p1.Id, Target_Units__c = 999, Territory__c = terr.Id, Target_Key__c = 'k3')};
        Map<String, Object> prm = new Map<String, Object>{'view' => 'primary', 'by' => 'sku'};
        ReportsService.ReportResult r = ReportsService.getSales(prm);
        System.assertEquals('₹200', r.kpis[0].value, 'primary = 10*10 + 5*20');
        // totals target = 10*10 + 10*20 = 300 -> 67%
        System.assertEquals('67%', r.kpis[3].value);
        prm.put('by', 'stockist'); r = ReportsService.getSales(prm);
        System.assertEquals('₹150', r.tables[0].rows[0].get('tv'), 'total SKU target 300 / 2 stockists');
        prm.put('view', 'trend'); System.assertEquals(1, ReportsService.getSales(prm).tables[0].rows.size());
        prm.put('view', 'achievement'); System.assertEquals(2, ReportsService.getSales(prm).tables[0].rows.size());
        prm.put('view', 'secondary'); prm.put('month', '2026-09'); ReportsService.getSales(prm);
        System.assertEquals(2, ReportsService.getSalesDrill(new Map<String, Object>{'by' => 'sku'}, String.valueOf(p1.Id)).rows.size() + 1);
        System.assertEquals(1, ReportsService.getSalesDrill(new Map<String, Object>{'by' => 'stockist'}, 'Stk 1').rows.size());
        ReportsController.getSales(JSON.serialize(prm)); ReportsController.getSalesDrill(JSON.serialize(prm), 'Stk 1');
    }
    @isTest static void salesNoData() {
        System.assert(ReportsService.getSales(new Map<String, Object>()).noData);
    }
    // 10: scope -- KAM sees own territory only; manager sees own + children and can narrow; admin sees all
    @isTest static void kamManagerAdminScopes() {
        init();
        Territory__c child = new Territory__c(Name = 'RPT Child', Territory_Code__c = 'RPT3', Type__c = 'Territory', Parent_Territory__c = terr.Id);
        Territory__c other = new Territory__c(Name = 'Other', Territory_Code__c = 'RPT2', Type__c = 'Territory');
        insert new List<Territory__c>{ child, other };
        Sciagen_Account__c mine = hcp('Dr. Mine');
        Sciagen_Account__c kid = new Sciagen_Account__c(Name = 'Dr. Kid', Type__c = 'HCP'); insert kid;
        Sciagen_Account__c theirs = new Sciagen_Account__c(Name = 'Dr. Theirs', Type__c = 'HCP'); insert theirs;
        delete [SELECT Id FROM Account_Territory__c WHERE Account__c IN :new List<Id>{ kid.Id, theirs.Id }];
        insert new List<Account_Territory__c>{ new Account_Territory__c(Account__c = kid.Id, Territory__c = child.Id), new Account_Territory__c(Account__c = theirs.Id, Territory__c = other.Id) };
        Test.startTest();
        // KAM: own territory only (its child counts as part of it), and the picker request is ignored
        ReportsService.managerOverride = false; ReportsService.adminOverride = false;
        List<ReportsService.HcpRow> rs = ReportsService.buildRows(td().addDays(-3), td(), null);
        System.assertNotEquals(null, row(rs, mine.Id)); System.assertEquals(null, row(rs, theirs.Id));
        System.assertEquals(0, ReportsService.getScopeOptions().territories.size(), 'KAM gets no pickers');
        // Manager: own + child territories, never another territory
        ReportsService.managerOverride = true;
        rs = ReportsService.buildRows(td().addDays(-3), td(), null);
        System.assertNotEquals(null, row(rs, kid.Id)); System.assertEquals(null, row(rs, theirs.Id));
        ReportsService.ScopeOptions so = ReportsService.getScopeOptions();
        System.assertEquals(2, so.territories.size(), 'parent + child offered');
        System.assert(so.territories[1].label.startsWith('—'), 'child indented under parent');
        // narrowing to the child territory
        ReportsService.reqTerritory = child.Id;
        rs = ReportsService.buildRows(td().addDays(-3), td(), null);
        System.assertNotEquals(null, row(rs, kid.Id)); System.assertEquals(null, row(rs, mine.Id));
        // a territory outside the manager's scope is refused
        ReportsService.reqTerritory = other.Id;
        try { ReportsService.buildRows(td().addDays(-3), td(), null); System.assert(false, 'should refuse'); } catch (AuraHandledException ex) { System.assert(true); }
        // narrowing to a KAM inside the manager's scope
        ReportsService.reqTerritory = null;
        rs = ReportsService.buildRows(td().addDays(-3), td(), UserInfo.getUserId());
        System.assertNotEquals(null, row(rs, mine.Id)); System.assertEquals(null, row(rs, theirs.Id));
        // Business Admin: every territory
        ReportsService.adminOverride = true;
        rs = ReportsService.buildRows(td().addDays(-3), td(), null);
        System.assertNotEquals(null, row(rs, theirs.Id));
        System.assert(ReportsService.getScopeOptions().isAdmin);
    }
    @isTest static void helpers() {
        System.assertEquals('Expired', ReportsService.consentState(true, Datetime.now().addYears(-4), td()));
        System.assertEquals('Pending', ReportsService.consentState(false, Datetime.now(), td()));
        System.assertEquals('Pending', ReportsService.consentState(null, null, td()));
        System.assert(ReportsService.periodLabel(td(), td(), 'Today').contains('Today'));
    }
}