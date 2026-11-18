/**
 * Single trigger for Service_Agreement__c. All logic is delegated to
 * ServiceAgreementTriggerHandler.
 */
trigger ServiceAgreementTrigger on Service_Agreement__c(after insert, after update) {
    ServiceAgreementTriggerHandler.handle(Trigger.operationType, Trigger.new);
}
