// Schedules the daily Renewal Task sweep (02:00, scheduling user's time zone).
// Safe to re-run: if the job is already scheduled, the existing one is kept.
//   sf apex run --file scripts/apex/scheduleRenewalBatch.apex --target-org <alias>
// To run the sweep immediately instead:
//   Database.executeBatch(new RenewalTaskBatch(), 200);
System.debug('Scheduled job Id: ' + RenewalTaskBatch.scheduleDaily());
