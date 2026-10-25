@isTest
private class SupportAttachmentTriggerCoverageTest {

    @isTest
    static void deletingALinkRunsTheAfterDeleteBranch() {
        Support_Request__c r = new Support_Request__c(Subject__c = 'Attach test', Category__c = 'Other', Priority__c = 'Normal');
        insert r;
        ContentVersion cv = new ContentVersion(Title = 'note', PathOnClient = 'note.txt', VersionData = Blob.valueOf('hello'));
        insert cv;
        Id docId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        ContentDocumentLink l = new ContentDocumentLink(ContentDocumentId = docId, LinkedEntityId = r.Id, ShareType = 'V');
        insert l;
        delete l;
        System.assertEquals(0, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :r.Id AND ContentDocumentId = :docId]);
    }

    @isTest
    static void disallowedFileTypeIsRejectedOnLink() {
        Support_Request__c r = new Support_Request__c(Subject__c = 'Bad type', Category__c = 'Other', Priority__c = 'Normal');
        insert r;
        ContentVersion cv = new ContentVersion(Title = 'bad', PathOnClient = 'bad.exe', VersionData = Blob.valueOf('x'));
        insert cv;
        Id docId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        Database.SaveResult sr = Database.insert(new ContentDocumentLink(ContentDocumentId = docId, LinkedEntityId = r.Id, ShareType = 'V'), false);
        System.assert(!sr.isSuccess());
    }
}