/**
 * Routes Task trigger events to the renewal domain.
 *
 * Task triggers fire for every Task in the org, so the service filters to
 * Renewal Tasks whose open/closed state changed before doing any query.
 */
public with sharing class TaskTriggerHandler {
    public static void handle(
        System.TriggerOperation operation,
        List<Task> newRecords,
        Map<Id, Task> oldRecordsById
    ) {
        switch on operation {
            when AFTER_UPDATE {
                // After context: IsClosed reflects the saved Status.
                RenewalTaskService.syncRenewalStatusFromTasks(newRecords, oldRecordsById);
            }
        }
    }
}
