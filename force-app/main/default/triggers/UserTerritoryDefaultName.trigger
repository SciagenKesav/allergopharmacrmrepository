// Names a User_Territory__c after its user when no Name was supplied (an import or API
// insert), so the record never shows up as a bare Salesforce Id.
trigger UserTerritoryDefaultName on User_Territory__c (before insert) {
    Set<Id> userIds = new Set<Id>();
    for (User_Territory__c ut : Trigger.new) {
        if (String.isBlank(ut.Name) && ut.User__c != null) userIds.add(ut.User__c);
    }
    if (userIds.isEmpty()) return;
    Map<Id, User> users = new Map<Id, User>([SELECT Id, Name FROM User WHERE Id IN :userIds]);
    for (User_Territory__c ut : Trigger.new) {
        if (String.isBlank(ut.Name) && ut.User__c != null && users.containsKey(ut.User__c)) {
            ut.Name = users.get(ut.User__c).Name;
        }
    }
}