@isTest
private class UserTerritoryDefaultNameTest {
    @isTest
    static void blankNameDefaultsToTheUsersName() {
        Territory__c t = new Territory__c(Name = 'Test Terr', Territory_Code__c = 'UTD_TST', Type__c = 'Territory');
        insert t;
        User_Territory__c ut = new User_Territory__c(User__c = UserInfo.getUserId(), Territory__c = t.Id, Is_Primary__c = true);
        insert ut;
        System.assertEquals(UserInfo.getName(), [SELECT Name FROM User_Territory__c WHERE Id = :ut.Id].Name);
    }
}