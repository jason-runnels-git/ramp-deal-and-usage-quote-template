import { LightningElement, api, wire, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getUsageGrantSummary from '@salesforce/apex/RlmUsageGrantController.getUsageGrantSummary';
import quoteHasGroups from '@salesforce/apex/RlmUsageGrantController.quoteHasGroups';

export default class RlmUsageGrantSummary extends LightningElement {
    @api recordId;
    @track rows = [];
    @track isLoading = false;
    @track isExpanded = false;
    _hasGroups = false;

    @wire(quoteHasGroups, { quoteId: '$recordId' })
    wiredGroupCheck({ data }) {
        this._hasGroups = data === true;
        if (!this._hasGroups && this.recordId) this.loadGrants();
    }

    get isHidden() {
        return this._hasGroups;
    }

    async loadGrants() {
        if (!this.recordId) return;
        this.isLoading = true;
        try {
            const raw = await getUsageGrantSummary({ quoteId: this.recordId });
            this.rows = raw.map(r => this.enrichRow(r));
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Error loading usage wallet',
                message: e.body?.message || e.message,
                variant: 'error'
            }));
        } finally {
            this.isLoading = false;
        }
    }

    enrichRow(r) {
        const grantFormatted = this.formatNumber(r.totalGrant);
        const resource = r.resourceName || 'Credits';
        const period = r.billingPeriod || 'per month';
        const periodFree = `${period} free`;
        const overageFormatted = r.overageRate != null
            ? `$${r.overageRate.toFixed(3)}/unit Overage`
            : r.isTiered
                ? 'Tiered Overage rates'
                : '';
        const overagePrefix = overageFormatted ? 'then ' : '';
        return {
            ...r,
            grantFormatted,
            resourceName: resource,
            periodFree,
            overageFormatted,
            overagePrefix
        };
    }

    handleToggle() {
        this.isExpanded = !this.isExpanded;
    }

    handleRefresh() {
        this.loadGrants();
    }

    get hasRows() {
        return !this.isLoading && this.rows.length > 0;
    }

    get toggleIcon() {
        return this.isExpanded ? 'utility:chevronup' : 'utility:chevrondown';
    }

    get toggleLabel() {
        return this.isExpanded ? 'Collapse' : 'Expand';
    }

    get collapsedProductName() {
        return this.rows.length ? this.rows[0].productName : '';
    }

    get collapsedGrant() {
        return this.rows.length ? this.rows[0].grantFormatted : '';
    }

    get collapsedResourceName() {
        return this.rows.length ? this.rows[0].resourceName : '';
    }

    get collapsedPeriodFree() {
        return this.rows.length ? this.rows[0].periodFree : '';
    }

    get collapsedOveragePrefix() {
        return this.rows.length ? this.rows[0].overagePrefix : '';
    }

    get collapsedOverage() {
        return this.rows.length ? this.rows[0].overageFormatted : '';
    }

    formatNumber(val) {
        if (val == null) return '0';
        return new Intl.NumberFormat('en-US').format(val);
    }
}
