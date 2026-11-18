/**
 * Routes Service_Agreement__c trigger events to the domain services.
 * Contains no business logic: it only decides which service runs for which
 * event, so new behaviour can be added without touching the trigger.
 *
 * No recursion guard is needed: RenewalTaskService is idempotent (a second
 * pass over the same agreement finds the Task of the current cycle and does
 * nothing), which is safer than a static flag that would also suppress
 * legitimate re-evaluation of records updated later in the same transaction.
 *
 * No catch-all try/catch: expected per-record failures are handled with
 * partial-success DML inside the service; an unexpected exception is a defect
 * and should roll back the save rather than leave data inconsistent.
 */
public with sharing class ServiceAgreementTriggerHandler {
    public static void handle(System.TriggerOperation operation, List<Service_Agreement__c> newRecords) {
        switch on operation {
            when AFTER_INSERT, AFTER_UPDATE {
                // After context: Renewal Tasks need the agreement Id (WhatId).
                RenewalTaskService.syncRenewalTasks(newRecords);
            }
        }
    }
}
