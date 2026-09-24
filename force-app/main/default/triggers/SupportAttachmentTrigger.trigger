trigger SupportAttachmentTrigger on ContentDocumentLink (before insert, after insert, after delete) {
    if (Trigger.isBefore) SupportFileService.validateLinks(Trigger.new);
    else if (Trigger.isInsert) SupportFileService.countLinks(Trigger.new, 1);
    else SupportFileService.countLinks(Trigger.old, -1);
}