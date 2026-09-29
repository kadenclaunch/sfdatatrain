/** Builds a bounded, reviewable dependency graph for one source record. */
public with sharing class DataTrainGraph {
    public static final Integer MAX_RECORDS = 30;
    public static final Integer MAX_DEPTH = 3;
    public static final Integer MAX_FILE_BYTES = 2 * 1024 * 1024;
    public static final Integer MAX_TOTAL_FILE_BYTES = 5 * 1024 * 1024;
    private static final Set<String> EXTERNAL_REFERENCES = new Set<String>{
        'User', 'Group', 'RecordType', 'Profile', 'Organization', 'QueueSobject', 'BusinessHours'
    };

    public class Node {
        @AuraEnabled public String key;
        @AuraEnabled public String objectName;
        @AuraEnabled public String sourceId;
        @AuraEnabled public String reason;
        @AuraEnabled public Map<String, String> lookups = new Map<String, String>();
        @AuraEnabled public List<String> requiredLookups = new List<String>();
        public Map<String, Object> values = new Map<String, Object>();
        public Map<String, Boolean> lookupUpdateable = new Map<String, Boolean>();
        public Boolean publishOnline = false;
        public String categoryObject;
        public Integer categoryCount = 0;
    }
    public class Plan {
        @AuraEnabled public List<Node> records = new List<Node>();
        @AuraEnabled public List<String> blockers = new List<String>();
        @AuraEnabled public List<String> warnings = new List<String>();
        @AuraEnabled public Integer recordCount = 0;
        @AuraEnabled public Boolean ready;
    }

    private Plan result = new Plan();
    private Map<String, Node> byKey = new Map<String, Node>();
    private Map<String, Map<String, Object>> destinationCache = new Map<String, Map<String, Object>>();
    private Map<String, String> recordTypeCache = new Map<String, String>();
    private Integer totalFileBytes = 0;

    public static Plan build(String objectName, String rootId, List<String> relations) {
        if (String.isBlank(rootId) || !DataTrainController.isValidRecordId(rootId))
            throw new AuraHandledException('Enter a valid source record ID.');
        Schema.DescribeSObjectResult d = DataTrainController.describeLocal(objectName);
        if (((Id) rootId).getSObjectType() != Schema.getGlobalDescribe().get(objectName))
            throw new AuraHandledException('The record ID does not match the chosen object.');
        DataTrainGraph graph = new DataTrainGraph();
        graph.add((Id) rootId, objectName, 'Selected record', 0);
        if (relations == null) relations = new List<String>();
        if (relations.size() > 12) graph.result.blockers.add('Select at most 12 related lists.');
        Set<String> allowed = new Set<String>();
        for (DataTrainController.Option option : DataTrainController.related(objectName)) allowed.add(option.value);
        for (String relation : relations) {
            if (!allowed.contains(relation)) {
                graph.result.blockers.add('Unknown related list: ' + relation);
                continue;
            }
            List<String> pair = relation.split(':');
            String child = pair[0];
            String field = pair[1];
            Integer remaining = MAX_RECORDS - graph.byKey.size();
            if (remaining <= 0) {
                graph.result.blockers.add('Plan exceeds ' + MAX_RECORDS + ' records.');
                break;
            }
            // Discover one extra ID so the preview can block truncation instead of silently dropping data.
            List<SObject> children = Database.query('SELECT Id FROM ' + String.escapeSingleQuotes(child) + ' WHERE ' + String.escapeSingleQuotes(field) +
                ' = :rootId WITH USER_MODE LIMIT ' + (remaining + 1));
            if (children.size() > remaining) {
                graph.result.blockers.add(relation + ' has more records than this bounded plan can transfer.');
                continue;
            }
            for (SObject row : children) graph.add((Id) row.get('Id'), child, 'Related to selected record via ' + field, 1);
        }
        graph.result.recordCount = graph.result.records.size();
        graph.result.ready = graph.result.blockers.isEmpty() && !graph.result.records.isEmpty();
        return graph.result;
    }

    private void add(Id sourceId, String objectName, String reason, Integer depth) {
        String key = String.valueOf(sourceId);
        if (byKey.containsKey(key) || !result.blockers.isEmpty()) return;
        if (byKey.size() >= MAX_RECORDS) {
            result.blockers.add('Plan exceeds ' + MAX_RECORDS + ' records.');
            return;
        }
        Schema.DescribeSObjectResult d = DataTrainController.describeLocal(objectName);
        if (objectName == 'ContentVersion' || objectName == 'ContentDocumentLink' || objectName == 'Attachment') {
            addBinary(sourceId, objectName, reason, depth);
            return;
        }
        Map<String, Object> remote = destination(objectName);
        if (remote.get('createable') != true) {
            result.blockers.add(objectName + ' cannot be created in the destination.');
            return;
        }
        Map<String, Map<String, Object>> target = new Map<String, Map<String, Object>>();
        for (Object raw : (List<Object>) remote.get('fields')) {
            Map<String, Object> f = (Map<String, Object>) raw;
            target.put((String) f.get('name'), f);
        }
        List<String> selected = new List<String>{'Id'};
        Map<String, Schema.DescribeFieldResult> usable = new Map<String, Schema.DescribeFieldResult>();
        for (String fieldKey : d.fields.getMap().keySet()) {
            Schema.DescribeFieldResult sf = d.fields.getMap().get(fieldKey).getDescribe();
            String name = sf.getName();
            Map<String, Object> tf = target.get(name);
            if (sf.isAccessible() && tf != null && tf.get('createable') == true && name != 'Id') {
                // Binary and compound fields require object-specific API handling.
                if (sf.getType() == Schema.DisplayType.BASE64 || sf.getType() == Schema.DisplayType.ADDRESS ||
                    sf.getType() == Schema.DisplayType.LOCATION) continue;
                usable.put(name, sf);
                selected.add(name);
            }
        }
        SObject row = Database.query('SELECT ' + String.join(selected, ',') + ' FROM ' + String.escapeSingleQuotes(d.getName()) +
            ' WHERE Id = :sourceId WITH USER_MODE LIMIT 1');
        Node node = new Node();
        node.key = key; node.sourceId = key; node.objectName = objectName; node.reason = reason;
        byKey.put(key, node);
        result.records.add(node);
        for (String name : usable.keySet()) {
            Schema.DescribeFieldResult sf = usable.get(name);
            Object value = row.get(name);
            if (value == null) continue;
            if (sf.getType() != Schema.DisplayType.REFERENCE) {
                node.values.put(name, value);
                continue;
            }
            if (name == 'RecordTypeId') {
                try { node.values.put(name, destinationRecordType((Id) value, objectName)); }
                catch (Exception ex) { result.blockers.add(objectName + ' Record Type mapping failed: ' + ex.getMessage().left(200)); }
                continue;
            }
            String referenced = String.valueOf(value);
            Schema.SObjectType token;
            try { token = ((Id) referenced).getSObjectType(); }
            catch (Exception ex) { result.warnings.add(objectName + '.' + name + ': lookup ID could not be identified.'); continue; }
            String parentType = token.getDescribe().getName();
            Boolean required = target.get(name).get('nillable') == false &&
                target.get(name).get('defaultedOnCreate') == false;
            if (EXTERNAL_REFERENCES.contains(parentType)) {
                if (required) result.blockers.add(objectName + '.' + name + ' requires a destination ' + parentType + ' mapping.');
                else result.warnings.add(objectName + '.' + name + ' uses a destination default; source ' + parentType + ' is not copied.');
                continue;
            }
            if (depth >= MAX_DEPTH) {
                if (required) result.blockers.add('Required dependency exceeds depth ' + MAX_DEPTH + ': ' + objectName + '.' + name);
                else result.warnings.add('Optional lookup beyond depth ' + MAX_DEPTH + ' skipped: ' + objectName + '.' + name);
                continue;
            }
            node.lookups.put(name, referenced);
            node.lookupUpdateable.put(name, target.get(name).get('updateable') == true);
            if (required) node.requiredLookups.add(name);
            if (!byKey.containsKey(referenced)) {
                try { add((Id) referenced, parentType, 'Referenced by ' + objectName + '.' + name, depth + 1); }
                catch (Exception ex) {
                    if (required) result.blockers.add('Required parent ' + parentType + ' ' + referenced + ': ' + ex.getMessage().left(150));
                    else result.warnings.add('Optional parent ' + parentType + ' ' + referenced + ' unavailable: ' + ex.getMessage().left(150));
                    node.lookups.remove(name);
                }
            }
        }
        // These metadata-required fields can be populated only if available in the source or via a mapped lookup.
        for (String name : target.keySet()) {
            Map<String, Object> f = target.get(name);
            if (f.get('createable') == true && f.get('nillable') == false && f.get('defaultedOnCreate') == false &&
                !node.values.containsKey(name) && !node.lookups.containsKey(name))
                result.blockers.add(objectName + ' ' + key + ' is missing required destination field ' + name + '.');
        }
        if (objectName.endsWith('__kav')) inspectArticle(node, sourceId, d);
    }

    private void addBinary(Id sourceId, String objectName, String reason, Integer depth) {
        if (byKey.size() >= MAX_RECORDS) { result.blockers.add('Plan exceeds ' + MAX_RECORDS + ' records.'); return; }
        Node node = new Node();
        node.key = String.valueOf(sourceId); node.sourceId = node.key;
        node.objectName = objectName; node.reason = reason;
        Id relatedRecord;
        Integer bytes;
        if (objectName == 'Attachment') {
            Map<String, Object> attachmentTarget = destination('Attachment');
            if (attachmentTarget.get('createable') != true ||
                !hasCreateableFields(attachmentTarget, new Set<String>{'Name', 'Body', 'ParentId'})) {
                result.blockers.add('Destination does not permit Attachment creation.'); return;
            }
            Attachment attachment = [SELECT Id, ParentId, Name, Description, ContentType, BodyLength
                                     FROM Attachment WHERE Id = :sourceId WITH USER_MODE LIMIT 1];
            relatedRecord = attachment.ParentId;
            bytes = attachment.BodyLength;
            node.values.put('Name', attachment.Name);
            if (attachment.Description != null) node.values.put('Description', attachment.Description);
            if (attachment.ContentType != null) node.values.put('ContentType', attachment.ContentType);
            node.lookups.put('ParentId', String.valueOf(relatedRecord));
            node.requiredLookups.add('ParentId');
        } else {
            Map<String, Object> fileTarget = destination('ContentVersion');
            if (fileTarget.get('createable') != true ||
                !hasCreateableFields(fileTarget, new Set<String>{'Title', 'PathOnClient', 'VersionData'})) {
                result.blockers.add('Destination does not permit Salesforce File creation.'); return;
            }
            ContentVersion version;
            if (objectName == 'ContentDocumentLink') {
                ContentDocumentLink link = [SELECT ContentDocumentId, LinkedEntityId FROM ContentDocumentLink
                                            WHERE Id = :sourceId WITH USER_MODE LIMIT 1];
                relatedRecord = link.LinkedEntityId;
                version = [SELECT Id, Title, PathOnClient, Description, ContentSize, ContentLocation
                           FROM ContentVersion WHERE ContentDocumentId = :link.ContentDocumentId
                           AND IsLatest = true WITH USER_MODE LIMIT 1];
            } else {
                version = [SELECT Id, Title, PathOnClient, Description, ContentSize, ContentLocation, FirstPublishLocationId
                           FROM ContentVersion WHERE Id = :sourceId WITH USER_MODE LIMIT 1];
                relatedRecord = version.FirstPublishLocationId;
            }
            if (version.ContentLocation != 'S') {
                result.blockers.add('External or linked file content cannot be copied: ' + sourceId); return;
            }
            bytes = version.ContentSize;
            node.values.put('VersionId', String.valueOf(version.Id));
            node.values.put('Title', version.Title);
            node.values.put('PathOnClient', String.isBlank(version.PathOnClient) ? version.Title : version.PathOnClient);
            if (version.Description != null) node.values.put('Description', version.Description);
            if (relatedRecord != null) {
                if (!hasCreateableFields(fileTarget, new Set<String>{'FirstPublishLocationId'})) {
                    result.blockers.add('Destination does not permit linking new Files with FirstPublishLocationId.'); return;
                }
                node.lookups.put('FirstPublishLocationId', String.valueOf(relatedRecord));
                node.requiredLookups.add('FirstPublishLocationId');
            }
        }
        if (bytes == null || bytes > MAX_FILE_BYTES || totalFileBytes + bytes > MAX_TOTAL_FILE_BYTES) {
            result.blockers.add('File ' + sourceId + ' exceeds the 2 MB per file or 5 MB per run limit.'); return;
        }
        totalFileBytes += bytes;
        node.values.put('ByteCount', bytes);
        byKey.put(node.key, node); result.records.add(node);
        if (relatedRecord != null && !byKey.containsKey(String.valueOf(relatedRecord))) {
            if (depth >= MAX_DEPTH) result.blockers.add('File parent exceeds lookup depth.');
            else add(relatedRecord, relatedRecord.getSObjectType().getDescribe().getName(),
                     'Record linked to ' + objectName, depth + 1);
        }
    }

    private void inspectArticle(Node node, Id sourceId, Schema.DescribeSObjectResult source) {
        if (source.fields.getMap().containsKey('IsMasterLanguage')) {
            SObject article = Database.query('SELECT IsMasterLanguage, PublishStatus FROM ' + String.escapeSingleQuotes(source.getName()) +
                ' WHERE Id = :sourceId WITH USER_MODE LIMIT 1');
            if (article.get('IsMasterLanguage') == false)
                result.blockers.add('Translated Knowledge versions require a separate translation workflow.');
            node.publishOnline = article.get('PublishStatus') == 'Online';
        }
        String categories = node.objectName.replace('__kav', '__DataCategorySelection');
        Schema.SObjectType categoryType = Schema.getGlobalDescribe().get(categories);
        if (categoryType != null && categoryType.getDescribe().isQueryable()) {
            List<SObject> assigned = Database.query('SELECT Id FROM ' + String.escapeSingleQuotes(categoryType.getDescribe().getName()) +
                ' WHERE ParentId = :sourceId WITH USER_MODE LIMIT 11');
            if (assigned.size() > 10) result.blockers.add('Knowledge article has more than 10 category assignments.');
            else if (!assigned.isEmpty()) {
                node.categoryObject = categories;
                node.categoryCount = assigned.size();
                try {
                    Map<String, Object> destinationCategories = destination(categories);
                    if (destinationCategories.get('createable') != true ||
                        !hasCreateableFields(destinationCategories,
                            new Set<String>{'ParentId', 'DataCategoryGroupName', 'DataCategoryName'}))
                        result.blockers.add('Destination does not permit Knowledge category assignments.');
                } catch (Exception ex) {
                    result.blockers.add('Destination Knowledge category object is unavailable: ' + ex.getMessage().left(150));
                }
                result.warnings.add('Knowledge categories (' + assigned.size() + ') will be copied if they exist in the destination.');
            }
        } else {
            result.warnings.add('Knowledge category assignments cannot be inspected with current source permissions.');
        }
        result.warnings.add('Knowledge article will be created as a draft' +
            (node.publishOnline ? ' and then published' : '') + '. Embedded images and translations are separate content.');
    }

    private Map<String, Object> destination(String name) {
        if (!destinationCache.containsKey(name)) destinationCache.put(name, DataTrainController.destinationDescribe(name));
        return destinationCache.get(name);
    }

    private static Boolean hasCreateableFields(Map<String, Object> described, Set<String> required) {
        Set<String> found = new Set<String>();
        for (Object raw : (List<Object>) described.get('fields')) {
            Map<String, Object> field = (Map<String, Object>) raw;
            if (field.get('createable') == true) found.add((String) field.get('name'));
        }
        return found.containsAll(required);
    }

    private String destinationRecordType(Id sourceTypeId, String objectName) {
        RecordType source = [SELECT DeveloperName FROM RecordType WHERE Id = :sourceTypeId WITH USER_MODE LIMIT 1];
        String key = objectName + ':' + source.DeveloperName;
        if (recordTypeCache.containsKey(key)) return recordTypeCache.get(key);
        String soql = 'SELECT Id FROM RecordType WHERE SobjectType = \'' +
            String.escapeSingleQuotes(objectName) + '\' AND DeveloperName = \'' +
            String.escapeSingleQuotes(source.DeveloperName) + '\' LIMIT 2';
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:Data_Train_Destination/services/data/v65.0/query?q=' +
            EncodingUtil.urlEncode(soql, 'UTF-8'));
        req.setMethod('GET');
        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) throw new PlanningException('Destination Record Type query failed (' + res.getStatusCode() + ').');
        Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> matches = (List<Object>) data.get('records');
        if (matches.size() != 1) throw new PlanningException('Expected exactly one destination Record Type named ' + source.DeveloperName + '.');
        String targetId = (String) ((Map<String, Object>) matches[0]).get('Id');
        recordTypeCache.put(key, targetId);
        return targetId;
    }

    private class PlanningException extends Exception {}
}
