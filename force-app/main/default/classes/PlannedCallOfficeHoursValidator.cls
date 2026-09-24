/**
 * Enforces office-hours scheduling on Planned_Call__c: a call's start time,
 * and its end time (start + Duration_Min__c), must both fall within the
 * window configured on Office_Hours_Setting__mdt's "Default" record (e.g.
 * 8:00 AM - 8:00 PM). Applies the same way to every user — System
 * Administrator and Standard Platform User are the only two profiles active
 * in this org, so there's no profile-based carve-out to make.
 *
 * Runs from a trigger rather than a Controller method because Planned_Call__c
 * is created/edited from several entry points that don't share a common Apex
 * call path: the web app's scheduleCallForm LWC saves straight through
 * lightning-record-edit-form (UI API, no Apex in between), and the iPad app
 * writes the sobject directly over the REST API. A before-insert/before-update
 * trigger is the one place every one of those passes through — see
 * PlannedCallOfficeHoursValidation.trigger.
 */
public without sharing class PlannedCallOfficeHoursValidator {

    public static void validate(List<Planned_Call__c> records, Map<Id, Planned_Call__c> oldMap) {
        List<Office_Hours_Setting__mdt> configs = [
            SELECT Start_Time__c, End_Time__c
            FROM Office_Hours_Setting__mdt
            WHERE DeveloperName = 'Default'
            LIMIT 1
        ];
        if (configs.isEmpty()) { return; } // not configured — nothing to enforce
        Time windowStart = parseHHmm(configs[0].Start_Time__c);
        Time windowEnd = parseHHmm(configs[0].End_Time__c);
        if (windowStart == null || windowEnd == null) { return; } // misconfigured — fail open, not closed

        for (Planned_Call__c pc : records) {
            if (pc.Call_DateTime__c == null) { continue; }

            // On update, only re-check when what actually drives the window
            // changed — an unrelated edit (e.g. marking an already-valid,
            // previously-saved call Completed/Cancelled) shouldn't get
            // re-blocked by a rule that only concerns scheduling.
            if (oldMap != null) {
                Planned_Call__c old = oldMap.get(pc.Id);
                if (old.Call_DateTime__c == pc.Call_DateTime__c && old.Duration_Min__c == pc.Duration_Min__c) {
                    continue;
                }
            }

            Integer durationMin = pc.Duration_Min__c != null ? pc.Duration_Min__c.intValue() : 30;
            // Datetime.time() — unlike .timeGmt() — already returns the
            // time-of-day in the running user's local time zone, so no
            // manual GMT-offset conversion is needed (or wanted: doing it by
            // hand here double-applies the offset that .time() already did).
            Time callStart = pc.Call_DateTime__c.time();
            Time callEnd = callStart.addMinutes(durationMin);

            // callEnd < callStart means the call wrapped past midnight (e.g.
            // an overnight duration) — always outside the window, regardless
            // of where windowStart/windowEnd happen to sit.
            Boolean withinWindow = callStart >= windowStart && callEnd <= windowEnd && callEnd >= callStart;

            if (!withinWindow) {
                pc.Call_DateTime__c.addError(
                    'Calls can only be planned within office hours (' + formatTime(windowStart) +
                    ' - ' + formatTime(windowEnd) + '). This call is scheduled ' +
                    formatTime(callStart) + ' - ' + formatTime(callEnd) + '.'
                );
            }
        }
    }

    /// "08:00"/"20:00" -> Time. Returns null (rather than throwing) for a
    /// blank or malformed config value, so a typo in Setup disables the rule
    /// instead of hard-locking every rep out of scheduling calls.
    private static Time parseHHmm(String hhmm) {
        if (String.isBlank(hhmm) || !Pattern.matches('^\\d{1,2}:\\d{2}$', hhmm)) { return null; }
        List<String> parts = hhmm.split(':');
        Integer hour = Integer.valueOf(parts[0]);
        Integer minute = Integer.valueOf(parts[1]);
        if (hour < 0 || hour > 23 || minute < 0 || minute > 59) { return null; }
        return Time.newInstance(hour, minute, 0, 0);
    }

    /// Time has no .format() of its own — borrow Date.today() as a throwaway
    /// date just to reuse Datetime's locale-aware "hh:mm a" formatting.
    private static String formatTime(Time t) {
        return Datetime.newInstance(Date.today(), t).format('hh:mm a');
    }
}
