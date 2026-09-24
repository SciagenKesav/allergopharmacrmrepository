trigger SampleLotTrigger on Sample_Lot__c (before insert, before update) {
    SampleLotService.beforeSave(Trigger.new, Trigger.isUpdate ? Trigger.oldMap : null);
}