/**
 * Backend for the Alert Admin LWC — lets an admin/manager author, target,
 * prioritize, and retire broadcast alerts (Company / Content / DCR) shown
 * on the iPad app's Home "My Alerts" tile. The iPad app itself queries
 * Sciagen_Alert__c directly via REST/SOQL (matching this codebase's
 * established read-path convention — see SalesforceRestDataService.swift);
 * this controller exists only for the authoring side.
 *
 * Security: `with sharing` + WITH USER_MODE / AccessLevel.USER_MODE on every
 * query and DML, matching RCPAMatrixController/DCRReviewController.
 */
public with sharing class AlertAdminController {

    public class AlertDTO {
        @AuraEnabled public Id id;
        @AuraEnabled public String title;
        @AuraEnabled public String message;
        @AuraEnabled public String type;
        @AuraEnabled public String priority;
        @AuraEnabled public String audienceType;
        @AuraEnabled public List<Id> targetProfileIds;
        @AuraEnabled public List<OptionDTO> targetUsers;
        @AuraEnabled public String audienceLabel;
        @AuraEnabled public Datetime activationDate;
        @AuraEnabled public Datetime expirationDate;
        @AuraEnabled public Boolean isActive;
    }

    public class OptionDTO {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
    }

    // MARK: - Queue

    // Target_Users__c was deployed successfully (Metadata/Tooling API both
    // confirm it exists) but this org's compiler/query/DML engine
    // intermittently can't resolve it at all ("Invalid field Target_Users__c"
    // / "No such column", even in a *fresh* compile) — a platform-side
    // propagation issue, not a code bug (Salesforce case pending). Because a
    // *static* reference to this field (inline SOQL or dot notation) fails to
    // COMPILE while that's happening — which would block deploying this very
    // class — every touch of Target_Users__c below goes through dynamic SOQL
    // (Database.query(String)) and dynamic sObject get()/put(), neither of
    // which is schema-checked until it actually runs. getAlerts()/saveAlert()
    // degrade to the legacy single-user Target_User__c lookup whenever the
    // runtime call fails, so the admin page keeps working — multi-user
    // targeting silently narrows to the first selected user until the
    // platform catches up. Remove this fallback once Target_Users__c is
    // reliably queryable again.
    private static final String TARGET_USERS_FIELD = 'Target_Users__c';

    @AuraEnabled
    public static List<AlertDTO> getAlerts() {
        List<Sciagen_Alert__c> alerts;
        Boolean targetUsersFieldUsable = true;
        try {
            alerts = Database.query(
                'SELECT Id, Title__c, Message__c, Type__c, Priority__c, Audience_Type__c, ' +
                'Target_Profile__c, ' + TARGET_USERS_FIELD + ', ' +
                'Activation_Date__c, Expiration_Date__c, Is_Active__c ' +
                'FROM Sciagen_Alert__c WITH USER_MODE ORDER BY Activation_Date__c DESC'
            );
        } catch (Exception e) {
            targetUsersFieldUsable = false;
            alerts = [
                SELECT Id, Title__c, Message__c, Type__c, Priority__c, Audience_Type__c,
                       Target_Profile__c, Target_User__c,
                       Activation_Date__c, Expiration_Date__c, Is_Active__c
                FROM Sciagen_Alert__c
                WITH USER_MODE
                ORDER BY Activation_Date__c DESC
            ];
        }

        // Target_Profile__c and Target_Users__c are both plain text holding a
        // comma-delimited list of Ids (Metadata API has no Lookup-to-Profile
        // support at all, and a single Lookup can't hold more than one Id —
        // see SF-045/"My alerts" multi-select), so names need their own bulk
        // lookups rather than a relationship traversal.
        Set<Id> profileIds = new Set<Id>();
        Set<Id> userIds = new Set<Id>();
        for (Sciagen_Alert__c a : alerts) {
            profileIds.addAll(parseIdList(a.Target_Profile__c));
            userIds.addAll(targetUsersFieldUsable ? parseIdList((String) a.get(TARGET_USERS_FIELD)) : legacyTargetUserIdList(a));
        }
        Map<Id, String> profileNameById = new Map<Id, String>();
        if (!profileIds.isEmpty()) {
            for (Profile p : [SELECT Id, Name FROM Profile WHERE Id IN :profileIds WITH USER_MODE]) {
                profileNameById.put(p.Id, p.Name);
            }
        }
        Map<Id, String> userNameById = new Map<Id, String>();
        if (!userIds.isEmpty()) {
            for (User u : [SELECT Id, Name FROM User WHERE Id IN :userIds WITH USER_MODE]) {
                userNameById.put(u.Id, u.Name);
            }
        }

        List<AlertDTO> result = new List<AlertDTO>();
        for (Sciagen_Alert__c a : alerts) {
            result.add(toDTO(a, profileNameById, userNameById, targetUsersFieldUsable));
        }
        return result;
    }

    // Sciagen_Alert__c.Target_User__c (legacy single-user Lookup) — see the
    // Target_Users__c fallback note above getAlerts().
    private static List<Id> legacyTargetUserIdList(Sciagen_Alert__c a) {
        List<Id> result = new List<Id>();
        if (a.Target_User__c != null) result.add(a.Target_User__c);
        return result;
    }

    private static AlertDTO toDTO(Sciagen_Alert__c a, Map<Id, String> profileNameById, Map<Id, String> userNameById, Boolean targetUsersFieldUsable) {
        AlertDTO dto = new AlertDTO();
        dto.id = a.Id;
        dto.title = a.Title__c;
        dto.message = a.Message__c;
        dto.type = a.Type__c;
        dto.priority = a.Priority__c;
        dto.audienceType = a.Audience_Type__c;
        dto.targetProfileIds = parseIdList(a.Target_Profile__c);
        dto.targetUsers = new List<OptionDTO>();
        List<Id> targetUserIds = targetUsersFieldUsable ? parseIdList((String) a.get(TARGET_USERS_FIELD)) : legacyTargetUserIdList(a);
        for (Id userId : targetUserIds) {
            OptionDTO o = new OptionDTO();
            o.id = userId;
            o.name = userNameById.containsKey(userId) ? userNameById.get(userId) : 'Unknown User';
            dto.targetUsers.add(o);
        }
        dto.activationDate = a.Activation_Date__c;
        dto.expirationDate = a.Expiration_Date__c;
        dto.isActive = a.Is_Active__c;
        if (a.Audience_Type__c == 'Profile') {
            List<String> names = new List<String>();
            for (Id profileId : dto.targetProfileIds) {
                names.add(profileNameById.containsKey(profileId) ? profileNameById.get(profileId) : 'Profile');
            }
            dto.audienceLabel = names.isEmpty() ? 'Profile' : String.join(names, ', ');
        } else if (a.Audience_Type__c == 'User') {
            List<String> names = new List<String>();
            for (OptionDTO u : dto.targetUsers) names.add(u.name);
            dto.audienceLabel = names.isEmpty() ? 'User' : String.join(names, ', ');
        } else {
            dto.audienceLabel = 'All Users';
        }
        return dto;
    }

    // Both Target_Profile__c and Target_Users__c are stored wrapped in leading/
    // trailing commas (",id1,id2,") so a SOQL LIKE '%,id,%' match (used by the
    // iPad app's direct-SOQL read in SalesforceRestDataService.swift) can't
    // false-match on an Id that's merely a substring of another Id.
    private static List<Id> parseIdList(String raw) {
        List<Id> result = new List<Id>();
        if (String.isBlank(raw)) return result;
        for (String part : raw.split(',')) {
            if (String.isNotBlank(part)) result.add((Id) part);
        }
        return result;
    }

    private static String buildIdListText(List<Id> ids) {
        if (ids == null || ids.isEmpty()) return null;
        List<String> parts = new List<String>();
        for (Id i : ids) parts.add(String.valueOf(i));
        return ',' + String.join(parts, ',') + ',';
    }

    // MARK: - Audience pickers

    @AuraEnabled(cacheable=true)
    public static List<OptionDTO> getProfileOptions() {
        List<Profile> profiles = [SELECT Id, Name FROM Profile WITH USER_MODE ORDER BY Name];
        List<OptionDTO> result = new List<OptionDTO>();
        for (Profile p : profiles) {
            OptionDTO o = new OptionDTO();
            o.id = p.Id;
            o.name = p.Name;
            result.add(o);
        }
        return result;
    }

    @AuraEnabled
    public static List<OptionDTO> getUserOptions(String searchTerm) {
        String term = '%' + String.escapeSingleQuotes(searchTerm) + '%';
        List<User> users = [
            SELECT Id, Name FROM User
            WHERE IsActive = true AND Name LIKE :term
            WITH USER_MODE
            ORDER BY Name
            LIMIT 20
        ];
        List<OptionDTO> result = new List<OptionDTO>();
        for (User u : users) {
            OptionDTO o = new OptionDTO();
            o.id = u.Id;
            o.name = u.Name;
            result.add(o);
        }
        return result;
    }

    // MARK: - Save / retire

    // Takes individual scalar parameters rather than one wrapper DTO — this
    // codebase's only other @AuraEnabled "save" methods (DCRReviewController,
    // RCPAMatrixController.saveRCPATarget) all use scalar parameters, never a
    // custom-class parameter. This one originally took a single `AlertInput`
    // object and every field arrived as null server-side despite the wire
    // payload (confirmed via network capture + a temporary System.debug)
    // showing the correct values — LWC-to-Apex parameter binding for a
    // custom-class parameter silently failed in this org/API-version
    // combination. Scalar parameters sidestep that binding path entirely.
    @AuraEnabled
    public static Id saveAlert(
        Id alertId,
        String title,
        String message,
        String type,
        String priority,
        String audienceType,
        List<Id> targetProfileIds,
        List<Id> targetUserIds,
        Datetime activationDate,
        Datetime expirationDate
    ) {
        if (String.isBlank(title)) {
            throw new AuraHandledException('Title is required.');
        }
        if (String.isBlank(type) || String.isBlank(priority) || String.isBlank(audienceType)) {
            throw new AuraHandledException('Type, Priority, and Audience Type are required.');
        }
        if (audienceType == 'Profile' && (targetProfileIds == null || targetProfileIds.isEmpty())) {
            throw new AuraHandledException('Select at least one Profile for a Profile-targeted alert.');
        }
        if (audienceType == 'User' && (targetUserIds == null || targetUserIds.isEmpty())) {
            throw new AuraHandledException('Select at least one User for a User-targeted alert.');
        }
        if (expirationDate == null) {
            throw new AuraHandledException('Expiration date is required.');
        }

        Sciagen_Alert__c alert = alertId != null ? new Sciagen_Alert__c(Id = alertId) : new Sciagen_Alert__c();
        alert.Title__c = title;
        alert.Message__c = message;
        alert.Type__c = type;
        alert.Priority__c = priority;
        alert.Audience_Type__c = audienceType;
        alert.Target_Profile__c = audienceType == 'Profile' ? buildIdListText(targetProfileIds) : null;
        alert.Activation_Date__c = activationDate != null ? activationDate : Datetime.now();
        alert.Expiration_Date__c = expirationDate;

        // Target_Users__c is written dynamically and best-effort — see the
        // fallback note above getAlerts(). Target_User__c (legacy, single
        // user) is always kept in sync too, so getAlerts()'s fallback query
        // has a correct value to read even if Target_Users__c later becomes
        // unusable again after this save.
        alert.Target_User__c = (audienceType == 'User' && !targetUserIds.isEmpty()) ? targetUserIds[0] : null;
        try {
            alert.put(TARGET_USERS_FIELD, audienceType == 'User' ? buildIdListText(targetUserIds) : null);
        } catch (Exception e) {
            // Platform-side field propagation lag — Target_User__c above already covers the single-user case.
        }

        try {
            if (alertId != null) {
                Database.update(alert, AccessLevel.USER_MODE);
            } else {
                Database.insert(alert, AccessLevel.USER_MODE);
            }
        } catch (DmlException e) {
            // The constructor argument alone is NOT what getMessage() returns
            // to a caller (Aura redacts it to "Script-thrown exception"
            // unless setMessage() is called explicitly) — without this call
            // both the LWC's error toast and any test failure message show
            // only that generic text, never the real DML error.
            AuraHandledException ex = new AuraHandledException(e.getDmlMessage(0));
            ex.setMessage(e.getDmlMessage(0));
            throw ex;
        }
        return alert.Id;
    }

    @AuraEnabled
    public static void setActive(Id alertId, Boolean isActive) {
        List<Sciagen_Alert__c> alerts = [
            SELECT Id FROM Sciagen_Alert__c WHERE Id = :alertId WITH USER_MODE LIMIT 1
        ];
        if (alerts.isEmpty()) {
            throw new AuraHandledException('Alert not found or not accessible.');
        }
        alerts[0].Is_Active__c = isActive;
        try {
            Database.update(alerts[0], AccessLevel.USER_MODE);
        } catch (DmlException e) {
            // The constructor argument alone is NOT what getMessage() returns
            // to a caller (Aura redacts it to "Script-thrown exception"
            // unless setMessage() is called explicitly) — without this call
            // both the LWC's error toast and any test failure message show
            // only that generic text, never the real DML error.
            AuraHandledException ex = new AuraHandledException(e.getDmlMessage(0));
            ex.setMessage(e.getDmlMessage(0));
            throw ex;
        }
    }
}