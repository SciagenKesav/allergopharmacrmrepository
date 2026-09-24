trigger SupportCommentTrigger on Support_Comment__c (before insert, after insert) {
    if (Trigger.isBefore) SupportCommentService.beforeInsert(Trigger.new);
    else SupportCommentService.afterInsert(Trigger.new);
}