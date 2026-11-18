// Schedules the daily Renewal Task sweep (02:00, scheduling user's time zone).
// Run once per org:
//   sf apex run --file scripts/apex/scheduleRenewalBatch.apex --target-org <alias>
// To run the sweep immediately instead:
//   Database.executeBatch(new RenewalTaskBatch(), 200);
System.debug('Scheduled job Id: ' + RenewalTaskBatch.scheduleDaily());
