/**
 * The single answer to "can this rep give this product to this doctor now?".
 * Combines: product rules (sample product, restricted), the doctor's licence,
 * drug-schedule licence for controlled substances, sample opt-in consent,
 * lot choice (first expiry first out) with stock, expiry and cold chain, and
 * every applicable limit (SampleLimitChecker). The iPad runs the same rules
 * offline against its synced copies; this is the authority.
 */
public without sharing class SampleEligibilityService {

    public class Request {
        public Id repUserId;
        public Id hcpAccountId;
        public Id productId;
        public Integer quantity;
        public Id callId;
        public Id lotId;                    // optional: a lot the rep picked
        public Decimal onCallSameProduct = 0;
        public Decimal onCallAll = 0;
    }

    public class Result {
        public String status = 'Eligible';  // Eligible, Warning, Blocked
        public Boolean blocked = false;
        public String message;
        public List<String> blockers = new List<String>();
        public List<String> warnings = new List<String>();
        public Boolean needsReason = false;
        public Boolean requiresManager = false;
        public Boolean requiresSignature = false;
        public Id lotId;
        public String lotNumber;
        public Date lotExpiry;
        public Decimal lotAvailable;
        public Id overrideId;
        public SampleLimitChecker.LimitCheckResult limits;
    }

    public static Result check(Request req) {
        Result r = new Result();
        Date today = Date.today();
        Integer qty = req.quantity == null ? 0 : req.quantity;

        Product__c p = [
            SELECT Id, Name, Is_Sample_Product__c, Is_Restricted__c, Restriction_Reason__c, Requires_Lot_Number__c, Requires_License_Validation__c,
                   Requires_Signature__c, Requires_Cold_Chain__c, Is_Controlled_Substance__c
            FROM Product__c WHERE Id = :req.productId LIMIT 1
        ];
        SampleConfig cfg = SampleConfig.load();
        r.requiresSignature = p.Requires_Signature__c == true || p.Is_Controlled_Substance__c == true;

        // 1. the product
        if (p.Is_Sample_Product__c != true) block(r, p.Name + ' is not set up as a sample product.');
        if (p.Is_Restricted__c == true) {
            block(r, p.Name + ' is restricted and can not be sampled'
                + (p.Restriction_Reason__c == 'Hypnotic_Sedative_Tranquillizer' ? ' (hypnotic, sedative or tranquillizer). Ref: UCPMP 2024 Clause 5.1(ii)(f).' : '.'));
        }
        if (qty <= 0) block(r, 'Enter a quantity above zero.');

        // 2. the doctor
        Sciagen_Account__c hcp = [
            SELECT Id, Name, Type__c, License_Verification_Status__c, License_Expiry_Date__c, Can_Prescribe__c, Controlled_Substance_License__c
            FROM Sciagen_Account__c WHERE Id = :req.hcpAccountId LIMIT 1
        ];
        if (p.Requires_License_Validation__c != false) licence(r, hcp, today);
        if (p.Is_Controlled_Substance__c == true && String.isBlank(hcp.Controlled_Substance_License__c)) {
            block(r, hcp.Name + ' has no drug-schedule licence on file for a controlled substance.');
        }

        // 3. sample opt-in
        if (cfg.requireOptIn && !hasOptIn(hcp.Id, today)) {
            String m = 'No valid sample opt-in consent for ' + hcp.Name + '. Capture it before sampling.';
            if (cfg.optInHardBlock) block(r, m); else r.warnings.add(m);
        }

        // 4. the lot
        if (p.Requires_Lot_Number__c != false && p.Is_Sample_Product__c == true) lot(r, req, p, qty, today);

        // 5. limits
        if (req.hcpAccountId != null && p.Id != null && qty > 0) {
            SampleLimitChecker.LimitCheckResult lc = SampleLimitChecker.checkLimits(req.repUserId, req.hcpAccountId, p.Id, qty, req.callId,
                req.onCallSameProduct, req.onCallAll);
            r.limits = lc;
            r.blockers.addAll(lc.blockers);
            r.warnings.addAll(lc.warnings);
            r.needsReason = lc.needsReason;
            r.requiresManager = lc.requiresManager;
            r.overrideId = lc.overrideId;
        }

        r.blocked = !r.blockers.isEmpty();
        r.status = r.blocked ? 'Blocked' : (r.warnings.isEmpty() ? 'Eligible' : 'Warning');
        List<String> lines = r.blocked ? r.blockers : r.warnings;
        r.message = lines.isEmpty() ? null : String.join(lines, ' ').left(255);
        return r;
    }

    private static void block(Result r, String message) { r.blockers.add(message); }

    private static void licence(Result r, Sciagen_Account__c hcp, Date today) {
        String status = hcp.License_Verification_Status__c;
        if (hcp.Can_Prescribe__c != true) {
            block(r, hcp.Name + ' is not qualified to prescribe, so cannot receive samples. Ref: UCPMP 2024 Clause 5.1(ii).');
        } else if (status != 'Verified') {
            String what = String.isBlank(status) ? 'unverified' : status.toLowerCase();
            block(r, 'HCP licence is ' + what + '. Verify ' + hcp.Name + '\'s Medical Council registration before sampling.');
        } else if (hcp.License_Expiry_Date__c == null) {
            block(r, 'HCP licence has no expiry date on file for ' + hcp.Name + '.');
        } else if (hcp.License_Expiry_Date__c < today) {
            block(r, 'HCP licence expired on ' + hcp.License_Expiry_Date__c.format() + '.');
        }
    }

    private static Boolean hasOptIn(Id hcpId, Date today) {
        return ![SELECT Id FROM Consent__c WHERE HCP__c = :hcpId AND Consent_Purpose__c INCLUDES ('Sample_Opt_In')
                 AND Sample_Opt_In_Valid_Until__c >= :today LIMIT 1].isEmpty();
    }

    /** First expiry first out. A lot the rep picked is validated instead. */
    private static void lot(Result r, Request req, Product__c p, Integer qty, Date today) {
        Sample_Lot__c chosen = null;
        if (req.lotId != null) {
            List<Sample_Lot__c> picked = [SELECT Id, Lot_Number__c, Expiry_Date__c, Available_Quantity__c, Status__c, Cold_Chain_Status__c, Product__c
                                          FROM Sample_Lot__c WHERE Id = :req.lotId LIMIT 1];
            if (!picked.isEmpty()) chosen = picked[0];
        }
        if (chosen == null) {
            List<Sample_Lot__c> candidates = [
                SELECT Id, Lot_Number__c, Expiry_Date__c, Available_Quantity__c, Status__c, Cold_Chain_Status__c, Product__c
                FROM Sample_Lot__c
                WHERE Owner_User__c = :req.repUserId AND Product__c = :p.Id AND Status__c = 'Active'
                  AND Available_Quantity__c > 0 AND Expiry_Date__c >= :today
                ORDER BY Expiry_Date__c ASC NULLS LAST, CreatedDate ASC LIMIT 20
            ];
            for (Sample_Lot__c l : candidates) { if (l.Available_Quantity__c >= qty) { chosen = l; break; } }
            if (chosen == null && !candidates.isEmpty()) chosen = candidates[0];
        }
        if (chosen == null) {
            block(r, 'You have no active lot of ' + p.Name + ' to give from. Confirm a receipt or ask for stock.');
            return;
        }
        r.lotId = chosen.Id;
        r.lotNumber = chosen.Lot_Number__c;
        r.lotExpiry = chosen.Expiry_Date__c;
        r.lotAvailable = chosen.Available_Quantity__c;
        if (chosen.Product__c != p.Id) block(r, 'Lot ' + chosen.Lot_Number__c + ' is a different product.');
        if (chosen.Status__c != 'Active') block(r, 'Lot ' + chosen.Lot_Number__c + ' is ' + chosen.Status__c + ' and can not be given out.');
        if (chosen.Expiry_Date__c != null && chosen.Expiry_Date__c < today) block(r, 'Lot ' + chosen.Lot_Number__c + ' has expired.');
        else if (chosen.Expiry_Date__c != null && today.daysBetween(chosen.Expiry_Date__c) <= 30) {
            r.warnings.add('Lot ' + chosen.Lot_Number__c + ' expires ' + chosen.Expiry_Date__c.format() + ' (' + today.daysBetween(chosen.Expiry_Date__c) + ' days).');
        }
        if (chosen.Available_Quantity__c < qty) r.warnings.add('Only ' + chosen.Available_Quantity__c.intValue() + ' packs in lot ' + chosen.Lot_Number__c + '.');
        if (p.Requires_Cold_Chain__c == true && chosen.Cold_Chain_Status__c == 'Breach') {
            block(r, 'Cold chain breach on lot ' + chosen.Lot_Number__c + '. Cannot distribute. Return to warehouse for quality assessment.');
        }
    }
}