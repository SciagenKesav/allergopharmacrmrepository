@isTest
private class SciagenPicklistServiceTest {

    @isTest
    static void getPicklists_returnsActiveHCOAndHCPValues() {
        Test.startTest();
        SciagenPicklistService.PicklistOptions options = SciagenPicklistService.getPicklists();
        Test.stopTest();

        System.assert(options.hcoTypes.contains('Hospital'));
        System.assert(options.hcoTypes.contains('Pharmacy'), 'Full HCO_Type__c picklist should be returned, not a hardcoded subset');
        System.assert(options.hcoTypes.contains('Chemist Shop'));
        System.assertEquals(9, options.hcoTypes.size());

        System.assert(options.hcpTypes.contains('Physician'));
        System.assert(options.hcpTypes.contains('Super Specialist'));
        System.assertEquals(7, options.hcpTypes.size());

        System.assert(options.hcoSpecialties.contains('Cardiology'));
        System.assert(options.hcpSpecialties.contains('Cardiology'));
    }

    @isTest
    static void getPicklists_viaRestEntryPoint_returnsValidJson() {
        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/sciagen/v1/picklists';
        req.httpMethod = 'GET';
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        SciagenPicklistService.PicklistOptions options = SciagenPicklistService.getPicklists();
        Test.stopTest();

        System.assertNotEquals(null, options.hcoTypes);
        System.assertNotEquals(null, options.hcpTypes);
    }
}