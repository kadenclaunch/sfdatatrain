import { LightningElement, track } from 'lwc';
import objects from '@salesforce/apex/DataTrainController.objects';
import related from '@salesforce/apex/DataTrainController.related';
import plan from '@salesforce/apex/DataTrainController.plan';
import start from '@salesforce/apex/DataTrainController.start';
import status from '@salesforce/apex/DataTrainController.status';

export default class DataTrain extends LightningElement {
    @track objects = [];
    @track relationships = [];
    objectName = '';
    recordId = '';
    selected = [];
    report = '';
    planRecords = [];
    planWarnings = [];
    canStart = false;
    busy = false;
    error = '';
    runId = '';
    runStatus = '';
    runResult = '';
    selectionVersion = 0;
    relationshipRequest = 0;
    plannedSelection = '';

    connectedCallback() {
        objects().then(result => { this.objects = [...result].sort((a, b) => a.label.localeCompare(b.label)); })
            .catch(e => { this.error = this.message(e); });
    }
    onObject(event) {
        this.objectName = event.detail.value;
        this.selected = [];
        this.invalidatePlan();
        this.relationships = [];
        const request = ++this.relationshipRequest;
        related({ parent: this.objectName }).then(result => {
            if (request !== this.relationshipRequest) return;
            this.relationships = [...result].sort((a, b) => a.label.localeCompare(b.label));
            this.selected = this.relationships.filter(option =>
                option.value === 'ContentDocumentLink:LinkedEntityId' ||
                option.value === 'Attachment:ParentId'
            ).map(option => option.value);
            this.invalidatePlan();
        }).catch(e => { if (request === this.relationshipRequest) this.error = this.message(e); });
    }
    onRecord(event) { this.recordId = event.detail.value.trim(); this.invalidatePlan(); }
    onRelated(event) { this.selected = event.detail.value; this.invalidatePlan(); }
    invalidatePlan() {
        this.selectionVersion += 1;
        this.plannedSelection = '';
        this.canStart = false;
        this.report = '';
        this.planRecords = [];
        this.planWarnings = [];
    }
    selectionKey() {
        return JSON.stringify([this.objectName, this.recordId, [...this.selected].sort()]);
    }
    async check() {
        this.busy = true; this.error = ''; this.canStart = false;
        const version = this.selectionVersion;
        const selection = this.selectionKey();
        try {
            const result = await plan({ objectName: this.objectName, rootId: this.recordId, relationships: this.selected });
            if (version !== this.selectionVersion || selection !== this.selectionKey()) return;
            this.planRecords = result.records.map((r, i) => ({
                key: r.key, number: i + 1, objectName: r.objectName,
                sourceId: r.sourceId, reason: r.reason, lookups: Object.keys(r.lookups || {}).join(', ') || 'None'
            }));
            this.planWarnings = result.warnings;
            this.canStart = result.ready;
            this.plannedSelection = result.ready ? selection : '';
            this.report = result.ready ?
                `Ready to copy ${result.recordCount} records. Review the dependencies below.` :
                `Transfer blocked: ${result.blockers.join('; ')}`;
        } catch (e) { if (version === this.selectionVersion) this.error = this.message(e); }
        finally { this.busy = false; }
    }
    async start() {
        if (!this.canStart || this.plannedSelection !== this.selectionKey()) {
            this.error = 'Build a current transfer plan before starting.';
            return;
        }
        this.busy = true; this.error = ''; this.canStart = false;
        const rootId = this.recordId;
        const objectName = this.objectName;
        const relationships = [...this.selected];
        try {
            this.runId = await start({ rootId, objectName, relationships });
            this.runStatus = 'Queued'; this.runResult = 'Refresh status to see results.';
        } catch (e) { this.error = this.message(e); }
        finally { this.busy = false; }
    }
    async refresh() {
        this.busy = true; this.error = '';
        try {
            const run = await status({ runId: this.runId });
            this.runStatus = run.Status__c; this.runResult = run.Result__c;
        } catch (e) { this.error = this.message(e); }
        finally { this.busy = false; }
    }
    message(e) { return e?.body?.message || e?.message || 'Request failed.'; }
}
