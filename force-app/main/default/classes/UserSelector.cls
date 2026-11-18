/**
 * Data access for User records needed by the renewal automation.
 */
public inherited sharing class UserSelector {
    /**
     * Returns the subset of the given Ids that belong to active users.
     * Non-user Ids (e.g. queues) are naturally excluded.
     */
    public static Set<Id> selectActiveUserIds(Set<Id> candidateIds) {
        return new Map<Id, User>(
                [SELECT Id FROM User WHERE Id IN :candidateIds AND IsActive = TRUE WITH SYSTEM_MODE]
            )
            .keySet();
    }
}
