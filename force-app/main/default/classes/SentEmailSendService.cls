/**
 * Server-side delivery of Approved Emails. The iPad app only *queues* an email
 * (Sent_Email__c, Folder__c = 'Sent', Status__c = 'Queued'); this service
 * re-validates it on the server and then sends it, so the checks that matter
 * for compliance can't be bypassed by a modified or out-of-date app:
 *
 *   1. The HCP has a current email opt-in (Consent_Email__c.Opted_In__c) for
 *      *this exact address*, captured within CONSENT_VALIDITY_YEARS.
 *   2. It references an approved CMS template (not rep-saved) that is not
 *      withdrawn or past its expiry date, and — when the iPad says which file
 *      version it composed from (Content_Hash__c) — that is still the current one.
 *   3. Every attachment is on that template's allowed-content list, and is
 *      delivered as a link to the approved asset — never a rep-supplied file.
 *   4. The rep is under DAILY_LIMIT sent emails today.
 *
 * The subject and body actually sent are rendered HERE from the approved
 * template (ApprovedEmailRenderer), never taken from the client's Subject__c /
 * Body_Text__c; the rep's personal note (Rep_Note__c, max 500 chars) is
 * appended in a separate, labelled block. After sending, Subject__c and
 * Body_Text__c are overwritten with exactly what was delivered.
 *
 * Outcome is written back to Status__c (Sent / Failed) with Status_Message__c
 * so the iPad can show delivery state. Delivery goes through sendOne(); it uses
 * Salesforce's own email service today, and that single method is the only
 * place to change to route through SendGrid / SES instead.
 *
 * `without sharing` on purpose: it must read the HCP's consent and the
 * template's allow-list regardless of which rep owns them, and only ever
 * returns pass/fail, never the underlying rows.
 */
