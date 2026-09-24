/** Re-checks specific accounts for duplicates in the background (a new record, or a freshly merged winner). */
public without sharing class DuplicateScanQueueable implements Queueable {
    private Set<Id> ids;
    public DuplicateScanQueueable(Set<Id> ids) { this.ids = ids; }
    public void execute(QueueableContext ctx) {
        DuplicateEngine.scan(ids, true);
    }
}