/**
 * Keeps Call_Visit_Report__c.Call_Category__c in step with CLM use: a report with
 * at least one presentation session is "Call with CLM", otherwise "Call Only".
 */
public without sharing class PresentationSessionCategoryService {
    public static void sync(List<Presentation_Session__c> sessions) {
        Set<Id> cvrIds = new Set<Id>();
        for (Presentation_Session__c s : sessions) {
            if (s.CVR__c != null) cvrIds.add(s.CVR__c);
        }
        if (cvrIds.isEmpty()) return;
        Set<Id> withSessions = new Set<Id>();
        for (AggregateResult ar : [SELECT CVR__c cvr FROM Presentation_Session__c
                                   WHERE CVR__c IN :cvrIds GROUP BY CVR__c]) {
            withSessions.add((Id) ar.get('cvr'));
        }
        List<Call_Visit_Report__c> upd = new List<Call_Visit_Report__c>();
        for (Call_Visit_Report__c c : [SELECT Id, Call_Category__c FROM Call_Visit_Report__c WHERE Id IN :cvrIds]) {
            String want = withSessions.contains(c.Id) ? 'Call with CLM' : 'Call Only';
            // Only manage blank or the two built-in values; any other label the app
            // sent (e.g. a newly added iPad call type) is left as stored.
            Boolean managed = String.isBlank(c.Call_Category__c)
                || c.Call_Category__c == 'Call Only' || c.Call_Category__c == 'Call with CLM';
            if (managed && c.Call_Category__c != want) { c.Call_Category__c = want; upd.add(c); }
        }
        if (!upd.isEmpty()) update upd;
    }
}