public without sharing class SentEmailSendService {

    public static final Integer DAILY_LIMIT = 50;
    public static final Integer CONSENT_VALIDITY_YEARS = 3;
    public static final String STATUS_QUEUED = 'Queued';
    public static final String STATUS_SENT = 'Sent';
    public static final String STATUS_FAILED = 'Failed';
    /** Rows handled per job: one Messaging.sendEmail call (limit 100 messages) and headroom for template callouts. The rest chain to a new job. */
    @TestVisible private static Integer maxPerJob = 50;
    /** Tests set this to treat every message as delivered without calling Messaging.sendEmail (an org's email deliverability setting can reject sends, even in tests). */
    @TestVisible private static Boolean simulateDelivery = false;

    public class SendJob implements Queueable, Database.AllowsCallouts {
        private Set<Id> ids;
        public SendJob(Set<Id> ids) { this.ids = ids; }
        public void execute(QueueableContext ctx) { processIds(ids); }
    }

    /** Before-insert: force every Sent-folder email into the Queued state, ignoring anything the client sent. */
    public static void markNewSentEmailsQueued(List<Sent_Email__c> rows) {
        for (Sent_Email__c r : rows) {
            if (r.Folder__c == 'Sent') {
                r.Status__c = STATUS_QUEUED;
                r.Status_Message__c = null;
                r.Sent_At__c = null;
            }
        }
    }

    /** Called from the trigger: queue a send job for any row newly in the Queued state. */
    public static void enqueueQueued(List<Sent_Email__c> rows, Map<Id, Sent_Email__c> oldMap) {
        Set<Id> ids = new Set<Id>();
        for (Sent_Email__c r : rows) {
            if (r.Folder__c != 'Sent' || r.Status__c != STATUS_QUEUED) continue;
            Sent_Email__c old = oldMap == null ? null : oldMap.get(r.Id);
            if (old != null && old.Status__c == STATUS_QUEUED) continue;
            ids.add(r.Id);
        }
        if (!ids.isEmpty()) System.enqueueJob(new SendJob(ids));
    }

    public static void processIds(Set<Id> ids) {
        List<Sent_Email__c> rows = [
            SELECT Id, HCP__c, To_Email__c, Subject__c, Body_Text__c, Rep_Note__c, Template__c, Content_Hash__c,
                   Attachment_Content_Ids__c, CreatedById, CreatedDate, CreatedBy.Name, CreatedBy.Email
            FROM Sent_Email__c WHERE Id IN :ids AND Status__c = :STATUS_QUEUED
            ORDER BY CreatedDate, Id
        ];
        if (rows.isEmpty()) return;
        // Chunk: anything past maxPerJob goes to a follow-up job, so a bulk insert never
        // hits the per-transaction email/callout limits and rolls everything back.
        Set<Id> deferred = new Set<Id>();
        while (rows.size() > maxPerJob) deferred.add(rows.remove(rows.size() - 1).Id);

        Set<Id> hcpIds = new Set<Id>();
        Set<Id> templateIds = new Set<Id>();
        Set<Id> creatorIds = new Set<Id>();
        Set<Id> contentIds = new Set<Id>();
        Map<Id, List<Id>> attachmentsByRow = new Map<Id, List<Id>>();
        Set<Id> badAttachmentRows = new Set<Id>();
        for (Sent_Email__c r : rows) {
            hcpIds.add(r.HCP__c);
            if (r.Template__c != null) templateIds.add(r.Template__c);
            creatorIds.add(r.CreatedById);
            try {
                List<Id> a = parseIds(r.Attachment_Content_Ids__c);
                attachmentsByRow.put(r.Id, a);
                contentIds.addAll(a);
            } catch (Exception e) {
                badAttachmentRows.add(r.Id);
                attachmentsByRow.put(r.Id, new List<Id>());
            }
        }

        Map<Id, Set<String>> consentedEmails = consentedEmailsByHcp(hcpIds);
        Map<Id, Email_Template__c> templates = new Map<Id, Email_Template__c>([
            SELECT Id, Is_Withdrawn__c, Expiry_Date__c, Is_User_Saved__c, Subject__c, Body__c, Asset_URL__c,
                   Content_Hash__c, Brand__c, Product__r.Name
            FROM Email_Template__c WHERE Id IN :templateIds
        ]);
        Map<Id, Set<Id>> allowedByTemplate = new Map<Id, Set<Id>>();
        for (Email_Template_Content__c j : [SELECT Template__c, Content__c FROM Email_Template_Content__c WHERE Template__c IN :templateIds]) {
            if (!allowedByTemplate.containsKey(j.Template__c)) allowedByTemplate.put(j.Template__c, new Set<Id>());
            allowedByTemplate.get(j.Template__c).add(j.Content__c);
        }
        Map<Id, Approved_Content__c> content = new Map<Id, Approved_Content__c>(
            [SELECT Id, Content_Name__c, Asset_URL__c FROM Approved_Content__c WHERE Id IN :contentIds]);
        Map<Id, Integer> sentToday = sentTodayByCreator(creatorIds);
        // Callouts (if any) happen here, before any DML or email in this transaction.
        Map<Id, ApprovedEmailRenderer.ApprovedCopy> copies = ApprovedEmailRenderer.loadApprovedCopy(templates);
        Map<Id, ApprovedEmailRenderer.MergeContext> contexts = ApprovedEmailRenderer.buildContexts(rows, templates);

        Map<Id, Sent_Email__c> updates = new Map<Id, Sent_Email__c>();
        List<Messaging.SingleEmailMessage> messages = new List<Messaging.SingleEmailMessage>();
        List<Sent_Email__c> messageRows = new List<Sent_Email__c>();
        for (Sent_Email__c r : rows) {
            Sent_Email__c u = new Sent_Email__c(Id = r.Id);
            updates.put(r.Id, u);
            String problem = badAttachmentRows.contains(r.Id)
                ? 'The attachment list is malformed.'
                : validate(r, consentedEmails, templates, allowedByTemplate, attachmentsByRow.get(r.Id), sentToday);
            String subject;
            String body;
            if (problem == null) {
                ApprovedEmailRenderer.ApprovedCopy copy = copies.get(r.Template__c);
                problem = copy == null ? 'Template no longer exists.' : copy.error;
                if (problem == null) {
                    try {
                        ApprovedEmailRenderer.MergeContext ctx = contexts.get(r.Id);
                        subject = ApprovedEmailRenderer.render(copy.subject, ctx).normalizeSpace();
                        body = composeBody(r, ApprovedEmailRenderer.render(copy.body, ctx), attachmentsByRow.get(r.Id), content);
                    } catch (ApprovedEmailRenderer.RenderException e) {
                        problem = e.getMessage();
                    }
                }
            }
            if (problem != null) {
                u.Status__c = STATUS_FAILED;
                u.Status_Message__c = problem.abbreviate(255);
                continue;
            }
            // Count it now so later rows in this batch see the limit.
            sentToday.put(r.CreatedById, (sentToday.containsKey(r.CreatedById) ? sentToday.get(r.CreatedById) : 0) + 1);
            u.Subject__c = subject.abbreviate(255);
            u.Body_Text__c = body;
            messages.add(buildMessage(r, u.Subject__c, body));
            messageRows.add(r);
        }

        List<String> errors = deliver(messages);
        for (Integer i = 0; i < messageRows.size(); i++) {
            Sent_Email__c r = messageRows[i];
            Sent_Email__c u = updates.get(r.Id);
            if (errors[i] == null) {
                u.Status__c = STATUS_SENT;
                u.Status_Message__c = 'Delivered to the mail service.';
                u.Sent_At__c = Datetime.now();
            } else {
                u.Status__c = STATUS_FAILED;
                u.Status_Message__c = errors[i].abbreviate(255);
                // Not sent: keep the client's record of what it composed.
                u.Subject__c = r.Subject__c;
                u.Body_Text__c = r.Body_Text__c;
            }
        }
        update updates.values();
        if (!deferred.isEmpty()) System.enqueueJob(new SendJob(deferred));
    }

    private static String validate(Sent_Email__c r, Map<Id, Set<String>> consentedEmails, Map<Id, Email_Template__c> templates,
                                   Map<Id, Set<Id>> allowedByTemplate, List<Id> attachIds, Map<Id, Integer> sentToday) {
        if (String.isBlank(r.To_Email__c)) return 'No recipient email address.';
        Set<String> ok = consentedEmails.get(r.HCP__c);
        if (ok == null || !ok.contains(r.To_Email__c.trim().toLowerCase())) {
            return 'No valid email consent on file for this address.';
        }
        if (r.Template__c == null) return 'An approved template is required.';
        Email_Template__c t = templates.get(r.Template__c);
        if (t == null) return 'Template no longer exists.';
        if (t.Is_User_Saved__c == true) return 'Only CMS-approved templates can be sent.';
        if (t.Is_Withdrawn__c == true || (t.Expiry_Date__c != null && t.Expiry_Date__c < Date.today())) {
            return 'Template has been withdrawn or has expired.';
        }
        if (String.isNotBlank(r.Content_Hash__c)
                && (String.isBlank(t.Content_Hash__c) || !r.Content_Hash__c.trim().equalsIgnoreCase(t.Content_Hash__c.trim()))) {
            return 'This email was composed from an out-of-date version of the template; open it again and resend.';
        }
        if (r.Rep_Note__c != null && r.Rep_Note__c.trim().length() > ApprovedEmailRenderer.REP_NOTE_MAX) {
            return 'Personal note is longer than ' + ApprovedEmailRenderer.REP_NOTE_MAX + ' characters.';
        }
        Set<Id> allowed = allowedByTemplate.containsKey(r.Template__c) ? allowedByTemplate.get(r.Template__c) : new Set<Id>();
        for (Id contentId : attachIds) {
            if (!allowed.contains(contentId)) return 'An attachment is not approved for this template.';
        }
        Integer used = sentToday.containsKey(r.CreatedById) ? sentToday.get(r.CreatedById) : 0;
        if (used >= DAILY_LIMIT) return 'Daily approved-email limit (' + DAILY_LIMIT + ') reached.';
        return null;
    }

    private static Map<Id, Set<String>> consentedEmailsByHcp(Set<Id> hcpIds) {
        Map<Id, Set<String>> result = new Map<Id, Set<String>>();
        Datetime cutoff = Datetime.now().addYears(-CONSENT_VALIDITY_YEARS);
        for (Consent_Email__c ce : [
            SELECT Email__c, Consent__r.HCP__c FROM Consent_Email__c
            WHERE Opted_In__c = true AND Email__c != null AND Consent__r.HCP__c IN :hcpIds
              AND Consent__r.Captured_At__c != null AND Consent__r.Captured_At__c >= :cutoff
        ]) {
            Id hcpId = ce.Consent__r.HCP__c;
            if (!result.containsKey(hcpId)) result.put(hcpId, new Set<String>());
            result.get(hcpId).add(ce.Email__c.trim().toLowerCase());
        }
        return result;
    }

    private static Map<Id, Integer> sentTodayByCreator(Set<Id> creatorIds) {
        Map<Id, Integer> result = new Map<Id, Integer>();
        for (AggregateResult ar : [
            SELECT CreatedById c, COUNT(Id) n FROM Sent_Email__c
            WHERE CreatedById IN :creatorIds AND Status__c = :STATUS_SENT AND Sent_At__c = TODAY
            GROUP BY CreatedById
        ]) {
            result.put((Id) ar.get('c'), (Integer) ar.get('n'));
        }
        return result;
    }

    private static List<Id> parseIds(String csv) {
        List<Id> out = new List<Id>();
        if (String.isBlank(csv)) return out;
        for (String part : csv.split(',')) {
            String p = part.trim();
            if (String.isNotBlank(p)) out.add((Id) p);
        }
        return out;
    }

    /** Approved body first, then the rep's note in its own labelled block, then links to approved material and the footer. */
    @TestVisible
    private static String composeBody(Sent_Email__c r, String approvedBody, List<Id> attachIds, Map<Id, Approved_Content__c> content) {
        String body = approvedBody;
        if (String.isNotBlank(r.Rep_Note__c)) {
            body += '\n\n------------------------------\n' +
                    'Personal note from ' + r.CreatedBy.Name + ' (not part of the approved content):\n' +
                    r.Rep_Note__c.trim() +
                    '\n------------------------------';
        }
        if (!attachIds.isEmpty()) {
            body += '\n\nApproved material:';
            for (Id cid : attachIds) {
                Approved_Content__c c = content.get(cid);
                if (c != null) body += '\n - ' + c.Content_Name__c + (String.isBlank(c.Asset_URL__c) ? '' : ': ' + c.Asset_URL__c);
            }
        }
        body += '\n\n--\nSent by ' + r.CreatedBy.Name + ' (' + r.CreatedBy.Email + ') through Sciagen CRM.\n' +
            'You are receiving this because you agreed to receive approved communications. ' +
            'To stop receiving them, reply to this email and ask to be removed.';
        return body;
    }

    private static Messaging.SingleEmailMessage buildMessage(Sent_Email__c r, String subject, String body) {
        Messaging.SingleEmailMessage msg = new Messaging.SingleEmailMessage();
        msg.setToAddresses(new List<String>{ r.To_Email__c.trim() });
        msg.setSubject(subject);
        msg.setPlainTextBody(body);
        msg.setSenderDisplayName(r.CreatedBy.Name);
        msg.setReplyTo(r.CreatedBy.Email);
        msg.setSaveAsActivity(false);
        return msg;
    }

    /**
     * The single delivery point — one Messaging.sendEmail call for the whole job
     * (one of the 10 allowed per transaction). Returns, per message, null on
     * success or an error message. Swap this for SendGrid / SES if needed.
     */
    private static List<String> deliver(List<Messaging.SingleEmailMessage> messages) {
        List<String> out = new List<String>();
        if (messages.isEmpty()) return out;
        if (Test.isRunningTest() && simulateDelivery) {
            for (Integer i = 0; i < messages.size(); i++) out.add(null);
            return out;
        }
        try {
            Messaging.SendEmailResult[] res = Messaging.sendEmail(messages, false);
            for (Messaging.SendEmailResult sr : res) {
                out.add(sr.isSuccess() ? null : (sr.getErrors().isEmpty() ? 'Send failed.' : sr.getErrors()[0].getMessage()));
            }
        } catch (Exception e) {
            out.clear();
            for (Integer i = 0; i < messages.size(); i++) out.add('Send failed: ' + e.getMessage());
        }
        return out;
    }
}