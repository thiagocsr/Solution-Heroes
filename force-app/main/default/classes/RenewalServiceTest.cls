/**
 * Tests for the renewal attention criteria (RenewalService) and the
 * SOQL-backed lookup used by the UI (ServiceAgreementSelector + UpcomingRenewal).
 *
 * Every test pins both the reference date (DateProvider) and the business
 * settings (RenewalSettings) so results do not depend on the day the tests
 * run or on how an administrator configured the Custom Metadata record.
 */
@IsTest
private class RenewalServiceTest {
    private static final Integer WINDOW_DAYS = 30;
    private static final Date REFERENCE_DATE = Date.newInstance(2026, 6, 15);
    private static final String RENEWAL_USER_LAST_NAME = 'RenewalUser';

    @TestSetup
    static void setup() {
        TestDataFactory.createAccount('Acme Corp');
        TestDataFactory.createStandardUser(RENEWAL_USER_LAST_NAME, TestDataFactory.RENEWAL_PERMISSION_SET);
    }

    // ------------------------------------------------------------------
    // Criteria: each condition in isolation
    // ------------------------------------------------------------------

    @IsTest
    static void requiresAttention_activeRenewalRequiredEndingInWindow_returnsTrue() {
        pinContext(REFERENCE_DATE);

        Assert.isTrue(RenewalService.requiresAttention(agreementEnding(REFERENCE_DATE.addDays(15)), REFERENCE_DATE));
    }

    @IsTest
    static void requiresAttention_statusOtherThanActive_returnsFalse() {
        pinContext(REFERENCE_DATE);

        for (String status : new List<String>{ 'Draft', 'Expired', 'Cancelled' }) {
            Service_Agreement__c agreement = agreementEnding(REFERENCE_DATE.addDays(15));
            agreement.Status__c = status;

            Assert.isFalse(
                RenewalService.requiresAttention(agreement, REFERENCE_DATE),
                'Status ' + status + ' must not require attention'
            );
        }
    }

    @IsTest
    static void requiresAttention_renewalNotRequired_returnsFalse() {
        pinContext(REFERENCE_DATE);
        Service_Agreement__c agreement = agreementEnding(REFERENCE_DATE.addDays(15));
        agreement.Renewal_Required__c = false;

        Assert.isFalse(RenewalService.requiresAttention(agreement, REFERENCE_DATE));
    }

    @IsTest
    static void requiresAttention_missingInputs_returnsFalse() {
        pinContext(REFERENCE_DATE);
        Service_Agreement__c withoutEndDate = agreementEnding(REFERENCE_DATE.addDays(15));
        withoutEndDate.End_Date__c = null;

        Assert.isFalse(RenewalService.requiresAttention(null, REFERENCE_DATE), 'Null agreement');
        Assert.isFalse(RenewalService.requiresAttention(withoutEndDate, REFERENCE_DATE), 'Null End Date');
        Assert.isFalse(
            RenewalService.requiresAttention(agreementEnding(REFERENCE_DATE.addDays(15)), null),
            'Null reference date'
        );
    }

    // ------------------------------------------------------------------
    // Window boundaries (inclusive on both ends)
    // ------------------------------------------------------------------

    @IsTest
    static void requiresAttention_endingToday_returnsTrue() {
        pinContext(REFERENCE_DATE);

        Assert.isTrue(RenewalService.requiresAttention(agreementEnding(REFERENCE_DATE), REFERENCE_DATE));
    }

    @IsTest
    static void requiresAttention_endingOnLastDayOfWindow_returnsTrue() {
        pinContext(REFERENCE_DATE);

        Assert.isTrue(
            RenewalService.requiresAttention(agreementEnding(REFERENCE_DATE.addDays(WINDOW_DAYS)), REFERENCE_DATE)
        );
    }

    @IsTest
    static void requiresAttention_endingDayAfterWindow_returnsFalse() {
        pinContext(REFERENCE_DATE);

        Assert.isFalse(
            RenewalService.requiresAttention(agreementEnding(REFERENCE_DATE.addDays(WINDOW_DAYS + 1)), REFERENCE_DATE)
        );
    }

