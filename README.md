# Service Agreement Renewals

First production-ready version of a renewal management solution for Service Agreements on Salesforce:

- **Identifies** agreements that need renewal attention (Apex service).
- **Creates one Renewal Task per renewal cycle** for the Account Manager, on create/update (trigger) and daily for agreements that enter the window without being edited (scheduled batch).
- **Upcoming Renewals** Lightning Web Component to review agreements and start renewal work.

| | |
|---|---|
| Apex tests | **86 passing, 100% coverage** on every class and both triggers |
| API version | 68.0 |
| Business rules | Configurable through Custom Metadata (30-day window, 10-day task lead time) |

---

## Contents

1. [Setup](#setup)
2. [How it works](#how-it-works)
3. [Data model](#data-model)
4. [Architecture](#architecture)
5. [Requirement mapping](#requirement-mapping)
6. [Assumptions](#assumptions)
7. [Key technical decisions](#key-technical-decisions)
8. [Security model](#security-model)
9. [Error handling](#error-handling)
10. [Testing strategy](#testing-strategy)
11. [Platform findings](#platform-findings)
12. [Limitations and next steps](#limitations-and-next-steps)
13. [Project structure](#project-structure)

---

## Setup

**Prerequisites:** Salesforce CLI (`sf`), an org authenticated with the CLI (Developer Edition or scratch org).

```bash
# 1. Deploy and run the local tests
sf project deploy start --source-dir force-app --target-org <alias> --test-level RunLocalTests

# 2. Grant access (required: fields deployed via metadata have no FLS on any profile)
sf org assign permset --name Renewal_Management --name Application_Log_Viewer --target-org <alias>

# 3. Schedule the daily sweep (02:00, scheduling user's time zone)
sf apex run --file scripts/apex/scheduleRenewalBatch.apex --target-org <alias>

# 4. Optional: load demo data (safe to re-run)
sf apex run --file scripts/apex/seedDemoData.apex --target-org <alias>
```

Then open **App Launcher → Renewals → Upcoming Renewals**.

To run the tests on their own: `sf apex run test --test-level RunLocalTests --code-coverage --result-format human --target-org <alias>`

> A scratch org definition is available in `config/project-scratch-def.json`.
>
> **Redeploying after the job is scheduled:** the platform locks the scheduled class **and every class it depends on** (services, selectors, logger). Abort the job first (Setup → Scheduled Jobs → *Daily Renewal Task Sync* → Del), deploy, then run `scheduleRenewalBatch.apex` again. The alternative is to enable *Allow deployments of components when corresponding Apex jobs are pending or in progress* in Deployment Settings.

### Permission sets

| Permission set | For | Grants |
|---|---|---|
| `Renewal_Management` | Account managers / renewal team | Service Agreement create/read/edit (no delete), FLS, Renewals app, tabs, controller class, read-only `Renewal_End_Date__c` on Task/Event |
| `Application_Log_Viewer` | Administrators / support | Read + View All on `Application_Log__c` |

### Demo data

`seedDemoData.apex` creates 5 `[Demo]` accounts and 12 agreements with dates relative to today:

| Scenario | Expected result |
|---|---|
| Ends today, in 4, 9, 15, 22 and 30 days (Active, renewal required) | Listed in the component; one Renewal Task each |
| Ends in 4 days | Task due date is in the past (overdue by design) |
| One agreement already started | Shows 🕒 In Progress; Task In Progress |
| One agreement whose Renewal Task was completed | Shows ✓ Completed; Start Renewal disabled |
| One agreement without Account Manager | Task assigned to the Owner; Warning in Application Logs |
| Ends in 31 days, ended 3 days ago, Draft, Cancelled, renewal not required | Not listed, no Task |
| Ends in 75 days | Not listed today; the daily batch creates its Task when it enters the window |

---

## How it works

**An agreement requires renewal attention when:**

- `Status__c = 'Active'`
- `Renewal_Required__c = true`
- `TODAY ≤ End_Date__c ≤ TODAY + 30` (both inclusive)

**Renewal Task rules** (one task per agreement per renewal cycle; the cycle is the agreement End Date, stamped on the Task as `Renewal_End_Date__c`):

| Situation when the agreement is evaluated | Action |
|---|---|
| A Renewal Task already exists for the current End Date (open **or completed**) | Nothing (this is what makes edits idempotent) |
| An **open** Renewal Task exists for a different End Date (End Date changed while work is pending) | Re-align that Task: new due date and cycle |
| No Renewal Task for this cycle | Create one, due `End_Date__c − 10` days, assigned to the Account Manager (or the Owner if the manager is blank/inactive) |
| New cycle on an agreement whose previous renewal was In Progress or Completed | Also reset `Renewal_Status__c` to Not Started |

**Renewal Status follows the current cycle's Renewal Task** (`TaskTrigger`):

| Renewal Task of the **current** cycle | Agreement `Renewal_Status__c` |
|---|---|
| Started from the component | In Progress (the Task moves to In Progress too) |
| Completed (closed) | **Completed** |
| Reopened | Back to In Progress |
| Task of a previous cycle, or a non-renewal Task | Ignored |

Completed agreements stay in the list (marked ✓) until they leave the window, typically when the renewal moves the End Date beyond the next 30 days.

**Entry points**, all applying the same rules through `RenewalTaskService`:

1. **Agreement trigger**, after insert / after update.
2. **Daily batch**, which catches agreements that enter the window just because time passed (no DML means no trigger).
3. **Upcoming Renewals component**: *Start Renewal* (row action or bulk selection, with confirmation) sets the agreement to In Progress and the open Renewal Task to In Progress. A Completed renewal is never moved back to In Progress.
4. **Task trigger**, after update: completing or reopening the current cycle's Renewal Task updates the agreement Renewal Status.

---

## Data model

**`Service_Agreement__c`**

| Field | Type | Notes |
|---|---|---|
| `Name` | Text | Agreement name |
| `Account__c` | Lookup(Account), required | Delete **restricted**: an Account with agreements cannot be deleted |
| `Start_Date__c` / `End_Date__c` | Date, required | Validation rule: End Date ≥ Start Date |
| `Status__c` | Picklist (Draft, Active, Expired, Cancelled), required | Restricted |
| `Agreement_Value__c` | Currency(16,2) | |
| `Renewal_Required__c` | Checkbox | |
| `Account_Manager__c` | Lookup(User) | Set Null on delete |
| `Renewal_Status__c` | Picklist (Not Started, In Progress, Completed) | Progress of the current renewal cycle |

Field history is tracked on End Date, Status, Renewal Required, Account Manager and Renewal Status.

**Supporting metadata**

| Component | Purpose |
|---|---|
| `Activity.Renewal_End_Date__c` (Date) | Identifies a Task as a Renewal Task **and** the cycle it belongs to. Written only by automation (read-only FLS); shown read-only on the Task layout |
| `Renewal_Setting__mdt` (record `Default`) | `Attention_Window_Days__c` = 30, `Task_Lead_Days__c` = 10 |
| `Application_Log__c` | Persistent log of automation errors and warnings (Source, Severity, Message, Record Id, Stack Trace) |
| `Renewals` Lightning app | Upcoming Renewals (App Page), Service Agreements, Accounts, Application Logs |

---

## Architecture

```
 LWC upcomingRenewals ──► UpcomingRenewalsController ──► RenewalService ──► ServiceAgreementSelector
                          (validation, error mapping)    (criteria, DTO)     (SOQL, USER_MODE)
                                                               │
 ServiceAgreementTrigger ─► ServiceAgreementTriggerHandler ─┐  │ startRenewal
 TaskTrigger ─────────────► TaskTriggerHandler ─────────────┤  │
                                                            ▼  ▼
 RenewalTaskBatch (Schedulable + Batchable) ─────────► RenewalTaskService ──► RenewalTaskSelector, UserSelector
                                                        (cycle rules, DML)     (SOQL, SYSTEM_MODE)
                                                               │
                                                        ApplicationLogger ──► Application_Log__c

 Cross-cutting: DateProvider (injectable "today"), RenewalSettings (Custom Metadata)
```

| Layer | Class | Responsibility |
|---|---|---|
| Entry | `ServiceAgreementTrigger` | One trigger per object; delegates only |
| Entry | `ServiceAgreementTriggerHandler` | Routes trigger events to services |
| Entry | `TaskTrigger` / `TaskTriggerHandler` | Renewal Task completed or reopened → agreement Renewal Status |
| Entry | `RenewalTaskBatch` | Daily sweep; reuses `RenewalTaskService` unchanged |
| Entry | `UpcomingRenewalsController` | `@AuraEnabled` boundary: input validation, user-friendly errors |
| Domain | `RenewalService` | **The renewal criteria** (in-memory and SOQL-backed), start renewal |
| Domain | `RenewalTaskService` | Renewal Task lifecycle: create, re-align, start, complete, duplicate prevention, assignee fallback |
| Data | `ServiceAgreementSelector`, `RenewalTaskSelector`, `UserSelector` | All SOQL, with explicit access mode |
| Model | `UpcomingRenewal` | DTO for the UI; Days Remaining computed server-side |
| Support | `DateProvider`, `RenewalSettings`, `ApplicationLogger` | Testable clock, configuration, persistent logging |

---

## Requirement mapping

| Requirement | Where |
|---|---|
| **1. Apex service** | `RenewalService.getUpcomingRenewals()` returns `UpcomingRenewal` DTOs (account, agreement, end date, days remaining, value, manager, renewal status). `requiresAttention()` / `filterRequiringAttention()` hold the same rule in memory |
| **2. Trigger** | `ServiceAgreementTrigger` → `RenewalTaskService.syncRenewalTasks()`. Bulk-safe: 2 queries and at most 4 DML statements (including the log write) per invocation, regardless of volume. Duplicate prevention by cycle (see [How it works](#how-it-works)) |
| **3. LWC** | `upcomingRenewals` on the *Upcoming Renewals* App Page: datatable, urgency highlighting, Start Renewal via row action or bulk selection, confirmation, toasts, refresh, empty and error states. Renewal progress (Not Started → In Progress → Completed) is visible per row; completion is driven by the Renewal Task (`TaskTrigger`) |
| **4. Date handling** | `Date` fields only; `Date.addDays()` / `Date.daysBetween()` for calendar arithmetic; `date-local` column type in the LWC; month, year and leap-year boundaries covered by tests |
| **5. Testing** | 7 test classes, 86 tests, see [Testing strategy](#testing-strategy) |

---

## Assumptions

1. **Custom object** `Service_Agreement__c` rather than the standard `ServiceContract`, so the solution does not depend on Field Service / Entitlements features or licences.
2. **Window boundaries are inclusive:** an agreement ending today (0 days) and one ending in exactly 30 days both qualify; day 31 does not.
3. **Agreements that already ended are excluded**, even if still Active: they are no longer *approaching* expiration. Closing them out is a separate process.
4. **Task due date = End Date − 10, applied literally.** If the agreement ends in fewer than 10 days, the Task is created already overdue, which signals urgency. The alternative (clamping to today) was rejected because it hides the urgency.
5. **One Renewal Task per renewal cycle**, the cycle being the End Date. A completed Task still covers its cycle. A new Task is created only when the End Date changes to a new cycle with no open Task.
6. **Assignee fallback:** if the Account Manager is blank or inactive, the Task goes to the agreement Owner (with a Warning log). If neither is an active user (e.g. a queue owner), no Task is created and an Error is logged.
7. **"Renewal work has started"** is represented by `Renewal_Status__c = In Progress` on the agreement, and the open Renewal Task also moves to In Progress. **Completing the current cycle's Renewal Task marks the renewal Completed**: the Task is where the account manager records that the work is done. Started and completed agreements **stay in the list** so the team keeps full visibility of everything ending soon. They leave it when the End Date moves beyond the window (renewal) or passes.
8. **"Today"** is the running user's local date (`Date.today()`). All fields are `Date`, so no time zone conversion is involved.
9. **Sharing:** Service Agreement OWD is Public Read/Write, assuming a collaborative renewal team. Delete is not granted: agreements are closed via Status, not deleted.
10. **Scale:** the 30-day window is expected to return tens or hundreds of records. The UI query is capped at 2,000 rows.

---

## Key technical decisions

| Decision | Why | Alternative considered |
|---|---|---|
| Cycle stamp field on the Task (`Renewal_End_Date__c`) for duplicate prevention | Source of truth lives on the Task itself, survives edits and completion, and distinguishes renewal cycles | Flag on the agreement (gets out of sync if the Task is deleted; nothing resets it next cycle); matching on Subject (fragile); "open Task exists" check (**creates duplicates after the Task is completed**) |
| Trigger evaluates every insert/update, not only changes to key fields | An agreement can enter the window by time passing; any later edit should then create the missing Task | Field-change filter (would miss that case) |
| No static recursion flag | The service is **idempotent**; re-entry (e.g. the Renewal Status reset) finds the Task and does nothing | Static flag (also suppresses legitimate re-evaluation later in the same transaction) |
| Daily scheduled batch | The trigger alone never fires for agreements nobody edits | Scheduled Flow (same rules would be duplicated in a second technology) |
| Renewal completion driven by the Renewal Task (Task trigger) | The account manager already closes the Task when the work is done; the agreement follows automatically, with no extra click. Only the **current cycle's** Task counts | A "Complete Renewal" button in the component (duplicates what the user already does on the Task) |
| Criteria in two forms (SOQL and in-memory) | The trigger already has the records (no query needed); the UI needs SOQL | A test (`getUpcomingRenewals_queryAndInMemoryCriteria_agree`) guarantees they never drift apart |
| `DateProvider` with `@TestVisible` override | `Date.today()` cannot be mocked; boundary tests need fixed dates, and the batch tests simulate time passing | Building test data relative to the real date (cannot test Feb 29 or Dec 31 deterministically) |
| Custom Metadata for 30/10 days | Changeable without code, deployable, no SOQL cost | Constants (code change needed); Custom Settings (data, not metadata) |
| Selectors with explicit access mode | Every query states its security intent | Default mode (implicit, and its behaviour changed in recent API versions, see [Platform findings](#platform-findings)) |
| Controller depends on a `RenewalService` instance | Allows replacing it with a **stub** (`System.StubProvider`) to test unexpected-error handling without test logic in production code | Test-only flags inside the controller |
| Declarative where it fits | Validation rule, Custom Metadata, permission sets, Lightning app/page, list views, field history | Apex for these would add code without benefit |
| Lookup to Account (not Master-Detail) | Agreements are financial records: no cascade delete, own sharing | Master-Detail (cascade delete, sharing inherited from Account) |

---

## Security model

| Operation | Mode | Rationale |
|---|---|---|
| UI read (`ServiceAgreementSelector.selectRequiringAttention`) | `WITH USER_MODE` + `with sharing` | Users only see what their CRUD, FLS and sharing allow |
| UI write: start renewal on the agreement | Explicit edit-permission check, current state read `USER_MODE`, then `update as user` (all-or-none) | Read-only users see the list but cannot start renewals; records deleted or hidden meanwhile are reported; the user must be allowed to edit every selected agreement |
| Renewal Task completed → agreement status | `SYSTEM_MODE` | Consequence of the assignee finishing their own Task; they may not have edit access to the agreement |
| Renewal Task create/update, Task and User lookups | `SYSTEM_MODE`, `without sharing` service | System automation: duplicate prevention must see every Renewal Task, including other users' Tasks. Nothing from these queries is returned to a user |
| Daily batch | `SYSTEM_MODE`, `without sharing` | Must process every qualifying agreement regardless of who scheduled it |
| Application logs | Inserted in `SYSTEM_MODE`; readable only with `Application_Log_Viewer` | Users causing an error do not need access to logs |

Missing access surfaces in the UI as a clear message: *"You do not have access to Service Agreements"* on read (`QueryException` from `USER_MODE`) and *"You do not have permission to start renewals"* on write (explicit permission check, which fails fast instead of relying on the platform's exception type). Tests prove that users without the permission set can neither read nor change data, and that read-only users can view the list but not start renewals.

---

## Error handling

- **Automation (trigger, batch):** partial-success DML (`allOrNone = false`). A record that cannot be processed is logged to `Application_Log__c` and does not block the save of the agreement or the processing of other records. Logs are buffered and written with a single DML statement.
- **Unexpected exceptions** in the trigger are not swallowed. A blanket catch would leave data inconsistent, so the save is rolled back and the defect is visible.
- **Batch:** chunks that fail entirely are reported to `Application_Log__c` in `finish()`.
- **UI:** the controller validates input (empty selection, more than 200 records, non-agreement Ids) and maps exceptions to friendly messages: access errors, business messages (e.g. an agreement deleted meanwhile: *refresh the list*), DML messages (e.g. a validation rule added by an admin), and a generic message for anything unexpected (internal details are not leaked).
- **Logging inside the controller is intentionally not done:** throwing `AuraHandledException` rolls back the transaction, including any log row.

---

## Testing strategy

**86 Apex tests in 7 classes, 100% coverage.** The goal is behaviour, not coverage: every rule, boundary and failure path has a dedicated, named test.

| Test class | Focus |
|---|---|
| `RenewalServiceTest` | Each criterion in isolation; window boundaries (day 0, 30, 31, yesterday); month, year and leap-year windows; configurable window; SOQL ↔ in-memory consistency; DTO fields; security (user with and without permission set) |
| `RenewalTaskServiceTest` | Task creation and assignment; non-qualifying agreements; becoming qualifying on update; **duplicate prevention** (repeated edits, completed task, End Date change with open task, new cycle, unrelated manual tasks); **bulk** (200 insert, 200 update, mixed 100/100, constant query count); assignee fallback; due-date calendar boundaries; overdue task; configurable lead time; real DML failure logging; **Task completion sync** (current cycle → Completed, reopen → In Progress, previous-cycle and non-renewal Tasks ignored, 200 Tasks completed in bulk, new cycle after Completed resets the status) |
| `RenewalTaskBatchTest` | Agreements entering the window without edits (200, time simulated); only qualifying processed; idempotent re-run; scheduling; failed-chunk logging |
| `UpcomingRenewalsControllerTest` | Read as renewal user / no-access user; start renewal (agreement + task, idempotent, a completed renewal never regresses); validation; no-access and **read-only** users (permission set built inside the test) change nothing; deleted record; DML failure and unexpected errors via **stub** |
| `ApplicationLoggerTest` | Buffering, single DML, exception capture, truncation, no-op flush |
| `RenewalSettingsTest` / `DateProviderTest` | Metadata values, fallbacks for blank/invalid config, date override |

**Principles**

- **Deterministic:** every test pins "today" (`DateProvider`) and the settings (`RenewalSettings`), so results do not depend on the run date or on admin configuration.
- **Independent of the running user's permissions:** setup and verification use `insert as system` / `WITH SYSTEM_MODE`. Security is tested explicitly with `System.runAs` and a Standard User with or without the permission set. The suite passes with no permission set assigned to the running user, which lets `RunLocalTests` deploys succeed in a fresh org.
- **Real data over mocks:** criteria, triggers and DML are tested against the database. The Stub API is used only where a real failure cannot be produced (unexpected exceptions in the controller).
- **Shared builders:** `TestDataFactory` builds a fully qualifying agreement by default, so each test changes only the attribute it is about.

**Date boundary examples covered**

| From | Window end / due date | Why it matters |
|---|---|---|
| Jan 31, 2027 + 30 days | **Mar 2**, 2027 | Crosses a 28-day February |
| Feb 10, 2028 + 30 days | **Mar 11**, 2028 (vs Mar 12 in 2027) | Leap year counts Feb 29 |
| Dec 15, 2026 + 30 days | **Jan 14**, 2027 | Year boundary |
| End Mar 5, 2028 − 10 days | **Feb 24**, 2028 | Task due date across Feb 29 |
| Feb 20 → Mar 1, 2028 | **10** days remaining | Days Remaining across Feb 29 |

---

## Platform findings

Two behaviours found and handled during development:

1. **Default access mode at API 68.0.** SOQL/DML without an explicit mode was enforced in user mode (FLS errors such as *"No such column"* in tests). All production code declares its mode explicitly, and tests use system mode for setup and verification.
2. **Activity field FLS in permission sets.** Declaring FLS as `Activity.Renewal_End_Date__c` worked on the first deploy but was **dropped** whenever the Activity field was redeployed in the same deployment. The permission set therefore lists `Task.Renewal_End_Date__c` and `Event.Renewal_End_Date__c` explicitly.

---

## Limitations and next steps

- **Logging survives only committed transactions.** A Platform Event based logger (e.g. Nebula Logger) would also capture errors from rolled-back transactions, such as controller errors.
- **Trigger bypass:** add a Custom Permission or Custom Metadata switch to bypass the automation for data migrations.
- **Notifications:** besides the standard task assignment email, a Custom Notification or Slack alert for urgent renewals.
- **Renewal outcome:** distinguish how a renewal ended (e.g. Renewed / Lost instead of a single Completed) and auto-create the next agreement on renewal.
- **Component:** filters (my agreements, urgent only), server-side pagination if volumes grow, and an Account record-page variant filtered by account.
- **Jest tests** for the LWC (not required for this assessment).
- **Configurable OWD:** move to Private sharing with sharing rules by team if required.

---

## Project structure

```
force-app/main/default/
├── applications/            Renewals Lightning app
├── classes/                 Apex services, selectors, controller, batch, tests
├── customMetadata/          Renewal_Setting.Default (30 / 10 days)
├── flexipages/              Upcoming Renewals App Page
├── layouts/                 Service Agreement, Application Log, Task (Renewal End Date)
├── lwc/upcomingRenewals/    Lightning Web Component
├── objects/                 Service_Agreement__c, Application_Log__c, Renewal_Setting__mdt, Activity field
├── permissionsets/          Renewal_Management, Application_Log_Viewer
├── tabs/                    Service Agreements, Upcoming Renewals, Application Logs
└── triggers/                ServiceAgreementTrigger, TaskTrigger
manifest/package.xml         Full component list (alternative deploy: --manifest)
scripts/apex/                scheduleRenewalBatch.apex, seedDemoData.apex
```
