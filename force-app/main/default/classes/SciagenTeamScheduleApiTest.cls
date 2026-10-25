@isTest
private class SciagenTeamScheduleApiTest {

    private static Map<String, Object> get(String action, Map<String, String> params) {
        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/sciagen/v1/team-schedule/' + action;
        req.httpMethod = 'GET';
        req.params.putAll(params);
        RestContext.request = req;
        RestContext.response = new RestResponse();
        SciagenTeamScheduleApi.doGet();
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(RestContext.response.responseBody.toString());
        body.put('status', RestContext.response.statusCode);
        return body;
    }

    private static User plainUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            Alias = 'tmapi', Email = 'tmapi@example.com', EmailEncodingKey = 'UTF-8', LastName = 'TeamApiTest',
            LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US', ProfileId = p.Id, TimeZoneSidKey = 'Asia/Kolkata',
            Username = 'tmapi' + System.currentTimeMillis() + '@example.com'
        );
        insert u;
        return u;
    }

    @isTest
    static void meReportsARoleAndWhetherTheUserCanViewTheTeam() {
        Map<String, Object> r = get('me', new Map<String, String>());
        System.assertEquals(200, r.get('status'));
        System.assertEquals(true, r.get('success'));
        System.assertEquals(UserInfo.getUserId(), (String) r.get('userId'));
        System.assert(new Set<String>{ 'KAM', 'MANAGER', 'ADMIN', 'USER' }.contains((String) r.get('role')));
    }

    @isTest
    static void aPlainUserIsNotATeamViewerAndGetsNoKams() {
        System.runAs(plainUser()) {
            Map<String, Object> me = get('me', new Map<String, String>());
            System.assertEquals(false, me.get('canViewTeam'));
            Map<String, Object> kams = get('kams', new Map<String, String>());
            System.assertEquals(200, kams.get('status'));
            System.assertEquals(0, ((List<Object>) kams.get('kams')).size());
        }
    }

    @isTest
    static void callsReturnsTheCallersOwnCallsWithNoUserId() {
        Date d = Date.today();
        Map<String, Object> r = get('calls', new Map<String, String>{ 'startDate' => String.valueOf(d), 'endDate' => String.valueOf(d.addDays(6)) });
        System.assertEquals(200, r.get('status'));
        System.assert(r.get('calls') instanceof List<Object>);
    }

    @isTest
    static void callsRejectsBadDatesAndAnOverlongRange() {
        System.assertEquals(400, get('calls', new Map<String, String>()).get('status'));
        System.assertEquals(400, get('calls', new Map<String, String>{ 'startDate' => '2026-02-10', 'endDate' => '2026-02-01' }).get('status'));
        System.assertEquals(400, get('calls', new Map<String, String>{ 'startDate' => '2026-01-01', 'endDate' => '2026-12-31' }).get('status'));
        System.assertEquals(400, get('calls', new Map<String, String>{ 'startDate' => '2026-02-01', 'endDate' => '2026-02-02', 'userId' => 'not-an-id' }).get('status'));
    }

    @isTest
    static void callsForAnotherUserIsForbiddenForANonManager() {
        User other = [SELECT Id FROM User WHERE IsActive = true AND Id != :UserInfo.getUserId() LIMIT 1];
        System.runAs(plainUser()) {
            Map<String, Object> r = get('calls', new Map<String, String>{
                'startDate' => String.valueOf(Date.today()), 'endDate' => String.valueOf(Date.today().addDays(1)), 'userId' => other.Id
            });
            System.assertEquals(403, r.get('status'));
            System.assertEquals(false, r.get('success'));
        }
    }

    @isTest
    static void anUnknownResourceIs404() {
        System.assertEquals(404, get('nope', new Map<String, String>()).get('status'));
    }

    @isTest
    static void accountsRejectsBadParametersAndANonManager() {
        System.assertEquals(400, get('accounts', new Map<String, String>()).get('status'));
        System.assertEquals(400, get('accounts', new Map<String, String>{ 'userId' => UserInfo.getUserId(), 'type' => 'XYZ' }).get('status'));
        System.assertEquals(400, get('accounts', new Map<String, String>{ 'userId' => UserInfo.getUserId(), 'limit' => '500' }).get('status'));
        System.assertEquals(400, get('accounts', new Map<String, String>{ 'userId' => UserInfo.getUserId(), 'offset' => '5000' }).get('status'));
        System.assertEquals(400, get('accounts', new Map<String, String>{ 'userId' => UserInfo.getUserId(), 'limit' => 'abc' }).get('status'));
        System.runAs(plainUser()) {
            Map<String, Object> r = get('accounts', new Map<String, String>{ 'userId' => UserInfo.getUserId() });
            System.assertEquals(403, r.get('status'));
        }
    }

    @isTest
    static void accountsBodyReturnsAKamsTerritoryAccountsWithTerritoryAffiliationAndSegmentation() {
        Sciagen_Account__c hcp = new Sciagen_Account__c(Type__c = 'HCP', Name = 'Dr. Team Api', First_Name__c = 'Team', Last_Name__c = 'Api', Specialty__c = 'Cardiology', HCP_Type__c = 'Physician');
        Sciagen_Account__c hcp2 = new Sciagen_Account__c(Type__c = 'HCP', Name = 'Dr. Other Api', First_Name__c = 'Other', Last_Name__c = 'Api', Specialty__c = 'Cardiology', HCP_Type__c = 'Physician');
        Sciagen_Account__c hco = new Sciagen_Account__c(Type__c = 'HCO', Name = 'Team Api Hospital', HCO_Type__c = 'Hospital', Speciality__c = 'Other');
        insert new List<Sciagen_Account__c>{ hcp, hcp2, hco };
        Territory__c inTerr = new Territory__c(Name = 'Team Api Territory', Territory_Code__c = 'TAT', Type__c = 'Territory');
        Territory__c outTerr = new Territory__c(Name = 'Elsewhere', Territory_Code__c = 'ELS', Type__c = 'Territory');
        insert new List<Territory__c>{ inTerr, outTerr };
        insert new List<Account_Territory__c>{
            new Account_Territory__c(Name = 'a1', Account__c = hcp.Id, Territory__c = inTerr.Id),
            new Account_Territory__c(Name = 'a2', Account__c = hco.Id, Territory__c = inTerr.Id),
            new Account_Territory__c(Name = 'a3', Account__c = hcp2.Id, Territory__c = outTerr.Id)
        };
        insert new Affiliation__c(HCP__c = hcp.Id, HCO__c = hco.Id, Is_Primary__c = true);
        insert new Segmentation__c(HCP__c = hcp.Id, Classification__c = 'V2');

        Map<String, Object> body = SciagenTeamScheduleApi.accountsBody(new Set<Id>{ inTerr.Id }, null, 100, 0, null);
        List<Object> hcps = (List<Object>) body.get('hcps');
        List<Object> hcos = (List<Object>) body.get('hcos');
        System.assertEquals(1, hcps.size(), 'Only the HCP in the KAM\'s territory');
        System.assertEquals(1, hcos.size());
        System.assertEquals(1, body.get('totalHcps'));
        Map<String, Object> row = (Map<String, Object>) hcps[0];
        System.assertEquals('Team Api Territory', row.get('territory'));
        System.assertEquals(hco.Id, row.get('primaryHcoId'));
        System.assertEquals('Team Api Hospital', row.get('primaryHcoName'));
        System.assertEquals('V2', ((Map<String, Object>) row.get('segmentation')).get('Classification__c'));

        Map<String, Object> hcoOnly = SciagenTeamScheduleApi.accountsBody(new Set<Id>{ inTerr.Id }, 'HCO', 1, 0, null);
        System.assert(!hcoOnly.containsKey('hcps'));
        System.assertEquals(false, hcoOnly.get('hasMoreHcos'));
        System.assertEquals(0, ((List<Object>) SciagenTeamScheduleApi.accountsBody(new Set<Id>(), 'HCP', 10, 0, null).get('hcps')).size());
    }

    @isTest
    static void accountsPagesWithAnExtraRowCheckAndAfterId() {
        Territory__c terr = new Territory__c(Name = 'Page Territory', Territory_Code__c = 'PGT', Type__c = 'Territory');
        insert terr;
        List<Sciagen_Account__c> hcps = new List<Sciagen_Account__c>();
        for (Integer i = 0; i < 3; i++) {
            hcps.add(new Sciagen_Account__c(Type__c = 'HCP', Name = 'Dr. Page ' + i, First_Name__c = 'Page', Last_Name__c = 'N' + i, Specialty__c = 'Cardiology', HCP_Type__c = 'Physician'));
        }
        insert hcps;
        List<Account_Territory__c> links = new List<Account_Territory__c>();
        for (Sciagen_Account__c h : hcps) { links.add(new Account_Territory__c(Name = 'p', Account__c = h.Id, Territory__c = terr.Id)); }
        insert links;

        Map<String, Object> first = SciagenTeamScheduleApi.accountsBody(new Set<Id>{ terr.Id }, 'HCP', 2, 0, null);
        System.assertEquals(2, ((List<Object>) first.get('hcps')).size());
        System.assertEquals(true, first.get('hasMoreHcps'));
        System.assertEquals(3, first.get('totalHcps'));
        Map<String, Object> next = SciagenTeamScheduleApi.accountsBody(new Set<Id>{ terr.Id }, 'HCP', 2, 0, (Id) first.get('lastHcpId'));
        System.assertEquals(1, ((List<Object>) next.get('hcps')).size());
        System.assertEquals(false, next.get('hasMoreHcps'));
    }

    @isTest
    static void accountActivityRejectsBadIdsAndANonManager() {
        System.assertEquals(400, get('account-activity', new Map<String, String>()).get('status'));
        System.assertEquals(400, get('account-activity', new Map<String, String>{ 'userId' => UserInfo.getUserId() }).get('status'));
        System.runAs(plainUser()) {
            Map<String, Object> r = get('account-activity', new Map<String, String>{ 'userId' => UserInfo.getUserId(), 'hcpId' => UserInfo.getUserId() });
            System.assertEquals(403, r.get('status'));
        }
    }

    @isTest
    static void activityReaderReturnsOnlyTheKamsRecordsForThatHcp() {
        Sciagen_Account__c hcp = new Sciagen_Account__c(Type__c = 'HCP', Name = 'Dr. Activity', First_Name__c = 'Activity', Last_Name__c = 'Test', Specialty__c = 'Cardiology', HCP_Type__c = 'Physician');
        Sciagen_Account__c hco = new Sciagen_Account__c(Type__c = 'HCO', Name = 'Activity Hospital', HCO_Type__c = 'Hospital', Speciality__c = 'Other');
        insert new List<Sciagen_Account__c>{ hcp, hco };
        Time safeTime = Time.newInstance(11, 0, 0, 0);
        insert new Planned_Call__c(HCP__c = hcp.Id, HCO__c = hco.Id, Call_DateTime__c = Datetime.newInstance(Date.today(), safeTime),
            Duration_Min__c = 30, Call_Type__c = 'Detailing', Status__c = 'Planned');
        insert new Call_Visit_Report__c(HCP__c = hcp.Id, HCO__c = hco.Id, Visit_Date__c = Date.today(), Call_Type__c = 'Detailing');
        insert new Sent_Email__c(HCP__c = hcp.Id, Subject__c = 'Hello', To_Email__c = 'a@example.com', Sent_At__c = Datetime.now());
        insert new Office_Window__c(HCP__c = hcp.Id, HCO__c = hco.Id, Day__c = 'Mon', Window__c = '10:00-12:00', Preference__c = 'Best');
        insert new Data_Change_Request__c(Subject_Account__c = hcp.Id, Subject_Name__c = 'Dr. Activity', Type__c = 'Edit HCP', Status__c = 'Pending Approval');

        Map<String, Object> mine = TeamAccountActivityReader.forKam(UserInfo.getUserId(), hcp.Id);
        System.assertEquals(1, ((List<Object>) mine.get('plannedCalls')).size());
        System.assertEquals(1, ((List<Object>) mine.get('cvrs')).size());
        System.assertEquals(1, ((List<Object>) mine.get('emails')).size());
        System.assertEquals(1, ((List<Object>) mine.get('officeWindows')).size());
        System.assertEquals(1, ((List<Object>) mine.get('dcrs')).size());
        System.assertEquals('Activity Hospital', ((Map<String, Object>) ((List<Object>) mine.get('cvrs'))[0]).get('hcoName'));
        System.assertEquals(0, (Integer) ((Map<String, Object>) ((List<Object>) mine.get('emails'))[0]).get('attachmentCount'));

        User other = [SELECT Id FROM User WHERE IsActive = true AND Id != :UserInfo.getUserId() LIMIT 1];
        Map<String, Object> theirs = TeamAccountActivityReader.forKam(other.Id, hcp.Id);
        System.assertEquals(0, ((List<Object>) theirs.get('cvrs')).size(), 'Another user\'s records are not returned');
        System.assertEquals(1, ((List<Object>) theirs.get('officeWindows')).size(), 'Office windows belong to the doctor');
    }
}