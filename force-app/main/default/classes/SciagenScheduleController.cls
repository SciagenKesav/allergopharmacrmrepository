/**
 * Backend for "My Schedule" — the logged-in rep's territory's Planned_Call__c
 * list, ported from the iOS CalendarPlannerView feature set (see the "My
 * Schedule — Salesforce LWC Port" plan for the full mapping). Deliberately
 * reuses SciagenAccountController's territory/search helpers rather than
 * duplicating them; Custom Lists and Saved Views are read via that
 * controller's existing getCustomLists()/getSavedViews() — this class only
 * adds what's missing: fetching planned calls for a date range, and
 * resolving one custom list's HCP membership for the schedule's Custom List
 * filter.
 *
 * getMyPlannedCalls() shows every call the running user has row-level access
 * to, not just ones they personally own — PlannedCallTerritorySharingService
 * keeps Planned_Call__Share in sync so a rep sees every rep's calls for an
 * HCP/HCO in a territory they're assigned to, the same way TerritorySharingService
 * already does for Sciagen_Account__c. A call always at least stays visible
 * to its own owner (Private OWD grants that regardless of shares), so this
 * only ever ADDS teammates' calls, never hides the rep's own.
 *
 * Security: `with sharing` + `WITH USER_MODE` on every SOQL statement, same as
 * SciagenAccountController.
 */
