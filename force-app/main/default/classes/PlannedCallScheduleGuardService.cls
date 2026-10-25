/**
 * Enforces the scheduling rules: no calls outside business hours (09:00-18:00),
 * and no call dated
 * further back than the org's backdate limit. Deliberately in Apex rather
 * than a declarative Validation Rule -- Datetime.hour()/.hourGmt() give
 * explicit, reliable control over which time zone the hour check runs in,
 * where a formula's TIMEVALUE() on a Datetime field is a well-known source
 * of off-by-timezone bugs. Only applies to actual calls, not medical/speaker
 * events (Is_Event__c) -- those are frequently scheduled for evening dinner
 * symposiums as a matter of course, a different scenario than a rep dragging
 * an HCP/HCO onto a calendar slot.
 */
public without sharing class PlannedCallScheduleGuardService {

    // Hours come from Sciagen App Config (SciagenAppConfig): Call Day Start/End Hour.
    // Non-working days (Sunday by default) are no longer blocked here: the schedule form
    // shows a soft warning instead, and the call can still be scheduled.

    public static final Integer DEFAULT_BACKDATE_LIMIT_DAYS = 30;

    /** Tests set this instead of inserting a Call_Backdate_Limit__c row. */
    @TestVisible private static Integer testBackdateLimitDays;

    public static void validate(List<Planned_Call__c> calls) {
        Integer limitDays = backdateLimitDays();
        Date earliestAllowed = Date.today().addDays(-limitDays);
        for (Planned_Call__c pc : calls) {
            if (pc.Is_Event__c == true || pc.Call_DateTime__c == null) {
                continue;
            }
            if (!SciagenAppConfig.isWithinCallHours(pc.Call_DateTime__c)) {
                pc.Call_DateTime__c.addError('Calls must be scheduled within business hours (' + SciagenAppConfig.callHoursLabel() + ').');
                continue;
            }
            if (pc.Call_DateTime__c.date() < earliestAllowed) {
                pc.Call_DateTime__c.addError('A call can\'t be dated more than ' + limitDays +
                    (limitDays == 1 ? ' day' : ' days') + ' in the past (earliest allowed is ' + earliestAllowed.format() + ').');
            }
        }
    }

    /**
     * Call_Backdate_Limit__c is the same Hierarchy Custom Setting Allergo-pharma
     * uses to gate how far back a Call Visit Report's visit date may be edited
     * (SciagenCVRController.getCallBackdateLimitDays) -- reused here so a single
     * admin-configurable number (Setup -> Custom Settings -> Call Backdate Limit
     * -> Manage, org default or a per-Profile/per-User override, no deploy
     * needed) also gates how far back a rep can date a Planned Call. A blank
     * Days__c at every level falls back to DEFAULT_BACKDATE_LIMIT_DAYS.
     */
    public static Integer backdateLimitDays() {
        if (testBackdateLimitDays != null) return testBackdateLimitDays;
        Call_Backdate_Limit__c setting = Call_Backdate_Limit__c.getInstance();
        return (setting != null && setting.Days__c != null) ? Integer.valueOf(setting.Days__c) : DEFAULT_BACKDATE_LIMIT_DAYS;
    }

}