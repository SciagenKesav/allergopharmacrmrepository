// Frozen monthly plans (MonthlyCallPlanService): keeps each call's Plan
// Deviation against the frozen baseline, protects the baseline fields, and
// stops a frozen call from being deleted (it must be cancelled instead).
trigger MonthlyPlanDeviation on Planned_Call__c (before insert, before update, before delete) {
    if (Trigger.isDelete) MonthlyCallPlanService.beforeDelete(Trigger.old);
    else MonthlyCallPlanService.beforeWrite(Trigger.new, Trigger.isUpdate ? Trigger.oldMap : null);
}