public with sharing class SciagenScheduleController {

    public class PlannedCallItem {
        @AuraEnabled public Id id;
        @AuraEnabled public Id hcpId;
        @AuraEnabled public String hcpName;
        @AuraEnabled public String specialty;
        @AuraEnabled public String hcpTerritory;
        @AuraEnabled public Id hcoId;
        @AuraEnabled public String hcoName;
        @AuraEnabled public String hcoTerritory;
        @AuraEnabled public Decimal latitude;
        @AuraEnabled public Decimal longitude;
        @AuraEnabled public Datetime callDateTime;
        @AuraEnabled public Integer durationMin;
        @AuraEnabled public String callType;
        @AuraEnabled public String status;
        @AuraEnabled public Boolean isEvent;
        @AuraEnabled public String eventTitle;
        @AuraEnabled public String venue;
        @AuraEnabled public Id productId;
        @AuraEnabled public String productName;
        @AuraEnabled public String programType;
        @AuraEnabled public Id resultingCVRId;
        // Drives the same Submitted/Saved/Draft color distinction the iPad
        // app's visitState(_:) makes on top of a CVR-linked call — without
        // this, every filed call just reads as "Completed" regardless of
        // whether the report itself was actually submitted.
        @AuraEnabled public String resultingCVRStatus;
        @AuraEnabled public Id ownerId;
        @AuraEnabled public String ownerName;
        @AuraEnabled public Boolean isMine;
    }

    /// Not cacheable — re-invoked after every create/edit/status-change/delete
    /// (form save, drag-and-drop quick-create, mark completed/cancelled) so the
    /// schedule always reflects the latest state, same reasoning as
    /// SciagenAccountController.getAccountDetail().
    ///
    /// Deliberately no OwnerId filter — row-level sharing (see this class's
    /// own doc comment) already limits the result to what the running user
    /// can see, which now includes every territory-mate's calls, not just
    /// their own.
    @AuraEnabled
    public static List<PlannedCallItem> getMyPlannedCalls(Date startDate, Date endDate) {
        Datetime startDt = Datetime.newInstance(startDate, Time.newInstance(0, 0, 0, 0));
        Datetime endDt = Datetime.newInstance(endDate, Time.newInstance(23, 59, 59, 999));
        Id currentUserId = UserInfo.getUserId();

        List<Planned_Call__c> calls = [
            SELECT Id, HCP__c, HCP__r.Name, HCP__r.Specialty__c, HCO__c, HCO__r.Name,
                   HCO__r.Geolocation__Latitude__s, HCO__r.Geolocation__Longitude__s,
                   Call_DateTime__c, Duration_Min__c, Call_Type__c, Status__c,
                   Is_Event__c, Event_Title__c, Venue__c, Product__c, Product__r.Name, Program_Type__c,
                   Resulting_CVR__c, Resulting_CVR__r.Record_Status__c, OwnerId
            FROM Planned_Call__c
            WHERE Call_DateTime__c >= :startDt AND Call_DateTime__c <= :endDt
            WITH USER_MODE
            ORDER BY Call_DateTime__c
        ];

        Set<Id> accountIds = new Set<Id>();
        Set<Id> ownerIds = new Set<Id>();
        for (Planned_Call__c c : calls) {
            if (c.HCP__c != null) { accountIds.add(c.HCP__c); }
            if (c.HCO__c != null) { accountIds.add(c.HCO__c); }
            ownerIds.add(c.OwnerId);
        }
        Map<Id, String> territoryByAccountId = SciagenAccountController.territoryNamesByAccountId(accountIds);

        // Looked up separately (rather than Owner.Name on the main query) so
        // this doesn't depend on FLS/relationship-traversal behavior for the
        // standard User object under WITH USER_MODE — a direct top-level
        // query on User is the same pattern territoryNamesByAccountId already
        // uses for its own lookups.
        Map<Id, String> ownerNameById = new Map<Id, String>();
        if (!ownerIds.isEmpty()) {
            for (User u : [SELECT Id, Name FROM User WHERE Id IN :ownerIds WITH USER_MODE]) {
                ownerNameById.put(u.Id, u.Name);
            }
        }

        List<PlannedCallItem> results = new List<PlannedCallItem>();
        for (Planned_Call__c c : calls) {
            PlannedCallItem item = new PlannedCallItem();
            item.id = c.Id;
            item.hcpId = c.HCP__c;
            item.hcpName = c.HCP__c != null ? c.HCP__r.Name : null;
            item.specialty = c.HCP__c != null ? c.HCP__r.Specialty__c : null;
            item.hcpTerritory = c.HCP__c != null ? territoryByAccountId.get(c.HCP__c) : null;
            item.hcoId = c.HCO__c;
            item.hcoName = c.HCO__c != null ? c.HCO__r.Name : null;
            item.hcoTerritory = c.HCO__c != null ? territoryByAccountId.get(c.HCO__c) : null;
            item.latitude = c.HCO__c != null ? c.HCO__r.Geolocation__Latitude__s : null;
            item.longitude = c.HCO__c != null ? c.HCO__r.Geolocation__Longitude__s : null;
            item.callDateTime = c.Call_DateTime__c;
            item.durationMin = c.Duration_Min__c != null ? c.Duration_Min__c.intValue() : 30;
            item.callType = c.Call_Type__c;
            item.status = c.Status__c;
            item.isEvent = c.Is_Event__c;
            item.eventTitle = c.Event_Title__c;
            item.venue = c.Venue__c;
            item.productId = c.Product__c;
            item.productName = c.Product__c != null ? c.Product__r.Name : null;
            item.programType = c.Program_Type__c;
            item.resultingCVRId = c.Resulting_CVR__c;
            item.resultingCVRStatus = c.Resulting_CVR__c != null ? c.Resulting_CVR__r.Record_Status__c : null;
            item.ownerId = c.OwnerId;
            item.ownerName = ownerNameById.get(c.OwnerId);
            item.isMine = c.OwnerId == currentUserId;
            results.add(item);
        }
        return results;
    }

    /// Account ids (HCP or HCO — Custom_List_Member__c.HCP__c is a lookup to
    /// Sciagen_Account__c generically, not type-restricted, since
    /// accountBrowser.js's "Add to List" lets a rep select either type) that
    /// belong to the given Custom_List__c. Used by both accountBrowser's own
    /// Custom List filter (matches either type) and My Schedule's narrower
    /// one, which can only match a Planned Call's hcpId — so a list holding
    /// only HCOs won't surface any calls there, since a planned call has no
    /// hcpId to compare against.
    @AuraEnabled(cacheable=true)
    public static List<Id> getCustomListMemberIds(Id listId) {
        List<Id> ids = new List<Id>();
        for (Custom_List_Member__c m : [
            SELECT HCP__c FROM Custom_List_Member__c WHERE List__c = :listId WITH USER_MODE
        ]) {
            ids.add(m.HCP__c);
        }
        return ids;
    }
}