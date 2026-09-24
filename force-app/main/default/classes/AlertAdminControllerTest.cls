@isTest
private class AlertAdminControllerTest {

    @testSetup
    static void setup() {
        Id myProfileId = [SELECT ProfileId FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1].ProfileId;
        Datetime now = Datetime.now();

        Sciagen_Alert__c allUsers = new Sciagen_Alert__c(
            Title__c = 'System Maintenance', Message__c = 'Sync will be briefly unavailable.',
            Type__c = 'Company', Priority__c = 'Urgent', Audience_Type__c = 'All Users',
            Activation_Date__c = now.addHours(-1), Expiration_Date__c = now.addDays(30), Is_Active__c = true
        );
        Sciagen_Alert__c profileTargeted = new Sciagen_Alert__c(
            Title__c = 'New Formulary Win', Message__c = 'Emrok added to state formulary.',
            Type__c = 'Content', Priority__c = 'Important', Audience_Type__c = 'Profile',
            Target_Profile__c = myProfileId, Activation_Date__c = now.addHours(-2), Expiration_Date__c = now.addDays(30), Is_Active__c = true
        );
        Sciagen_Alert__c userTargeted = new Sciagen_Alert__c(
            Title__c = 'Your DCR was rejected', Message__c = 'See rejection reason on the request.',
            Type__c = 'DCR', Priority__c = 'Normal', Audience_Type__c = 'User',
            Target_User__c = UserInfo.getUserId(), Activation_Date__c = now.addHours(-3), Expiration_Date__c = now.addDays(30), Is_Active__c = true
        );
        Sciagen_Alert__c inactive = new Sciagen_Alert__c(
            Title__c = 'Retired Alert', Type__c = 'Company', Priority__c = 'Normal', Audience_Type__c = 'All Users',
            Activation_Date__c = now.addHours(-4), Expiration_Date__c = now.addDays(30), Is_Active__c = false
        );
        insert new List<Sciagen_Alert__c>{ allUsers, profileTargeted, userTargeted, inactive };
    }

    @isTest
    static void testGetAlertsReturnsAllSortedByActivationDateDescending() {
        Test.startTest();
        List<AlertAdminController.AlertDTO> alerts = AlertAdminController.getAlerts();
        Test.stopTest();

        System.assertEquals(4, alerts.size(), 'Admin queue must show every alert regardless of active/expired state');
        for (Integer i = 1; i < alerts.size(); i++) {
            System.assert(alerts[i - 1].activationDate >= alerts[i].activationDate, 'Must be sorted newest-first');
        }
        System.assertEquals('System Maintenance', alerts[0].title);

        Map<String, AlertAdminController.AlertDTO> byTitle = new Map<String, AlertAdminController.AlertDTO>();
        for (AlertAdminController.AlertDTO a : alerts) byTitle.put(a.title, a);

        System.assertEquals('All Users', byTitle.get('System Maintenance').audienceLabel);
        System.assert(byTitle.get('New Formulary Win').audienceLabel != 'All Users', 'Profile-targeted alert must resolve a profile name label');
        System.assertEquals(UserInfo.getName(), byTitle.get('Your DCR was rejected').audienceLabel);
    }

    @isTest
    static void testGetProfileOptionsReturnsProfiles() {
        Test.startTest();
        List<AlertAdminController.OptionDTO> options = AlertAdminController.getProfileOptions();
        Test.stopTest();

        System.assert(!options.isEmpty(), 'Org must have at least one Profile');
    }

    @isTest
    static void testGetUserOptionsFiltersByNameAndActive() {
        String firstNamePart = UserInfo.getName().substringBefore(' ');
        Test.startTest();
        List<AlertAdminController.OptionDTO> options = AlertAdminController.getUserOptions(firstNamePart);
        Test.stopTest();

        Boolean found = false;
        for (AlertAdminController.OptionDTO o : options) {
            if (o.id == UserInfo.getUserId()) found = true;
        }
        System.assertEquals(true, found, 'Running user must be findable by a substring of their own name');
    }

    @isTest
    static void testSaveAlertCreatesNewAlertWithDefaults() {
        Datetime expiry = Datetime.now().addDays(30);
        Test.startTest();
        Id newId = AlertAdminController.saveAlert(
            null, 'New Content Demo Available', 'Check out the new multi-format deck.',
            'Content', 'Normal', 'All Users', null, null, null, null, expiry
        );
        Test.stopTest();

        Sciagen_Alert__c created = [SELECT Title__c, Is_Active__c, Activation_Date__c FROM Sciagen_Alert__c WHERE Id = :newId];
        System.assertEquals('New Content Demo Available', created.Title__c);
        System.assertEquals(true, created.Is_Active__c, 'New alerts default active');
        System.assertNotEquals(null, created.Activation_Date__c, 'Activation date defaults to now when not supplied');
    }

    @isTest
    static void testSaveAlertUpdatesExistingAlert() {
        Sciagen_Alert__c existing = [SELECT Id FROM Sciagen_Alert__c WHERE Title__c = 'System Maintenance' LIMIT 1];

        Test.startTest();
        AlertAdminController.saveAlert(
            existing.Id, 'System Maintenance (Updated)', null,
            'Company', 'Important', 'All Users', null, null, null, Datetime.now(), Datetime.now().addDays(30)
        );
        Test.stopTest();

        Sciagen_Alert__c updated = [SELECT Title__c, Priority__c FROM Sciagen_Alert__c WHERE Id = :existing.Id];
        System.assertEquals('System Maintenance (Updated)', updated.Title__c);
        System.assertEquals('Important', updated.Priority__c);
        System.assertEquals(4, [SELECT COUNT() FROM Sciagen_Alert__c], 'Must update in place, not insert a second row');
    }

    @isTest
    static void testSaveAlertThrowsWhenExpirationDateMissing() {
        Test.startTest();
        try {
            AlertAdminController.saveAlert(
                null, 'No Expiration Set', null, 'Company', 'Normal', 'All Users', null, null, null, null, null
            );
            System.assert(false, 'Expected AuraHandledException for a missing expiration date');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @isTest
    static void testSaveAlertThrowsWhenAudienceTargetMissing() {
        Test.startTest();
        try {
            // audienceType 'User' with no targetUserId supplied
            AlertAdminController.saveAlert(
                null, 'Missing Target', null, 'Company', 'Normal', 'User', null, null, null, null, null
            );
            System.assert(false, 'Expected AuraHandledException for a User-audience alert with no target user');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @isTest
    static void testSaveAlertThrowsWhenRequiredFieldsMissing() {
        Test.startTest();
        try {
            AlertAdminController.saveAlert(
                null, '', null, 'Company', 'Normal', 'All Users', null, null, null, null, null
            );
            System.assert(false, 'Expected AuraHandledException for a blank title');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @isTest
    static void testSetActiveTogglesFlag() {
        Sciagen_Alert__c existing = [SELECT Id FROM Sciagen_Alert__c WHERE Title__c = 'Retired Alert' LIMIT 1];

        Test.startTest();
        AlertAdminController.setActive(existing.Id, true);
        Test.stopTest();

        System.assertEquals(true, [SELECT Is_Active__c FROM Sciagen_Alert__c WHERE Id = :existing.Id].Is_Active__c);
    }

    @isTest
    static void testSetActiveThrowsForUnknownId() {
        Test.startTest();
        try {
            AlertAdminController.setActive(UserInfo.getUserId(), false); // a valid Id of the wrong sObject type
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        Test.stopTest();
    }
}