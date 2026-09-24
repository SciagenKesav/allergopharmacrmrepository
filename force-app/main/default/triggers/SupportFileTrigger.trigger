trigger SupportFileTrigger on ContentVersion (before insert) {
    SupportFileService.validateVersions(Trigger.new);
}