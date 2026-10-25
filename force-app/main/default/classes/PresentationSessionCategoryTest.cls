@IsTest
private class PresentationSessionCategoryTest {
    @IsTest
    static void sessionFlipsCategoryBothWays() {
        Sciagen_Account__c hcp = new Sciagen_Account__c(
            Type__c = 'HCP', Name = 'Dr. Cat Test', Prefix__c = 'Dr.', First_Name__c = 'Cat',
            Last_Name__c = 'Test', Specialty__c = 'Cardiology', HCP_Type__c = 'Physician');
        insert hcp;
        Call_Visit_Report__c cvr = new Call_Visit_Report__c(HCP__c = hcp.Id, Visit_Date__c = Date.today(), Record_Status__c = 'Draft');
        insert cvr;

        Presentation__c p = new Presentation__c(Presentation_Name__c = 'Cat Deck', Version__c = 'v1', Approval_Status__c = 'Approved Promotional');
        insert p;
        Presentation_Session__c s = new Presentation_Session__c(CVR__c = cvr.Id, Presentation__c = p.Id);
        insert s;
        System.assertEquals('Call with CLM', [SELECT Call_Category__c FROM Call_Visit_Report__c WHERE Id = :cvr.Id].Call_Category__c);

        delete s;
        System.assertEquals('Call Only', [SELECT Call_Category__c FROM Call_Visit_Report__c WHERE Id = :cvr.Id].Call_Category__c);
    }
}