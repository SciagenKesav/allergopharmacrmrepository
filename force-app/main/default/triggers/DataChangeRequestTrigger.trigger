trigger DataChangeRequestTrigger on Data_Change_Request__c (before update) {
    if (Trigger.isBefore && Trigger.isUpdate) {
        DataChangeRequestApprovalHandler.handleApprovals(Trigger.new, Trigger.oldMap);
    }
}