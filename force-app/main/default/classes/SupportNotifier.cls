/**
 * Bell notifications and email for Help & Support. Best effort: a failed
 * notification must never roll back the request or reply that caused it.
 */
public without sharing class SupportNotifier {

    /** Bell notifications per transaction; a bulk load should not raise hundreds of them. */
    private static final Integer MAX_BELLS = 8;
    private static Integer bellsSent = 0;
    private static Id typeId;
    private static Boolean typeLooked = false;

    public static void bell(Set<Id> userIds, String title, String body, Id targetId) {
        if (userIds == null || targetId == null) return;
        Set<String> recipients = new Set<String>();
        for (Id u : userIds) if (u != null && u != UserInfo.getUserId()) recipients.add(String.valueOf(u));
        if (recipients.isEmpty() || bellsSent >= MAX_BELLS) return;
        try {
            if (!typeLooked) {
                typeLooked = true;
                List<CustomNotificationType> types = [SELECT Id FROM CustomNotificationType WHERE DeveloperName = 'Support_Update' LIMIT 1];
                if (!types.isEmpty()) typeId = types[0].Id;
            }
            if (typeId == null) return;
            bellsSent++;
            Messaging.CustomNotification n = new Messaging.CustomNotification();
            n.setNotificationTypeId(typeId);
            n.setTitle((title == null ? '' : title).left(250));
            n.setBody((body == null ? '' : body).left(750));
            n.setTargetId(targetId);
            n.send(recipients);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Support notification not sent: ' + e.getMessage());
        }
    }

    /** Email to people who may not be in Salesforce right now (reps in the field, managers). */
    public static void email(Set<Id> userIds, String subject, String body) {
        if (userIds == null || userIds.isEmpty() || !SupportConfig.load().sendEmails) return;
        try {
            List<Messaging.SingleEmailMessage> mails = new List<Messaging.SingleEmailMessage>();
            for (Id u : userIds) {
                if (u == null || u == UserInfo.getUserId()) continue;
                Messaging.SingleEmailMessage m = new Messaging.SingleEmailMessage();
                m.setTargetObjectId(u);
                m.setSaveAsActivity(false);
                m.setSubject((subject == null ? '' : subject).left(200));
                m.setPlainTextBody((body == null ? '' : body).left(4000));
                mails.add(m);
            }
            Integer room = Limits.getLimitEmailInvocations() - Limits.getEmailInvocations();
            if (mails.isEmpty() || room <= 0) return;
            Messaging.sendEmail(mails, false);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Support email not sent: ' + e.getMessage());
        }
    }

    public static Set<Id> ids(Id a, Id b, Id c) {
        Set<Id> out = new Set<Id>();
        if (a != null) out.add(a);
        if (b != null) out.add(b);
        if (c != null) out.add(c);
        return out;
    }
}