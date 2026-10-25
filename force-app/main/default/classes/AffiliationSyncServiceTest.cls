@isTest
private class AffiliationSyncServiceTest {

    private static Sciagen_Account__c hcp(String last) {
        return new Sciagen_Account__c(
            Type__c = 'HCP', Name = 'Dr. ' + last, Prefix__c = 'Dr.', First_Name__c = 'Aff',
            Last_Name__c = last, Specialty__c = 'Cardiology', HCP_Type__c = 'Physician',
            Billing_City__c = 'Own City'
        );
    }

    private static Sciagen_Account__c hco(String name, String city) {
        return new Sciagen_Account__c(Type__c = 'HCO', Name = name, HCO_Type__c = 'Hospital', Billing_City__c = city);
    }

    @isTest
    static void primaryAffiliationMirrorsHcoAddress() {
        Sciagen_Account__c doc = hcp('Primary');
        Sciagen_Account__c hosp = hco('Mirror Hospital', 'Pune');
        insert new List<Sciagen_Account__c>{ doc, hosp };

        Test.startTest();
        insert new Affiliation__c(HCP__c = doc.Id, HCO__c = hosp.Id, Is_Primary__c = true);
        Test.stopTest();

        System.assertEquals('Pune', [SELECT Billing_City__c FROM Sciagen_Account__c WHERE Id = :doc.Id].Billing_City__c);
    }

    @isTest
    static void nonPrimaryAffiliationLeavesHcpAddressAlone() {
        Sciagen_Account__c doc = hcp('NonPrimary');
        Sciagen_Account__c hosp = hco('Secondary Clinic', 'Nagpur');
        insert new List<Sciagen_Account__c>{ doc, hosp };

        Test.startTest();
        insert new Affiliation__c(HCP__c = doc.Id, HCO__c = hosp.Id, Is_Primary__c = false);
        Test.stopTest();

        System.assertEquals('Own City', [SELECT Billing_City__c FROM Sciagen_Account__c WHERE Id = :doc.Id].Billing_City__c,
            'Adding a non-primary affiliation must not clear the doctor\'s address');
    }

    @isTest
    static void removingThePrimaryClearsTheMirroredAddress() {
        Sciagen_Account__c doc = hcp('Removed');
        Sciagen_Account__c hosp = hco('Old Hospital', 'Surat');
        insert new List<Sciagen_Account__c>{ doc, hosp };
        Affiliation__c aff = new Affiliation__c(HCP__c = doc.Id, HCO__c = hosp.Id, Is_Primary__c = true);
        insert aff;

        Test.startTest();
        delete aff;
        Test.stopTest();

        System.assertEquals(null, [SELECT Billing_City__c FROM Sciagen_Account__c WHERE Id = :doc.Id].Billing_City__c);
    }

    @isTest
    static void onlyOnePrimaryPerHcp() {
        Sciagen_Account__c doc = hcp('TwoPrimaries');
        Sciagen_Account__c a = hco('First', 'Agra');
        Sciagen_Account__c b = hco('Second', 'Kochi');
        insert new List<Sciagen_Account__c>{ doc, a, b };
        insert new Affiliation__c(HCP__c = doc.Id, HCO__c = a.Id, Is_Primary__c = true);

        Test.startTest();
        insert new Affiliation__c(HCP__c = doc.Id, HCO__c = b.Id, Is_Primary__c = true);
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Affiliation__c WHERE HCP__c = :doc.Id AND Is_Primary__c = true]);
        System.assertEquals('Kochi', [SELECT Billing_City__c FROM Sciagen_Account__c WHERE Id = :doc.Id].Billing_City__c);
    }
}