    @IsTest
    static void requiresAttention_alreadyEnded_returnsFalse() {
        pinContext(REFERENCE_DATE);

        Assert.isFalse(RenewalService.requiresAttention(agreementEnding(REFERENCE_DATE.addDays(-1)), REFERENCE_DATE));
    }

    // ------------------------------------------------------------------
    // Calendar boundaries
    // ------------------------------------------------------------------

    @IsTest
    static void window_crossingMonthEndIntoShortFebruary_endsOnMarch2() {
        // Jan 31 + 30 days: Feb 2027 has 28 days, so the window ends on Mar 2.
        assertWindow(Date.newInstance(2027, 1, 31), Date.newInstance(2027, 3, 2));
    }

    @IsTest
    static void window_crossingYearEnd_endsInJanuaryOfNextYear() {
        assertWindow(Date.newInstance(2026, 12, 15), Date.newInstance(2027, 1, 14));
    }

    @IsTest
    static void window_crossingLeapFebruary_countsFebruary29() {
        // Feb 10 2028 + 30 days: Feb 2028 has 29 days, so the window ends on Mar 11.
        assertWindow(Date.newInstance(2028, 2, 10), Date.newInstance(2028, 3, 11));
    }

    @IsTest
    static void window_crossingNonLeapFebruary_endsOneDayLater() {
        // Same start as the leap-year case one year earlier: window ends on Mar 12.
        assertWindow(Date.newInstance(2027, 2, 10), Date.newInstance(2027, 3, 12));
    }

    @IsTest
    static void requiresAttention_endingOnLeapDay_returnsTrue() {
        Date today = Date.newInstance(2028, 2, 10);
        pinContext(today);

        Assert.isTrue(RenewalService.requiresAttention(agreementEnding(Date.newInstance(2028, 2, 29)), today));
    }

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    @IsTest
    static void requiresAttention_customWindowFromSettings_isHonoured() {
        DateProvider.todayOverride = REFERENCE_DATE;
        RenewalSettings.settingOverride = new Renewal_Setting__mdt(Attention_Window_Days__c = 45, Task_Lead_Days__c = 10);

        Assert.isTrue(RenewalService.requiresAttention(agreementEnding(REFERENCE_DATE.addDays(45)), REFERENCE_DATE));
        Assert.isFalse(RenewalService.requiresAttention(agreementEnding(REFERENCE_DATE.addDays(46)), REFERENCE_DATE));
    }

    // ------------------------------------------------------------------
    // filterRequiringAttention
    // ------------------------------------------------------------------

    @IsTest
    static void filterRequiringAttention_mixedList_returnsOnlyQualifying() {
        pinContext(REFERENCE_DATE);
        Service_Agreement__c qualifying = agreementEnding(REFERENCE_DATE.addDays(5));
        Service_Agreement__c tooFar = agreementEnding(REFERENCE_DATE.addDays(60));
        Service_Agreement__c draft = agreementEnding(REFERENCE_DATE.addDays(5));
        draft.Status__c = 'Draft';

        List<Service_Agreement__c> result = RenewalService.filterRequiringAttention(
            new List<Service_Agreement__c>{ qualifying, tooFar, draft },
            REFERENCE_DATE
        );

        Assert.areEqual(1, result.size());
        Assert.areEqual(qualifying, result[0]);
    }

    @IsTest
    static void filterRequiringAttention_nullList_returnsEmptyList() {
        pinContext(REFERENCE_DATE);

        Assert.isTrue(RenewalService.filterRequiringAttention(null, REFERENCE_DATE).isEmpty());
    }

    // ------------------------------------------------------------------
    // getUpcomingRenewals (SOQL, security, presentation data)
    // ------------------------------------------------------------------

