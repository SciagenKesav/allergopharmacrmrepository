/**
 * Inbound REST API for the iPad app's My Schedule manager view: lets the app tell what kind of
 * user is signed in, list the KAMs a manager can look at, and pull one KAM's scheduled calls.
 *
 * GET /services/apexrest/sciagen/v1/team-schedule/me
 *      -> { success, userId, name, role, canViewTeam }
 *      role: "KAM" (Key Account Manager), "MANAGER" (a manager, incl. Manager-named roles),
 *            "ADMIN" (Business Admin / System Admin) or "USER" (anyone else). The app shows the
 *            "My Schedule / KAM" picker only when canViewTeam is true.
 *
 * GET /services/apexrest/sciagen/v1/team-schedule/kams
 *      -> { success, role, canViewTeam, kams: [{ id, name, territoryName, territoryIds }] }
 *      Empty for a KAM / other user.
 *
 * GET /services/apexrest/sciagen/v1/team-schedule/calls?userId=<KAM id>&startDate=yyyy-MM-dd&endDate=yyyy-MM-dd
 *      -> { success, calls: [ ...planned calls (same fields as the web My Schedule) ] }
 *      userId is optional: omit it (or pass your own id) for your own calls. Any other userId
 *      must be a KAM in the caller's own territories, or the call is refused with 403.
 *
 * GET /services/apexrest/sciagen/v1/team-schedule/accounts?userId=<KAM id>&type=HCP|HCO&limit=100&offset=0&afterId=<Id>
 *      -> { success, hcps: [...], hcos: [...], totalHcps, totalHcos, hasMoreHcps, hasMoreHcos, lastHcpId, lastHcoId }
 *      The HCPs / HCOs in the KAM's own territories (the same rule that gives the KAM their own
 *      Accounts list), read-only. userId is required and must be a KAM in the caller's territories
 *      (403 otherwise). type is optional: omit it for both lists, or pass HCP / HCO to page one list.
 *      Page with limit (max 200) and offset (max 2000), or with afterId = the previous page's
 *      lastHcpId / lastHcoId for territories larger than that. Rows use Salesforce field names (the
 *      same ones the iPad maps for its own accounts) plus: territory; for HCPs primaryHcoId,
 *      primaryHcoName and segmentation { Classification__c, Potential__c, Priority__c, Tier__c, Is_KOL__c, Tags__c }.
 *
 * GET /services/apexrest/sciagen/v1/team-schedule/account-activity?userId=<KAM id>&hcpId=<HCP id>
 *      -> { success, cvrs, plannedCalls, emails, officeWindows, dcrs }  (dates ISO 8601)
 *      One KAM's activity for one doctor, for the Timeline / Engagement / Activity / DCR tabs of a
 *      KAM's doctor profile. Same access as accounts (a Manager/Admin, and a KAM in their territories).
 *        cvrs:          id, visitDate, callType, hcoName, recordStatus, durationMin
 *        plannedCalls:  id, callDateTime, callType, hcoName, status, durationMin
 *        emails:        id, subject, templateName, toEmail, sentAt, attachmentCount
 *        officeWindows: id, day, window, preference, hcoId, hcoName   (the doctor's, not per rep)
 *        dcrs:          id, type, status, subjectName, summary, submittedBy, submittedAt, rejectionReason
 *      Each list is capped at 500 rows, newest first.
 *
 * This is a thin wrapper over SciagenScheduleController, the same code behind the web
 * My Schedule page, so the iPad and the web always agree on who a manager can see and which
 * calls come back. Read-only: nothing here writes to Salesforce.
 */
