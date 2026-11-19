/**
 * Tests for the daily renewal sweep. "Time passing" is simulated by inserting
 * agreements with an early reference date (outside the window, so the trigger
 * creates nothing) and then moving DateProvider forward before the job runs.
 */
@IsTest
private class RenewalTaskBatchTest {
    private static final Date REFERENCE_DATE = Date.newInstance(2026, 6, 15);

    @TestSetup
    static void setup() {
        TestDataFactory.createAccount('Acme Corp');
    }

    @IsTest
    static void batch_agreementsEnteringWindowWithoutEdits_getRenewalTasks() {
        pinContext(REFERENCE_DATE.addDays(-60));
        List<Service_Agreement__c> agreements = TestDataFactory.buildAgreements(
            getAccountId(),
            200,
            REFERENCE_DATE.addDays(20)
        );
        insert as system agreements;
        Assert.areEqual(0, countRenewalTasks(), 'Agreements were outside the window when saved');

        pinContext(REFERENCE_DATE);
        Test.startTest();
        Database.executeBatch(new RenewalTaskBatch(), RenewalTaskBatch.BATCH_SIZE);
        Test.stopTest();

        Assert.areEqual(200, countRenewalTasks(), 'Each agreement now in the window must get one Task');
    }

    @IsTest
    static void batch_onlyProcessesQualifyingAgreements() {
        pinContext(REFERENCE_DATE.addDays(-60));
        Id accountId = getAccountId();
        Service_Agreement__c entering = TestDataFactory.buildAgreement(accountId, 'Entering', REFERENCE_DATE.addDays(10));
        Service_Agreement__c stillFar = TestDataFactory.buildAgreement(accountId, 'Still far', REFERENCE_DATE.addDays(45));
        Service_Agreement__c cancelled = TestDataFactory.buildAgreement(accountId, 'Cancelled', REFERENCE_DATE.addDays(10));
        cancelled.Status__c = 'Cancelled';
        insert as system new List<Service_Agreement__c>{ entering, stillFar, cancelled };

        pinContext(REFERENCE_DATE);
        Test.startTest();
        Database.executeBatch(new RenewalTaskBatch());
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM Task WHERE WhatId = :entering.Id WITH SYSTEM_MODE]);
        Assert.areEqual(1, countRenewalTasks(), 'Only the qualifying agreement may get a Task');
    }

    @IsTest
    static void batch_agreementsAlreadyHavingTasks_areNotDuplicated() {
        pinContext(REFERENCE_DATE);
        insert as system TestDataFactory.buildAgreements(getAccountId(), 50, REFERENCE_DATE.addDays(15));
        Assert.areEqual(50, countRenewalTasks(), 'Trigger creates the Tasks on insert');

        Test.startTest();
        Database.executeBatch(new RenewalTaskBatch());
        Test.stopTest();

        Assert.areEqual(50, countRenewalTasks(), 'The sweep must be idempotent');
    }

    // Scheduled jobs and async job history of the org are visible inside
    // tests, so these tests use their own job name and compare counts
    // before/after instead of assuming an empty org.
    private static final String TEST_JOB_NAME = 'Daily Renewal Task Sync (test)';

    @IsTest
    static void scheduleDaily_registersCronJobThatLaunchesTheBatch() {
        Integer batchJobsBefore = countRenewalBatchJobs();

        Test.startTest();
        Id cronId = RenewalTaskBatch.scheduleDaily(TEST_JOB_NAME);
        Test.stopTest();

        CronTrigger cron = [
            SELECT CronExpression, CronJobDetail.Name, NextFireTime
            FROM CronTrigger
            WHERE Id = :cronId
            WITH SYSTEM_MODE
        ];
        Assert.areEqual(RenewalTaskBatch.DAILY_CRON, cron.CronExpression);
        Assert.areEqual(TEST_JOB_NAME, cron.CronJobDetail.Name);
        Assert.isNotNull(cron.NextFireTime);
        Assert.areEqual(
            batchJobsBefore + 1,
            countRenewalBatchJobs(),
            'Running the scheduled job must enqueue the batch'
        );
    }

    @IsTest
    static void scheduleDaily_calledTwice_keepsSingleSchedule() {
        Id firstId = RenewalTaskBatch.scheduleDaily(TEST_JOB_NAME);
        Id secondId = RenewalTaskBatch.scheduleDaily(TEST_JOB_NAME);

        Assert.areEqual(firstId, secondId, 'Re-running the setup must not fail nor duplicate the schedule');
        Assert.areEqual(
            1,
            [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name = :TEST_JOB_NAME WITH SYSTEM_MODE]
        );
    }

    @IsTest
    static void scheduleDaily_defaultName_usesStandardJobName() {
        // Works whether or not the org already has the real schedule (idempotent).
        Id cronId = RenewalTaskBatch.scheduleDaily();

        Assert.areEqual(
            RenewalTaskBatch.JOB_NAME,
            [SELECT CronJobDetail.Name FROM CronTrigger WHERE Id = :cronId WITH SYSTEM_MODE].CronJobDetail.Name
        );
    }

    private static Integer countRenewalBatchJobs() {
        return [
            SELECT COUNT()
            FROM AsyncApexJob
            WHERE JobType = 'BatchApex' AND ApexClass.Name = 'RenewalTaskBatch'
            WITH SYSTEM_MODE
        ];
    }

    @IsTest
    static void logFailedChunks_withFailures_logsError() {
        Id jobId = UserInfo.getUserId(); // any Id: only stored as text on the log

        RenewalTaskBatch.logFailedChunks(jobId, 2, 5);

        Application_Log__c log = [
            SELECT Severity__c, Source__c, Message__c
            FROM Application_Log__c
            WHERE Record_Id__c = :jobId
            WITH SYSTEM_MODE
        ];
        Assert.areEqual(ApplicationLogger.SEVERITY_ERROR, log.Severity__c);
        Assert.areEqual(RenewalTaskBatch.LOG_SOURCE, log.Source__c);
        Assert.isTrue(log.Message__c.startsWith('2 of 5'), log.Message__c);
    }

    @IsTest
    static void logFailedChunks_withoutFailures_logsNothing() {
        RenewalTaskBatch.logFailedChunks(UserInfo.getUserId(), 0, 5);

        Assert.areEqual(0, [SELECT COUNT() FROM Application_Log__c WITH SYSTEM_MODE]);
    }

    private static void pinContext(Date today) {
        DateProvider.todayOverride = today;
        RenewalSettings.settingOverride = new Renewal_Setting__mdt(
            Attention_Window_Days__c = 30,
            Task_Lead_Days__c = 10
        );
    }

    private static Integer countRenewalTasks() {
        return [SELECT COUNT() FROM Task WHERE Renewal_End_Date__c != NULL WITH SYSTEM_MODE];
    }

    private static Id getAccountId() {
        return [SELECT Id FROM Account WHERE Name = 'Acme Corp' LIMIT 1].Id;
    }
}
