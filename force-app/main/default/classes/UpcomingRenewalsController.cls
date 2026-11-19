/**
 * Thin Apex entry point for the upcomingRenewals Lightning Web Component.
 *
 * Responsibilities limited to the UI boundary: input validation and turning
 * exceptions into user-friendly AuraHandledExceptions. Business rules live in
 * RenewalService / RenewalTaskService.
 *
 * Errors are not written to Application_Log__c here: an exception thrown
 * back to the component rolls back the transaction, which would also discard
 * the log row (see ApplicationLogger). Unexpected errors are sent to the
 * debug log and a generic message is shown.
 */
public with sharing class UpcomingRenewalsController {
    @TestVisible
    private static final Integer MAX_SELECTION = 200;
    @TestVisible
    private static final String NO_ACCESS_MESSAGE = 'You do not have access to Service Agreements. Please contact your administrator.';
    @TestVisible
    private static final String EMPTY_SELECTION_MESSAGE = 'Select at least one agreement.';
    @TestVisible
    private static final String INVALID_SELECTION_MESSAGE = 'The selection contains records that are not Service Agreements.';
    @TestVisible
    private static final String GENERIC_ERROR_MESSAGE = 'Something went wrong. Please try again or contact your administrator.';

    /**
     * Business service dependency. @TestVisible so tests can replace it with
     * a stub (Test.createStub) to exercise error handling in isolation.
     */
    @TestVisible
    private static RenewalService service = new RenewalService();

    /**
     * Agreements requiring renewal attention, visible to the running user.
     * cacheable: read-only, enables Lightning Data Service caching and @wire.
     */
    @AuraEnabled(cacheable=true)
    public static List<UpcomingRenewal> getUpcomingRenewals() {
        try {
            return service.getUpcomingRenewals();
        } catch (QueryException e) {
            // USER_MODE raises QueryException when object/field access is missing.
            throw buildException(NO_ACCESS_MESSAGE);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, e.getTypeName() + ': ' + e.getMessage() + '\n' + e.getStackTraceString());
            throw buildException(GENERIC_ERROR_MESSAGE);
        }
    }

    /**
     * Marks renewal work as started for the selected agreements.
     */
    @AuraEnabled
    public static void startRenewal(List<Id> agreementIds) {
        validateSelection(agreementIds);
        try {
            service.startRenewal(new Set<Id>(agreementIds));
        } catch (RenewalService.RenewalException e) {
            // Business rule or permission message, written to be shown to users.
            throw buildException(e.getMessage());
        } catch (DmlException e) {
            // Permission, sharing or validation problems: the platform message is meaningful to the user.
            throw buildException(e.getDmlMessage(0));
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, e.getTypeName() + ': ' + e.getMessage() + '\n' + e.getStackTraceString());
            throw buildException(GENERIC_ERROR_MESSAGE);
        }
    }

    private static void validateSelection(List<Id> agreementIds) {
        if (agreementIds == null || agreementIds.isEmpty()) {
            throw buildException(EMPTY_SELECTION_MESSAGE);
        }
        if (agreementIds.size() > MAX_SELECTION) {
            throw buildException('Select up to ' + MAX_SELECTION + ' agreements at a time.');
        }
        for (Id agreementId : agreementIds) {
            if (agreementId == null || agreementId.getSObjectType() != Service_Agreement__c.SObjectType) {
                throw buildException(INVALID_SELECTION_MESSAGE);
            }
        }
    }

    /**
     * AuraHandledException only exposes its message to Apex (and tests) when
     * setMessage() is called explicitly.
     */
    private static AuraHandledException buildException(String message) {
        AuraHandledException ex = new AuraHandledException(message);
        ex.setMessage(message);
        return ex;
    }
}
