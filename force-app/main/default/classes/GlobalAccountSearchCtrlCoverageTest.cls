@isTest
private class GlobalAccountSearchCtrlCoverageTest {

    private static GlobalAccountSearchController.SearchCriteria crit() {
        return new GlobalAccountSearchController.SearchCriteria();
    }

    @TestSetup
    static void setup() {
        Territory__c t = new Territory__c(Name = 'GASCov Terr', Territory_Code__c = 'GCV', Type__c = 'Territory');
        insert t;
        Sciagen_Account__c parent = new Sciagen_Account__c(
            Name = 'GASCov Parent Hospital', Type__c = 'HCO', HCO_Type__c = 'Chemist Shop', Speciality__c = 'Other');
        insert parent;
        Sciagen_Account__c hco = new Sciagen_Account__c(
            Name = 'GASCov Clinic', Type__c = 'HCO', HCO_Type__c = 'Chemist Shop', Speciality__c = 'Other',
            Parent_Account__c = parent.Id, Billing_Street__c = '12 Gandhi Road', Billing_City__c = 'Mumbai',
            Billing_State__c = 'Maharashtra', Billing_Postal_Code__c = '400001', Phone__c = '9876500001');
        Sciagen_Account__c hcp = new Sciagen_Account__c(
            Name = 'Dr. GASCov Kumar', Type__c = 'HCP', First_Name__c = 'Gcov', Last_Name__c = 'Kumar',
            Specialty__c = 'Cardiology', HCP_Type__c = 'Physician', Billing_City__c = 'Mumbai');
        insert new List<Sciagen_Account__c>{ hco, hcp };
    }

    @isTest
    static void searchByAllAddressAndNameFields() {
        Sciagen_Account__c parent = [SELECT Id FROM Sciagen_Account__c WHERE Name = 'GASCov Parent Hospital'];
        GlobalAccountSearchController.SearchCriteria c = crit();
        c.name = 'GASCov Clinic';
        c.nameExact = true;
        c.specialty = 'Other';
        c.primaryParentId = parent.Id;
        c.addressLine1 = '12 Gandhi';
        c.addressStartsWith = true;
        c.city = 'Mumb';
        c.state = 'Mahar';
        c.postalCode = '4000';
        c.phone = '98765';
        List<GlobalAccountSearchController.SearchResultRow> rows = GlobalAccountSearchController.search(JSON.serialize(c));
        System.assertEquals(1, rows.size());
        GlobalAccountSearchController.SearchResultRow r = rows[0];
        System.assertEquals('GASCov Clinic', r.name);
        System.assertEquals('Other', r.specialty);
        System.assertEquals('Mumbai', r.city);
        System.assertEquals('400001', r.postalCode);
        System.assertEquals('12 Gandhi Road', r.street);
        System.assertEquals(false, r.inMyTerritory);
    }

    @isTest
    static void searchByPartialNameAndContainsAddress() {
        GlobalAccountSearchController.SearchCriteria c = crit();
        c.name = 'GASCov Cli';
        c.addressLine1 = 'Gandhi';
        c.addressStartsWith = false;
        System.assertEquals(1, GlobalAccountSearchController.search(JSON.serialize(c)).size());
    }

    @isTest
    static void searchByFirstAndLastNameForHcp() {
        GlobalAccountSearchController.SearchCriteria c = crit();
        c.firstName = 'Gcov';
        c.lastName = 'Kumar';
        c.specialty = 'Cardiology';
        List<GlobalAccountSearchController.SearchResultRow> rows = GlobalAccountSearchController.search(JSON.serialize(c));
        System.assertEquals(1, rows.size());
        System.assertEquals('Cardiology', rows[0].specialty);
        System.assertEquals('HCP', rows[0].type);
    }

    @isTest
    static void searchThrowsWhenMoreThanTwentyMatch() {
        List<Sciagen_Account__c> many = new List<Sciagen_Account__c>();
        for (Integer i = 0; i < 21; i++) {
            many.add(new Sciagen_Account__c(Name = 'GASCov Bulk ' + i, Type__c = 'HCO', HCO_Type__c = 'Chemist Shop',
                Speciality__c = 'Other', Billing_City__c = 'Bulkville'));
        }
        insert many;
        GlobalAccountSearchController.SearchCriteria c = crit();
        c.city = 'Bulkville';
        try {
            GlobalAccountSearchController.search(JSON.serialize(c));
            System.assert(false, 'Expected too-many-results exception');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    @isTest
    static void territoryLookupFallsBackToNonPrimaryAssignment() {
        Territory__c t = [SELECT Id FROM Territory__c WHERE Name = 'GASCov Terr'];
        Sciagen_Account__c hcp = [SELECT Id FROM Sciagen_Account__c WHERE Name = 'Dr. GASCov Kumar'];
        insert new User_Territory__c(User__c = UserInfo.getUserId(), Territory__c = t.Id, Is_Primary__c = false);
        insert new Account_Territory__c(Account__c = hcp.Id, Territory__c = t.Id);

        GlobalAccountSearchController.SearchCriteria c = crit();
        c.lastName = 'Kumar';
        List<GlobalAccountSearchController.SearchResultRow> rows = GlobalAccountSearchController.search(JSON.serialize(c));
        System.assertEquals(1, rows.size());
        System.assertEquals(true, rows[0].inMyTerritory);
    }
}