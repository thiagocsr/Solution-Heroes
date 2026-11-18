/**
 * Tests for the LWC boundary: validation, error translation, security, and
 * the "start renewal" action. Calls run as a Standard User holding the
 * Renewal_Management permission set, i.e. a realistic renewal team member.
 */
@IsTest
private class UpcomingRenewalsControllerTest {
    private static final Date REFERENCE_DATE = Date.newInstance(2026, 6, 15);
    private static final String RENEWAL_USER_LAST_NAME = 'RenewalUser';

    @TestSetup
    static void setup() {
        TestDataFactory.createAccount('Acme Corp');
        TestDataFactory.createStandardUser(RENEWAL_USER_LAST_NAME, TestDataFactory.RENEWAL_PERMISSION_SET);
    }

    // ------------------------------------------------------------------
    // getUpcomingRenewals
    // ------------------------------------------------------------------

    @IsTest
    static void getUpcomingRenewals_renewalUser_returnsQualifyingAgreements() {
        pinContext();
        insert as system TestDataFactory.buildAgreement(getAccountId(), 'Qualifying', REFERENCE_DATE.addDays(5));
        insert as system TestDataFactory.buildAgreement(getAccountId(), 'Too far', REFERENCE_DATE.addDays(60));

        List<UpcomingRenewal> renewals;
        System.runAs(getRenewalUser()) {
            renewals = UpcomingRenewalsController.getUpcomingRenewals();
        }

        Assert.areEqual(1, renewals.size());
        Assert.areEqual('Qualifying', renewals[0].agreementName);
    }

    @IsTest
    static void getUpcomingRenewals_userWithoutAccess_throwsFriendlyMessage() {
        pinContext();
        User noAccessUser = TestDataFactory.createStandardUser('NoAccessUser', null);

        AuraHandledException caught;
        System.runAs(noAccessUser) {
            try {
                UpcomingRenewalsController.getUpcomingRenewals();
            } catch (AuraHandledException e) {
                caught = e;
            }
        }

        Assert.isNotNull(caught, 'Access must be denied');
        Assert.areEqual(UpcomingRenewalsController.NO_ACCESS_MESSAGE, caught.getMessage());
    }

    // ------------------------------------------------------------------
    // startRenewal: happy path
    // ------------------------------------------------------------------

    @IsTest
    static void startRenewal_selectedAgreements_setsInProgressOnAgreementAndOpenTask() {
        pinContext();
        Service_Agreement__c first = TestDataFactory.buildAgreement(getAccountId(), 'First', REFERENCE_DATE.addDays(5));
        Service_Agreement__c second = TestDataFactory.buildAgreement(getAccountId(), 'Second', REFERENCE_DATE.addDays(8));
        Service_Agreement__c untouched = TestDataFactory.buildAgreement(getAccountId(), 'Untouched', REFERENCE_DATE.addDays(9));
        insert as system new List<Service_Agreement__c>{ first, second, untouched };

        Test.startTest();
        System.runAs(getRenewalUser()) {
            UpcomingRenewalsController.startRenewal(new List<Id>{ first.Id, second.Id });
        }
        Test.stopTest();

        Map<Id, Service_Agreement__c> agreements = new Map<Id, Service_Agreement__c>(
            [SELECT Renewal_Status__c FROM Service_Agreement__c WITH SYSTEM_MODE]
        );
        Assert.areEqual(RenewalService.RENEWAL_STATUS_IN_PROGRESS, agreements.get(first.Id).Renewal_Status__c);
        Assert.areEqual(RenewalService.RENEWAL_STATUS_IN_PROGRESS, agreements.get(second.Id).Renewal_Status__c);
        Assert.areEqual(RenewalService.RENEWAL_STATUS_NOT_STARTED, agreements.get(untouched.Id).Renewal_Status__c);

        Assert.areEqual(RenewalTaskService.TASK_STATUS_IN_PROGRESS, getTaskStatus(first.Id));
        Assert.areEqual(RenewalTaskService.TASK_STATUS_IN_PROGRESS, getTaskStatus(second.Id));
        Assert.areNotEqual(RenewalTaskService.TASK_STATUS_IN_PROGRESS, getTaskStatus(untouched.Id));
        Assert.areEqual(3, [SELECT COUNT() FROM Task WITH SYSTEM_MODE], 'Starting a renewal must not create Tasks');
    }

