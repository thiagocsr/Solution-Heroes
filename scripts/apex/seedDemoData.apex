// Demo data for the Upcoming Renewals walkthrough. Dates are relative to today,
// so the scenarios stay valid whenever the script runs. Safe to re-run: previous
// demo records (Accounts named "[Demo] ...") are removed first.
//
//   sf apex run --file scripts/apex/seedDemoData.apex --target-org <alias>
//
// Requires the Renewal_Management permission set on the running user.

final String PREFIX = '[Demo] ';
Date today = Date.today();
Id currentUserId = UserInfo.getUserId();

// --- Clean previous run (agreements first: Account lookup is delete-restricted;
//     their Tasks are deleted with them) ---
delete [SELECT Id FROM Service_Agreement__c WHERE Account__r.Name LIKE '[Demo] %'];
delete [SELECT Id FROM Account WHERE Name LIKE '[Demo] %'];
delete [SELECT Id FROM Application_Log__c];

List<Account> accounts = new List<Account>{
    new Account(Name = PREFIX + 'Acme Corp'),
    new Account(Name = PREFIX + 'Globex'),
    new Account(Name = PREFIX + 'Initech'),
    new Account(Name = PREFIX + 'Umbrella'),
    new Account(Name = PREFIX + 'Stark Industries')
};
insert accounts;

// name, account, days until end, status, renewal required, value, has manager, renewal status
List<Service_Agreement__c> agreements = new List<Service_Agreement__c>();
List<List<Object>> scenarios = new List<List<Object>>{
    // --- Qualifying (appear in the component, get a Renewal Task) ---
    new Object[]{ 'Acme Premium Support',     0, 0,  'Active', true, 48000, true,  'Not Started' }, // ends today
    new Object[]{ 'Globex Cloud Hosting',     1, 4,  'Active', true, 120000, true, 'Not Started' }, // urgent, task overdue
    new Object[]{ 'Initech Field Service',    2, 9,  'Active', true, 15500, true,  'Completed' },   // urgent, renewal done
    new Object[]{ 'Umbrella Maintenance',     3, 15, 'Active', true, 32000, true,  'In Progress' }, // already started
    new Object[]{ 'Stark Managed Network',    4, 22, 'Active', true, 250000, false, 'Not Started' }, // no manager -> owner
    new Object[]{ 'Acme Analytics License',   0, 30, 'Active', true, 9900, true,   'Not Started' }, // last day of window
    // --- Not qualifying (must NOT appear, no Task) ---
    new Object[]{ 'Globex Training Package',  1, 31, 'Active', true, 7000, true,   'Not Started' }, // day 31
    new Object[]{ 'Initech Legacy Support',   2, -3, 'Active', true, 5000, true,   'Not Started' }, // already ended
    new Object[]{ 'Umbrella Pilot',           3, 10, 'Draft', true, 3000, true,    'Not Started' }, // not Active
    new Object[]{ 'Stark Consulting Retainer',4, 12, 'Cancelled', true, 60000, true, 'Not Started' }, // not Active
    new Object[]{ 'Acme One-off Migration',   0, 8,  'Active', false, 18000, true, 'Not Started' }, // renewal not required
    new Object[]{ 'Globex Security Audit',    1, 75, 'Active', true, 22000, true,  'Not Started' }  // enters window later (batch)
};

for (List<Object> s : scenarios) {
    Date endDate = today.addDays((Integer) s[2]);
    agreements.add(
        new Service_Agreement__c(
            Name = (String) s[0],
            Account__c = accounts[(Integer) s[1]].Id,
            Start_Date__c = endDate.addYears(-1).addDays(1),
            End_Date__c = endDate,
            Status__c = (String) s[3],
            Renewal_Required__c = (Boolean) s[4],
            Agreement_Value__c = (Integer) s[5],
            Account_Manager__c = (Boolean) s[6] ? currentUserId : null
        )
    );
}
insert agreements;

// Drive renewal progress through the real flows, so agreement and Renewal Task
// stay consistent: start via the same service the component uses, complete by
// closing the Task (TaskTrigger then marks the agreement Completed).
Set<Id> startedIds = new Set<Id>();
Set<Id> completedIds = new Set<Id>();
for (Integer i = 0; i < scenarios.size(); i++) {
    String progress = (String) scenarios[i][7];
    if (progress == 'In Progress' || progress == 'Completed') {
        startedIds.add(agreements[i].Id);
    }
    if (progress == 'Completed') {
        completedIds.add(agreements[i].Id);
    }
}
new RenewalService().startRenewal(startedIds);

List<Task> tasksToComplete = [SELECT Id FROM Task WHERE WhatId IN :completedIds AND Renewal_End_Date__c != NULL];
for (Task renewalTask : tasksToComplete) {
    renewalTask.Status = 'Completed';
}
update tasksToComplete;

System.debug('Demo data created: ' + accounts.size() + ' accounts, ' + agreements.size() + ' agreements, ' +
    [SELECT COUNT() FROM Task WHERE WhatId IN :agreements AND Renewal_End_Date__c != NULL] + ' renewal tasks.');
