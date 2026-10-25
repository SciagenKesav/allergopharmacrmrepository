/**
 * Retries a batch of *__Share inserts in their own later transaction.
 *
 * This exists for exactly one scenario: a sharing-service (TerritorySharingService /
 * DCRTerritorySharingService / RCPAAuditTerritorySharingService) tries to grant a Manual
 * share on a parent record that was itself inserted earlier in the SAME transaction, and the
 * running user isn't that parent's owner. The platform rejects that insert with
 * INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY regardless of `without sharing` or
 * AccessLevel.SYSTEM_MODE — neither bypasses this specific check, since it isn't a CRUD/FLS/
 * sharing-rule check but the sharing engine not yet having settled visibility for a
 * same-transaction parent. Running the identical insert in a fresh transaction (this queueable)
 * succeeds because by then the parent's existence is fully committed and visible.
 *
 * Generic over SObject type so all three sharing services can reuse it.
 */
public without sharing class DeferredShareInsertQueueable implements Queueable {
    private final List<SObject> shares;

    public DeferredShareInsertQueueable(List<SObject> shares) {
        this.shares = shares;
    }

    public void execute(QueueableContext ctx) {
        if (shares != null && !shares.isEmpty()) {
            Database.insert(shares, false, AccessLevel.SYSTEM_MODE);
        }
    }
}