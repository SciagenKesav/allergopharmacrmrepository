/**
 * Service targets and switches for Help & Support, with defaults when nothing
 * is saved in Support_Setting__c (getOrgDefaults() returns an empty record).
 */
public without sharing class SupportConfig {
    public Integer slaUrgentHours = 4;
    public Integer slaHighHours = 8;
    public Integer slaNormalHours = 24;
    public Integer slaLowHours = 72;
    public Integer closeResolvedDays = 7;
    public Integer closeWaitingDays = 14;
    public Integer reopenDays = 14;
    public Integer maxRequestsPerDay = 20;
    public Integer maxCommentsPerDay = 200;
    public Boolean sendEmails = true;
    public Boolean autoAssign = false;

    private static SupportConfig cached;

    public static SupportConfig load() {
        if (cached != null) return cached;
        SupportConfig c = new SupportConfig();
        Support_Setting__c r = Support_Setting__c.getOrgDefaults();
        if (r != null && r.Id != null) {
            if (r.Sla_Urgent_Hours__c != null) c.slaUrgentHours = r.Sla_Urgent_Hours__c.intValue();
            if (r.Sla_High_Hours__c != null) c.slaHighHours = r.Sla_High_Hours__c.intValue();
            if (r.Sla_Normal_Hours__c != null) c.slaNormalHours = r.Sla_Normal_Hours__c.intValue();
            if (r.Sla_Low_Hours__c != null) c.slaLowHours = r.Sla_Low_Hours__c.intValue();
            if (r.Auto_Close_Resolved_Days__c != null) c.closeResolvedDays = r.Auto_Close_Resolved_Days__c.intValue();
            if (r.Auto_Close_Waiting_Days__c != null) c.closeWaitingDays = r.Auto_Close_Waiting_Days__c.intValue();
            if (r.Reopen_Window_Days__c != null) c.reopenDays = r.Reopen_Window_Days__c.intValue();
            if (r.Max_Requests_Per_Day__c != null) c.maxRequestsPerDay = r.Max_Requests_Per_Day__c.intValue();
            if (r.Max_Comments_Per_Day__c != null) c.maxCommentsPerDay = r.Max_Comments_Per_Day__c.intValue();
            c.sendEmails = r.Send_Emails__c == true;
            c.autoAssign = r.Auto_Assign__c == true;
        }
        cached = c;
        return c;
    }

    @TestVisible private static void reset() { cached = null; }

    /** When a first reply is due for a request raised at the given time. */
    public Datetime firstResponseDue(String priority, Datetime raisedAt) {
        Integer hours = slaNormalHours;
        if (priority == 'Urgent') hours = slaUrgentHours;
        else if (priority == 'High') hours = slaHighHours;
        else if (priority == 'Low') hours = slaLowHours;
        return raisedAt.addHours(hours);
    }
}