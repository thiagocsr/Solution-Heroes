/**
 * Data access for Renewal Tasks: Tasks related to a Service Agreement and
 * stamped with Renewal_End_Date__c by the renewal automation.
 */
public inherited sharing class RenewalTaskSelector {
    /**
     * All Renewal Tasks (open and closed) for the given agreements.
     *
     * Runs WITH SYSTEM_MODE on purpose: duplicate prevention must see every
     * Renewal Task, including those owned by other users and not visible to
     * the user who edited the agreement. These records are used internally
     * and never returned to the UI.
     */
    public static List<Task> selectByAgreementIds(Set<Id> agreementIds) {
        return [
            SELECT Id, WhatId, OwnerId, Status, ActivityDate, Renewal_End_Date__c, IsClosed
            FROM Task
            WHERE WhatId IN :agreementIds AND Renewal_End_Date__c != NULL
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC
        ];
    }
}
