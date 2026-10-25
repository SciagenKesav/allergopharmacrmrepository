/**
 * Freezes what the rep originally planned. The iPad overwrites Call_DateTime__c
 * and Call_Type__c with the actual values when the call is completed, so without
 * this the plan would be lost and Planned vs Actual could not be measured.
 * Original_* is written once and never changed afterwards.
 */
public with sharing class PlannedCallOriginService {

    public static final String ORIGIN_PLANNED = 'Planned';
    public static final String ORIGIN_LOG = 'Call log';

    public static void capture(List<Planned_Call__c> rows, Map<Id, Planned_Call__c> oldMap) {
        for (Planned_Call__c pc : rows) {
            Planned_Call__c old = oldMap == null ? null : oldMap.get(pc.Id);
            if (String.isBlank(pc.Origin__c)) {
                String statusThen = old != null ? old.Status__c : pc.Status__c;
                pc.Origin__c = statusThen == 'Completed' ? ORIGIN_LOG : ORIGIN_PLANNED;
            }
            if (pc.Origin__c != ORIGIN_PLANNED) continue;
            if (pc.Original_Call_DateTime__c == null) {
                // Legacy row first touched by an update: what it held before this edit is the plan.
                pc.Original_Call_DateTime__c = old != null && old.Call_DateTime__c != null ? old.Call_DateTime__c : pc.Call_DateTime__c;
            }
            if (String.isBlank(pc.Original_Call_Type__c)) {
                pc.Original_Call_Type__c = old != null && !String.isBlank(old.Call_Type__c) ? old.Call_Type__c : pc.Call_Type__c;
            }
        }
        if (oldMap != null) {
            for (Planned_Call__c pc : rows) {
                Planned_Call__c old = oldMap.get(pc.Id);
                if (old.Original_Call_DateTime__c != null) pc.Original_Call_DateTime__c = old.Original_Call_DateTime__c;
                if (!String.isBlank(old.Original_Call_Type__c)) pc.Original_Call_Type__c = old.Original_Call_Type__c;
            }
        }
    }
}