/**
 * Backs the "Reset Local Data" admin-approval gate (Profile > Reset Local
 * Data on the iPad app): a rep can only wipe local app data after their
 * manager approves the request via Salesforce's own Approval Process and
 * hands them a one-time code. This class does the three things a plain
 * Approval Process can't do declaratively:
 *   1. auto-submits every new request for approval (the app just inserts a
 *      bare record -- there's no "Submit for Approval" button to tap),
 *   2. generates a genuinely random one-time code the instant a request is
 *      approved (formulas can't do this), and
 *   3. emails that code to the approver so they have it in hand to relay to
 *      the rep by phone or their own email, satisfying the "collect it
 *      orally or by email" requirement without the app needing its own
 *      email-sending infrastructure.
 */
public with sharing class DeviceResetRequestHandler {

    private static final Integer OTP_VALID_HOURS = 24;
    public static final Integer MAX_ATTEMPTS = 5;

    /** Set only by DeviceResetVerifyApi around the update that records a verification attempt. */
    public static Boolean verifying = false;

    /** Fields only the approval process, the verify endpoint or an admin may change. */
    private static final List<String> SERVER_FIELDS = new List<String>{ 'OTP__c', 'OTP_Expires__c', 'Verified__c', 'Attempts__c', 'Manager__c' };

    /** Populates Manager__c from the owner's User.ManagerId so the Approval
     * Process can route dynamically without a hardcoded approver. Called in
     * a before-insert context so the field is set before the record is saved. */
    public static void stampManager(List<Device_Reset_Request__c> newRequests) {
        Set<Id> ownerIds = new Set<Id>();
        for (Device_Reset_Request__c req : newRequests) ownerIds.add(req.OwnerId);
        Map<Id, User> users = new Map<Id, User>([SELECT Id, ManagerId FROM User WHERE Id IN :ownerIds]);
        for (Device_Reset_Request__c req : newRequests) {
            User u = users.get(req.OwnerId);
            // Always from the owner's User record, never from the client: the approver must not be self-chosen.
            req.Manager__c = u == null ? null : u.ManagerId;
            // A new request always starts clean.
            req.Status__c = 'Pending Approval';
            req.OTP__c = null;
            req.OTP_Expires__c = null;
            req.Verified__c = false;
            req.Attempts__c = 0;
        }
    }

    /**
     * Before update, ahead of generateOTPOnApproval: a rep can't approve their own request (so no
     * code is minted for them), can't mark it verified/used, and can't touch the code, its expiry,
     * the attempt counter or the approver (QA-34 / H10). Allowed: the approver (Manager__c) -- the
     * approval process's Set Status Approved / Rejected field updates run as that user -- the
     * verify endpoint, and admins with Modify All Data.
     */
    public static void guardUpdates(List<Device_Reset_Request__c> newList, Map<Id, Device_Reset_Request__c> oldMap) {
        if (verifying) return;
        Boolean admin = null;
        Id me = UserInfo.getUserId();
        for (Device_Reset_Request__c req : newList) {
            Device_Reset_Request__c old = oldMap.get(req.Id);
            Boolean statusChanged = req.Status__c != old.Status__c;
            Boolean serverFieldChanged = false;
            for (String f : SERVER_FIELDS) {
                if (req.get(f) != old.get(f)) { serverFieldChanged = true; break; }
            }
            if (!statusChanged && !serverFieldChanged) continue;
            if (admin == null) admin = SciagenAccess.hasModifyAllData();
            if (admin) continue;
            Boolean approverDeciding = statusChanged && old.Manager__c != null && old.Manager__c == me
                && (req.Status__c == 'Approved' || req.Status__c == 'Rejected') && !serverFieldChanged;
            if (approverDeciding) continue;
            req.addError(req.Status__c == 'Approved' && statusChanged
                ? 'Only your manager can approve a device reset request.'
                : 'This device reset request can only be changed by the approval process or the reset-code check.');
        }
    }

    /** Every new request needs to enter the org's Approval Process immediately --
     * best-effort per record, so one bad record (e.g. no manager set, so no
     * approver can be resolved) doesn't block the others in the same batch. */
    public static void submitForApproval(List<Device_Reset_Request__c> newRequests) {
        for (Device_Reset_Request__c req : newRequests) {
            try {
                Approval.ProcessSubmitRequest submitRequest = new Approval.ProcessSubmitRequest();
                submitRequest.setObjectId(req.Id);
                Approval.process(submitRequest);
            } catch (Exception e) {
                // Surfaces in the record's own history/debug log rather than
                // failing the insert the app is waiting on -- a rep whose
                // request can't be routed (e.g. missing manager) should still
                // see "Pending Approval" and know to contact an admin,
                // instead of the reset flow erroring out inexplicably.
                System.debug(LoggingLevel.ERROR, 'DeviceResetRequestHandler.submitForApproval failed for ' + req.Id + ': ' + e.getMessage());
            }
        }
    }

    /** Runs in the SAME save as the Approval Process's own "Approved" field
     * update (before-update, so no extra DML/recursion) -- the instant
     * Status__c lands on Approved with no code yet, mint one. Six digits,
     * zero-padded, expires in OTP_VALID_HOURS so an approved-but-forgotten
     * request can't be redeemed indefinitely. */
    public static void generateOTPOnApproval(List<Device_Reset_Request__c> newList, Map<Id, Device_Reset_Request__c> oldMap) {
        for (Device_Reset_Request__c req : newList) {
            Device_Reset_Request__c old = oldMap.get(req.Id);
            Boolean justApproved = req.Status__c == 'Approved' && old.Status__c != 'Approved';
            if (justApproved && String.isBlank(req.OTP__c)) {
                req.OTP__c = newCode();
                req.OTP_Expires__c = System.now().addHours(OTP_VALID_HOURS);
                req.Attempts__c = 0;
            }
        }
    }

    /** Six random digits from the platform CSPRNG (Crypto.getRandomInteger), without modulo bias. */
    @TestVisible
    private static String newCode() {
        final Integer bound = 2147000000;   // largest multiple of 1,000,000 below 2^31
        Integer r;
        do {
            r = Crypto.getRandomInteger() & 2147483647;
        } while (r >= bound);
        return String.valueOf(Math.mod(r, 1000000)).leftPad(6, '0');
    }

    /** Fires right after the code lands, so it queries back the final saved
     * value rather than trying to thread it through from the before-trigger.
     * Emails the requesting rep's manager (the approver, per this org's
     * Role Hierarchy-based routing) -- best-effort: a rep can also just get
     * the code read to them over the phone, so a failed/undeliverable email
     * here shouldn't be treated as the approval itself having failed. */
    public static void emailApproverTheCode(List<Device_Reset_Request__c> newList, Map<Id, Device_Reset_Request__c> oldMap) {
        Set<Id> justApprovedIds = new Set<Id>();
        for (Device_Reset_Request__c req : newList) {
            Device_Reset_Request__c old = oldMap.get(req.Id);
            if (req.Status__c == 'Approved' && old.Status__c != 'Approved' && String.isNotBlank(req.OTP__c)) {
                justApprovedIds.add(req.Id);
            }
        }
        if (justApprovedIds.isEmpty()) return;

        // Device_Reset_Request__c.OwnerId is polymorphic (User or Queue), so
        // Owner.ManagerId can't be traversed directly in this object's own
        // SOQL -- look the owning User up separately instead. Requests are
        // always owned by the requesting rep (never queue-assigned), so this
        // is safe to assume rather than branch on.
        List<Device_Reset_Request__c> toNotify = [
            SELECT Id, Name, OTP__c, OwnerId FROM Device_Reset_Request__c WHERE Id IN :justApprovedIds
        ];
        Set<Id> ownerIds = new Set<Id>();
        for (Device_Reset_Request__c req : toNotify) ownerIds.add(req.OwnerId);
        Map<Id, User> owners = new Map<Id, User>([
            SELECT Id, Name, ManagerId, Manager.Email, Manager.Name FROM User WHERE Id IN :ownerIds
        ]);
        List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();
        for (Device_Reset_Request__c req : toNotify) {
            User owner = owners.get(req.OwnerId);
            if (owner == null || owner.ManagerId == null || String.isBlank(owner.Manager.Email)) continue;
            Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
            mail.setToAddresses(new List<String>{ owner.Manager.Email });
            mail.setSubject('Device reset approved for ' + owner.Name + ' -- one-time code ' + req.OTP__c);
            mail.setPlainTextBody(
                'You approved ' + owner.Name + '\'s request (' + req.Name + ') to reset local app data on their iPad.\n\n' +
                'One-time code: ' + req.OTP__c + '\n\n' +
                'Read or forward this code to ' + owner.Name + ' -- they need to enter it in the app to complete the reset. ' +
                'The code expires in ' + OTP_VALID_HOURS + ' hours.');
            mail.setSaveAsActivity(false);
            emails.add(mail);
        }
        if (!emails.isEmpty()) {
            try {
                Messaging.sendEmail(emails, false);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'DeviceResetRequestHandler.emailApproverTheCode failed: ' + e.getMessage());
            }
        }
    }
}