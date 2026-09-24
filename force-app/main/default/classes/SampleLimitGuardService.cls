/**
 * Protects the regulatory (UCPMP) limits: they can't be deleted, switched off,
 * relaxed or overridden. Overrides for company limits start Pending (a rep's
 * request) and only a sample manager can make them Active.
 */
public with sharing class SampleLimitGuardService {

    public static void beforeLimitDelete(List<Sample_Limit__c> olds) {
        for (Sample_Limit__c l : olds) {
            if (l.Is_Regulatory__c == true) l.addError('UCPMP limits can\'t be deleted.');
        }
    }

    public static void beforeLimitUpdate(List<Sample_Limit__c> news, Map<Id, Sample_Limit__c> oldMap) {
        for (Sample_Limit__c l : news) {
            Sample_Limit__c o = oldMap.get(l.Id);
            if (o.Is_Regulatory__c != true) continue;
            if (l.Is_Regulatory__c != true) l.addError('A UCPMP limit can\'t stop being regulatory.');
            else if (l.Hard_Block__c != true) l.addError('A UCPMP limit must stay a hard block.');
            else if (l.Is_Active__c != true) l.addError('A UCPMP limit can\'t be switched off.');
            else if (l.Limit_Quantity__c > o.Limit_Quantity__c) l.addError('A UCPMP limit can\'t be raised.');
            else if (l.Limit_Scope__c != o.Limit_Scope__c || l.Limit_Period__c != o.Limit_Period__c || l.Product__c != o.Product__c) {
                l.addError('The scope, period and product of a UCPMP limit can\'t be changed.');
            }
        }
    }

    public static void beforeOverrideSave(List<Sample_Limit_Override__c> rows, Map<Id, Sample_Limit_Override__c> oldMap) {
        Set<Id> limitIds = new Set<Id>();
        for (Sample_Limit_Override__c r : rows) limitIds.add(r.Sample_Limit__c);
        Map<Id, Sample_Limit__c> limits = new Map<Id, Sample_Limit__c>([SELECT Id, Is_Regulatory__c FROM Sample_Limit__c WHERE Id IN :limitIds]);
        Boolean manager = FeatureManagement.checkPermission('Manage_Sample_Inventory');
        for (Sample_Limit_Override__c r : rows) {
            Sample_Limit_Override__c old = oldMap == null ? null : oldMap.get(r.Id);
            Sample_Limit__c lim = limits.get(r.Sample_Limit__c);
            if (lim != null && lim.Is_Regulatory__c == true) { r.addError('UCPMP limits can\'t be overridden.'); continue; }
            Boolean activating = r.Status__c == 'Active' && (old == null || old.Status__c != 'Active');
            if (activating) {
                if (!manager) { r.addError('Only a sample manager can approve an override.'); continue; }
                r.Approved_By__c = UserInfo.getUserId();
                r.Approved_At__c = System.now();
            }
        }
    }
}