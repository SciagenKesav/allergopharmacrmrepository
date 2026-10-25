@isTest
private class SciagenAccountPhoneGuardServiceTest {

    @isTest
    static void plainTenDigitNumberIsAllowed() {
        Test.startTest();
        Sciagen_Account__c hcp = new Sciagen_Account__c(
            Type__c = 'HCP', Name = 'Dr. Phone Test', Prefix__c = 'Dr.', First_Name__c = 'Phone',
            Last_Name__c = 'Test', Specialty__c = 'Cardiology', HCP_Type__c = 'Physician',
            Phone__c = '9876543210'
        );
        insert hcp;
        Test.stopTest();

        System.assertEquals('9876543210', [SELECT Phone__c FROM Sciagen_Account__c WHERE Id = :hcp.Id].Phone__c);
    }

    @isTest
    static void countryCodeFormattedNumberIsAllowed() {
        Test.startTest();
        Sciagen_Account__c hco = new Sciagen_Account__c(
            Type__c = 'HCO', Name = 'Phone Test Hospital', HCO_Type__c = 'Hospital', Speciality__c = 'Other',
            Phone__c = '+91-98765-43210'
        );
        insert hco;
        Test.stopTest();

        System.assertEquals('+91-98765-43210', [SELECT Phone__c FROM Sciagen_Account__c WHERE Id = :hco.Id].Phone__c);
    }

    @isTest
    static void moreThanTenDigitsIsRejected() {
        Test.startTest();
        try {
            insert new Sciagen_Account__c(
                Type__c = 'HCO', Name = 'Bad Phone Hospital', HCO_Type__c = 'Hospital', Speciality__c = 'Other',
                Phone__c = '987654321099'
            );
            System.assert(false, 'Expected a validation exception for a 12-digit phone number');
        } catch (DmlException e) {
            System.assert(e.getMessage().contains('more than 10 digits'));
        }
        Test.stopTest();
    }

    @isTest
    static void updatingAnUnrelatedFieldDoesNotRevalidatePhone() {
        Sciagen_Account__c hco = new Sciagen_Account__c(
            Type__c = 'HCO', Name = 'Untouched Phone Hospital', HCO_Type__c = 'Hospital', Speciality__c = 'Other',
            Phone__c = '9876543210'
        );
        insert hco;

        Test.startTest();
        hco.Name = 'Untouched Phone Hospital Renamed';
        update hco;
        Test.stopTest();

        System.assertEquals('Untouched Phone Hospital Renamed', [SELECT Name FROM Sciagen_Account__c WHERE Id = :hco.Id].Name);
    }
}