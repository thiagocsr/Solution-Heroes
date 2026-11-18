/**
 * Data access for Service_Agreement__c. All SOQL for the object lives here so
 * field lists, ordering and security mode are defined in one place.
 *
 * inherited sharing: the sharing context is decided by the caller (the
 * service/controller layer), not by the data access layer.
 */
public inherited sharing class ServiceAgreementSelector {
    /**
     * Safety cap for interactive queries. A 30-day window is not expected to
     * approach this; if it ever does, the UI should move to server-side
     * pagination rather than raising the cap.
     */
    @TestVisible
    private static final Integer MAX_ROWS = 2000;

    /**
     * Active, renewal-required agreements whose End Date falls between the
     * two dates (both inclusive), soonest first.
     *
     * Runs WITH USER_MODE: object permissions, field-level security and
     * sharing of the running user are enforced, so the result is safe to
     * return to the UI.
     */
    public static List<Service_Agreement__c> selectRequiringAttention(Date windowStart, Date windowEnd) {
        String activeStatus = RenewalService.STATUS_ACTIVE;
        Integer maxRows = MAX_ROWS;

        return [
            SELECT
                Id,
                Name,
                Status__c,
                Renewal_Required__c,
                Start_Date__c,
                End_Date__c,
                Agreement_Value__c,
                Renewal_Status__c,
                Account__c,
                Account__r.Name,
                Account_Manager__c,
                Account_Manager__r.Name
            FROM Service_Agreement__c
            WHERE
                Status__c = :activeStatus
                AND Renewal_Required__c = TRUE
                AND End_Date__c >= :windowStart
                AND End_Date__c <= :windowEnd
            WITH USER_MODE
            ORDER BY End_Date__c ASC, Name ASC
            LIMIT :maxRows
        ];
    }

    /**
     * Query locator for the daily renewal batch: same criteria as
     * selectRequiringAttention, with the fields RenewalTaskService needs.
     *
     * Runs WITH SYSTEM_MODE: the scheduled job is system automation and must
     * process every qualifying agreement, regardless of the sharing and
     * permissions of the user who scheduled it. No data reaches a UI.
     */
    public static Database.QueryLocator queryLocatorRequiringAttention(Date windowStart, Date windowEnd) {
        String activeStatus = RenewalService.STATUS_ACTIVE;

        return Database.getQueryLocator(
            [
                SELECT
                    Id,
                    Name,
                    OwnerId,
                    Status__c,
                    Renewal_Required__c,
                    End_Date__c,
                    Renewal_Status__c,
                    Account_Manager__c
                FROM Service_Agreement__c
                WHERE
                    Status__c = :activeStatus
                    AND Renewal_Required__c = TRUE
                    AND End_Date__c >= :windowStart
                    AND End_Date__c <= :windowEnd
                WITH SYSTEM_MODE
            ]
        );
    }
}
