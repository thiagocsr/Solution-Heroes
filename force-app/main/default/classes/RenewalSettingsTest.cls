@IsTest
private class RenewalSettingsTest {
    @IsTest
    static void settings_withoutOverride_readDeployedDefaultRecord() {
        Renewal_Setting__mdt deployed = Renewal_Setting__mdt.getInstance(RenewalSettings.DEFAULT_RECORD_NAME);

        Assert.isNotNull(deployed, 'The Default Renewal Setting record must be deployed');
        Assert.areEqual(deployed.Attention_Window_Days__c.intValue(), RenewalSettings.attentionWindowDays());
        Assert.areEqual(deployed.Task_Lead_Days__c.intValue(), RenewalSettings.taskLeadDays());
    }

    @IsTest
    static void settings_withConfiguredValues_returnConfiguredValues() {
        RenewalSettings.settingOverride = new Renewal_Setting__mdt(
            Attention_Window_Days__c = 45,
            Task_Lead_Days__c = 7
        );

        Assert.areEqual(45, RenewalSettings.attentionWindowDays());
        Assert.areEqual(7, RenewalSettings.taskLeadDays());
    }

    @IsTest
    static void settings_withBlankValues_fallBackToBusinessDefaults() {
        RenewalSettings.settingOverride = new Renewal_Setting__mdt();

        Assert.areEqual(RenewalSettings.DEFAULT_ATTENTION_WINDOW_DAYS, RenewalSettings.attentionWindowDays());
        Assert.areEqual(RenewalSettings.DEFAULT_TASK_LEAD_DAYS, RenewalSettings.taskLeadDays());
    }

    @IsTest
    static void settings_withNegativeValues_fallBackToBusinessDefaults() {
        RenewalSettings.settingOverride = new Renewal_Setting__mdt(
            Attention_Window_Days__c = -1,
            Task_Lead_Days__c = -5
        );

        Assert.areEqual(RenewalSettings.DEFAULT_ATTENTION_WINDOW_DAYS, RenewalSettings.attentionWindowDays());
        Assert.areEqual(RenewalSettings.DEFAULT_TASK_LEAD_DAYS, RenewalSettings.taskLeadDays());
    }
}
