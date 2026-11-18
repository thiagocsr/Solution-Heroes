/**
 * Daily sweep that creates Renewal Tasks for agreements that entered the
 * attention window simply because time passed.
 *
 * The trigger only runs when an agreement is saved. An agreement ending on
 * Dec 31 that nobody edits enters the 30-day window on Dec 1 without any DML,
 * so without this job it would never get a Renewal Task.
 *
 * The batch reuses RenewalTaskService unchanged, so the trigger and the job
 * apply exactly the same rules, including duplicate prevention: running the
 * job repeatedly (or after a trigger already created the Task) is safe.
 *
 * Implements Schedulable as well, so one class is both the job and its
 * scheduler. Schedule once with RenewalTaskBatch.scheduleDaily()
 * (see scripts/apex/scheduleRenewalBatch.apex).
 *
 * without sharing: system automation that must process every qualifying
 * agreement regardless of who scheduled it.
 */
public without sharing class RenewalTaskBatch implements Database.Batchable<SObject>, Schedulable {
    public static final String JOB_NAME = 'Daily Renewal Task Sync';
    /** Every day at 02:00 (scheduling user's time zone). */
    public static final String DAILY_CRON = '0 0 2 * * ?';
    @TestVisible
    private static final Integer BATCH_SIZE = 200;
    @TestVisible
    private static final String LOG_SOURCE = 'RenewalTaskBatch';

    /** Registers the daily schedule and returns the CronTrigger Id. */
    public static Id scheduleDaily() {
        return System.schedule(JOB_NAME, DAILY_CRON, new RenewalTaskBatch());
    }

    // Schedulable
    public void execute(SchedulableContext context) {
        Database.executeBatch(new RenewalTaskBatch(), BATCH_SIZE);
    }

    // Batchable
    public Database.QueryLocator start(Database.BatchableContext context) {
        Date today = DateProvider.today();
        return ServiceAgreementSelector.queryLocatorRequiringAttention(today, RenewalService.getWindowEnd(today));
    }

    public void execute(Database.BatchableContext context, List<Service_Agreement__c> scope) {
        RenewalTaskService.syncRenewalTasks(scope);
    }

    /**
     * Per-record failures are already logged by RenewalTaskService. Here we
     * only surface chunks that failed entirely (unhandled exceptions), which
     * would otherwise be visible only in Setup > Apex Jobs.
     */
    public void finish(Database.BatchableContext context) {
        AsyncApexJob job = [
            SELECT Id, NumberOfErrors, TotalJobItems
            FROM AsyncApexJob
            WHERE Id = :context.getJobId()
            WITH SYSTEM_MODE
        ];
        logFailedChunks(job.Id, job.NumberOfErrors, job.TotalJobItems);
    }

    @TestVisible
    private static void logFailedChunks(Id jobId, Integer failedChunks, Integer totalChunks) {
        if (failedChunks == null || failedChunks == 0) {
            return;
        }
        ApplicationLogger.error(
            LOG_SOURCE,
            failedChunks + ' of ' + totalChunks + ' batch chunk(s) failed. See Setup > Apex Jobs for details.',
            jobId
        );
        ApplicationLogger.flush();
    }
}
