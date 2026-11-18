/**
 * Minimal persistent logger backed by Application_Log__c.
 *
 * Entries are buffered in memory and written with a single DML statement on
 * flush(), so logging inside bulk operations never multiplies DML usage.
 * Callers flush once at the end of their unit of work.
 *
 * Logs are inserted in SYSTEM_MODE: the user whose action caused the error
 * does not need (and should not have) access to the log object.
 *
 * Known limitation: log rows share the caller's transaction, so they are lost
 * if that transaction rolls back. The renewal automation uses partial-success
 * DML precisely so it does not roll back; a Platform Event based logger
 * (e.g. Nebula Logger) would remove this limitation if ever required.
 */
public inherited sharing class ApplicationLogger {
    @TestVisible
    private static final String SEVERITY_ERROR = 'Error';
    @TestVisible
    private static final String SEVERITY_WARNING = 'Warning';

    private static final Integer SOURCE_MAX_LENGTH = Application_Log__c.Source__c.getDescribe().getLength();
    private static final Integer MESSAGE_MAX_LENGTH = Application_Log__c.Message__c.getDescribe().getLength();
    private static final Integer STACK_TRACE_MAX_LENGTH = Application_Log__c.Stack_Trace__c.getDescribe().getLength();

    private static List<Application_Log__c> pendingEntries = new List<Application_Log__c>();

    public static void error(String source, String message, Id recordId) {
        add(SEVERITY_ERROR, source, message, null, recordId);
    }

    public static void error(String source, Exception ex, Id recordId) {
        add(SEVERITY_ERROR, source, ex.getTypeName() + ': ' + ex.getMessage(), ex.getStackTraceString(), recordId);
    }

    public static void warning(String source, String message, Id recordId) {
        add(SEVERITY_WARNING, source, message, null, recordId);
    }

    /**
     * Persists buffered entries. A failure to log must never break the
     * business transaction, so insert errors are only sent to the debug log.
     */
    public static void flush() {
        if (pendingEntries.isEmpty()) {
            return;
        }
        List<Application_Log__c> entries = pendingEntries;
        pendingEntries = new List<Application_Log__c>();

        for (Database.SaveResult result : Database.insert(entries, false, AccessLevel.SYSTEM_MODE)) {
            if (!result.isSuccess()) {
                System.debug(LoggingLevel.ERROR, 'ApplicationLogger could not persist entry: ' + result.getErrors());
            }
        }
    }

    @TestVisible
    private static Integer pendingCount() {
        return pendingEntries.size();
    }

    private static void add(String severity, String source, String message, String stackTrace, Id recordId) {
        System.debug(LoggingLevel.ERROR, severity + ' [' + source + '] ' + message);
        pendingEntries.add(
            new Application_Log__c(
                Severity__c = severity,
                Source__c = source?.left(SOURCE_MAX_LENGTH),
                Message__c = message?.left(MESSAGE_MAX_LENGTH),
                Stack_Trace__c = stackTrace?.left(STACK_TRACE_MAX_LENGTH),
                Record_Id__c = recordId
            )
        );
    }
}
