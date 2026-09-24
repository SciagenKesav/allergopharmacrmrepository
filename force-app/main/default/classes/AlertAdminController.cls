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
        @AuraEnabled public Id targetProfileId;
        @AuraEnabled public Id targetUserId;
        @AuraEnabled public List<Id> targetUserIds;
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

    @AuraEnabled
    public static List<AlertDTO> getAlerts() {
        List<Sciagen_Alert__c> alerts = [
            SELECT Id, Title__c, Message__c, Type__c, Priority__c, Audience_Type__c,
                   Target_Profile__c, Target_User__c, Target_User__r.Name,
                   Activation_Date__c, Expiration_Date__c, Is_Active__c
            FROM Sciagen_Alert__c
            WITH USER_MODE
            ORDER BY Activation_Date__c DESC
        ];

        // Target_Profile__c is plain text (Metadata API has no Lookup-to-Profile
        // support), so profile names need their own bulk lookup rather than a
        // relationship traversal.
        Set<Id> profileIds = new Set<Id>();
        for (Sciagen_Alert__c a : alerts) {
            if (a.Audience_Type__c == 'Profile' && String.isNotBlank(a.Target_Profile__c)) {
                profileIds.add((Id) a.Target_Profile__c);
            }
        }
        Map<Id, String> profileNameById = new Map<Id, String>();
        if (!profileIds.isEmpty()) {
            for (Profile p : [SELECT Id, Name FROM Profile WHERE Id IN :profileIds WITH USER_MODE]) {
                profileNameById.put(p.Id, p.Name);
            }
        }

        // Alert_Recipient__c is the junction backing 'Multiple Users' —
        // bulk-load every alert's recipients in one query rather than one
        // per row.
        Map<Id, List<Id>> recipientIdsByAlertId = new Map<Id, List<Id>>();
        for (Alert_Recipient__c ar : [
            SELECT Alert__c, User__c
            FROM Alert_Recipient__c
            WHERE Alert__c IN :alerts AND User__c != null
            WITH USER_MODE
        ]) {
            if (!recipientIdsByAlertId.containsKey(ar.Alert__c)) {
                recipientIdsByAlertId.put(ar.Alert__c, new List<Id>());
            }
            recipientIdsByAlertId.get(ar.Alert__c).add(ar.User__c);
        }

        List<AlertDTO> result = new List<AlertDTO>();
        for (Sciagen_Alert__c a : alerts) {
            result.add(toDTO(a, profileNameById, recipientIdsByAlertId.get(a.Id)));
        }
        return result;
    }

    private static AlertDTO toDTO(Sciagen_Alert__c a, Map<Id, String> profileNameById, List<Id> recipientIds) {
        AlertDTO dto = new AlertDTO();
        dto.id = a.Id;
        dto.title = a.Title__c;
        dto.message = a.Message__c;
        dto.type = a.Type__c;
        dto.priority = a.Priority__c;
        dto.audienceType = a.Audience_Type__c;
        dto.targetProfileId = String.isNotBlank(a.Target_Profile__c) ? (Id) a.Target_Profile__c : null;
        dto.targetUserId = a.Target_User__c;
        dto.targetUserIds = recipientIds != null ? recipientIds : new List<Id>();
        dto.activationDate = a.Activation_Date__c;
        dto.expirationDate = a.Expiration_Date__c;
        dto.isActive = a.Is_Active__c;
        if (a.Audience_Type__c == 'Profile') {
            String name = String.isNotBlank(a.Target_Profile__c) ? profileNameById.get((Id) a.Target_Profile__c) : null;
            dto.audienceLabel = name != null ? name : 'Profile';
        } else if (a.Audience_Type__c == 'User') {
            dto.audienceLabel = a.Target_User__r != null ? a.Target_User__r.Name : 'User';
        } else if (a.Audience_Type__c == 'Multiple Users') {
            Integer count = recipientIds != null ? recipientIds.size() : 0;
            dto.audienceLabel = count + (count == 1 ? ' user' : ' users');
        } else {
            dto.audienceLabel = 'All Users';
        }
        return dto;
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

    /// Full active-user list for the "Multiple Users" dual-listbox's
    /// "Available" pane — distinct from getUserOptions(searchTerm) below,
    /// which is the single-user audience's type-ahead search and deliberately
    /// caps at 20 narrow matches rather than listing everyone.
    @AuraEnabled(cacheable=true)
    public static List<OptionDTO> getActiveUserOptions() {
        List<User> users = [
            SELECT Id, Name FROM User
            WHERE IsActive = true
            WITH USER_MODE
            ORDER BY Name
            LIMIT 2000
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
        Id targetProfileId,
        Id targetUserId,
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
        if (audienceType == 'Profile' && targetProfileId == null) {
            throw new AuraHandledException('Select a Profile for a Profile-targeted alert.');
        }
        if (audienceType == 'User' && targetUserId == null) {
            throw new AuraHandledException('Select a User for a User-targeted alert.');
        }
        if (audienceType == 'Multiple Users' && (targetUserIds == null || targetUserIds.isEmpty())) {
            throw new AuraHandledException('Move at least one user into Target Users for a Multiple-Users alert.');
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
        alert.Target_Profile__c = audienceType == 'Profile' ? targetProfileId : null;
        alert.Target_User__c = audienceType == 'User' ? targetUserId : null;
        alert.Activation_Date__c = activationDate != null ? activationDate : Datetime.now();
        alert.Expiration_Date__c = expirationDate;

        Savepoint sp = Database.setSavepoint();
        try {
            if (alertId != null) {
                Database.update(alert, AccessLevel.USER_MODE);
            } else {
                Database.insert(alert, AccessLevel.USER_MODE);
            }
            // Multiple Users' recipient set is fully replaced on every save —
            // the dual-listbox's own state already reflects the complete
            // desired membership (not an incremental add/remove), and every
            // other audience type means this alert has none, so the existing
            // rows are always cleared first regardless of the new type.
            List<Alert_Recipient__c> existing = [
                SELECT Id FROM Alert_Recipient__c WHERE Alert__c = :alert.Id WITH USER_MODE
            ];
            if (!existing.isEmpty()) {
                Database.delete(existing, AccessLevel.USER_MODE);
            }
            if (audienceType == 'Multiple Users') {
                List<Alert_Recipient__c> toInsert = new List<Alert_Recipient__c>();
                Set<Id> seen = new Set<Id>();
                for (Id userId : targetUserIds) {
                    if (userId == null || seen.contains(userId)) { continue; }
                    seen.add(userId);
                    toInsert.add(new Alert_Recipient__c(Alert__c = alert.Id, User__c = userId));
                }
                Database.insert(toInsert, AccessLevel.USER_MODE);
            }
        } catch (DmlException e) {
            Database.rollback(sp);
            throw new AuraHandledException(e.getDmlMessage(0));
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
            throw new AuraHandledException(e.getDmlMessage(0));
        }
    }
}