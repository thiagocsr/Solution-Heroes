/**
 * Tests for Renewal Task automation, exercised end-to-end through
 * ServiceAgreementTrigger (insert/update DML) unless a unit-level test is
 * the only way to reach a branch.
 *
 * Reference date and settings are pinned so results are deterministic.
 */
@IsTest
private class RenewalTaskServiceTest {
    private static final Date REFERENCE_DATE = Date.newInstance(2026, 6, 15);
    private static final Integer LEAD_DAYS = 10;
    private static final String MANAGER_LAST_NAME = 'AccountManager';

    @TestSetup
    static void setup() {
        TestDataFactory.createAccount('Acme Corp');
        TestDataFactory.createStandardUser(MANAGER_LAST_NAME, TestDataFactory.RENEWAL_PERMISSION_SET);
    }

    // ------------------------------------------------------------------
    // Qualifying / non-qualifying
    // ------------------------------------------------------------------

    @IsTest
    static void insert_qualifyingAgreement_createsRenewalTaskForAccountManager() {
        pinContext(REFERENCE_DATE);
        User manager = getManager();
        Service_Agreement__c agreement = buildAgreement('Support 2026', REFERENCE_DATE.addDays(20));
        agreement.Account_Manager__c = manager.Id;

        Test.startTest();
        insert as system agreement;
        Test.stopTest();

        List<Task> tasks = getRenewalTasks(agreement.Id);
        Assert.areEqual(1, tasks.size(), 'Exactly one Renewal Task expected');
        Task renewalTask = tasks[0];
        Assert.areEqual(manager.Id, renewalTask.OwnerId, 'Task must be assigned to the Account Manager');
        Assert.areEqual(REFERENCE_DATE.addDays(20 - LEAD_DAYS), renewalTask.ActivityDate, 'Due 10 days before End Date');
        Assert.areEqual(agreement.End_Date__c, renewalTask.Renewal_End_Date__c, 'Cycle must be stamped');
        Assert.areEqual(RenewalTaskService.SUBJECT_PREFIX + 'Support 2026', renewalTask.Subject);
        Assert.isFalse(renewalTask.IsClosed, 'New Renewal Task must be open');
    }