    @IsTest
    static void startRenewal_alreadyStarted_isIdempotent() {
        pinContext();
        Service_Agreement__c agreement = TestDataFactory.buildAgreement(getAccountId(), 'Twice', REFERENCE_DATE.addDays(5));
        insert as system agreement;

        System.runAs(getRenewalUser()) {
            UpcomingRenewalsController.startRenewal(new List<Id>{ agreement.Id });
            UpcomingRenewalsController.startRenewal(new List<Id>{ agreement.Id });
        }

        Assert.areEqual(
            RenewalService.RENEWAL_STATUS_IN_PROGRESS,
            [SELECT Renewal_Status__c FROM Service_Agreement__c WHERE Id = :agreement.Id WITH SYSTEM_MODE].Renewal_Status__c
        );
        Assert.areEqual(1, [SELECT COUNT() FROM Task WITH SYSTEM_MODE]);
    }

    @IsTest
    static void startRenewal_completedTask_isNotReopened() {
        pinContext();
        Service_Agreement__c agreement = TestDataFactory.buildAgreement(getAccountId(), 'Done', REFERENCE_DATE.addDays(5));
        insert as system agreement;
        Task renewalTask = [SELECT Id FROM Task WHERE WhatId = :agreement.Id WITH SYSTEM_MODE];
        renewalTask.Status = 'Completed';
        update as system renewalTask;

        System.runAs(getRenewalUser()) {
            UpcomingRenewalsController.startRenewal(new List<Id>{ agreement.Id });
        }

        Assert.areEqual('Completed', getTaskStatus(agreement.Id), 'Closed Tasks must stay closed');
    }

    // ------------------------------------------------------------------
    // startRenewal: validation and security
    // ------------------------------------------------------------------

    @IsTest
    static void startRenewal_emptyOrNullSelection_isRejected() {
        assertRejected(null, UpcomingRenewalsController.EMPTY_SELECTION_MESSAGE);
        assertRejected(new List<Id>(), UpcomingRenewalsController.EMPTY_SELECTION_MESSAGE);
    }

    @IsTest
    static void startRenewal_nonAgreementIds_areRejected() {
        assertRejected(new List<Id>{ getAccountId() }, UpcomingRenewalsController.INVALID_SELECTION_MESSAGE);
        assertRejected(new List<Id>{ null }, UpcomingRenewalsController.INVALID_SELECTION_MESSAGE);
    }

    @IsTest
    static void startRenewal_selectionAboveLimit_isRejected() {
        List<Id> ids = new List<Id>();
        String prefix = Service_Agreement__c.SObjectType.getDescribe().getKeyPrefix();
        for (Integer i = 0; i <= UpcomingRenewalsController.MAX_SELECTION; i++) {
            ids.add(Id.valueOf(prefix + String.valueOf(i).leftPad(12, '0')));
        }

        assertRejected(ids, 'Select up to ' + UpcomingRenewalsController.MAX_SELECTION + ' agreements at a time.');
    }

    @IsTest
    static void startRenewal_userWithoutEditAccess_isRejectedAndNothingChanges() {
        pinContext();
        Service_Agreement__c agreement = TestDataFactory.buildAgreement(getAccountId(), 'Protected', REFERENCE_DATE.addDays(5));
        insert as system agreement;
        User noAccessUser = TestDataFactory.createStandardUser('NoAccessUser', null);

        AuraHandledException caught;
        System.runAs(noAccessUser) {
            try {
                UpcomingRenewalsController.startRenewal(new List<Id>{ agreement.Id });
            } catch (AuraHandledException e) {
                caught = e;
            }
        }

        Assert.isNotNull(caught, 'Users without edit access must not start renewals');
        Assert.areEqual(UpcomingRenewalsController.NO_ACCESS_MESSAGE, caught.getMessage());
        Assert.areEqual(
            RenewalService.RENEWAL_STATUS_NOT_STARTED,
            [SELECT Renewal_Status__c FROM Service_Agreement__c WHERE Id = :agreement.Id WITH SYSTEM_MODE].Renewal_Status__c
        );
        Assert.areNotEqual(RenewalTaskService.TASK_STATUS_IN_PROGRESS, getTaskStatus(agreement.Id));
    }

