/** Copies one dependency graph after the user has reviewed its preview. */
public with sharing class DataTrainWorker implements Queueable, Database.AllowsCallouts {
    private Id runId;
    private String rootId;
    private String rootType;
    private List<String> related;

    public DataTrainWorker(Id runId, String rootId, String rootType, List<String> related) {
        this.runId = runId; this.rootId = String.valueOf((Id) rootId); this.rootType = rootType; this.related = related;
    }

    public void execute(QueueableContext context) {
        Data_Train_Run__c run = new Data_Train_Run__c(Id = runId);
        List<String> log = new List<String>();
        try {
            DataTrainGraph.Plan plan = DataTrainGraph.build(rootType, rootId, related);
            if (!plan.ready) throw new TransferException('Plan blocked: ' + String.join(plan.blockers, '; ').left(1000));
            Integer possibleCallouts = plan.records.size() * 2;
            for (DataTrainGraph.Node node : plan.records) {
                possibleCallouts += node.categoryCount;
                if (node.publishOnline) possibleCallouts++;
            }
            if (possibleCallouts > Limits.getLimitCallouts() - Limits.getCallouts())
                throw new TransferException('Plan may exceed Apex callout limits; select fewer related records.');
            Map<String, Id> mapped = new Map<String, Id>();
            Map<String, Set<String>> deferred = new Map<String, Set<String>>();
            Boolean incomplete = false;
            Map<String, DataTrainGraph.Node> pending = new Map<String, DataTrainGraph.Node>();
            List<DataTrainGraph.Node> created = new List<DataTrainGraph.Node>();
            for (DataTrainGraph.Node node : plan.records) pending.put(node.key, node);
            while (!pending.isEmpty()) {
                DataTrainGraph.Node next;
                // Prefer a record whose every copied parent is already in the destination.
                for (DataTrainGraph.Node node : pending.values()) {
                    Boolean complete = true;
                    for (String dependency : node.lookups.values())
                        if (!mapped.containsKey(dependency)) complete = false;
                    if (complete) { next = node; break; }
                }
                // An optional lookup cycle can be created without that lookup and patched later.
                if (next == null) {
                    for (DataTrainGraph.Node node : pending.values()) {
                        Boolean requiredReady = true;
                        for (String field : node.requiredLookups)
                            if (!mapped.containsKey(node.lookups.get(field))) requiredReady = false;
                        if (requiredReady) { next = node; break; }
                    }
                }
                if (next == null) throw new TransferException('Required lookup cycle cannot be inserted.');
                Map<String, Object> body = new Map<String, Object>();
                body.putAll(next.values);
                Set<String> missingLookups = new Set<String>();
                for (String field : next.lookups.keySet()) {
                    Id targetId = mapped.get(next.lookups.get(field));
                    if (targetId != null) body.put(field, targetId);
                    else missingLookups.add(field);
                }
                deferred.put(next.key, missingLookups);
                Id destinationId;
                if (next.objectName == 'ContentDocumentLink' || next.objectName == 'ContentVersion' ||
                    next.objectName == 'Attachment') destinationId = copyBinary(next, body);
                else destinationId = call('POST', next.objectName, null, body);
                mapped.put(next.key, destinationId);
                if (next.key == rootId) run.Destination_Record_Id__c = String.valueOf(destinationId);
                created.add(next);
                pending.remove(next.key);
                log.add(next.objectName + ' ' + next.sourceId + ' → ' + destinationId);
            }
            for (DataTrainGraph.Node node : created) {
                Map<String, Object> patch = new Map<String, Object>();
                for (String field : deferred.get(node.key)) {
                    if (node.lookupUpdateable.get(field) == true) patch.put(field, mapped.get(node.lookups.get(field)));
                    else if (!node.requiredLookups.contains(field)) {
                        incomplete = true;
                        log.add(node.objectName + '.' + field + ': lookup cannot be updated; verify if preserved.');
                    }
                }
                if (!patch.isEmpty()) call('PATCH', node.objectName, mapped.get(node.key), patch);
            }
            // Category assignments belong to the new article version, before publication.
            for (DataTrainGraph.Node node : created) if (node.categoryObject != null) {
                Id oldVersionId = (Id) node.sourceId;
                List<SObject> categories = Database.query('SELECT DataCategoryGroupName, DataCategoryName FROM ' +
                    node.categoryObject + ' WHERE ParentId = :oldVersionId WITH USER_MODE LIMIT 11');
                for (SObject category : categories) {
                    call('POST', node.categoryObject, null, new Map<String, Object>{
                        'ParentId' => mapped.get(node.key),
                        'DataCategoryGroupName' => category.get('DataCategoryGroupName'),
                        'DataCategoryName' => category.get('DataCategoryName')
                    });
                }
                log.add(node.objectName + ': copied ' + categories.size() + ' category assignments.');
            }
            for (DataTrainGraph.Node node : created) if (node.publishOnline == true) {
                publish(mapped.get(node.key));
                log.add(node.objectName + ': published destination article.');
            }
            run.Status__c = incomplete ? 'Partial' : 'Completed';
            log.add('Copied ' + created.size() + ' records. Review destination validation and links.');
        } catch (Exception ex) {
            run.Status__c = 'Failed';
            log.add('Stopped: ' + ex.getMessage().left(1000));
            log.add('Records already created in the destination are not rolled back. Do not restart without checking the run log.');
        }
        run.Result__c = String.join(log, '\n').left(32000);
        update run;
    }

    private static Id call(String method, String type, Id id, Map<String, Object> body) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:Data_Train_Destination/services/data/v65.0/sobjects/' +
            EncodingUtil.urlEncode(type, 'UTF-8') + (id == null ? '' : '/' + id));
        req.setMethod(method);
        req.setHeader('Content-Type', 'application/json');
        req.setBody(JSON.serialize(body));
        req.setTimeout(30000);
        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != (method == 'POST' ? 201 : 204))
            throw new TransferException(type + ' returned ' + res.getStatusCode() + ': ' + res.getBody().left(400));
        if (method == 'PATCH') return id;
        return (Id) ((Map<String, Object>) JSON.deserializeUntyped(res.getBody())).get('id');
    }

    private static Id copyBinary(DataTrainGraph.Node node, Map<String, Object> mappedBody) {
        Integer plannedBytes = (Integer) node.values.get('ByteCount');
        Blob bytes;
        Map<String, Object> body = new Map<String, Object>();
        if (node.objectName == 'Attachment') {
            Id attachmentId = (Id) node.sourceId;
            Attachment source = [SELECT Body FROM Attachment WHERE Id = :attachmentId WITH USER_MODE LIMIT 1];
            bytes = source.Body;
            body.put('Name', node.values.get('Name'));
            body.put('ParentId', mappedBody.get('ParentId'));
            if (node.values.containsKey('Description')) body.put('Description', node.values.get('Description'));
            if (node.values.containsKey('ContentType')) body.put('ContentType', node.values.get('ContentType'));
        } else {
            Id versionId = (Id) node.values.get('VersionId');
            ContentVersion source = [SELECT VersionData FROM ContentVersion WHERE Id = :versionId WITH USER_MODE LIMIT 1];
            bytes = source.VersionData;
            body.put('Title', node.values.get('Title'));
            body.put('PathOnClient', node.values.get('PathOnClient'));
            if (node.values.containsKey('Description')) body.put('Description', node.values.get('Description'));
            if (mappedBody.containsKey('FirstPublishLocationId'))
                body.put('FirstPublishLocationId', mappedBody.get('FirstPublishLocationId'));
        }
        if (bytes == null || bytes.size() != plannedBytes || bytes.size() > DataTrainGraph.MAX_FILE_BYTES)
            throw new TransferException('File changed or exceeds safe size; transfer stopped: ' + node.sourceId);
        body.put(node.objectName == 'Attachment' ? 'Body' : 'VersionData', EncodingUtil.base64Encode(bytes));
        return call('POST', node.objectName == 'Attachment' ? 'Attachment' : 'ContentVersion', null, body);
    }

    @TestVisible private static void publish(Id versionId) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:Data_Train_Destination/services/data/v65.0/knowledgeManagement/' +
            'articleVersions/masterVersions/' + versionId);
        req.setMethod('PATCH');
        req.setHeader('Content-Type', 'application/json');
        req.setBody('{"publishStatus":"Online","versionNumber":"NextVersion"}');
        req.setTimeout(30000);
        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 204)
            throw new TransferException('Knowledge publication failed (' + res.getStatusCode() + '): ' + res.getBody().left(400));
    }

    private class TransferException extends Exception {}
}
