trigger SciagenAccountPhoneGuard on Sciagen_Account__c (before insert, before update) {
    List<Sciagen_Account__c> toCheck = new List<Sciagen_Account__c>();
    for (Sciagen_Account__c acc : Trigger.new) {
        Sciagen_Account__c old = Trigger.isInsert ? null : Trigger.oldMap.get(acc.Id);
        if (old == null || acc.Phone__c != old.Phone__c) {
            toCheck.add(acc);
        }
    }
    SciagenAccountPhoneGuardService.validate(toCheck);
}