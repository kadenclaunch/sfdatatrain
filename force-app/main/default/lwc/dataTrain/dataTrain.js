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

    connectedCallback() {
        objects().then(result => { this.objects = [...result].sort((a, b) => a.label.localeCompare(b.label)); })
            .catch(e => { this.error = this.message(e); });
    }
    onObject(event) {
        this.objectName = event.detail.value;
        this.selected = []; this.planRecords = []; this.planWarnings = [];
        this.report = '';
        this.canStart = false;
        this.relationships = [];
        related({ parent: this.objectName }).then(result => {
            this.relationships = [...result].sort((a, b) => a.label.localeCompare(b.label));
            this.selected = this.relationships.filter(option =>
                option.value === 'ContentDocumentLink:LinkedEntityId' ||
                option.value === 'Attachment:ParentId'
            ).map(option => option.value);
        }).catch(e => { this.error = this.message(e); });
    }
    onRecord(event) { this.recordId = event.detail.value.trim(); this.canStart = false; this.report = ''; this.planRecords = []; }
    onRelated(event) { this.selected = event.detail.value; this.canStart = false; this.report = ''; this.planRecords = []; }
    async check() {
        this.busy = true; this.error = ''; this.canStart = false;
        try {
            const result = await plan({ objectName: this.objectName, rootId: this.recordId, relationships: this.selected });
            this.planRecords = result.records.map((r, i) => ({
                key: r.key, number: i + 1, objectName: r.objectName,
                sourceId: r.sourceId, reason: r.reason, lookups: Object.keys(r.lookups || {}).join(', ') || 'None'
            }));
            this.planWarnings = result.warnings;
            this.canStart = result.ready;
            this.report = result.ready ?
                `Ready to copy ${result.recordCount} records. Review the dependencies below.` :
                `Transfer blocked: ${result.blockers.join('; ')}`;
        } catch (e) { this.error = this.message(e); }
        finally { this.busy = false; }
    }
    async start() {
        this.busy = true; this.error = ''; this.canStart = false;
        try {
            this.runId = await start({ rootId: this.recordId, objectName: this.objectName, relationships: this.selected });
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
