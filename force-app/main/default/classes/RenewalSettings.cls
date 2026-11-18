/**
 * Read-only access to the renewal business parameters stored in the
 * Renewal_Setting__mdt "Default" record.
 *
 * Custom Metadata is used so the 30-day window and 10-day task lead time can
 * be changed by an administrator (and deployed between environments) without
 * code changes. getInstance() is served from the application cache and does
 * not consume a SOQL query.
 *
 * If the record is missing or holds an invalid value, the documented business
 * defaults are used so the automation never stops working because of a
 * configuration gap.
 */
public inherited sharing class RenewalSettings {
    @TestVisible
    private static final String DEFAULT_RECORD_NAME = 'Default';
    @TestVisible
    private static final Integer DEFAULT_ATTENTION_WINDOW_DAYS = 30;
    @TestVisible
    private static final Integer DEFAULT_TASK_LEAD_DAYS = 10;

    @TestVisible
    private static Renewal_Setting__mdt settingOverride;

    /**
     * Number of calendar days ahead of today (inclusive) in which an agreement
     * End Date requires renewal attention.
     */
    public static Integer attentionWindowDays() {
        Renewal_Setting__mdt setting = getSetting();
        return resolve(setting?.Attention_Window_Days__c, DEFAULT_ATTENTION_WINDOW_DAYS);
    }

    /**
     * Number of calendar days before the agreement End Date that the Renewal
     * Task is due.
     */
    public static Integer taskLeadDays() {
        Renewal_Setting__mdt setting = getSetting();
        return resolve(setting?.Task_Lead_Days__c, DEFAULT_TASK_LEAD_DAYS);
    }

    private static Renewal_Setting__mdt getSetting() {
        return settingOverride != null ? settingOverride : Renewal_Setting__mdt.getInstance(DEFAULT_RECORD_NAME);
    }

    private static Integer resolve(Decimal configuredValue, Integer defaultValue) {
        if (configuredValue == null || configuredValue < 0) {
            return defaultValue;
        }
        return configuredValue.intValue();
    }
}
