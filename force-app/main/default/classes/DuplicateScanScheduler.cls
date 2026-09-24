/** Nightly entry point: System.schedule('Sciagen Duplicate Scan', '0 0 2 * * ?', new DuplicateScanScheduler()); */
public without sharing class DuplicateScanScheduler implements Schedulable {
    public void execute(SchedulableContext sc) {
        if (DuplicateEngine.loadSettings().enabled) DuplicateScanBatch.run(false);
    }
}