    @IsTest
    static void startRenewal_agreementDeletedMeanwhile_returnsPlatformMessage() {
        // Simulates a stale list: another user deleted the agreement after it was displayed.
        pinContext();
        Service_Agreement__c agreement = TestDataFactory.buildAgreement(getAccountId(), 'Deleted', REFERENCE_DATE.addDays(5));
        insert as system agreement;
        delete as system agreement;

        AuraHandledException caught;
        System.runAs(getRenewalUser()) {
            try {
                UpcomingRenewalsController.startRenewal(new List<Id>{ agreement.Id });
            } catch (AuraHandledException e) {
                caught = e;
            }
        }

        Assert.isNotNull(caught);
        Assert.areEqual('entity is deleted', caught.getMessage(), 'The DML error message must reach the user');
    }

    // ------------------------------------------------------------------
    // Unexpected errors (service replaced by a failing stub)
    // ------------------------------------------------------------------

    @IsTest
    static void getUpcomingRenewals_unexpectedError_returnsGenericMessage() {
        useFailingService();

        AuraHandledException caught;
        System.runAs(getRenewalUser()) {
            try {
                UpcomingRenewalsController.getUpcomingRenewals();
            } catch (AuraHandledException e) {
                caught = e;
            }
        }

        Assert.isNotNull(caught);
        Assert.areEqual(
            UpcomingRenewalsController.GENERIC_ERROR_MESSAGE,
            caught.getMessage(),
            'Internal details must not leak to the user'
        );
    }

    @IsTest
    static void startRenewal_unexpectedError_returnsGenericMessageAndChangesNothing() {
        pinContext();
        Service_Agreement__c agreement = TestDataFactory.buildAgreement(getAccountId(), 'Failure', REFERENCE_DATE.addDays(5));
        insert as system agreement;
        useFailingService();

        AuraHandledException caught;
        System.runAs(getRenewalUser()) {
            try {
                UpcomingRenewalsController.startRenewal(new List<Id>{ agreement.Id });
            } catch (AuraHandledException e) {
                caught = e;
            }
        }

        Assert.isNotNull(caught);
        Assert.areEqual(UpcomingRenewalsController.GENERIC_ERROR_MESSAGE, caught.getMessage());
        Assert.areEqual(
            RenewalService.RENEWAL_STATUS_NOT_STARTED,
            [SELECT Renewal_Status__c FROM Service_Agreement__c WHERE Id = :agreement.Id WITH SYSTEM_MODE].Renewal_Status__c
        );
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    private class SimulatedException extends Exception {
    }

    /**
     * Stub (not a mock): it only provides a canned behaviour, throwing an
     * unexpected exception for any call. Tests assert on the controller's
     * outcome, not on the interactions with the service.
     */
    private class FailingRenewalServiceStub implements System.StubProvider {
        public Object handleMethodCall(
            Object stubbedObject,
            String stubbedMethodName,
            System.Type returnType,
            List<System.Type> paramTypes,
            List<String> paramNames,
            List<Object> args
        ) {
            throw new SimulatedException('internal detail from ' + stubbedMethodName);
        }
    }

    private static void useFailingService() {
        UpcomingRenewalsController.service = (RenewalService) Test.createStub(
            RenewalService.class,
            new FailingRenewalServiceStub()
        );
    }

    private static void assertRejected(List<Id> agreementIds, String expectedMessage) {
        AuraHandledException caught;
        System.runAs(getRenewalUser()) {
            try {
                UpcomingRenewalsController.startRenewal(agreementIds);
            } catch (AuraHandledException e) {
                caught = e;
            }
        }
        Assert.isNotNull(caught, 'Selection must be rejected: ' + agreementIds);
        Assert.areEqual(expectedMessage, caught.getMessage());
    }

    private static void pinContext() {
        DateProvider.todayOverride = REFERENCE_DATE;
        RenewalSettings.settingOverride = new Renewal_Setting__mdt(
            Attention_Window_Days__c = 30,
            Task_Lead_Days__c = 10
        );
    }

    private static String getTaskStatus(Id agreementId) {
        return [SELECT Status FROM Task WHERE WhatId = :agreementId WITH SYSTEM_MODE LIMIT 1].Status;
    }

    private static Id getAccountId() {
        return [SELECT Id FROM Account WHERE Name = 'Acme Corp' LIMIT 1].Id;
    }

    private static User getRenewalUser() {
        return [SELECT Id FROM User WHERE LastName = :RENEWAL_USER_LAST_NAME LIMIT 1];
    }
}
