/**
 * Runs the cross-user Planned_Call__c/Call_Visit_Report__c reads for
 * SciagenScheduleController.getPlannedCallsForUser's manager-viewing-a-KAM case.
 *
 * `without sharing` (not AccessLevel.SYSTEM_MODE) is deliberate: AccessLevel.SYSTEM_MODE
 * does not reliably bypass Private-object record sharing for plain SELECT queries in this
 * org — confirmed empirically, the same surprising gap already documented on
 * TerritorySharingService's insert path (see DeferredShareInsertQueueable). A manager with
 * full object CRUD (granted via permission set) and an explicit `WITH SYSTEM_MODE` clause
 * still saw zero rows for a KAM's owned record. `without sharing` is the older, already-
 * proven mechanism this codebase's own territory sharing services rely on instead.
 *
 * The caller (getPlannedCallsForUser) is solely responsible for authorization: this class
 * runs unconditionally for whatever ownerId it's given, same as any other `without sharing`
 * service in this codebase.
 */
public without sharing class ScheduleCrossUserReader {

    public static List<Planned_Call__c> plannedCallsForOwner(Id ownerId, Datetime startDt, Datetime endDt) {
        return [
            SELECT Id, HCP__c, HCP__r.Name, HCP__r.Specialty__c, HCO__c, HCO__r.Name,
                   HCO__r.Geolocation__Latitude__s, HCO__r.Geolocation__Longitude__s,
                   Call_DateTime__c, Duration_Min__c, Call_Type__c, Status__c,
                   Is_Event__c, Event_Title__c, Venue__c, Product__c, Product__r.Name, Program_Type__c,
                   Resulting_CVR__c, Resulting_CVR__r.Record_Status__c, Resulting_CVR__r.Call_Category__c, Call_Category__c
            FROM Planned_Call__c
            WHERE OwnerId = :ownerId AND Call_DateTime__c >= :startDt AND Call_DateTime__c <= :endDt
            ORDER BY Call_DateTime__c
        ];
    }

    public static List<Call_Visit_Report__c> walkInsForOwner(Id ownerId, Date startDate, Date endDate) {
        return [
            SELECT Id, HCP__c, HCP__r.Name, HCP__r.Specialty__c, HCO__c, HCO__r.Name,
                   HCO__r.Geolocation__Latitude__s, HCO__r.Geolocation__Longitude__s,
                   Call_Type__c, Visit_Date__c, Start_Time__c, End_Time__c, Check_In_At__c, Record_Status__c, Call_Category__c
            FROM Call_Visit_Report__c
            WHERE OwnerId = :ownerId AND Source_Planned_Call__c = null
              AND Visit_Date__c >= :startDate AND Visit_Date__c <= :endDate
              AND Id NOT IN (SELECT Resulting_CVR__c FROM Planned_Call__c WHERE Resulting_CVR__c != null)
            ORDER BY Visit_Date__c, Start_Time__c
        ];
    }

    public static List<Leave_Request__c> leaveForOwner(Id ownerId, Date startDate, Date endDate) {
        return [
            SELECT From_Date__c, To_Date__c, Type__c, Status__c FROM Leave_Request__c
            WHERE OwnerId = :ownerId AND Status__c IN ('Pending', 'Approved')
              AND From_Date__c <= :endDate AND To_Date__c >= :startDate
        ];
    }
}