    @IsTest
    static void getUpcomingRenewals_mixedData_returnsOnlyQualifyingSoonestFirst() {
        pinContext(REFERENCE_DATE);
        Id accountId = getAccountId();

        Service_Agreement__c later = TestDataFactory.buildAgreement(accountId, 'Later', REFERENCE_DATE.addDays(20));
        Service_Agreement__c sooner = TestDataFactory.buildAgreement(accountId, 'Sooner', REFERENCE_DATE.addDays(3));
        Service_Agreement__c outsideWindow = TestDataFactory.buildAgreement(accountId, 'Outside', REFERENCE_DATE.addDays(31));
        Service_Agreement__c ended = TestDataFactory.buildAgreement(accountId, 'Ended', REFERENCE_DATE.addDays(-1));
        Service_Agreement__c cancelled = TestDataFactory.buildAgreement(accountId, 'Cancelled', REFERENCE_DATE.addDays(10));
        cancelled.Status__c = 'Cancelled';
        Service_Agreement__c noRenewal = TestDataFactory.buildAgreement(accountId, 'No Renewal', REFERENCE_DATE.addDays(10));
        noRenewal.Renewal_Required__c = false;
        insert as system new List<Service_Agreement__c>{ later, sooner, outsideWindow, ended, cancelled, noRenewal };

        List<UpcomingRenewal> renewals;
        System.runAs(getRenewalUser()) {
            Test.startTest();
            renewals = new RenewalService().getUpcomingRenewals();
            Test.stopTest();
        }

        Assert.areEqual(2, renewals.size(), 'Only the two qualifying agreements must be returned');
        Assert.areEqual(sooner.Id, renewals[0].agreementId, 'Results must be ordered by End Date ascending');
        Assert.areEqual(later.Id, renewals[1].agreementId);
    }

    @IsTest
    static void getUpcomingRenewals_qualifyingAgreement_populatesPresentationFields() {
        pinContext(REFERENCE_DATE);
        Id accountId = getAccountId();
        Service_Agreement__c agreement = TestDataFactory.buildAgreement(accountId, 'Support 2026', REFERENCE_DATE.addDays(12));
        agreement.Agreement_Value__c = 25000;
        agreement.Renewal_Status__c = RenewalService.RENEWAL_STATUS_IN_PROGRESS;
        insert as system agreement;

        List<UpcomingRenewal> renewals;
        System.runAs(getRenewalUser()) {
            renewals = new RenewalService().getUpcomingRenewals();
        }

        Assert.areEqual(1, renewals.size());
        UpcomingRenewal renewal = renewals[0];
        Assert.areEqual(agreement.Id, renewal.agreementId);
        Assert.areEqual('Support 2026', renewal.agreementName);
        Assert.areEqual(accountId, renewal.accountId);
        Assert.areEqual('Acme Corp', renewal.accountName);
        Assert.areEqual(REFERENCE_DATE.addDays(12), renewal.endDate);
        Assert.areEqual(12, renewal.daysRemaining);
        Assert.areEqual(25000, renewal.agreementValue);
        Assert.areEqual(UserInfo.getUserId(), renewal.accountManagerId);
        Assert.areEqual(UserInfo.getName(), renewal.accountManagerName);
        Assert.areEqual(RenewalService.RENEWAL_STATUS_IN_PROGRESS, renewal.renewalStatus);
        Assert.isTrue(renewal.renewalStarted);
    }

    @IsTest
    static void getUpcomingRenewals_withoutAccountManager_returnsBlankManager() {
        pinContext(REFERENCE_DATE);
        Service_Agreement__c agreement = TestDataFactory.buildAgreement(getAccountId(), 'Unassigned', REFERENCE_DATE.addDays(5));
        agreement.Account_Manager__c = null;
        insert as system agreement;

        List<UpcomingRenewal> renewals;
        System.runAs(getRenewalUser()) {
            renewals = new RenewalService().getUpcomingRenewals();
        }

        Assert.areEqual(1, renewals.size());
        Assert.isNull(renewals[0].accountManagerId);
        Assert.isNull(renewals[0].accountManagerName);
        Assert.isFalse(renewals[0].renewalStarted, 'Default renewal status is Not Started');
    }

    @IsTest
    static void getUpcomingRenewals_daysRemainingAcrossLeapDay_countsFebruary29() {
        Date today = Date.newInstance(2028, 2, 20);
        pinContext(today);
        insert as system TestDataFactory.buildAgreement(getAccountId(), 'Leap', Date.newInstance(2028, 3, 1));

        List<UpcomingRenewal> renewals;
        System.runAs(getRenewalUser()) {
            renewals = new RenewalService().getUpcomingRenewals();
        }

        Assert.areEqual(1, renewals.size());
        Assert.areEqual(10, renewals[0].daysRemaining, 'Feb 20 -> Mar 1 2028 is 10 days because of Feb 29');
    }

