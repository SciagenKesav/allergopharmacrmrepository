/**
 * Reads one KAM's activity for one HCP (call reports, planned calls, sent emails, office windows,
 * change requests) for SciagenTeamScheduleApi's account-activity endpoint -- the Timeline /
 * Engagement / Activity / DCR tabs a manager sees inside a KAM's doctor profile on the iPad.
 *
 * `without sharing` for the same reason as ScheduleCrossUserReader and TeamAccountsReader: these
 * objects are Private (owned by the KAM), so a manager cannot read them through normal sharing, and
 * `WITH USER_MODE` would re-apply sharing and return nothing. Field-level security is still
 * enforced for the manager (WITH SECURITY_ENFORCED). The caller authorises the manager -> KAM
 * relationship; this class runs for whatever kamId / hcpId it is given.
 *
 * Rows are limited to the KAM's own records for that HCP (OwnerId = the KAM). Office windows are
 * the one exception: they belong to the doctor, not a rep, so all of the doctor's windows return.
 */
public without sharing class TeamAccountActivityReader {

    private static final Integer ROW_LIMIT = 500;

    public static Map<String, Object> forKam(Id kamId, Id hcpId) {
        List<Map<String, Object>> cvrs = new List<Map<String, Object>>();
        for (Call_Visit_Report__c c : [
            SELECT Id, Visit_Date__c, Call_Type__c, HCO__r.Name, Record_Status__c, Duration_Min__c
            FROM Call_Visit_Report__c
            WHERE OwnerId = :kamId AND HCP__c = :hcpId
            WITH SECURITY_ENFORCED ORDER BY Visit_Date__c DESC, CreatedDate DESC LIMIT :ROW_LIMIT
        ]) {
            cvrs.add(new Map<String, Object>{
                'id' => c.Id, 'visitDate' => c.Visit_Date__c, 'callType' => c.Call_Type__c,
                'hcoName' => c.HCO__r != null ? c.HCO__r.Name : null,
                'recordStatus' => c.Record_Status__c, 'durationMin' => c.Duration_Min__c
            });
        }

        List<Map<String, Object>> plannedCalls = new List<Map<String, Object>>();
        for (Planned_Call__c p : [
            SELECT Id, Call_DateTime__c, Call_Type__c, HCO__r.Name, Status__c, Duration_Min__c
            FROM Planned_Call__c
            WHERE OwnerId = :kamId AND HCP__c = :hcpId
            WITH SECURITY_ENFORCED ORDER BY Call_DateTime__c DESC LIMIT :ROW_LIMIT
        ]) {
            plannedCalls.add(new Map<String, Object>{
                'id' => p.Id, 'callDateTime' => p.Call_DateTime__c, 'callType' => p.Call_Type__c,
                'hcoName' => p.HCO__r != null ? p.HCO__r.Name : null,
                'status' => p.Status__c, 'durationMin' => p.Duration_Min__c
            });
        }

        List<Map<String, Object>> emails = new List<Map<String, Object>>();
        for (Sent_Email__c e : [
            SELECT Id, Subject__c, Template__r.Name, To_Email__c, Sent_At__c,
                   (SELECT Id FROM Attachments__r)
            FROM Sent_Email__c
            WHERE OwnerId = :kamId AND HCP__c = :hcpId
            WITH SECURITY_ENFORCED ORDER BY Sent_At__c DESC LIMIT :ROW_LIMIT
        ]) {
            emails.add(new Map<String, Object>{
                'id' => e.Id, 'subject' => e.Subject__c,
                'templateName' => e.Template__r != null ? e.Template__r.Name : null,
                'toEmail' => e.To_Email__c, 'sentAt' => e.Sent_At__c,
                'attachmentCount' => e.Attachments__r.size()
            });
        }

        List<Map<String, Object>> officeWindows = new List<Map<String, Object>>();
        for (Office_Window__c w : [
            SELECT Id, Day__c, Window__c, Preference__c, HCO__c, HCO__r.Name
            FROM Office_Window__c WHERE HCP__c = :hcpId
            WITH SECURITY_ENFORCED ORDER BY Day__c LIMIT :ROW_LIMIT
        ]) {
            officeWindows.add(new Map<String, Object>{
                'id' => w.Id, 'day' => w.Day__c, 'window' => w.Window__c, 'preference' => w.Preference__c,
                'hcoId' => w.HCO__c, 'hcoName' => w.HCO__r != null ? w.HCO__r.Name : null
            });
        }

        List<Map<String, Object>> dcrs = new List<Map<String, Object>>();
        for (Data_Change_Request__c d : [
            SELECT Id, Type__c, Status__c, Subject_Name__c, Summary__c, Submitted_By__c, Submitted_At__c, Rejection_Reason__c
            FROM Data_Change_Request__c
            WHERE OwnerId = :kamId AND Subject_Account__c = :hcpId
            WITH SECURITY_ENFORCED ORDER BY Submitted_At__c DESC NULLS LAST LIMIT :ROW_LIMIT
        ]) {
            dcrs.add(new Map<String, Object>{
                'id' => d.Id, 'type' => d.Type__c, 'status' => d.Status__c, 'subjectName' => d.Subject_Name__c,
                'summary' => d.Summary__c, 'submittedBy' => d.Submitted_By__c, 'submittedAt' => d.Submitted_At__c,
                'rejectionReason' => d.Rejection_Reason__c
            });
        }

        return new Map<String, Object>{
            'success' => true, 'cvrs' => cvrs, 'plannedCalls' => plannedCalls, 'emails' => emails,
            'officeWindows' => officeWindows, 'dcrs' => dcrs
        };
    }
}