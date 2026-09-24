/// Nightly retention purge for Sync_Tracking__c — the server-side mirror of
/// the iPad app's on-device sync log (see UserDataStore.swift's syncLog /
/// SciagenCRMApp.swift's onSyncLogEntryChanged wiring). Without this job the
/// object grows forever: every rep-initiated push (CVR, DCR, Segmentation,
/// Leave Request, ...) adds one row and nothing ever removes one. On this
/// org's tiny Developer Edition data-storage allocation (5MB) that's exactly
/// what happened — 2,356 accumulated rows (most of them periodic Accounts/
/// Planned-Calls background-sync heartbeats that have since been stopped
/// from mirroring at all, see UserDataStore.logSyncPending's
/// `mirrorToSalesforce` parameter) exhausted the limit and blocked every new
/// record creation org-wide, Call Reports included. This job is the
/// second, durable half of that fix: even genuine rep-activity rows now
/// age out automatically instead of accumulating forever.
public class SyncTrackingPurgeJob implements Database.Batchable<SObject>, Schedulable {
    /// How long a Sync_Tracking__c row survives before this job deletes it.
    /// Purging is safe at any retention length — this object only ever
    /// mirrors sync *status*, never the underlying business data (the CVR,
    /// DCR, etc. records themselves are untouched).
    public static final Integer RETENTION_DAYS = 90;

    public void execute(SchedulableContext ctx) {
        Database.executeBatch(new SyncTrackingPurgeJob(), 200);
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        DateTime cutoff = DateTime.now().addDays(-RETENTION_DAYS);
        return Database.getQueryLocator([
            SELECT Id FROM Sync_Tracking__c WHERE CreatedDate < :cutoff
        ]);
    }

    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        delete scope;
    }

    public void finish(Database.BatchableContext bc) {
    }
}