@RestResource(urlMapping='/sciagen/v1/team-schedule/*')
global with sharing class SciagenTeamScheduleApi {

    private static final Integer MAX_RANGE_DAYS = 62;

    @HttpGet
    global static void doGet() {
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');
        String path = RestContext.request.requestURI;
        String action = path.substring(path.lastIndexOf('/') + 1).toLowerCase();
        try {
            if (action == 'me') {
                respond(200, me());
            } else if (action == 'kams') {
                respond(200, kams());
            } else if (action == 'calls') {
                calls();
            } else if (action == 'accounts') {
                accounts();
            } else if (action == 'account-activity') {
                accountActivity();
            } else {
                fail(404, 'Unknown resource "' + action + '". Use me, kams or calls.');
            }
        } catch (Exception e) {
            fail(500, e.getMessage());
        }
    }

    // ===================== me =====================

    private static String roleOf(SciagenScheduleController.SchedulePickerData picker) {
        if (picker.mode == 'ADMIN') { return 'ADMIN'; }
        if (picker.mode == 'MANAGER') { return 'MANAGER'; }
        return SciagenAccountController.isKeyAccountManager() ? 'KAM' : 'USER';
    }

    private static Map<String, Object> me() {
        SciagenScheduleController.SchedulePickerData picker = SciagenScheduleController.getSchedulePickerData();
        String role = roleOf(picker);
        return new Map<String, Object>{
            'success' => true,
            'userId' => UserInfo.getUserId(),
            'name' => UserInfo.getName(),
            'role' => role,
            'canViewTeam' => role == 'MANAGER' || role == 'ADMIN'
        };
    }

    // ===================== kams =====================

    private static Map<String, Object> kams() {
        SciagenScheduleController.SchedulePickerData picker = SciagenScheduleController.getSchedulePickerData();
        String role = roleOf(picker);
        return new Map<String, Object>{
            'success' => true,
            'role' => role,
            'canViewTeam' => role == 'MANAGER' || role == 'ADMIN',
            'kams' => picker.kams
        };
    }

    // ===================== calls =====================

    private static void calls() {
        Map<String, String> p = RestContext.request.params;
        Date startDate;
        Date endDate;
        try {
            startDate = Date.valueOf(p.get('startDate'));
            endDate = Date.valueOf(p.get('endDate'));
        } catch (Exception e) {
            startDate = null;
        }
        if (startDate == null || endDate == null || endDate < startDate) {
            fail(400, 'startDate and endDate are required as yyyy-MM-dd, and endDate must not be before startDate.');
            return;
        }
        if (startDate.daysBetween(endDate) > MAX_RANGE_DAYS) {
            fail(400, 'The date range can be at most ' + MAX_RANGE_DAYS + ' days.');
            return;
        }

        Id targetUserId = null;
        String userIdParam = p.get('userId');
        if (String.isNotBlank(userIdParam)) {
            try {
                targetUserId = Id.valueOf(userIdParam);
            } catch (Exception e) {
                fail(400, 'userId is not a valid Salesforce Id.');
                return;
            }
        }
        // Authorisation is checked here for a clean 403 (the controller re-checks it too).
        if (targetUserId != null && targetUserId != UserInfo.getUserId()) {
            if (!SciagenScheduleController.isManagerOrHasManagerRole()) {
                fail(403, 'Only managers can view another user\'s schedule.');
                return;
            }
            if (!SciagenScheduleController.isKamVisibleToRunningManager(targetUserId)) {
                fail(403, 'That user is not a KAM in your territory.');
                return;
            }
        }
        respond(200, new Map<String, Object>{
            'success' => true,
            'calls' => SciagenScheduleController.getPlannedCallsForUser(startDate, endDate, targetUserId)
        });
    }

    // ===================== accounts =====================

    private static final Integer MAX_PAGE = 200;
    private static final Integer MAX_OFFSET = 2000;

    private static void accounts() {
        Map<String, String> p = RestContext.request.params;
        Id kamId;
        try {
            kamId = Id.valueOf(p.get('userId'));
        } catch (Exception e) {
            fail(400, 'userId is required and must be a valid Salesforce Id.');
            return;
        }
        String type = String.isBlank(p.get('type')) ? null : p.get('type').toUpperCase();
        if (type != null && type != 'HCP' && type != 'HCO') {
            fail(400, 'type must be HCP or HCO.');
            return;
        }
        Integer pageSize;
        Integer pageOffset;
        Id afterId = null;
        try {
            pageSize = String.isBlank(p.get('limit')) ? 100 : Integer.valueOf(p.get('limit'));
            pageOffset = String.isBlank(p.get('offset')) ? 0 : Integer.valueOf(p.get('offset'));
            if (String.isNotBlank(p.get('afterId'))) { afterId = Id.valueOf(p.get('afterId')); }
        } catch (Exception e) {
            fail(400, 'limit and offset must be numbers and afterId a valid Id.');
            return;
        }
        if (pageSize < 1 || pageSize > MAX_PAGE || pageOffset < 0 || pageOffset > MAX_OFFSET) {
            fail(400, 'limit must be 1-' + MAX_PAGE + ' and offset 0-' + MAX_OFFSET + ' (use afterId to page further).');
            return;
        }
        Set<Id> territoryIds = kamTerritoriesOrFail(kamId);
        if (territoryIds == null) { return; }
        respond(200, accountsBody(territoryIds, type, pageSize, pageOffset, afterId));
    }

    // Only a manager/admin, and only for a KAM in their own territories. Writes the 403 and returns
    // null when that does not hold.
    private static Set<Id> kamTerritoriesOrFail(Id kamId) {
        if (!SciagenScheduleController.isManagerOrHasManagerRole()) {
            fail(403, 'Only managers can view a KAM\'s accounts.');
            return null;
        }
        for (SciagenScheduleController.KamUserOption k : SciagenScheduleController.getKamUsersInMyTerritory()) {
            if (k.id == kamId) {
                Set<Id> territoryIds = new Set<Id>();
                for (String t : k.territoryIds) { territoryIds.add((Id) t); }
                return territoryIds;
            }
        }
        fail(403, 'That user is not a KAM in your territory.');
        return null;
    }

    private static void accountActivity() {
        Map<String, String> p = RestContext.request.params;
        Id kamId;
        Id hcpId;
        try {
            kamId = Id.valueOf(p.get('userId'));
            hcpId = Id.valueOf(p.get('hcpId'));
        } catch (Exception e) {
            fail(400, 'userId and hcpId are required and must be valid Salesforce Ids.');
            return;
        }
        if (kamTerritoriesOrFail(kamId) == null) { return; }
        respond(200, TeamAccountActivityReader.forKam(kamId, hcpId));
    }

    @TestVisible
    private static Map<String, Object> accountsBody(Set<Id> territoryIds, String type, Integer pageSize, Integer pageOffset, Id afterId) {
        Map<String, Object> body = new Map<String, Object>{ 'success' => true };
        if (type == null || type == 'HCP') {
            TeamAccountsReader.AccountPage hcps = TeamAccountsReader.page('HCP', territoryIds, pageSize, pageOffset, afterId);
            body.put('hcps', hcps.rows);
            body.put('totalHcps', hcps.total);
            body.put('hasMoreHcps', hcps.hasMore);
            body.put('lastHcpId', hcps.lastId);
        }
        if (type == null || type == 'HCO') {
            TeamAccountsReader.AccountPage hcos = TeamAccountsReader.page('HCO', territoryIds, pageSize, pageOffset, afterId);
            body.put('hcos', hcos.rows);
            body.put('totalHcos', hcos.total);
            body.put('hasMoreHcos', hcos.hasMore);
            body.put('lastHcoId', hcos.lastId);
        }
        return body;
    }

    // ===================== helpers =====================

    private static void respond(Integer status, Object body) {
        RestContext.response.statusCode = status;
        RestContext.response.responseBody = Blob.valueOf(JSON.serialize(body));
    }

    private static void fail(Integer status, String message) {
        respond(status, new Map<String, Object>{ 'success' => false, 'message' => message });
    }
}