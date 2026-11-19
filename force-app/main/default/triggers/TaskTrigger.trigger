/**
 * Single trigger for Task. All logic is delegated to TaskTriggerHandler.
 */
trigger TaskTrigger on Task(after update) {
    TaskTriggerHandler.handle(Trigger.operationType, Trigger.new, Trigger.oldMap);
}
