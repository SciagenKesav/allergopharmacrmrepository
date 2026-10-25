trigger PromoDropTrigger on Promo_Drop__c (before insert, before update) {
    PromoDropService.apply(Trigger.new, Trigger.oldMap);
}
