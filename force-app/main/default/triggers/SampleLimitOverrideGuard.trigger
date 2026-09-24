trigger SampleLimitOverrideGuard on Sample_Limit_Override__c (before insert, before update) {
    SampleLimitGuardService.beforeOverrideSave(Trigger.new, Trigger.isUpdate ? Trigger.oldMap : null);
}