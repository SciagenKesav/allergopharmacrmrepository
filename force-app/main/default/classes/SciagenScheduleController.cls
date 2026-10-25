/**
 * Backend for "My Schedule" — the logged-in rep's Planned_Call__c list, ported
 * from the iOS CalendarPlannerView feature set (see the "My Schedule — Salesforce
 * LWC Port" plan for the full mapping). Deliberately reuses
 * SciagenAccountController's territory/search helpers rather than duplicating
 * them; Custom Lists and Saved Views are read via that controller's existing
 * getCustomLists()/getSavedViews() — this class only adds what's missing:
 * fetching the rep's own planned calls for a date range, and resolving one
 * custom list's HCP membership for the schedule's Custom List filter.
 *
 * Security: `with sharing` + `WITH USER_MODE` on every SOQL statement, same as
 * SciagenAccountController — except getPlannedCallsForUser's own query when a manager
 * is viewing a KAM's schedule (see that method's doc).
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
        // Record_Status__c of the linked report (Draft/Saved/Submitted) -- drives the Submitted/Saved/Draft colours.
        @AuraEnabled public String resultingCVRStatus;
        // Submitted Call Visit Reports are compliance/audit records — the
        // server (PlannedCallDeleteGuard trigger) rejects deleting a call
        // once its report is submitted, so the UI hides Delete for these
        // instead of surfacing a raw DML error.
        @AuraEnabled public Boolean isLocked;
        // 'Call with CLM' or 'Call Only' (mirrors the iPad's Call Only pill).
        @AuraEnabled public String callCategory;
        // A Call Visit Report with no Planned_Call__c behind it (a walk-in / unplanned
        // visit). It's shown on the schedule as a completed visit so it isn't invisible,
        // but there is no planned call to edit, complete, cancel or delete -- `id` is the
        // report's own Id and the only action is opening it.
        @AuraEnabled public Boolean isReportOnly;
    }

    public class KamUserOption {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String territoryName;
        @AuraEnabled public List<String> territoryIds = new List<String>();
    }

    public class TerritoryOption {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public Id parentId;
        @AuraEnabled public String type;
    }

    /// What the My Schedule picker should offer the running user.
    ///   SELF    - a KAM (or anyone without a team): no picker, just their own schedule.
    ///   MANAGER - a manager: the KAMs in their own territories.
    ///   ADMIN   - Business Admin / System Admin: Region -> Territory -> KAM.
    public class SchedulePickerData {
        @AuraEnabled public String mode = 'SELF';
        @AuraEnabled public List<TerritoryOption> territories = new List<TerritoryOption>();
        @AuraEnabled public List<KamUserOption> kams = new List<KamUserOption>();
    }

    /// True for a user who should get the "view a KAM's schedule" picker on My Schedule:
    /// the Manager profile, or a UserRole whose name contains "Manager" (this org's
    /// regional-manager roles are named e.g. "North Region Manager" — there's no role
    /// literally called "Manager", so a substring match on the role name is what actually
    /// covers them).
    @AuraEnabled(cacheable=true)
    public static Boolean isManagerOrHasManagerRole() {
        User me = [SELECT Profile.Name, Profile.PermissionsViewAllData, UserRole.Name FROM User WHERE Id = :UserInfo.getUserId() WITH USER_MODE LIMIT 1];
        // A user in the "Key Account Manager" role only ever sees their own schedule. The role name
        // contains "manager", so without this the substring match below handed every KAM the picker
        // (and a list of their peers). Decided by role, not profile, so a KAM-profile user placed in
        // a regional-manager role (e.g. "North Region Manager") still counts as a manager.
        if (me.UserRole != null && me.UserRole.Name == 'Key Account Manager') { return false; }
        if (me.Profile.Name == 'Manager') { return true; }
        if (me.Profile.Name == 'Business Admin') { return true; }
        // A System Administrator (View All Data) can view any KAM's schedule too.
        if (me.Profile.PermissionsViewAllData == true) { return true; }
        return me.UserRole != null && me.UserRole.Name != null && me.UserRole.Name.toLowerCase().contains('manager');
    }

    /// KAM users a manager can view the schedule of: every Key Account Manager profile
    /// user assigned (directly, or via TerritoryHierarchyUtil's descendant walk — same
    /// model TerritorySharingService uses for account sharing) to one of the running
    /// manager's own User_Territory__c territories. Empty for a non-manager or a manager
    /// with no territory assignment of their own, rather than throwing — the LWC only
    /// shows the picker when isManagerOrHasManagerRole() is true, but this stays safe
    /// either way since it's cacheable and called directly from the client too.
    ///
    /// The KAM-matching query runs at AccessLevel.SYSTEM_MODE rather than WITH USER_MODE:
    /// most non-admin profiles (Manager included) have no read access to the Profile
    /// object itself, so `User__r.Profile.Name` resolves to null under USER_MODE for
    /// anyone but the record's own owner or an admin — confirmed empirically, this isn't
    /// hypothetical — silently matching zero rows instead of throwing. That's safe to
    /// elevate here only because this method already gated on isManagerOrHasManagerRole()
    /// above and scoped the search to visibleTerritoryIds, which came from the running
    /// manager's own legitimate User_Territory__c rows — never an open-ended user lookup.
    @AuraEnabled(cacheable=true)
    public static List<KamUserOption> getKamUsersInMyTerritory() {
        if (!isManagerOrHasManagerRole()) { return new List<KamUserOption>(); }

        // View All Data (System Administrator): every active KAM, not scoped to the
        // admin's own territories (an admin normally has none assigned).
        Boolean viewAll = isAdminView();
        if (viewAll) {
            // Every active KAM, including ones with no territory assigned yet.
            List<User> kams = [
                SELECT Id, Name FROM User
                WHERE Profile.Name = 'Key Account Manager' AND IsActive = true
                ORDER BY Name
            ];
            Map<Id, String> firstTerritory = new Map<Id, String>();
            Map<Id, List<String>> territoryIdsByUser = new Map<Id, List<String>>();
            for (User_Territory__c ut : [
                SELECT User__c, Territory__c, Territory__r.Name FROM User_Territory__c
                WHERE User__c IN :kams AND Territory__c != null
                ORDER BY Is_Primary__c DESC, CreatedDate
            ]) {
                if (!firstTerritory.containsKey(ut.User__c)) { firstTerritory.put(ut.User__c, ut.Territory__r.Name); }
                if (!territoryIdsByUser.containsKey(ut.User__c)) { territoryIdsByUser.put(ut.User__c, new List<String>()); }
                territoryIdsByUser.get(ut.User__c).add(ut.Territory__c);
            }
            List<KamUserOption> allOptions = new List<KamUserOption>();
            for (User u : kams) {
                KamUserOption o = new KamUserOption();
                o.id = u.Id;
                o.name = u.Name;
                o.territoryName = firstTerritory.get(u.Id);
                if (territoryIdsByUser.containsKey(u.Id)) { o.territoryIds = territoryIdsByUser.get(u.Id); }
                allOptions.add(o);
            }
            return allOptions;
        }

        Set<Id> myTerritoryIds = new Set<Id>();
        for (User_Territory__c ut : [
            SELECT Territory__c FROM User_Territory__c
            WHERE User__c = :UserInfo.getUserId() AND Territory__c != null
            WITH USER_MODE
        ]) {
            myTerritoryIds.add(ut.Territory__c);
        }
        if (myTerritoryIds.isEmpty()) { return new List<KamUserOption>(); }

        Set<Id> visibleTerritoryIds = TerritoryHierarchyUtil.withDescendants(myTerritoryIds);

        List<User_Territory__c> rows = (List<User_Territory__c>) Database.queryWithBinds(
            'SELECT User__c, User__r.Name, Territory__c, Territory__r.Name ' +
            'FROM User_Territory__c ' +
            'WHERE Territory__c IN :visibleTerritoryIds ' +
            'AND User__c != null ' +
            'AND User__r.Profile.Name = \'Key Account Manager\' ' +
            'AND User__r.IsActive = true ' +
            'ORDER BY User__r.Name',
            new Map<String, Object>{ 'visibleTerritoryIds' => visibleTerritoryIds },
            AccessLevel.SYSTEM_MODE
        );

        Map<Id, KamUserOption> byUser = new Map<Id, KamUserOption>();
        List<KamUserOption> options = new List<KamUserOption>();
        for (User_Territory__c ut : rows) {
            KamUserOption opt = byUser.get(ut.User__c);
            if (opt == null) {
                opt = new KamUserOption();
                opt.id = ut.User__c;
                opt.name = ut.User__r.Name;
                opt.territoryName = ut.Territory__r.Name;
                byUser.put(ut.User__c, opt);
                options.add(opt);
            }
            opt.territoryIds.add(ut.Territory__c);
        }
        return options;
    }

    /// True for a Business Admin or a System Administrator (View All Data): they pick any KAM,
    /// not just the ones in their own territories.
    private static Boolean isAdminView() {
        User me = [SELECT Profile.Name, Profile.PermissionsViewAllData FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];
        return me.Profile.PermissionsViewAllData == true || me.Profile.Name == 'Business Admin';
    }

    /// Drives the My Schedule picker (see SchedulePickerData). Authorisation of the actual
    /// cross-user read is still re-checked in getPlannedCallsForUser, not trusted from here.
    @AuraEnabled(cacheable=true)
    public static SchedulePickerData getSchedulePickerData() {
        SchedulePickerData data = new SchedulePickerData();
        if (!isManagerOrHasManagerRole()) { return data; }
        data.kams = getKamUsersInMyTerritory();
        if (isAdminView()) {
            data.mode = 'ADMIN';
            for (Territory__c t : [SELECT Id, Name, Parent_Territory__c, Type__c FROM Territory__c WITH USER_MODE ORDER BY Name]) {
                TerritoryOption o = new TerritoryOption();
                o.id = t.Id; o.name = t.Name; o.parentId = t.Parent_Territory__c; o.type = t.Type__c;
                data.territories.add(o);
            }
        } else {
            data.mode = 'MANAGER';
        }
        return data;
    }

    /// True if targetUserId is a Key Account Manager assigned (directly or via
    /// TerritoryHierarchyUtil's descendant walk) to one of the running user's own
    /// territories — i.e. exactly the set getKamUsersInMyTerritory() would return.
    /// Recomputed here rather than trusting a client-supplied selection, since
    /// getPlannedCallsForUser uses this to decide whether to elevate to SYSTEM_MODE.
    public static Boolean isKamVisibleToRunningManager(Id targetUserId) {
        for (KamUserOption opt : getKamUsersInMyTerritory()) {
            if (opt.id == targetUserId) { return true; }
        }
        return false;
    }

    /// Not cacheable — re-invoked after every create/edit/status-change/delete
    /// (form save, drag-and-drop quick-create, mark completed/cancelled) so the
    /// schedule always reflects the latest state, same reasoning as
    /// SciagenAccountController.getAccountDetail().
    @AuraEnabled
    public static List<PlannedCallItem> getMyPlannedCalls(Date startDate, Date endDate) {
        return getPlannedCallsForUser(startDate, endDate, null);
    }

    /// Same data as getMyPlannedCalls, but for a manager viewing a KAM's schedule: a null
    /// userId (or the running user's own id) means "my own schedule", completely
    /// unchanged from before — same static SOQL, still WITH USER_MODE. Any other userId
    /// must be one getKamUsersInMyTerritory() would return for the running user —
    /// re-checked here, not just trusted from the client — or this throws rather than
    /// silently returning an empty list, so a UI bug surfaces loudly instead of looking
    /// like an empty schedule.
    ///
    /// Planned_Call__c/Call_Visit_Report__c are Private with no sharing rule tied to
    /// Territory__c (only Role Hierarchy roll-up shares them today — see
    /// RoleHierarchySharingTest), so the territory check above is what actually authorizes
    /// a cross-user read here. That read runs through ScheduleCrossUserReader
    /// (`without sharing`) rather than AccessLevel.SYSTEM_MODE: SYSTEM_MODE does not
    /// reliably bypass Private-object sharing for a plain SELECT in this org — confirmed
    /// empirically, the same surprising gap documented on TerritorySharingService's
    /// insert path. `without sharing` is the older, already-proven mechanism instead.
    @AuraEnabled
    public static List<PlannedCallItem> getPlannedCallsForUser(Date startDate, Date endDate, Id userId) {
        Id targetUserId = userId == null ? UserInfo.getUserId() : userId;
        Boolean isSelf = targetUserId == UserInfo.getUserId();
        if (!isSelf) {
            if (!isManagerOrHasManagerRole()) {
                throw new AuraHandledException('Only managers can view another user\'s schedule.');
            }
            if (!isKamVisibleToRunningManager(targetUserId)) {
                throw new AuraHandledException('That user is not a KAM in your territory.');
            }
        }

        Datetime startDt = Datetime.newInstance(startDate, Time.newInstance(0, 0, 0, 0));
        Datetime endDt = Datetime.newInstance(endDate, Time.newInstance(23, 59, 59, 999));

        List<Planned_Call__c> calls = isSelf
            ? [
                SELECT Id, HCP__c, HCP__r.Name, HCP__r.Specialty__c, HCO__c, HCO__r.Name,
                       HCO__r.Geolocation__Latitude__s, HCO__r.Geolocation__Longitude__s,
                       Call_DateTime__c, Duration_Min__c, Call_Type__c, Status__c,
                       Is_Event__c, Event_Title__c, Venue__c, Product__c, Product__r.Name, Program_Type__c,
                       Resulting_CVR__c, Resulting_CVR__r.Record_Status__c, Resulting_CVR__r.Call_Category__c
                FROM Planned_Call__c
                WHERE OwnerId = :targetUserId
                  AND Call_DateTime__c >= :startDt AND Call_DateTime__c <= :endDt
                WITH USER_MODE
                ORDER BY Call_DateTime__c
            ]
            : ScheduleCrossUserReader.plannedCallsForOwner(targetUserId, startDt, endDt);

        Set<Id> accountIds = new Set<Id>();
        for (Planned_Call__c c : calls) {
            if (c.HCP__c != null) { accountIds.add(c.HCP__c); }
            if (c.HCO__c != null) { accountIds.add(c.HCO__c); }
        }
        Map<Id, String> territoryByAccountId = SciagenAccountController.territoryNamesByAccountId(accountIds);

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
            // The iPad's "Save as Unassigned CLM Session" files a placeholder call already
            // marked Completed. Until a call report is actually filed against it (no
            // Resulting_CVR__c), it's still just an unassigned draft.
            if (c.Status__c == 'Completed' && c.Resulting_CVR__c == null
                && String.isNotBlank(c.Event_Title__c) && c.Event_Title__c.startsWith('Unassigned CLM')) {
                item.status = 'Draft';
            }
            item.isEvent = c.Is_Event__c;
            item.eventTitle = c.Event_Title__c;
            item.venue = c.Venue__c;
            item.productId = c.Product__c;
            item.productName = c.Product__c != null ? c.Product__r.Name : null;
            item.programType = c.Program_Type__c;
            item.resultingCVRId = c.Resulting_CVR__c;
            item.resultingCVRStatus = c.Resulting_CVR__c != null ? c.Resulting_CVR__r.Record_Status__c : null;
            item.isLocked = c.Resulting_CVR__c != null && c.Resulting_CVR__r.Record_Status__c == 'Submitted';
            item.isReportOnly = false;
            if (c.Resulting_CVR__c != null && c.Resulting_CVR__r.Call_Category__c != null) {
                item.callCategory = c.Resulting_CVR__r.Call_Category__c;
            } else if (String.isNotBlank(c.Event_Title__c) && c.Event_Title__c.startsWith('Unassigned CLM')) {
                item.callCategory = 'Call with CLM';
            } else {
                item.callCategory = 'Call Only';
            }
            results.add(item);
        }

        // Walk-in visits: the target user's reports for this range that no planned call
        // points at (neither Source_Planned_Call__c on the report nor Resulting_CVR__c on
        // a call). Without these, a report created for an unplanned visit never appears
        // anywhere on My Schedule.
        List<Call_Visit_Report__c> walkIns = isSelf
            ? [
                SELECT Id, HCP__c, HCP__r.Name, HCP__r.Specialty__c, HCO__c, HCO__r.Name,
                       HCO__r.Geolocation__Latitude__s, HCO__r.Geolocation__Longitude__s,
                       Call_Type__c, Visit_Date__c, Start_Time__c, End_Time__c, Check_In_At__c, Record_Status__c, Call_Category__c
                FROM Call_Visit_Report__c
                WHERE OwnerId = :targetUserId
                  AND Source_Planned_Call__c = null
                  AND Visit_Date__c >= :startDate AND Visit_Date__c <= :endDate
                  AND Id NOT IN (SELECT Resulting_CVR__c FROM Planned_Call__c WHERE Resulting_CVR__c != null)
                WITH USER_MODE
                ORDER BY Visit_Date__c, Start_Time__c
            ]
            : ScheduleCrossUserReader.walkInsForOwner(targetUserId, startDate, endDate);
        if (!walkIns.isEmpty()) {
            Set<Id> walkInAccountIds = new Set<Id>();
            for (Call_Visit_Report__c r : walkIns) {
                if (r.HCP__c != null) { walkInAccountIds.add(r.HCP__c); }
                if (r.HCO__c != null) { walkInAccountIds.add(r.HCO__c); }
            }
            Map<Id, String> walkInTerritories = SciagenAccountController.territoryNamesByAccountId(walkInAccountIds);
            for (Call_Visit_Report__c r : walkIns) {
                PlannedCallItem item = new PlannedCallItem();
                item.id = r.Id;
                item.hcpId = r.HCP__c;
                item.hcpName = r.HCP__c != null ? r.HCP__r.Name : null;
                item.specialty = r.HCP__c != null ? r.HCP__r.Specialty__c : null;
                item.hcpTerritory = r.HCP__c != null ? walkInTerritories.get(r.HCP__c) : null;
                item.hcoId = r.HCO__c;
                item.hcoName = r.HCO__c != null ? r.HCO__r.Name : null;
                item.hcoTerritory = r.HCO__c != null ? walkInTerritories.get(r.HCO__c) : null;
                item.latitude = r.HCO__c != null ? r.HCO__r.Geolocation__Latitude__s : null;
                item.longitude = r.HCO__c != null ? r.HCO__r.Geolocation__Longitude__s : null;
                Datetime visitAt = r.Start_Time__c != null ? r.Start_Time__c
                    : (r.Check_In_At__c != null ? r.Check_In_At__c
                    : Datetime.newInstance(r.Visit_Date__c, Time.newInstance(12, 0, 0, 0)));
                item.callDateTime = visitAt;
                Integer minutes = (r.Start_Time__c != null && r.End_Time__c != null)
                    ? Integer.valueOf((r.End_Time__c.getTime() - r.Start_Time__c.getTime()) / 60000) : 30;
                item.durationMin = minutes > 0 ? minutes : 30;
                item.callType = r.Call_Type__c;
                // An unassigned (walk-in) call isn't "Completed" until its report is submitted;
                // until then it's a Draft.
                item.status = r.Record_Status__c == 'Submitted' ? 'Completed' : 'Draft';
                item.isEvent = false;
                item.resultingCVRId = r.Id;
                item.resultingCVRStatus = r.Record_Status__c;
                item.isLocked = r.Record_Status__c == 'Submitted';
                item.isReportOnly = true;
                item.callCategory = r.Call_Category__c != null ? r.Call_Category__c : 'Call Only';
                results.add(item);
            }
            results.sort(new PlannedCallItemByTime());
        }
        return results;
    }

    public class TimeOffItem {
        @AuraEnabled public Date fromDate;
        @AuraEnabled public Date toDate;
        @AuraEnabled public String leaveType;
        @AuraEnabled public String status;
    }

    /// Time-off periods (Leave_Request__c, Pending or Approved) overlapping the range, for the
    /// week grid's "Time Off" header chip and day tint -- same authorization as
    /// getPlannedCallsForUser: your own, or a KAM your manager role can see.
    @AuraEnabled
    public static List<TimeOffItem> getTimeOff(Date startDate, Date endDate, Id userId) {
        Id targetUserId = userId == null ? UserInfo.getUserId() : userId;
        Boolean isSelf = targetUserId == UserInfo.getUserId();
        if (!isSelf) {
            if (!isManagerOrHasManagerRole()) {
                throw new AuraHandledException('Only managers can view another user\'s schedule.');
            }
            if (!isKamVisibleToRunningManager(targetUserId)) {
                throw new AuraHandledException('That user is not a KAM in your territory.');
            }
        }
        List<Leave_Request__c> leave = isSelf
            ? [
                SELECT From_Date__c, To_Date__c, Type__c, Status__c FROM Leave_Request__c
                WHERE OwnerId = :targetUserId AND Status__c IN ('Pending', 'Approved')
                  AND From_Date__c <= :endDate AND To_Date__c >= :startDate
                WITH USER_MODE
            ]
            : ScheduleCrossUserReader.leaveForOwner(targetUserId, startDate, endDate);
        List<TimeOffItem> out = new List<TimeOffItem>();
        for (Leave_Request__c l : leave) {
            TimeOffItem t = new TimeOffItem();
            t.fromDate = l.From_Date__c;
            t.toDate = l.To_Date__c;
            t.leaveType = l.Type__c;
            t.status = l.Status__c;
            out.add(t);
        }
        return out;
    }

    private class PlannedCallItemByTime implements System.Comparator<PlannedCallItem> {
        public Integer compare(PlannedCallItem a, PlannedCallItem b) {
            Long x = a.callDateTime == null ? 0 : a.callDateTime.getTime();
            Long y = b.callDateTime == null ? 0 : b.callDateTime.getTime();
            return x < y ? -1 : (x > y ? 1 : 0);
        }
    }

    public class OpenPlannedCallItem {
        @AuraEnabled public Id id;
        @AuraEnabled public String hcpId;
        @AuraEnabled public String hcpName;
        @AuraEnabled public String hcoId;
        @AuraEnabled public String hcoName;
        @AuraEnabled public Datetime callDateTime;
        @AuraEnabled public String callType;
    }

    /// Planned Calls with no Call Visit Report yet (Resulting_CVR__c null) --
    /// the "start a call from this planned visit" picker in the Call Reports
    /// tab (previously that tab could only create a report from scratch, with
    /// no link back to what was actually scheduled).
    @AuraEnabled
    public static List<OpenPlannedCallItem> getOpenPlannedCalls() {
        Datetime windowStart = Datetime.now().addDays(-60);
        Datetime windowEnd = Datetime.now().addDays(14);
        List<OpenPlannedCallItem> results = new List<OpenPlannedCallItem>();
        for (Planned_Call__c c : [
            SELECT Id, HCP__c, HCP__r.Name, HCO__c, HCO__r.Name, Call_DateTime__c, Call_Type__c
            FROM Planned_Call__c
            WHERE OwnerId = :UserInfo.getUserId()
              AND Resulting_CVR__c = null
              AND Is_Event__c = false
              AND Call_DateTime__c >= :windowStart AND Call_DateTime__c <= :windowEnd
            WITH USER_MODE
            ORDER BY Call_DateTime__c DESC
            LIMIT 50
        ]) {
            OpenPlannedCallItem item = new OpenPlannedCallItem();
            item.id = c.Id;
            item.hcpId = c.HCP__c;
            item.hcpName = c.HCP__c != null ? c.HCP__r.Name : null;
            item.hcoId = c.HCO__c;
            item.hcoName = c.HCO__c != null ? c.HCO__r.Name : null;
            item.callDateTime = c.Call_DateTime__c;
            item.callType = c.Call_Type__c;
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