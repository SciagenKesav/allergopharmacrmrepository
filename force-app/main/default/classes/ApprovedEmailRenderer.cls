/**
 * Builds the subject and body of an Approved Email on the server, from the
 * MLR-approved template only. The client's Subject__c / Body_Text__c are never
 * sent (QA-29 / S-04 / H9).
 *
 * Where the approved wording lives
 * --------------------------------
 * The Sciagen CMS publishes each template as a JSON file
 * `{ "schemaVersion": 1, "subject": "...", "bodyText": "..." }` and pushes
 * only a pointer (Email_Template__c.Asset_URL__c) and its SHA-256
 * (Content_Hash__c) through CMSEmailTemplateReceiver. That file is the
 * authoritative copy (it is what the iPad downloads, hash-checks and shows).
 * Email_Template__c.Subject__c / Body__c are the CMS's optional plain-text copy
 * and are used only when there is no file, or the file can't be fetched right
 * now. Email_Template_Content__c is the attachment allow-list, not wording.
 *
 * The file is loaded either straight from Salesforce Files (when the pointer is
 * a Salesforce content-distribution link, `.../sfc/dist/version/download/?ids=068...`,
 * which is what the org uses today — no callout needed) or with an HTTP GET
 * (an S3 URL: needs a Remote Site Setting for the bucket host). A file whose
 * SHA-256 doesn't match Content_Hash__c is rejected, never used.
 *
 * Merge tokens
 * ------------
 * Exactly the set the iPad composer supports (EmailModels.swift EmailToken +
 * the legacy {{HCP}} / {{REP}}), filled from Salesforce data:
 *   {{Rep Name}} {{Rep Email}} {{Rep Phone}}          -> the sending User (MobilePhone, else Phone)
 *   {{HCP Name}} {{HCP}} {{HCP Specialty}}            -> Sciagen_Account__c
 *   {{HCO Name}}                                      -> the HCP's primary Affiliation__c HCO
 *   {{Territory}}                                     -> HCP's territory (the rep's own if shared), else the rep's primary
 *   {{Product Name}} {{Brand Name}}                   -> the template's Product__c / Brand__c
 *   {{Call Date}}                                     -> HCP Last_Visit__c, else the queue date
 *   {{Meeting Date}}                                  -> the date the email was queued
 *   {{Next Visit Date}}                               -> the rep's next Planned_Call__c with this HCP, else queue date + 7
 * A token outside this set, or one whose value isn't on file, fails the send
 * with a message naming the token — nothing half-filled is ever delivered.
 */
