/**
 * Org settings from the Sciagen_App_Config__mdt "Default" record (Setup →
 * Custom Metadata Types → Sciagen App Config → Default), with the shipped
 * defaults whenever a value is blank or out of range. Every scheduling,
 * planning and group-call rule reads from here; the iPad reads the same
 * record (DataService.fetchAppConfig), so both sides apply the same rules.
 *
 * Custom metadata reads don't count against SOQL limits and are cached per
 * transaction here.
 */
public without sharing class SciagenAppConfig {

    public static final Integer DEFAULT_DAY_START_HOUR = 9;
    public static final Integer DEFAULT_DAY_END_HOUR = 18;
    public static final String DEFAULT_NON_WORKING_DAYS = 'Sunday';
    public static final Integer DEFAULT_CALL_MINUTES = 30;
    public static final Integer DEFAULT_GAP_MINUTES = 30;
    public static final Integer DEFAULT_STEP_MINUTES = 30;
    public static final String DEFAULT_CALL_TYPE = 'Detailing';
    public static final Integer DEFAULT_FREEZE_MIN_CALLS = 1;
    public static final Integer DEFAULT_GRACE_DAYS = 14;
    public static final Integer DEFAULT_FOLLOW_UP_HOUR = 10;
    public static final List<String> DEFAULT_GROUP_MIRRORED_FIELDS = new List<String>{
        'Visit_Date__c', 'Start_Time__c', 'End_Time__c', 'Activity_Type__c', 'Call_Type__c', 'Call_Status__c',
        'Record_Status__c', 'Record_Type_Label__c', 'Rep__c', 'Territory__c', 'HCO__c', 'Discussion_Summary__c'
    };
    private static final List<String> WEEKDAYS = new List<String>{ 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday' };

    /** Tests set this instead of deploying custom metadata. */
    @TestVisible private static Sciagen_App_Config__mdt testRecord;
    private static Sciagen_App_Config__mdt cached;
    /** False when the org has no Default record: every setting is then its default. */
    private static Boolean hasRecord = true;

    @TestVisible
    private static Sciagen_App_Config__mdt record() {
        if (testRecord != null) return testRecord;
        if (cached == null) {
            cached = Sciagen_App_Config__mdt.getInstance('Default');
            if (cached == null) { cached = new Sciagen_App_Config__mdt(); hasRecord = false; }
        }
        return cached;
    }

    // ------------------------------------------------------------------ call scheduling

    public static Integer dayStartHour() {
        Integer v = intOr(record().Call_Day_Start_Hour__c, DEFAULT_DAY_START_HOUR);
        Integer e = intOr(record().Call_Day_End_Hour__c, DEFAULT_DAY_END_HOUR);
        return (v < 0 || v > 23 || e <= v || e > 24) ? DEFAULT_DAY_START_HOUR : v;
    }

    public static Integer dayEndHour() {
        Integer s = intOr(record().Call_Day_Start_Hour__c, DEFAULT_DAY_START_HOUR);
        Integer v = intOr(record().Call_Day_End_Hour__c, DEFAULT_DAY_END_HOUR);
        return (s < 0 || s > 23 || v <= s || v > 24) ? DEFAULT_DAY_END_HOUR : v;
    }

    /** Hour of `dt` (running user's time zone) is within the call day. */
    public static Boolean isWithinCallHours(Datetime dt) {
        Integer h = dt.hour();
        return h >= dayStartHour() && h < dayEndHour();
    }

    /** "9:00 AM - 6:00 PM" */
    public static String callHoursLabel() {
        return hourLabel(dayStartHour()) + ' - ' + hourLabel(dayEndHour());
    }

    /** Weekday names on which calls can't be planned, e.g. {'Sunday'}. */
    public static Set<String> nonWorkingDays() {
        String raw = record().Non_Working_Days__c;
        if (raw == null) raw = DEFAULT_NON_WORKING_DAYS;
        Set<String> out = new Set<String>();
        for (String part : raw.split(',')) {
            String p = part.trim();
            for (String w : WEEKDAYS) if (w.equalsIgnoreCase(p)) out.add(w);
        }
        return out;
    }

    public static Boolean isNonWorkingDay(Datetime dt) {
        return dt != null && nonWorkingDays().contains(dt.format('EEEE'));
    }

    public static Boolean isNonWorkingDay(Date d) {
        return d != null && isNonWorkingDay(Datetime.newInstance(d, Time.newInstance(12, 0, 0, 0)));
    }

    /** "Sunday" / "Saturday or Sunday" for messages. */
    public static String nonWorkingDaysLabel() {
        List<String> days = new List<String>();
        for (String w : WEEKDAYS) if (nonWorkingDays().contains(w)) days.add(w);
        if (days.isEmpty()) return 'a non-working day';
        if (days.size() == 1) return days[0];
        String last = days.remove(days.size() - 1);
        return String.join(days, ', ') + ' or ' + last;
    }

    /** Hour for an automatic follow-up call, kept inside the call day. */
    public static Integer followUpCallHour() {
        Integer h = intOr(record().Follow_Up_Call_Hour__c, DEFAULT_FOLLOW_UP_HOUR);
        return (h < dayStartHour() || h >= dayEndHour()) ? dayStartHour() : h;
    }

    // ------------------------------------------------------------------ scheduler + monthly plan

    public static Integer plannerCallMinutes() { return positive(record().Planner_Call_Minutes__c, DEFAULT_CALL_MINUTES); }
    public static Integer plannerGapMinutes() { return nonNegative(record().Planner_Gap_Minutes__c, DEFAULT_GAP_MINUTES); }
    public static Integer plannerStepMinutes() { return positive(record().Planner_Slot_Step_Minutes__c, DEFAULT_STEP_MINUTES); }
    public static String plannerDefaultCallType() {
        return String.isBlank(record().Planner_Default_Call_Type__c) ? DEFAULT_CALL_TYPE : record().Planner_Default_Call_Type__c.trim();
    }

    public static Boolean planFreezeEnabled() { return flag(record().Plan_Freeze_Enabled__c, true); }
    public static Integer planFreezeMinCalls() { return positive(record().Plan_Freeze_Min_Calls__c, DEFAULT_FREEZE_MIN_CALLS); }
    public static Boolean allowPastMonthFreeze() { return flag(record().Allow_Past_Month_Freeze__c, false); }
    /** Freezing the month's plan also locks the rep's segmentation for that month. */
    public static Boolean lockSegmentationOnFreeze() { return flag(record().Lock_Segmentation_On_Freeze__c, true); }

    // ------------------------------------------------------------------ group calls, plan vs actual, detailing

    public static Boolean groupCallsEnabled() { return flag(record().Group_Calls_Enabled__c, true); }

    /** Mirrored fields, only those that exist on Call_Visit_Report__c and can be written. */
    public static List<String> groupCallMirroredFields() {
        String raw = record().Group_Call_Mirrored_Fields__c;
        if (String.isBlank(raw)) return DEFAULT_GROUP_MIRRORED_FIELDS;
        Map<String, Schema.SObjectField> fields = Schema.SObjectType.Call_Visit_Report__c.fields.getMap();
        Set<String> blocked = new Set<String>{ 'hcp__c', 'parent_call__c', 'is_group_call__c', 'group_attendee_count__c', 'ownerid', 'id', 'name' };
        List<String> out = new List<String>();
        for (String part : raw.split(',')) {
            String f = part.trim();
            Schema.SObjectField sf = fields.get(f.toLowerCase());
            if (sf == null || blocked.contains(f.toLowerCase())) continue;
            Schema.DescribeFieldResult d = sf.getDescribe();
            if (d.isCalculated() || !d.isUpdateable()) continue;
            out.add(d.getName());
        }
        return out.isEmpty() ? DEFAULT_GROUP_MIRRORED_FIELDS : out;
    }

    public static Integer planVsActualGraceDays() { return nonNegative(record().Plan_Vs_Actual_Grace_Days__c, DEFAULT_GRACE_DAYS); }

    // ------------------------------------------------------------------ helpers

    private static Boolean flag(Boolean v, Boolean fallback) { return (!hasRecord && testRecord == null) || v == null ? fallback : v; }
    private static Integer intOr(Decimal d, Integer fallback) { return d == null ? fallback : d.intValue(); }
    private static Integer positive(Decimal d, Integer fallback) { return d == null || d <= 0 ? fallback : d.intValue(); }
    private static Integer nonNegative(Decimal d, Integer fallback) { return d == null || d < 0 ? fallback : d.intValue(); }

    private static String hourLabel(Integer h) {
        if (h == 0 || h == 24) return '12:00 AM';
        if (h == 12) return '12:00 PM';
        return (h > 12 ? h - 12 : h) + ':00 ' + (h >= 12 ? 'PM' : 'AM');
    }
}