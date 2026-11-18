/**
 * Creates and maintains Renewal Tasks for Service Agreements that require
 * renewal attention (see RenewalService for the criteria).
 *
 * Rules
 *   - One Renewal Task per agreement per renewal cycle. The cycle is
 *     identified by the agreement End Date, stamped on the Task as
 *     Renewal_End_Date__c.
 *   - A Task already exists for the current End Date (open or completed):
 *     nothing to do. This is what makes repeated edits idempotent.
 *   - An open Task exists for a different End Date (End Date was changed
 *     while renewal work is pending): the existing Task is re-aligned to the
 *     new End Date instead of creating a second one.
 *   - Otherwise a new Task is created, due Task_Lead_Days__c (10) calendar
 *     days before the End Date, assigned to the Account Manager, or to the
 *     agreement Owner when the Account Manager is blank or inactive.
 *   - When a new cycle starts for an agreement whose renewal was In Progress
 *     in a previous cycle, its Renewal Status is reset to Not Started.
 *
 * Bulk behaviour: a fixed number of queries (2) and at most 4 DML statements
 * (create, re-align, status reset, log write) per invocation, regardless of
 * how many agreements are processed.
 *
 * Error handling: partial-success DML. A record that cannot be processed is
 * logged to Application_Log__c and does not block the save of the agreement
 * or the processing of the other records.
 *
 * without sharing: this is system automation. Duplicate prevention must see
 * every Renewal Task, and the Task must be created even if the user editing
 * the agreement cannot see the Account Manager's activities. Nothing in this
 * class returns data to a user.
 */
