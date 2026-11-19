/**
 * Business rules for identifying Service Agreements that require renewal
 * attention.
 *
 * An agreement requires attention when:
 *   - Status = Active
 *   - Renewal Required = true
 *   - End Date is between today and today + window (both inclusive),
 *     where window = Renewal_Setting__mdt.Attention_Window_Days__c (30).
 *
 * Agreements that already ended (End Date before today) are excluded: they
 * are no longer "approaching" expiration.
 *
 * The rule is exposed in two forms that must stay equivalent:
 *   - requiresAttention(): in-memory check, used by the trigger on records
 *     that are already loaded (no SOQL).
 *   - getUpcomingRenewals(): SOQL-backed lookup for the UI.
 * RenewalServiceTest asserts both forms agree on the same data set.
 *
 * getUpcomingRenewals() and startRenewal() are instance methods so callers
 * (UpcomingRenewalsController) can receive this service as a dependency and
 * tests can replace it with a stub (System.StubProvider). The criteria
 * helpers stay static: they are pure functions shared by trigger and batch.
 */
public with sharing class RenewalService {
    public static final String STATUS_ACTIVE = 'Active';
    public static final String RENEWAL_STATUS_NOT_STARTED = 'Not Started';
    public static final String RENEWAL_STATUS_IN_PROGRESS = 'In Progress';
    public static final String RENEWAL_STATUS_COMPLETED = 'Completed';
    public static final String AGREEMENTS_UNAVAILABLE_MESSAGE = 'Some of the selected agreements are no longer available. Refresh the list and try again.';
    public static final String NO_EDIT_ACCESS_MESSAGE = 'You do not have permission to start renewals. Please contact your administrator.';

    /** Business rule violation with a message that is safe to show to users. */
    public class RenewalException extends Exception {
    }

    /**
     * Agreements visible to the running user that require renewal attention,
     * soonest End Date first, ready for presentation.
     */
    public List<UpcomingRenewal> getUpcomingRenewals() {
        Date today = DateProvider.today();
        List<Service_Agreement__c> agreements = ServiceAgreementSelector.selectRequiringAttention(
            today,
            getWindowEnd(today)
        );

        List<UpcomingRenewal> renewals = new List<UpcomingRenewal>();
        for (Service_Agreement__c agreement : agreements) {
            renewals.add(new UpcomingRenewal(agreement, today));
        }
        return renewals;
    }

    /**
     * Marks renewal work as started for the given agreements.
     *
     * 0. Checks that the user may edit Service Agreements and Renewal Status,
     *    failing fast with a clear message (users with read-only access can
     *    see the list but must not start renewals).
     * 1. Reads the current state AS USER: an agreement that was deleted or
     *    is not visible to the user fails the whole request with a clear
     *    message (the list on screen is stale).
     * 2. Agreements whose renewal is already Completed are left untouched, so
     *    a completed renewal never regresses to In Progress.
     * 3. The update runs AS USER (all-or-none): the user must be allowed to
     *    edit every agreement and Renewal Status, otherwise nothing changes.
     * 4. Only then are the related open Renewal Tasks moved to In Progress
     *    (a system-side consequence of an action the user was authorised to
     *    perform).
     *
     * Idempotent: agreements already In Progress are simply re-saved.
     */
    public void startRenewal(Set<Id> agreementIds) {
        if (!canEditRenewalStatus()) {
            throw new RenewalException(NO_EDIT_ACCESS_MESSAGE);
        }
        List<Service_Agreement__c> currentAgreements = ServiceAgreementSelector.selectRenewalStateByIds(
            agreementIds,
            AccessLevel.USER_MODE
        );
        if (currentAgreements.size() != agreementIds.size()) {
            throw new RenewalException(AGREEMENTS_UNAVAILABLE_MESSAGE);
        }

        Map<Id, Service_Agreement__c> agreementsToStart = new Map<Id, Service_Agreement__c>();
        for (Service_Agreement__c agreement : currentAgreements) {
            if (agreement.Renewal_Status__c != RENEWAL_STATUS_COMPLETED) {
                agreementsToStart.put(
                    agreement.Id,
                    new Service_Agreement__c(Id = agreement.Id, Renewal_Status__c = RENEWAL_STATUS_IN_PROGRESS)
                );
            }
        }
        if (agreementsToStart.isEmpty()) {
            return;
        }
        update as user agreementsToStart.values();

        RenewalTaskService.markRenewalTasksInProgress(agreementsToStart.keySet());
    }

    private static Boolean canEditRenewalStatus() {
        return Schema.SObjectType.Service_Agreement__c.isUpdateable() &&
            Schema.SObjectType.Service_Agreement__c.fields.Renewal_Status__c.isUpdateable();
    }

    /**
     * In-memory evaluation of the renewal criteria for a single record.
     */
    public static Boolean requiresAttention(Service_Agreement__c agreement, Date today) {
        if (agreement == null || agreement.End_Date__c == null || today == null) {
            return false;
        }
        return agreement.Status__c == STATUS_ACTIVE &&
            agreement.Renewal_Required__c == true &&
            agreement.End_Date__c >= today &&
            agreement.End_Date__c <= getWindowEnd(today);
    }

    /**
     * Returns the subset of the given agreements that require attention.
     */
    public static List<Service_Agreement__c> filterRequiringAttention(
        List<Service_Agreement__c> agreements,
        Date today
    ) {
        List<Service_Agreement__c> qualifying = new List<Service_Agreement__c>();
        if (agreements == null) {
            return qualifying;
        }
        for (Service_Agreement__c agreement : agreements) {
            if (requiresAttention(agreement, today)) {
                qualifying.add(agreement);
            }
        }
        return qualifying;
    }

    /**
     * Last End Date (inclusive) that falls inside the attention window.
     * Date.addDays() works on calendar days and handles month ends, year ends
     * and February 29th natively.
     */
    public static Date getWindowEnd(Date today) {
        return today.addDays(RenewalSettings.attentionWindowDays());
    }
}
