@IsTest
private class ApplicationLoggerTest {
    @IsTest
    static void flush_bufferedEntries_persistsAllWithSingleDml() {
        Id recordId = UserInfo.getUserId();
        ApplicationLogger.error('Source.error', 'Something failed', recordId);
        ApplicationLogger.warning('Source.warning', 'Something odd', null);
        Assert.areEqual(2, ApplicationLogger.pendingCount(), 'Entries must be buffered until flush');

        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        ApplicationLogger.flush();
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(1, dmlUsed, 'All entries must be written with one DML statement');
        Assert.areEqual(0, ApplicationLogger.pendingCount(), 'Buffer must be cleared after flush');

        Application_Log__c errorLog = [
            SELECT Severity__c, Message__c, Record_Id__c
            FROM Application_Log__c
            WHERE Source__c = 'Source.error' WITH SYSTEM_MODE
        ];
        Assert.areEqual(ApplicationLogger.SEVERITY_ERROR, errorLog.Severity__c);
        Assert.areEqual('Something failed', errorLog.Message__c);
        Assert.areEqual(recordId, errorLog.Record_Id__c);
        Assert.areEqual(
            ApplicationLogger.SEVERITY_WARNING,
            [SELECT Severity__c FROM Application_Log__c WHERE Source__c = 'Source.warning' WITH SYSTEM_MODE].Severity__c
        );
    }

    @IsTest
    static void error_withException_capturesTypeMessageAndStackTrace() {
        try {
            Integer invalid = 1 / 0;
        } catch (MathException e) {
            ApplicationLogger.error('Source.exception', e, null);
        }

        Test.startTest();
        ApplicationLogger.flush();
        Test.stopTest();

        Application_Log__c log = [SELECT Message__c, Stack_Trace__c FROM Application_Log__c WITH SYSTEM_MODE];
        Assert.isTrue(log.Message__c.startsWith('System.MathException'), log.Message__c);
        Assert.isNotNull(log.Stack_Trace__c, 'Stack trace must be captured');
    }

    @IsTest
    static void flush_withoutEntries_performsNoDml() {
        Test.startTest();
        ApplicationLogger.flush();
        Integer dmlUsed = Limits.getDmlStatements();
        Test.stopTest();

        Assert.areEqual(0, dmlUsed);
        Assert.areEqual(0, [SELECT COUNT() FROM Application_Log__c WITH SYSTEM_MODE]);
    }

    @IsTest
    static void error_withOversizedValues_truncatesToFieldLengths() {
        Integer sourceLength = Application_Log__c.Source__c.getDescribe().getLength();
        Integer messageLength = Application_Log__c.Message__c.getDescribe().getLength();
        ApplicationLogger.error('S'.repeat(sourceLength + 10), 'M'.repeat(messageLength + 10), null);

        Test.startTest();
        ApplicationLogger.flush();
        Test.stopTest();

        Application_Log__c log = [SELECT Source__c, Message__c FROM Application_Log__c WITH SYSTEM_MODE];
        Assert.areEqual(sourceLength, log.Source__c.length());
        Assert.areEqual(messageLength, log.Message__c.length());
    }
}