    @IsTest
    static void insert_nonQualifyingAgreements_createsNoTasks() {
        pinContext(REFERENCE_DATE);
        Service_Agreement__c draft = buildAgreement('Draft', REFERENCE_DATE.addDays(5));
        draft.Status__c = 'Draft';
        Service_Agreement__c expired = buildAgreement('Expired', REFERENCE_DATE.addDays(5));
        expired.Status__c = 'Expired';
        Service_Agreement__c noRenewal = buildAgreement('No Renewal', REFERENCE_DATE.addDays(5));
        noRenewal.Renewal_Required__c = false;
        Service_Agreement__c outsideWindow = buildAgreement('Day 31', REFERENCE_DATE.addDays(31));
        Service_Agreement__c alreadyEnded = buildAgreement('Ended', REFERENCE_DATE.addDays(-1));

        Test.startTest();
        insert as system new List<Service_Agreement__c>{ draft, expired, noRenewal, outsideWindow, alreadyEnded };
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Task WITH SYSTEM_MODE], 'No agreement qualifies, so no Task may be created');
    }

    @IsTest
    static void update_agreementBecomesQualifying_createsTask() {
        pinContext(REFERENCE_DATE);
        Service_Agreement__c agreement = buildAgreement('Activated later', REFERENCE_DATE.addDays(15));
        agreement.Status__c = 'Draft';
        insert as system agreement;
        Assert.areEqual(0, getRenewalTasks(agreement.Id).size(), 'Draft agreement must not get a Task');

        Test.startTest();
        agreement.Status__c = RenewalService.STATUS_ACTIVE;
        update as system agreement;
        Test.stopTest();

        Assert.areEqual(1, getRenewalTasks(agreement.Id).size(), 'Activating the agreement must create the Task');
    }

    // ------------------------------------------------------------------
    // Duplicate prevention
    // ------------------------------------------------------------------

    @IsTest
    static void update_qualifyingAgreementEditedRepeatedly_doesNotDuplicateTask() {
        pinContext(REFERENCE_DATE);
        Service_Agreement__c agreement = buildAgreement('Edited', REFERENCE_DATE.addDays(15));
        insert as system agreement;

        Test.startTest();
        agreement.Agreement_Value__c = 20000;
        update as system agreement;
        agreement.Agreement_Value__c = 30000;
        update as system agreement;
        Test.stopTest();

        Assert.areEqual(1, getRenewalTasks(agreement.Id).size(), 'Edits must not create additional Tasks');
    }

    @IsTest
    static void update_afterTaskCompletedInSameCycle_doesNotRecreateTask() {
        pinContext(REFERENCE_DATE);
        Service_Agreement__c agreement = buildAgreement('Completed cycle', REFERENCE_DATE.addDays(15));
        insert as system agreement;
        completeTasks(agreement.Id);

        Test.startTest();
        agreement.Agreement_Value__c = 50000;
        update as system agreement;
        Test.stopTest();

        List<Task> tasks = getRenewalTasks(agreement.Id);
        Assert.areEqual(1, tasks.size(), 'A completed Task still covers the current cycle');
        Assert.isTrue(tasks[0].IsClosed);
    }

    @IsTest
    static void update_endDateChangedWhileTaskOpen_reschedulesExistingTask() {
        pinContext(REFERENCE_DATE);
        Service_Agreement__c agreement = buildAgreement('Moved', REFERENCE_DATE.addDays(15));
        insert as system agreement;

        Test.startTest();
        agreement.End_Date__c = REFERENCE_DATE.addDays(25);
        update as system agreement;
        Test.stopTest();

        List<Task> tasks = getRenewalTasks(agreement.Id);
        Assert.areEqual(1, tasks.size(), 'The open Task must be reused, not duplicated');
        Assert.areEqual(REFERENCE_DATE.addDays(25), tasks[0].Renewal_End_Date__c, 'Cycle must follow the new End Date');
        Assert.areEqual(REFERENCE_DATE.addDays(25 - LEAD_DAYS), tasks[0].ActivityDate, 'Due date must be recalculated');
    }

    @IsTest
    static void update_endDateChangedAfterTaskCompleted_startsNewCycle() {
        pinContext(REFERENCE_DATE);
        Service_Agreement__c agreement = buildAgreement('Renewed', REFERENCE_DATE.addDays(5));
        agreement.Renewal_Status__c = RenewalService.RENEWAL_STATUS_IN_PROGRESS;
        insert as system agreement;
        completeTasks(agreement.Id);

        Test.startTest();
        agreement.End_Date__c = REFERENCE_DATE.addDays(28);
        update as system agreement;
        Test.stopTest();

        List<Task> tasks = getRenewalTasks(agreement.Id);
        Assert.areEqual(2, tasks.size(), 'A new cycle must get its own Task');
        Task newTask = tasks[0].IsClosed ? tasks[1] : tasks[0];
        Assert.isFalse(newTask.IsClosed);
        Assert.areEqual(REFERENCE_DATE.addDays(28), newTask.Renewal_End_Date__c);

        Service_Agreement__c reloaded = [SELECT Renewal_Status__c FROM Service_Agreement__c WHERE Id = :agreement.Id WITH SYSTEM_MODE];
        Assert.areEqual(
            RenewalService.RENEWAL_STATUS_NOT_STARTED,
            reloaded.Renewal_Status__c,
            'Renewal Status must reset when a new cycle starts'
        );
    }

    @IsTest
    static void update_agreementWithUnrelatedTask_stillCreatesRenewalTask() {
        pinContext(REFERENCE_DATE);
        Service_Agreement__c agreement = buildAgreement('Has other tasks', REFERENCE_DATE.addDays(90));
        insert as system agreement;
        insert as system new Task(WhatId = agreement.Id, Subject = 'Call customer', OwnerId = UserInfo.getUserId());

        Test.startTest();
        agreement.End_Date__c = REFERENCE_DATE.addDays(10);
        update as system agreement;
        Test.stopTest();

        Assert.areEqual(1, getRenewalTasks(agreement.Id).size(), 'Manual Tasks must not count as Renewal Tasks');
        Assert.areEqual(2, [SELECT COUNT() FROM Task WHERE WhatId = :agreement.Id WITH SYSTEM_MODE]);
    }

    // ------------------------------------------------------------------
    // Bulk
    // ------------------------------------------------------------------

    @IsTest
    static void bulkInsert_200QualifyingAgreements_createsOneTaskEachWithConstantQueries() {
        pinContext(REFERENCE_DATE);
        List<Service_Agreement__c> agreements = TestDataFactory.buildAgreements(
            getAccountId(),
            200,
            REFERENCE_DATE.addDays(20)
        );

        Test.startTest();
        insert as system agreements;
        Integer queriesUsed = Limits.getQueries();
        Test.stopTest();

        Assert.areEqual(200, [SELECT COUNT() FROM Task WHERE Renewal_End_Date__c != NULL WITH SYSTEM_MODE]);
        Assert.areEqual(
            200,
            [SELECT COUNT_DISTINCT(WhatId) total FROM Task WITH SYSTEM_MODE].get(0).get('total'),
            'Each agreement must get exactly one Task'
        );
        Assert.isTrue(queriesUsed <= 2, 'Query count must not grow with volume; used ' + queriesUsed);
    }

    @IsTest
    static void bulkUpdate_200Agreements_doesNotDuplicateTasks() {
        pinContext(REFERENCE_DATE);
        List<Service_Agreement__c> agreements = TestDataFactory.buildAgreements(
            getAccountId(),
            200,
            REFERENCE_DATE.addDays(20)
        );
        insert as system agreements;

        Test.startTest();
        for (Service_Agreement__c agreement : agreements) {
            agreement.Agreement_Value__c = 99999;
        }
        update as system agreements;
        Test.stopTest();

        Assert.areEqual(200, [SELECT COUNT() FROM Task WITH SYSTEM_MODE], 'Bulk edit must not create duplicate Tasks');
    }

    @IsTest
    static void bulkInsert_mixedAgreements_createsTasksOnlyForQualifying() {
        pinContext(REFERENCE_DATE);
        Id accountId = getAccountId();
        List<Service_Agreement__c> qualifying = TestDataFactory.buildAgreements(accountId, 100, REFERENCE_DATE.addDays(10));
        List<Service_Agreement__c> notQualifying = TestDataFactory.buildAgreements(accountId, 100, REFERENCE_DATE.addDays(60));
        List<Service_Agreement__c> all = new List<Service_Agreement__c>(qualifying);
        all.addAll(notQualifying);

        Test.startTest();
        insert as system all;
        Test.stopTest();

        Assert.areEqual(100, [SELECT COUNT() FROM Task WHERE WhatId IN :qualifying WITH SYSTEM_MODE]);
        Assert.areEqual(0, [SELECT COUNT() FROM Task WHERE WhatId IN :notQualifying WITH SYSTEM_MODE]);
    }

    // ------------------------------------------------------------------
    // Assignee resolution
    // ------------------------------------------------------------------

    @IsTest
    static void insert_withoutAccountManager_assignsOwnerAndLogsWarning() {
        pinContext(REFERENCE_DATE);
        Service_Agreement__c agreement = buildAgreement('No manager', REFERENCE_DATE.addDays(10));
        agreement.Account_Manager__c = null;

        Test.startTest();
        insert as system agreement;
        Test.stopTest();

        List<Task> tasks = getRenewalTasks(agreement.Id);
        Assert.areEqual(1, tasks.size());
        Assert.areEqual(UserInfo.getUserId(), tasks[0].OwnerId, 'Owner is the fallback assignee');
        assertLogged(ApplicationLogger.SEVERITY_WARNING, agreement.Id);
    }

    @IsTest
    static void insert_withInactiveAccountManager_assignsOwner() {
        pinContext(REFERENCE_DATE);
        User manager = getManager();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            manager.IsActive = false;
            update as system manager;
        }
        Service_Agreement__c agreement = buildAgreement('Inactive manager', REFERENCE_DATE.addDays(10));
        agreement.Account_Manager__c = manager.Id;

        Test.startTest();
        insert as system agreement;
        Test.stopTest();

        List<Task> tasks = getRenewalTasks(agreement.Id);
        Assert.areEqual(1, tasks.size());
        Assert.areEqual(UserInfo.getUserId(), tasks[0].OwnerId, 'Inactive manager must fall back to the Owner');
    }

    @IsTest
    static void sync_noActiveAssignee_skipsAgreementAndLogsError() {
        // Queue ownership/inactive owners cannot be produced through DML in a
        // test, so the service is invoked directly with an in-memory owner.
        pinContext(REFERENCE_DATE);
        Service_Agreement__c agreement = buildAgreement('Unassignable', REFERENCE_DATE.addDays(90));
        insert as system agreement;
        agreement.End_Date__c = REFERENCE_DATE.addDays(10);
        agreement.Account_Manager__c = null;
        agreement.OwnerId = fakeId(Group.SObjectType);

        Test.startTest();
        RenewalTaskService.syncRenewalTasks(new List<Service_Agreement__c>{ agreement });
        Test.stopTest();

        Assert.areEqual(0, getRenewalTasks(agreement.Id).size(), 'No Task without an active assignee');
        assertLogged(ApplicationLogger.SEVERITY_ERROR, agreement.Id);
    }

    @IsTest
    static void resolveAssignee_prefersActiveManagerThenOwner() {
        Id managerId = fakeId(User.SObjectType);
        Id ownerId = UserInfo.getUserId();
        Service_Agreement__c agreement = new Service_Agreement__c(Account_Manager__c = managerId, OwnerId = ownerId);

        Assert.areEqual(managerId, RenewalTaskService.resolveAssignee(agreement, new Set<Id>{ managerId, ownerId }));
        Assert.areEqual(ownerId, RenewalTaskService.resolveAssignee(agreement, new Set<Id>{ ownerId }));
        Assert.isNull(RenewalTaskService.resolveAssignee(agreement, new Set<Id>()));
    }

    // ------------------------------------------------------------------
    // Due date calculation (calendar boundaries)
    // ------------------------------------------------------------------

    @IsTest
    static void calculateDueDate_acrossCalendarBoundaries() {
        pinContext(REFERENCE_DATE);

        Assert.areEqual(Date.newInstance(2026, 6, 25), RenewalTaskService.calculateDueDate(Date.newInstance(2026, 7, 5)), 'Month boundary');
        Assert.areEqual(Date.newInstance(2026, 12, 26), RenewalTaskService.calculateDueDate(Date.newInstance(2027, 1, 5)), 'Year boundary');
        Assert.areEqual(Date.newInstance(2028, 2, 24), RenewalTaskService.calculateDueDate(Date.newInstance(2028, 3, 5)), 'Leap year: Feb 29 counted');
        Assert.areEqual(Date.newInstance(2027, 2, 23), RenewalTaskService.calculateDueDate(Date.newInstance(2027, 3, 5)), 'Non-leap year');
        Assert.areEqual(Date.newInstance(2028, 2, 29), RenewalTaskService.calculateDueDate(Date.newInstance(2028, 3, 10)), 'Due on leap day');
    }

    @IsTest
    static void insert_agreementEndingAcrossLeapDay_setsCorrectDueDate() {
        pinContext(Date.newInstance(2028, 2, 15));
        Service_Agreement__c agreement = buildAgreement('Leap', Date.newInstance(2028, 3, 5));

        Test.startTest();
        insert as system agreement;
        Test.stopTest();

        Assert.areEqual(Date.newInstance(2028, 2, 24), getRenewalTasks(agreement.Id)[0].ActivityDate);
    }

    @IsTest
    static void insert_agreementEndingWithinLeadTime_createsOverdueTask() {
        pinContext(REFERENCE_DATE);
        Service_Agreement__c agreement = buildAgreement('Ends soon', REFERENCE_DATE.addDays(5));

        Test.startTest();
        insert as system agreement;
        Test.stopTest();

        Assert.areEqual(
            REFERENCE_DATE.addDays(-5),
            getRenewalTasks(agreement.Id)[0].ActivityDate,
            'Rule is applied literally: due date may be in the past (overdue)'
        );
    }

    @IsTest
    static void insert_customLeadTimeFromSettings_isHonoured() {
        DateProvider.todayOverride = REFERENCE_DATE;
        RenewalSettings.settingOverride = new Renewal_Setting__mdt(Attention_Window_Days__c = 30, Task_Lead_Days__c = 7);
        Service_Agreement__c agreement = buildAgreement('Custom lead', REFERENCE_DATE.addDays(20));

        Test.startTest();
        insert as system agreement;
        Test.stopTest();

        Assert.areEqual(REFERENCE_DATE.addDays(13), getRenewalTasks(agreement.Id)[0].ActivityDate);
    }

    // ------------------------------------------------------------------
    // Task completion -> agreement Renewal Status (TaskTrigger)
    // ------------------------------------------------------------------

    @IsTest
    static void completeTask_currentCycle_marksAgreementCompleted() {
        pinContext(REFERENCE_DATE);
        Service_Agreement__c agreement = buildAgreement('Finish', REFERENCE_DATE.addDays(15));
        agreement.Renewal_Status__c = RenewalService.RENEWAL_STATUS_IN_PROGRESS;
        insert as system agreement;

        Test.startTest();
        completeTasks(agreement.Id);
        Test.stopTest();

        Assert.areEqual(RenewalService.RENEWAL_STATUS_COMPLETED, getRenewalStatus(agreement.Id));
    }

    @IsTest
    static void completeTask_renewalNeverStarted_stillMarksAgreementCompleted() {
        // The manager may finish the work without clicking Start Renewal first.
        pinContext(REFERENCE_DATE);
        Service_Agreement__c agreement = buildAgreement('Direct finish', REFERENCE_DATE.addDays(15));
        insert as system agreement;

        Test.startTest();
        completeTasks(agreement.Id);
        Test.stopTest();

        Assert.areEqual(RenewalService.RENEWAL_STATUS_COMPLETED, getRenewalStatus(agreement.Id));
    }

    @IsTest
    static void reopenTask_currentCycle_movesAgreementBackToInProgress() {
        pinContext(REFERENCE_DATE);
        Service_Agreement__c agreement = buildAgreement('Reopened', REFERENCE_DATE.addDays(15));
        insert as system agreement;
        completeTasks(agreement.Id);

        Test.startTest();
        Task renewalTask = getRenewalTasks(agreement.Id)[0];
        renewalTask.Status = RenewalTaskService.TASK_STATUS_IN_PROGRESS;
        update as system renewalTask;
        Test.stopTest();

        Assert.areEqual(RenewalService.RENEWAL_STATUS_IN_PROGRESS, getRenewalStatus(agreement.Id));
    }

    @IsTest
    static void taskUpdateWithoutStatusChange_leavesAgreementUntouched() {
        pinContext(REFERENCE_DATE);
        Service_Agreement__c agreement = buildAgreement('Untouched', REFERENCE_DATE.addDays(15));
        insert as system agreement;

        Test.startTest();
        Task renewalTask = getRenewalTasks(agreement.Id)[0];
        renewalTask.Subject = 'Renamed by the manager';
        update as system renewalTask;
        Test.stopTest();

        Assert.areEqual(RenewalService.RENEWAL_STATUS_NOT_STARTED, getRenewalStatus(agreement.Id));
    }

    @IsTest
    static void completeTask_previousCycle_doesNotChangeCurrentCycle() {
        pinContext(REFERENCE_DATE);
        Service_Agreement__c agreement = buildAgreement('Two cycles', REFERENCE_DATE.addDays(5));
        insert as system agreement;
        completeTasks(agreement.Id); // cycle 1 done -> Completed
        agreement.End_Date__c = REFERENCE_DATE.addDays(28);
        update as system agreement; // cycle 2: new Task, status reset to Not Started
        Task previousCycleTask = [
            SELECT Id
            FROM Task
            WHERE WhatId = :agreement.Id AND Renewal_End_Date__c = :REFERENCE_DATE.addDays(5)
            WITH SYSTEM_MODE
        ];

        Test.startTest();
        previousCycleTask.Status = RenewalTaskService.TASK_STATUS_IN_PROGRESS; // reopen old cycle
        update as system previousCycleTask;
        previousCycleTask.Status = 'Completed'; // and close it again
        update as system previousCycleTask;
        Test.stopTest();

        Assert.areEqual(
            RenewalService.RENEWAL_STATUS_NOT_STARTED,
            getRenewalStatus(agreement.Id),
            'Tasks of a previous cycle must not drive the current renewal status'
        );
    }

    @IsTest
    static void completeTask_nonRenewalTask_leavesAgreementUntouched() {
        pinContext(REFERENCE_DATE);
        Service_Agreement__c agreement = buildAgreement('Manual task', REFERENCE_DATE.addDays(90));
        insert as system agreement;
        Task manualTask = new Task(WhatId = agreement.Id, Subject = 'Call customer', OwnerId = UserInfo.getUserId());
        insert as system manualTask;

        Test.startTest();
        manualTask.Status = 'Completed';
        update as system manualTask;
        Test.stopTest();

        Assert.areEqual(RenewalService.RENEWAL_STATUS_NOT_STARTED, getRenewalStatus(agreement.Id));
    }

    @IsTest
    static void bulkCompleteTasks_200Agreements_allMarkedCompletedWithConstantQueries() {
        pinContext(REFERENCE_DATE);
        List<Service_Agreement__c> agreements = TestDataFactory.buildAgreements(
            getAccountId(),
            200,
            REFERENCE_DATE.addDays(20)
        );
        insert as system agreements;
        List<Task> tasks = [SELECT Id FROM Task WHERE Renewal_End_Date__c != NULL WITH SYSTEM_MODE];
        for (Task renewalTask : tasks) {
            renewalTask.Status = 'Completed';
        }

        Test.startTest();
        update as system tasks;
        Integer queriesUsed = Limits.getQueries();
        Test.stopTest();

        Assert.areEqual(
            200,
            [
                SELECT COUNT()
                FROM Service_Agreement__c
                WHERE Renewal_Status__c = :RenewalService.RENEWAL_STATUS_COMPLETED
                WITH SYSTEM_MODE
            ]
        );
        // 1 query to read the agreements + 2 from the re-entrant agreement trigger (idempotent pass).
        Assert.isTrue(queriesUsed <= 3, 'Query count must not grow with volume; used ' + queriesUsed);
    }

    @IsTest
    static void update_newCycleAfterCompletedRenewal_resetsStatus() {
        pinContext(REFERENCE_DATE);
        Service_Agreement__c agreement = buildAgreement('Completed then renewed', REFERENCE_DATE.addDays(5));
        insert as system agreement;
        completeTasks(agreement.Id);
        Assert.areEqual(RenewalService.RENEWAL_STATUS_COMPLETED, getRenewalStatus(agreement.Id));

        Test.startTest();
        agreement.End_Date__c = REFERENCE_DATE.addDays(28);
        update as system agreement;
        Test.stopTest();

        Assert.areEqual(RenewalService.RENEWAL_STATUS_NOT_STARTED, getRenewalStatus(agreement.Id));
        Assert.areEqual(2, getRenewalTasks(agreement.Id).size(), 'New cycle gets its own Task');
    }

    // ------------------------------------------------------------------
    // Error handling
    // ------------------------------------------------------------------

    @IsTest
    static void processSaveResults_failedDml_logsErrorAndReportsOnlySuccesses() {
        Id accountId = getAccountId();
        // An Account Id is not a valid Task owner: produces a genuine DML failure.
        List<Database.SaveResult> results = Database.insert(
            new List<Task>{ new Task(Subject = 'Invalid owner', OwnerId = accountId) },
            false,
            AccessLevel.SYSTEM_MODE
        );

        Test.startTest();
        Set<Id> succeeded = RenewalTaskService.processSaveResults(results, new List<Id>{ accountId }, 'Test operation');
        ApplicationLogger.flush();
        Test.stopTest();

        Assert.isTrue(succeeded.isEmpty());
        Application_Log__c log = [SELECT Severity__c, Source__c, Message__c FROM Application_Log__c WHERE Record_Id__c = :accountId WITH SYSTEM_MODE];
        Assert.areEqual(ApplicationLogger.SEVERITY_ERROR, log.Severity__c);
        Assert.areEqual(RenewalTaskService.LOG_SOURCE, log.Source__c);
        Assert.isTrue(log.Message__c.startsWith('Test operation failed:'), log.Message__c);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    private static void pinContext(Date today) {
        DateProvider.todayOverride = today;
        RenewalSettings.settingOverride = new Renewal_Setting__mdt(
            Attention_Window_Days__c = 30,
            Task_Lead_Days__c = LEAD_DAYS
        );
    }

    private static Service_Agreement__c buildAgreement(String name, Date endDate) {
        return TestDataFactory.buildAgreement(getAccountId(), name, endDate);
    }

    private static List<Task> getRenewalTasks(Id agreementId) {
        return [
            SELECT Id, OwnerId, Subject, ActivityDate, Renewal_End_Date__c, IsClosed
            FROM Task
            WHERE WhatId = :agreementId AND Renewal_End_Date__c != NULL WITH SYSTEM_MODE
        ];
    }

    private static void completeTasks(Id agreementId) {
        List<Task> tasks = getRenewalTasks(agreementId);
        for (Task renewalTask : tasks) {
            renewalTask.Status = 'Completed';
        }
        update as system tasks;
    }

    private static String getRenewalStatus(Id agreementId) {
        return [SELECT Renewal_Status__c FROM Service_Agreement__c WHERE Id = :agreementId WITH SYSTEM_MODE]
        .Renewal_Status__c;
    }

    private static void assertLogged(String severity, Id recordId) {
        Assert.areEqual(
            1,
            [SELECT COUNT() FROM Application_Log__c WHERE Severity__c = :severity AND Record_Id__c = :recordId WITH SYSTEM_MODE],
            'Expected one ' + severity + ' log for ' + recordId
        );
    }

    private static Id getAccountId() {
        return [SELECT Id FROM Account WHERE Name = 'Acme Corp' LIMIT 1].Id;
    }

    private static User getManager() {
        return [SELECT Id, IsActive FROM User WHERE LastName = :MANAGER_LAST_NAME LIMIT 1];
    }

    private static Id fakeId(Schema.SObjectType sObjectType) {
        return Id.valueOf(sObjectType.getDescribe().getKeyPrefix() + '000000000001');
    }
}
