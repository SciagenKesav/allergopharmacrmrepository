/**
 * One place to raise Sample Management alerts (bell notifications): lot expiry,
 * returns, large adjustments, cold chain breaches, pending approvals. A failed
 * notification must never roll back the inventory change that raised it, so
 * everything here is best-effort.
 */
public without sharing class SampleNotifier {

    public static void notify(Set<Id> userIds, String title, String body, Id targetId) {
        if (userIds == null || userIds.isEmpty() || targetId == null) return;
        try {
            List<CustomNotificationType> types = [SELECT Id FROM CustomNotificationType WHERE DeveloperName = 'Sample_Alert' LIMIT 1];
            if (types.isEmpty()) return;
            Set<String> recipients = new Set<String>();
            for (Id u : userIds) if (u != null) recipients.add(String.valueOf(u));
            Messaging.CustomNotification n = new Messaging.CustomNotification();
            n.setNotificationTypeId(types[0].Id);
            n.setTitle(title.left(250));
            n.setBody((body == null ? '' : body).left(750));
            n.setTargetId(targetId);
            n.send(recipients);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Sample alert not sent: ' + e.getMessage());
        }
    }

    /** Line managers of the given users (User.ManagerId). */
    public static Set<Id> managersOf(Set<Id> userIds) {
        Set<Id> out = new Set<Id>();
        if (userIds == null || userIds.isEmpty()) return out;
        for (User u : [SELECT ManagerId FROM User WHERE Id IN :userIds AND ManagerId != null]) out.add(u.ManagerId);
        return out;
    }

    /** Active users holding the Sample Admin permission set. */
    public static Set<Id> sampleAdmins() {
        Set<Id> out = new Set<Id>();
        for (PermissionSetAssignment a : [
            SELECT AssigneeId FROM PermissionSetAssignment
            WHERE PermissionSet.Name = 'Sciagen_Sample_Admin' AND Assignee.IsActive = true
        ]) out.add(a.AssigneeId);
        return out;
    }
}