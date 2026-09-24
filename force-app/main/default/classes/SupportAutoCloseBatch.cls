/**
 * Keeps the tracker tidy at scale: resolved requests close after a few days,
 * and requests waiting on a rep who never answered close as "No Response".
 * Schedule daily with SupportAutoCloseBatch.schedule().
 */
public without sharing class SupportAutoCloseBatch implements Database.Batchable<SObject>, Schedulable {

    public static final String JOB_NAME = 'Support Auto Close';

    public static Id schedule() {
        for (CronTrigger t : [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = :JOB_NAME]) System.abortJob(t.Id);
        return System.schedule(JOB_NAME, '0 30 2 * * ?', new SupportAutoCloseBatch());
    }

    public void execute(SchedulableContext sc) { Database.executeBatch(new SupportAutoCloseBatch(), 200); }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        SupportConfig cfg = SupportConfig.load();
        Datetime resolvedBefore = Datetime.now().addDays(-cfg.closeResolvedDays);
        Datetime waitingBefore = Datetime.now().addDays(-cfg.closeWaitingDays);
        return Database.getQueryLocator([
            SELECT Id, Status__c FROM Support_Request__c
            WHERE (Status__c = 'Resolved' AND Resolved_At__c < :resolvedBefore)
               OR (Status__c = 'Waiting on Rep' AND Last_Activity_At__c < :waitingBefore)
        ]);
    }

    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        List<Support_Request__c> updates = new List<Support_Request__c>();
        for (SObject s : scope) {
            Support_Request__c r = (Support_Request__c) s;
            Support_Request__c u = new Support_Request__c(Id = r.Id, Status__c = 'Closed');
            if (r.Status__c == 'Waiting on Rep') u.Resolution_Type__c = 'No Response';
            updates.add(u);
        }
        SupportRequestService.updateInternally(updates, false);
    }

    public void finish(Database.BatchableContext bc) {}
}