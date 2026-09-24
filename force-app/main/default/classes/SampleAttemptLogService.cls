/**
 * Records refused sample lines. A refused save rolls its own transaction back,
 * so the attempt is published as a platform event (which commits on its own)
 * and turned into a Sample_Blocked_Attempt__c by the event trigger.
 */
public without sharing class SampleAttemptLogService {

    public static void publish(Id productId, Id hcpId, Id repId, Id callId, Integer quantity, String reason) {
        try {
            EventBus.publish(new Sample_Attempt__e(Product_Id__c = productId, HCP_Id__c = hcpId, Rep_Id__c = repId, Call_Id__c = callId,
                Quantity__c = quantity, Reason__c = reason == null ? null : reason.left(255), Reason_Type__c = classify(reason)));
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Sample attempt not logged: ' + e.getMessage());
        }
    }

    public static String classify(String reason) {
        String r = reason == null ? '' : reason.toLowerCase();
        if (r.contains('restricted') || r.contains('hypnotic')) return 'Restricted_Product';
        if (r.contains('limit')) return 'Limit';
        if (r.contains('licence') || r.contains('license') || r.contains('prescribe')) return 'Licence';
        if (r.contains('cold chain')) return 'Cold_Chain';
        if (r.contains('signature')) return 'Signature';
        if (r.contains('lot') || r.contains('stock') || r.contains('expired')) return 'Lot_Or_Stock';
        return 'Other';
    }

    public static void log(List<Sample_Attempt__e> events) {
        List<Sample_Blocked_Attempt__c> rows = new List<Sample_Blocked_Attempt__c>();
        for (Sample_Attempt__e e : events) {
            rows.add(new Sample_Blocked_Attempt__c(
                Product__c = valid(e.Product_Id__c), HCP_Account__c = valid(e.HCP_Id__c), Rep__c = valid(e.Rep_Id__c), Call_Report__c = valid(e.Call_Id__c),
                Quantity__c = e.Quantity__c, Reason__c = e.Reason__c, Reason_Type__c = e.Reason_Type__c, Attempted_At__c = e.CreatedDate));
        }
        insert rows;
    }

    private static Id valid(String s) {
        try { return String.isBlank(s) ? null : (Id) s; } catch (Exception e) { return null; }
    }
}