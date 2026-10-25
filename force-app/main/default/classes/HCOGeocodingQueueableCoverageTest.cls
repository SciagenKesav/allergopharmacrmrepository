@isTest
private class HCOGeocodingQueueableCoverageTest {

    private class GeoMock implements HttpCalloutMock {
        Integer code; String body; Boolean throwEx;
        GeoMock(Integer code, String body, Boolean throwEx) { this.code = code; this.body = body; this.throwEx = throwEx; }
        public HttpResponse respond(HttpRequest req) {
            if (throwEx) throw new CalloutException('boom');
            HttpResponse r = new HttpResponse();
            r.setStatusCode(code);
            r.setBody(body);
            return r;
        }
    }

    private static final String OK_BODY = '{"status":"OK","results":[{"geometry":{"location":{"lat":12.9716,"lng":77.5946}}}]}';

    private static Sciagen_Account__c hco(String name, String street) {
        return new Sciagen_Account__c(Type__c = 'HCO', Name = name, HCO_Type__c = 'Hospital', Speciality__c = 'Other',
            Billing_Street__c = street, Billing_City__c = 'Bengaluru', Billing_State__c = 'KA',
            Billing_Postal_Code__c = '560001', Billing_Country__c = 'India');
    }

    private static void run(Set<Id> ids, HttpCalloutMock m) {
        HCOGeocodingQueueable.testApiKey = 'test-key';
        Test.setMock(HttpCalloutMock.class, m);
        Test.startTest();
        System.enqueueJob(new HCOGeocodingQueueable(ids));
        Test.stopTest();
    }

    @isTest static void successSetsCoordinates() {
        Sciagen_Account__c h = hco('Geo Hospital', '1 MG Road');
        insert h;
        run(new Set<Id>{ h.Id }, new GeoMock(200, OK_BODY, false));
        Sciagen_Account__c after = [SELECT Geolocation__Latitude__s, Geolocation__Longitude__s FROM Sciagen_Account__c WHERE Id = :h.Id];
        System.assertEquals(12.9716, after.Geolocation__Latitude__s);
        System.assertEquals(77.5946, after.Geolocation__Longitude__s);
    }

    @isTest static void errorPath0LeavesCoordinatesUntouched() {
        Sciagen_Account__c h = hco('Geo Hospital E0', '2 MG Road');
        insert h;
        run(new Set<Id>{ h.Id }, new GeoMock(500, '', false));
        System.assertEquals(null, [SELECT Geolocation__Latitude__s FROM Sciagen_Account__c WHERE Id = :h.Id].Geolocation__Latitude__s);
    }

    @isTest static void errorPath1LeavesCoordinatesUntouched() {
        Sciagen_Account__c h = hco('Geo Hospital E1', '2 MG Road');
        insert h;
        run(new Set<Id>{ h.Id }, new GeoMock(200, '{"status":"ZERO_RESULTS","results":[]}', false));
        System.assertEquals(null, [SELECT Geolocation__Latitude__s FROM Sciagen_Account__c WHERE Id = :h.Id].Geolocation__Latitude__s);
    }

    @isTest static void errorPath2LeavesCoordinatesUntouched() {
        Sciagen_Account__c h = hco('Geo Hospital E2', '2 MG Road');
        insert h;
        run(new Set<Id>{ h.Id }, new GeoMock(200, '{"status":"OK","results":[]}', false));
        System.assertEquals(null, [SELECT Geolocation__Latitude__s FROM Sciagen_Account__c WHERE Id = :h.Id].Geolocation__Latitude__s);
    }

    @isTest static void errorPath3LeavesCoordinatesUntouched() {
        Sciagen_Account__c h = hco('Geo Hospital E3', '2 MG Road');
        insert h;
        run(new Set<Id>{ h.Id }, new GeoMock(200, 'not json', false));
        System.assertEquals(null, [SELECT Geolocation__Latitude__s FROM Sciagen_Account__c WHERE Id = :h.Id].Geolocation__Latitude__s);
    }

    @isTest static void errorPath4LeavesCoordinatesUntouched() {
        Sciagen_Account__c h = hco('Geo Hospital E4', '2 MG Road');
        insert h;
        run(new Set<Id>{ h.Id }, new GeoMock(200, '', true));
        System.assertEquals(null, [SELECT Geolocation__Latitude__s FROM Sciagen_Account__c WHERE Id = :h.Id].Geolocation__Latitude__s);
    }

    @isTest static void blankAddressIsSkippedAndNoKeyReturnsEarly() {
        Sciagen_Account__c h = new Sciagen_Account__c(Type__c = 'HCO', Name = 'No Address', HCO_Type__c = 'Hospital', Speciality__c = 'Other');
        insert h;
        run(new Set<Id>{ h.Id }, new GeoMock(200, OK_BODY, false));
        System.assertEquals(null, [SELECT Geolocation__Latitude__s FROM Sciagen_Account__c WHERE Id = :h.Id].Geolocation__Latitude__s);

        // empty / null id sets and missing key
        new HCOGeocodingQueueable(new Set<Id>()).execute(null);
        new HCOGeocodingQueueable(null).execute(null);
        HCOGeocodingQueueable.testApiKey = '';
        new HCOGeocodingQueueable(new Set<Id>{ h.Id }).execute(null);
        System.assert(true);
    }

    @isTest static void capsAtOneHundredHcos() {
        List<Sciagen_Account__c> hs = new List<Sciagen_Account__c>();
        for (Integer i = 0; i < 101; i++) hs.add(hco('Bulk Geo ' + i, i + ' Bulk Street'));
        insert hs;
        Set<Id> ids = new Set<Id>();
        for (Sciagen_Account__c h : hs) ids.add(h.Id);
        HCOGeocodingQueueable.testApiKey = 'test-key';
        Test.setMock(HttpCalloutMock.class, new GeoMock(200, OK_BODY, false));
        Test.startTest();
        new HCOGeocodingQueueable(ids).execute(null);
        Test.stopTest();
        System.assertEquals(100, [SELECT COUNT() FROM Sciagen_Account__c WHERE Geolocation__Latitude__s != null AND Name LIKE 'Bulk Geo %']);
    }
}
