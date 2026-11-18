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
     * The agreement update runs AS USER (all-or-none): the running user must
     * have edit access to every selected agreement and to Renewal Status,
     * otherwise nothing changes. Only after that succeeds are the related
     * open Renewal Tasks moved to In Progress (a system-side consequence of
     * an action the user was authorised to perform).
     *
     * Idempotent: agreements already In Progress are simply re-saved.
     */
    public void startRenewal(Set<Id> agreementIds) {
        List<Service_Agreement__c> agreements = new List<Service_Agreement__c>();
        for (Id agreementId : agreementIds) {
            agreements.add(new Service_Agreement__c(Id = agreementId, Renewal_Status__c = RENEWAL_STATUS_IN_PROGRESS));
        }
        update as user agreements;

        RenewalTaskService.markRenewalTasksInProgress(agreementIds);
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