public without sharing class ApprovedEmailRenderer {

    public static final Integer REP_NOTE_MAX = 500;

    /** Result of loading one template's approved wording. error != null means unusable. */
    public class ApprovedCopy {
        public String subject;
        public String body;
        public String error;
    }

    /** Everything a token can resolve to, for one email. */
    public class MergeContext {
        public Map<String, String> values = new Map<String, String>();
    }

    // Canonical token key (lower-case label) -> the label shown in messages.
    private static final Map<String, String> KNOWN_TOKENS = new Map<String, String>{
        'rep name' => 'Rep Name', 'rep email' => 'Rep Email', 'rep phone' => 'Rep Phone',
        'hcp name' => 'HCP Name', 'hcp specialty' => 'HCP Specialty', 'hco name' => 'HCO Name',
        'territory' => 'Territory', 'product name' => 'Product Name', 'brand name' => 'Brand Name',
        'call date' => 'Call Date', 'meeting date' => 'Meeting Date', 'next visit date' => 'Next Visit Date',
        'hcp' => 'HCP', 'rep' => 'REP'
    };
    private static final Pattern TOKEN = Pattern.compile('\\{\\{\\s*([^{}]*?)\\s*\\}\\}');

    // ---------------------------------------------------------------- approved copy

    /** Loads the approved subject/body of every template. Must run before any DML in the transaction (it may call out). */
    public static Map<Id, ApprovedCopy> loadApprovedCopy(Map<Id, Email_Template__c> templates) {
        Map<Id, ApprovedCopy> out = new Map<Id, ApprovedCopy>();
        // Salesforce-hosted files in one query.
        Map<Id, Id> versionByTemplate = new Map<Id, Id>();
        for (Email_Template__c t : templates.values()) {
            Id vId = salesforceFileVersionId(t.Asset_URL__c);
            if (vId != null) versionByTemplate.put(t.Id, vId);
        }
        Map<Id, ContentVersion> versions = new Map<Id, ContentVersion>();
        if (!versionByTemplate.isEmpty()) {
            versions = new Map<Id, ContentVersion>([
                SELECT Id, VersionData FROM ContentVersion WHERE Id IN :versionByTemplate.values()
            ]);
        }
        for (Email_Template__c t : templates.values()) {
            Blob file = null;
            Boolean hasFile = String.isNotBlank(t.Asset_URL__c);
            if (hasFile) {
                if (versionByTemplate.containsKey(t.Id)) {
                    ContentVersion cv = versions.get(versionByTemplate.get(t.Id));
                    file = cv == null ? null : cv.VersionData;
                } else {
                    file = httpGet(t.Asset_URL__c);
                }
            }
            out.put(t.Id, toCopy(t, file, hasFile));
        }
        return out;
    }

    @TestVisible
    private static ApprovedCopy toCopy(Email_Template__c t, Blob file, Boolean hasFile) {
        ApprovedCopy c = new ApprovedCopy();
        if (file != null) {
            if (String.isNotBlank(t.Content_Hash__c) && sha256Hex(file) != t.Content_Hash__c.trim().toLowerCase()) {
                c.error = 'The approved template file failed its integrity check (hash mismatch); not sent.';
                return c;
            }
            try {
                Map<String, Object> m = (Map<String, Object>) JSON.deserializeUntyped(file.toString());
                String s = (String) m.get('subject');
                String b = (String) m.get('bodyText');
                if (String.isBlank(b)) {
                    c.error = 'The approved template file has no body text.';
                    return c;
                }
                c.subject = String.isNotBlank(s) ? s : t.Subject__c;
                c.body = b;
            } catch (Exception e) {
                c.error = 'The approved template file could not be read.';
                return c;
            }
        } else if (String.isNotBlank(t.Body__c)) {
            // No file, or it can't be fetched right now: the CMS-pushed plain-text copy.
            c.subject = t.Subject__c;
            c.body = t.Body__c;
        } else {
            c.error = hasFile
                ? 'The approved template file could not be loaded; try again later.'
                : 'The template has no approved content.';
            return c;
        }
        if (String.isBlank(c.subject)) c.error = 'The template has no approved subject.';
        return c;
    }

    /** 068... id from a Salesforce content-distribution download link, else null. */
    @TestVisible
    private static Id salesforceFileVersionId(String url) {
        if (String.isBlank(url) || !url.containsIgnoreCase('/sfc/dist/version/download')) return null;
        Matcher m = Pattern.compile('[?&]ids=(068[a-zA-Z0-9]{12}(?:[a-zA-Z0-9]{3})?)').matcher(url);
        if (!m.find()) return null;
        try { return (Id) m.group(1); } catch (Exception e) { return null; }
    }

    private static Blob httpGet(String url) {
        if (!url.startsWithIgnoreCase('https://')) return null;
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(url);
            req.setMethod('GET');
            req.setTimeout(20000);
            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() >= 200 && res.getStatusCode() < 300) return res.getBodyAsBlob();
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Approved email template fetch failed: ' + e.getTypeName());
        }
        return null;
    }

    public static String sha256Hex(Blob b) {
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', b)).toLowerCase();
    }

    // ---------------------------------------------------------------- merge data

    /** Builds merge values for each email, with a fixed number of queries for the whole list. */
    public static Map<Id, MergeContext> buildContexts(List<Sent_Email__c> rows, Map<Id, Email_Template__c> templates) {
        Set<Id> hcpIds = new Set<Id>();
        Set<Id> repIds = new Set<Id>();
        for (Sent_Email__c r : rows) {
            if (r.HCP__c != null) hcpIds.add(r.HCP__c);
            repIds.add(r.CreatedById);
        }
        Map<Id, User> reps = new Map<Id, User>([SELECT Id, Name, Email, MobilePhone, Phone, TimeZoneSidKey FROM User WHERE Id IN :repIds]);
        Map<Id, Sciagen_Account__c> hcps = new Map<Id, Sciagen_Account__c>([
            SELECT Id, Name, Prefix__c, First_Name__c, Last_Name__c, Specialty__c, Last_Visit__c
            FROM Sciagen_Account__c WHERE Id IN :hcpIds
        ]);
        Map<Id, String> hcoByHcp = new Map<Id, String>();
        for (Affiliation__c a : [SELECT HCP__c, HCO__r.Name FROM Affiliation__c
                                 WHERE HCP__c IN :hcpIds AND Is_Primary__c = true ORDER BY CreatedDate]) {
            if (!hcoByHcp.containsKey(a.HCP__c) && a.HCO__r != null) hcoByHcp.put(a.HCP__c, a.HCO__r.Name);
        }
        Map<Id, List<Account_Territory__c>> terrByHcp = new Map<Id, List<Account_Territory__c>>();
        for (Account_Territory__c at : [SELECT Account__c, Territory__c, Territory__r.Name FROM Account_Territory__c
                                        WHERE Account__c IN :hcpIds ORDER BY CreatedDate]) {
            if (!terrByHcp.containsKey(at.Account__c)) terrByHcp.put(at.Account__c, new List<Account_Territory__c>());
            terrByHcp.get(at.Account__c).add(at);
        }
        Map<Id, Set<Id>> repTerritories = new Map<Id, Set<Id>>();
        Map<Id, String> repPrimaryTerritory = new Map<Id, String>();
        for (User_Territory__c ut : [SELECT User__c, Territory__c, Territory__r.Name, Is_Primary__c FROM User_Territory__c
                                     WHERE User__c IN :repIds ORDER BY Is_Primary__c DESC, CreatedDate]) {
            if (!repTerritories.containsKey(ut.User__c)) repTerritories.put(ut.User__c, new Set<Id>());
            repTerritories.get(ut.User__c).add(ut.Territory__c);
            if (!repPrimaryTerritory.containsKey(ut.User__c) && ut.Territory__r != null) repPrimaryTerritory.put(ut.User__c, ut.Territory__r.Name);
        }
        Map<String, Datetime> nextCall = new Map<String, Datetime>();
        for (Planned_Call__c pc : [SELECT HCP__c, OwnerId, Call_DateTime__c FROM Planned_Call__c
                                   WHERE HCP__c IN :hcpIds AND OwnerId IN :repIds AND Call_DateTime__c >= :Datetime.now()
                                   ORDER BY Call_DateTime__c ASC]) {
            String k = pc.OwnerId + '|' + pc.HCP__c;
            if (!nextCall.containsKey(k)) nextCall.put(k, pc.Call_DateTime__c);
        }

        Map<Id, MergeContext> out = new Map<Id, MergeContext>();
        for (Sent_Email__c r : rows) {
            MergeContext ctx = new MergeContext();
            User rep = reps.get(r.CreatedById);
            Sciagen_Account__c hcp = hcps.get(r.HCP__c);
            Email_Template__c t = templates.get(r.Template__c);
            String tz = rep != null && rep.TimeZoneSidKey != null ? rep.TimeZoneSidKey : UserInfo.getTimeZone().getID();
            Datetime queuedAt = r.CreatedDate != null ? r.CreatedDate : Datetime.now();

            if (rep != null) {
                put(ctx, 'rep name', rep.Name);
                put(ctx, 'rep', rep.Name);
                put(ctx, 'rep email', rep.Email);
                put(ctx, 'rep phone', String.isNotBlank(rep.MobilePhone) ? rep.MobilePhone : rep.Phone);
            }
            if (hcp != null) {
                String full = joinNonBlank(new List<String>{ hcp.Prefix__c, hcp.First_Name__c, hcp.Last_Name__c });
                if (String.isBlank(full)) full = hcp.Name;
                put(ctx, 'hcp name', full);
                put(ctx, 'hcp', full);
                put(ctx, 'hcp specialty', hcp.Specialty__c);
                put(ctx, 'call date', formatDate(hcp.Last_Visit__c != null ? Datetime.newInstance(hcp.Last_Visit__c, Time.newInstance(12, 0, 0, 0)) : queuedAt, tz));
            }
            put(ctx, 'hco name', hcoByHcp.get(r.HCP__c));
            put(ctx, 'territory', territoryFor(terrByHcp.get(r.HCP__c), repTerritories.get(r.CreatedById), repPrimaryTerritory.get(r.CreatedById)));
            if (t != null) {
                String product = t.Product__r != null ? t.Product__r.Name : null;
                put(ctx, 'product name', product);
                put(ctx, 'brand name', String.isNotBlank(t.Brand__c) ? t.Brand__c : product);
            }
            put(ctx, 'meeting date', formatDate(queuedAt, tz));
            Datetime nv = nextCall.get(r.CreatedById + '|' + r.HCP__c);
            put(ctx, 'next visit date', formatDate(nv != null ? nv : queuedAt.addDays(7), tz));
            out.put(r.Id, ctx);
        }
        return out;
    }

    private static String territoryFor(List<Account_Territory__c> hcpTerr, Set<Id> repTerr, String repPrimary) {
        if (hcpTerr != null && !hcpTerr.isEmpty()) {
            if (repTerr != null) {
                for (Account_Territory__c at : hcpTerr) {
                    if (repTerr.contains(at.Territory__c) && at.Territory__r != null) return at.Territory__r.Name;
                }
            }
            if (hcpTerr[0].Territory__r != null) return hcpTerr[0].Territory__r.Name;
        }
        return repPrimary;
    }

    private static void put(MergeContext ctx, String key, String value) {
        if (String.isNotBlank(value)) ctx.values.put(key, value.trim());
    }

    private static String joinNonBlank(List<String> parts) {
        List<String> kept = new List<String>();
        for (String p : parts) if (String.isNotBlank(p)) kept.add(p.trim());
        return String.join(kept, ' ');
    }

    private static String formatDate(Datetime dt, String tz) {
        return dt.format('d MMM yyyy', tz);
    }

    // ---------------------------------------------------------------- rendering

    public class RenderException extends Exception {}

    /** Replaces every {{token}}; throws RenderException naming the first token it can't fill. */
    public static String render(String text, MergeContext ctx) {
        if (text == null) return '';
        Matcher m = TOKEN.matcher(text);
        String out = '';
        Integer last = 0;
        while (m.find()) {
            String raw = m.group(1);
            String key = raw == null ? '' : raw.trim().toLowerCase();
            if (!KNOWN_TOKENS.containsKey(key)) {
                throw new RenderException('Template uses the merge field {{' + raw + '}}, which the server cannot fill in; not sent.');
            }
            String v = ctx.values.get(key);
            if (String.isBlank(v)) {
                throw new RenderException('Template needs {{' + KNOWN_TOKENS.get(key) + '}} but no value is on file for it; not sent.');
            }
            out += text.substring(last, m.start()) + v;
            last = m.end();
        }
        return out + text.substring(last);
    }
}