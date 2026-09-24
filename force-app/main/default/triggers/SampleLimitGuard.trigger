trigger SampleLimitGuard on Sample_Limit__c (before update, before delete) {
    if (Trigger.isDelete) SampleLimitGuardService.beforeLimitDelete(Trigger.old);
    else SampleLimitGuardService.beforeLimitUpdate(Trigger.new, Trigger.oldMap);
}