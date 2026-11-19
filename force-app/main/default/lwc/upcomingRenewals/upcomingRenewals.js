import { LightningElement, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LightningConfirm from 'lightning/confirm';
import getUpcomingRenewals from '@salesforce/apex/UpcomingRenewalsController.getUpcomingRenewals';
import startRenewal from '@salesforce/apex/UpcomingRenewalsController.startRenewal';

/** Agreements ending within this many days are highlighted (matches the Task lead time). */
export const URGENT_DAYS = 10;
export const ACTION_START_RENEWAL = 'start_renewal';

const RENEWAL_IN_PROGRESS_ICON = 'utility:clock';
const RENEWAL_COMPLETED_ICON = 'utility:success';
const URGENT_ICON = 'utility:warning';

/**
 * Row actions are resolved per row so "Start Renewal" is disabled once the
 * renewal is In Progress or Completed.
 */
function getRowActions(row, doneCallback) {
    doneCallback([
        {
            label: 'Start Renewal',
            name: ACTION_START_RENEWAL,
            iconName: 'utility:play',
            disabled: row.renewalStarted
        }
    ]);
}

const COLUMNS = [
    {
        label: 'Agreement',
        fieldName: 'agreementUrl',
        type: 'url',
        typeAttributes: { label: { fieldName: 'agreementName' }, target: '_self' }
    },
    {
        label: 'Account',
        fieldName: 'accountUrl',
        type: 'url',
        typeAttributes: { label: { fieldName: 'accountName' }, target: '_self' }
    },
    {
        // date-local: Apex Date arrives as "YYYY-MM-DD"; this type renders it
        // without a time zone shift (type "date" could display the previous day).
        label: 'End Date',
        fieldName: 'endDate',
        type: 'date-local',
        typeAttributes: { year: 'numeric', month: 'short', day: '2-digit' }
    },
    {
        label: 'Days Remaining',
        fieldName: 'daysRemaining',
        type: 'number',
        cellAttributes: {
            alignment: 'left',
            class: { fieldName: 'daysRemainingClass' },
            iconName: { fieldName: 'daysRemainingIcon' }
        }
    },
    {
        label: 'Agreement Value',
        fieldName: 'agreementValue',
        type: 'currency',
        cellAttributes: { alignment: 'left' }
    },
    { label: 'Account Manager', fieldName: 'accountManagerName', type: 'text' },
    {
        label: 'Renewal Status',
        fieldName: 'renewalStatus',
        type: 'text',
        cellAttributes: { iconName: { fieldName: 'renewalStatusIcon' } }
    },
    { type: 'action', typeAttributes: { rowActions: getRowActions } }
];

/** Adds presentation-only fields to the server DTO. */
function toRow(renewal) {
    const isUrgent = renewal.daysRemaining <= URGENT_DAYS;
    return {
        ...renewal,
        agreementUrl: `/${renewal.agreementId}`,
        accountUrl: renewal.accountId ? `/${renewal.accountId}` : undefined,
        daysRemainingClass: isUrgent ? 'slds-text-color_error' : undefined,
        daysRemainingIcon: isUrgent ? URGENT_ICON : undefined,
        renewalStatusIcon: getRenewalStatusIcon(renewal)
    };
}

function getRenewalStatusIcon(renewal) {
    if (renewal.renewalCompleted) {
        return RENEWAL_COMPLETED_ICON;
    }
    return renewal.renewalStarted ? RENEWAL_IN_PROGRESS_ICON : undefined;
}

/** Extracts a readable message from Apex / wire / JS errors. */
export function reduceError(error) {
    if (!error) {
        return 'Unknown error';
    }
    if (Array.isArray(error.body)) {
        return error.body.map((entry) => entry.message).join(', ');
    }
    if (error.body && typeof error.body.message === 'string') {
        return error.body.message;
    }
    if (typeof error.message === 'string') {
        return error.message;
    }
    return 'Unknown error';
}

export default class UpcomingRenewals extends LightningElement {
    columns = COLUMNS;
    renewals = [];
    selectedRowIds = [];
    errorMessage;
    isLoading = true;
    isProcessing = false;

    wiredRenewalsResult;

    @wire(getUpcomingRenewals)
    wiredRenewals(result) {
        this.wiredRenewalsResult = result;
        const { data, error } = result;
        if (data) {
            this.renewals = data.map(toRow);
            this.errorMessage = undefined;
            this.isLoading = false;
        } else if (error) {
            this.renewals = [];
            this.errorMessage = reduceError(error);
            this.isLoading = false;
        }
    }

    get cardTitle() {
        return this.isLoading ? 'Upcoming Renewals' : `Upcoming Renewals (${this.renewals.length})`;
    }

    get hasRenewals() {
        return this.renewals.length > 0;
    }

    get isEmpty() {
        return !this.isLoading && !this.errorMessage && !this.hasRenewals;
    }

    get showSpinner() {
        return this.isLoading || this.isProcessing;
    }

    get notStartedCount() {
        return this.renewals.filter((row) => !row.renewalStarted).length;
    }

    get completedCount() {
        return this.renewals.filter((row) => row.renewalCompleted).length;
    }

    get selectedPendingRows() {
        const selected = new Set(this.selectedRowIds);
        return this.renewals.filter((row) => selected.has(row.agreementId) && !row.renewalStarted);
    }

    get startButtonLabel() {
        const count = this.selectedPendingRows.length;
        return count > 0 ? `Start Renewal (${count})` : 'Start Renewal';
    }

    get isStartDisabled() {
        return this.isProcessing || this.selectedPendingRows.length === 0;
    }

    get urgentDays() {
        return URGENT_DAYS;
    }

    handleRowSelection(event) {
        this.selectedRowIds = event.detail.selectedRows.map((row) => row.agreementId);
    }

    handleRowAction(event) {
        if (event.detail.action.name === ACTION_START_RENEWAL) {
            this.startRenewals([event.detail.row]);
        }
    }

    handleStartSelected() {
        this.startRenewals(this.selectedPendingRows);
    }

    async handleRefresh() {
        this.isLoading = true;
        try {
            await refreshApex(this.wiredRenewalsResult);
        } finally {
            this.isLoading = false;
        }
    }

    async startRenewals(rows) {
        const pendingRows = rows.filter((row) => !row.renewalStarted);
        if (pendingRows.length === 0) {
            this.showToast(
                'Nothing to start',
                'Renewal work has already started or been completed for the selected agreement.',
                'info'
            );
            return;
        }

        const confirmed = await LightningConfirm.open({
            label: 'Start Renewal',
            message: this.buildConfirmMessage(pendingRows),
            theme: 'default'
        });
        if (!confirmed) {
            return;
        }

        this.isProcessing = true;
        try {
            await startRenewal({ agreementIds: pendingRows.map((row) => row.agreementId) });
            this.showToast(
                'Renewal started',
                pendingRows.length === 1
                    ? `Renewal work started for ${pendingRows[0].agreementName}.`
                    : `Renewal work started for ${pendingRows.length} agreements.`,
                'success'
            );
            this.selectedRowIds = [];
            await refreshApex(this.wiredRenewalsResult);
        } catch (error) {
            this.showToast('Could not start renewal', reduceError(error), 'error');
        } finally {
            this.isProcessing = false;
        }
    }

    buildConfirmMessage(rows) {
        return rows.length === 1
            ? `Start renewal work for "${rows[0].agreementName}"? The Account Manager's renewal task will be set to In Progress.`
            : `Start renewal work for ${rows.length} agreements? Their renewal tasks will be set to In Progress.`;
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