public without sharing class RenewalTaskService {
    @TestVisible
    private static final String LOG_SOURCE = 'RenewalTaskService';
    @TestVisible
    private static final String SUBJECT_PREFIX = 'Renewal: ';
    @TestVisible
    private static final String TASK_STATUS_IN_PROGRESS = 'In Progress';
    private static final Integer SUBJECT_MAX_LENGTH = Task.Subject.getDescribe().getLength();

    public static void syncRenewalTasks(List<Service_Agreement__c> agreements) {
        List<Service_Agreement__c> candidates = RenewalService.filterRequiringAttention(
            agreements,
            DateProvider.today()
        );
        if (candidates.isEmpty()) {
            return;
        }

        Map<Id, List<Task>> renewalTasksByAgreement = getRenewalTasksByAgreement(candidates);
        Set<Id> activeUserIds = UserSelector.selectActiveUserIds(collectPossibleAssignees(candidates));

        List<Task> tasksToCreate = new List<Task>();
        List<Task> tasksToReschedule = new List<Task>();
        Set<Id> agreementsStartingNewCycle = new Set<Id>();

        for (Service_Agreement__c agreement : candidates) {
            List<Task> existingTasks = renewalTasksByAgreement.containsKey(agreement.Id)
                ? renewalTasksByAgreement.get(agreement.Id)
                : new List<Task>();

            if (hasTaskForCycle(existingTasks, agreement.End_Date__c)) {
                continue;
            }

            Task openTask = findOpenTask(existingTasks);
            if (openTask != null) {
                tasksToReschedule.add(
                    new Task(
                        Id = openTask.Id,
                        WhatId = agreement.Id,
                        ActivityDate = calculateDueDate(agreement.End_Date__c),
                        Renewal_End_Date__c = agreement.End_Date__c
                    )
                );
                continue;
            }

            Id assigneeId = resolveAssignee(agreement, activeUserIds);
            if (assigneeId == null) {
                ApplicationLogger.error(
                    LOG_SOURCE,
                    'Renewal Task not created: neither the Account Manager nor the Owner is an active user.',
                    agreement.Id
                );
                continue;
            }
            if (assigneeId != agreement.Account_Manager__c) {
                ApplicationLogger.warning(
                    LOG_SOURCE,
                    'Account Manager is blank or inactive; Renewal Task assigned to the agreement Owner.',
                    agreement.Id
                );
            }

            tasksToCreate.add(buildTask(agreement, assigneeId));
            if (!existingTasks.isEmpty() && agreement.Renewal_Status__c == RenewalService.RENEWAL_STATUS_IN_PROGRESS) {
                agreementsStartingNewCycle.add(agreement.Id);
            }
        }

        Set<Id> agreementsWithNewTask = insertTasks(tasksToCreate);
        updateTasks(tasksToReschedule, 'Renewal Task reschedule');
        agreementsStartingNewCycle.retainAll(agreementsWithNewTask);
        resetRenewalStatus(agreementsStartingNewCycle);

        ApplicationLogger.flush();
    }

    /**
     * Moves the open Renewal Tasks of the given agreements to In Progress.
     * Closed Tasks and Tasks already In Progress are left untouched. Failures
     * are logged and do not undo the agreement status change: the agreement
     * Renewal Status is the source of truth shown in the UI.
     */
    public static void markRenewalTasksInProgress(Set<Id> agreementIds) {
        List<Task> tasksToStart = new List<Task>();
        for (Task renewalTask : RenewalTaskSelector.selectByAgreementIds(agreementIds)) {
            if (!renewalTask.IsClosed && renewalTask.Status != TASK_STATUS_IN_PROGRESS) {
                tasksToStart.add(new Task(Id = renewalTask.Id, WhatId = renewalTask.WhatId, Status = TASK_STATUS_IN_PROGRESS));
            }
        }
        updateTasks(tasksToStart, 'Renewal Task start');
        ApplicationLogger.flush();
    }

    /**
     * Renewal Task due date: Task_Lead_Days__c calendar days before the End
     * Date. Date.addDays() handles month ends, year ends and February 29th.
     * If the agreement ends sooner than the lead time, the due date falls in
     * the past by design, flagging the Task as overdue (documented assumption).
     */
    public static Date calculateDueDate(Date endDate) {
        return endDate.addDays(-RenewalSettings.taskLeadDays());
    }

    /**
     * Account Manager when active; otherwise the agreement Owner when it is an
     * active user; otherwise null (e.g. Owner is a queue or inactive).
     */
    @TestVisible
    private static Id resolveAssignee(Service_Agreement__c agreement, Set<Id> activeUserIds) {
        if (agreement.Account_Manager__c != null && activeUserIds.contains(agreement.Account_Manager__c)) {
            return agreement.Account_Manager__c;
        }
        if (agreement.OwnerId != null && activeUserIds.contains(agreement.OwnerId)) {
            return agreement.OwnerId;
        }
        return null;
    }

    /**
     * Logs failed results and returns the related record Ids that succeeded.
     * relatedRecordIds must be index-aligned with results.
     */
    @TestVisible
    private static Set<Id> processSaveResults(
        List<Database.SaveResult> results,
        List<Id> relatedRecordIds,
        String operation
    ) {
        Set<Id> succeeded = new Set<Id>();
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                succeeded.add(relatedRecordIds[i]);
            } else {
                ApplicationLogger.error(
                    LOG_SOURCE,
                    operation + ' failed: ' + formatErrors(results[i].getErrors()),
                    relatedRecordIds[i]
                );
            }
        }
        return succeeded;
    }

    private static Map<Id, List<Task>> getRenewalTasksByAgreement(List<Service_Agreement__c> agreements) {
        Map<Id, List<Task>> tasksByAgreement = new Map<Id, List<Task>>();
        for (Task renewalTask : RenewalTaskSelector.selectByAgreementIds(new Map<Id, Service_Agreement__c>(agreements).keySet())) {
            if (!tasksByAgreement.containsKey(renewalTask.WhatId)) {
                tasksByAgreement.put(renewalTask.WhatId, new List<Task>());
            }
            tasksByAgreement.get(renewalTask.WhatId).add(renewalTask);
        }
        return tasksByAgreement;
    }

    private static Set<Id> collectPossibleAssignees(List<Service_Agreement__c> agreements) {
        Set<Id> userIds = new Set<Id>();
        for (Service_Agreement__c agreement : agreements) {
            if (agreement.Account_Manager__c != null) {
                userIds.add(agreement.Account_Manager__c);
            }
            if (agreement.OwnerId != null) {
                userIds.add(agreement.OwnerId);
            }
        }
        return userIds;
    }

    private static Boolean hasTaskForCycle(List<Task> renewalTasks, Date endDate) {
        for (Task renewalTask : renewalTasks) {
            if (renewalTask.Renewal_End_Date__c == endDate) {
                return true;
            }
        }
        return false;
    }

    /** Most recent open Renewal Task (the selector orders by CreatedDate DESC). */
    private static Task findOpenTask(List<Task> renewalTasks) {
        for (Task renewalTask : renewalTasks) {
            if (!renewalTask.IsClosed) {
                return renewalTask;
            }
        }
        return null;
    }

    private static Task buildTask(Service_Agreement__c agreement, Id assigneeId) {
        return new Task(
            WhatId = agreement.Id,
            OwnerId = assigneeId,
            Subject = (SUBJECT_PREFIX + agreement.Name).left(SUBJECT_MAX_LENGTH),
            ActivityDate = calculateDueDate(agreement.End_Date__c),
            Renewal_End_Date__c = agreement.End_Date__c,
            Description = 'Service Agreement "' +
                agreement.Name +
                '" ends on ' +
                agreement.End_Date__c.format() +
                '. Start the renewal process with the customer.'
        );
    }

    private static Set<Id> insertTasks(List<Task> tasks) {
        if (tasks.isEmpty()) {
            return new Set<Id>();
        }
        Database.DMLOptions options = new Database.DMLOptions();
        options.OptAllOrNone = false;
        // Sends the standard "new task assigned" email to the assignee.
        options.EmailHeader.triggerUserEmail = true;

        List<Database.SaveResult> results = Database.insert(tasks, options, AccessLevel.SYSTEM_MODE);
        return processSaveResults(results, collectWhatIds(tasks), 'Renewal Task creation');
    }

    private static void updateTasks(List<Task> tasks, String operation) {
        if (tasks.isEmpty()) {
            return;
        }
        List<Database.SaveResult> results = Database.update(tasks, false, AccessLevel.SYSTEM_MODE);
        processSaveResults(results, collectWhatIds(tasks), operation);
    }

    private static void resetRenewalStatus(Set<Id> agreementIds) {
        if (agreementIds.isEmpty()) {
            return;
        }
        List<Id> orderedIds = new List<Id>(agreementIds);
        List<Service_Agreement__c> agreements = new List<Service_Agreement__c>();
        for (Id agreementId : orderedIds) {
            agreements.add(
                new Service_Agreement__c(Id = agreementId, Renewal_Status__c = RenewalService.RENEWAL_STATUS_NOT_STARTED)
            );
        }
        List<Database.SaveResult> results = Database.update(agreements, false, AccessLevel.SYSTEM_MODE);
        processSaveResults(results, orderedIds, 'Renewal Status reset');
    }

    private static List<Id> collectWhatIds(List<Task> tasks) {
        List<Id> whatIds = new List<Id>();
        for (Task renewalTask : tasks) {
            whatIds.add(renewalTask.WhatId);
        }
        return whatIds;
    }

    private static String formatErrors(List<Database.Error> errors) {
        List<String> messages = new List<String>();
        for (Database.Error error : errors) {
            messages.add(error.getStatusCode() + ': ' + error.getMessage());
        }
        return String.join(messages, '; ');
    }
}
