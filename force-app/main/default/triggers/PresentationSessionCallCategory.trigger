trigger PresentationSessionCallCategory on Presentation_Session__c (after insert, after delete, after undelete) {
    PresentationSessionCategoryService.sync(Trigger.isDelete ? Trigger.old : Trigger.new);
}