    @IsTest
    static void getUpcomingRenewals_noQualifyingAgreements_returnsEmptyList() {
        pinContext(REFERENCE_DATE);
        insert as system TestDataFactory.buildAgreement(getAccountId(), 'Far Away', REFERENCE_DATE.addDays(90));

        List<UpcomingRenewal> renewals;
        System.runAs(getRenewalUser()) {
            renewals = new RenewalService().getUpcomingRenewals();
        }

        Assert.isNotNull(renewals, 'An empty list, never null, must be returned');
        Assert.isTrue(renewals.isEmpty());
    }

    @IsTest
    static void getUpcomingRenewals_queryAndInMemoryCriteria_agree() {
        // Guards against the SOQL filter and requiresAttention() drifting apart.
        pinContext(REFERENCE_DATE);
        Id accountId = getAccountId();
        List<Service_Agreement__c> agreements = new List<Service_Agreement__c>();
        for (Integer offset = -3; offset <= WINDOW_DAYS + 3; offset++) {
            agreements.add(TestDataFactory.buildAgreement(accountId, 'Offset ' + offset, REFERENCE_DATE.addDays(offset)));
        }
        Service_Agreement__c draft = TestDataFactory.buildAgreement(accountId, 'Draft', REFERENCE_DATE.addDays(5));
        draft.Status__c = 'Draft';
        agreements.add(draft);
        insert as system agreements;

        Set<Id> expectedIds = new Map<Id, Service_Agreement__c>(
                RenewalService.filterRequiringAttention(agreements, REFERENCE_DATE)
            )
            .keySet();

        Set<Id> actualIds = new Set<Id>();
        System.runAs(getRenewalUser()) {
            for (UpcomingRenewal renewal : new RenewalService().getUpcomingRenewals()) {
                actualIds.add(renewal.agreementId);
            }
        }

        Assert.areEqual(WINDOW_DAYS + 1, expectedIds.size(), 'Days 0..30 inclusive must qualify');
        Assert.areEqual(expectedIds, actualIds, 'SOQL and in-memory criteria must select the same agreements');
    }

    @IsTest
    static void getUpcomingRenewals_userWithoutPermissionSet_isDenied() {
        pinContext(REFERENCE_DATE);
        insert as system TestDataFactory.buildAgreement(getAccountId(), 'Restricted', REFERENCE_DATE.addDays(5));
        User userWithoutAccess = TestDataFactory.createStandardUser('NoAccessUser', null);

        Exception caught;
        System.runAs(userWithoutAccess) {
            try {
                new RenewalService().getUpcomingRenewals();
            } catch (QueryException e) {
                caught = e;
            }
        }

        Assert.isNotNull(caught, 'USER_MODE must block users without access to Service Agreements');
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    private static void pinContext(Date today) {
        DateProvider.todayOverride = today;
        RenewalSettings.settingOverride = new Renewal_Setting__mdt(
            Attention_Window_Days__c = WINDOW_DAYS,
            Task_Lead_Days__c = 10
        );
    }

    /**
     * Asserts the last qualifying End Date for a given "today": the expected
     * last day qualifies and the following day does not.
     */
    private static void assertWindow(Date today, Date expectedLastDay) {
        pinContext(today);

        Assert.areEqual(expectedLastDay, RenewalService.getWindowEnd(today), 'Unexpected window end');
        Assert.isTrue(
            RenewalService.requiresAttention(agreementEnding(expectedLastDay), today),
            'Last day of the window must qualify'
        );
        Assert.isFalse(
            RenewalService.requiresAttention(agreementEnding(expectedLastDay.addDays(1)), today),
            'Day after the window must not qualify'
        );
    }

    /** In-memory qualifying agreement; no DML needed for criteria tests. */
    private static Service_Agreement__c agreementEnding(Date endDate) {
        return TestDataFactory.buildAgreement(null, 'In Memory', endDate);
    }

    private static Id getAccountId() {
        return [SELECT Id FROM Account WHERE Name = 'Acme Corp' LIMIT 1].Id;
    }

    private static User getRenewalUser() {
        return [SELECT Id FROM User WHERE LastName = :RENEWAL_USER_LAST_NAME LIMIT 1];
    }
}
