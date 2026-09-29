public with sharing class DataTrainController {
    private static final String DESTINATION = 'callout:Data_Train_Destination';
    private static final String API = '/services/data/v65.0';

    public class Option {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        public Option(String l, String v) { label = l; value = v; }
    }

    public class Preview {
        @AuraEnabled public List<String> fields = new List<String>();
        @AuraEnabled public List<String> missingRequired = new List<String>();
        @AuraEnabled public List<String> skippedReferences = new List<String>();
        @AuraEnabled public List<String> unavailableFields = new List<String>();
        @AuraEnabled public Boolean supported;
    }

    @AuraEnabled(cacheable=true)
    public static List<Option> objects() {
        List<Option> out = new List<Option>();
        for (Schema.SObjectType token : Schema.getGlobalDescribe().values()) {
            Schema.DescribeSObjectResult d = token.getDescribe();
            if (d.isAccessible() && d.isQueryable() && (!d.isCustom() || d.getName().endsWith('__kav')) &&
                d.getName() != 'Data_Train_Run__c') out.add(new Option(d.getLabel() + ' (' + d.getName() + ')', d.getName()));
        }
        return out;
    }

    @AuraEnabled(cacheable=true)
    public static List<Option> related(String parent) {
        Schema.DescribeSObjectResult d = describeLocal(parent);
        List<Option> out = new List<Option>();
        for (Schema.ChildRelationship c : d.getChildRelationships()) {
            if (c.getField() == null || c.getRelationshipName() == null) continue;
            Schema.DescribeSObjectResult child = c.getChildSObject().getDescribe();
            if (child.isAccessible() && child.isQueryable() && (!child.isCustom() || child.getName().endsWith('__kav'))) {
                String encoded = child.getName() + ':' + c.getField().getDescribe().getName();
                out.add(new Option(child.getLabel() + ' — ' + c.getRelationshipName() + ' (' + encoded + ')', encoded));
            }
        }
        return out;
    }

    @AuraEnabled
    public static Preview preview(String objectName, String parentField) {
        Schema.DescribeSObjectResult local = describeLocal(objectName);
        Map<String, Object> remote = destinationDescribe(objectName);
        return compatibleFields(local, remote, parentField);
    }

    @AuraEnabled
    public static DataTrainGraph.Plan plan(String objectName, String rootId, List<String> relationships) {
        return DataTrainGraph.build(objectName, rootId, relationships);
    }

    @AuraEnabled
    public static Id start(String rootId, String objectName, List<String> relationships) {
        Schema.DescribeSObjectResult d = describeLocal(objectName);
        if (String.isBlank(rootId) || !Id.isValid(rootId) ||
            ((Id) rootId).getSObjectType() != Schema.getGlobalDescribe().get(objectName))
            throw new AuraHandledException('Enter one source record ID for the selected object.');
        if (relationships == null) relationships = new List<String>();
        if (relationships.size() > 12) throw new AuraHandledException('Select at most 12 related lists.');
        Set<String> allowed = new Set<String>();
        for (Option option : related(objectName)) allowed.add(option.value);
        for (String relation : relationships) if (!allowed.contains(relation))
            throw new AuraHandledException('Invalid related list selection.');
        DataTrainGraph.Plan transferPlan = DataTrainGraph.build(objectName, rootId, relationships);
        if (!transferPlan.ready) throw new AuraHandledException('Transfer blocked: ' + String.join(transferPlan.blockers, '; ').left(1000));
        Data_Train_Run__c run = new Data_Train_Run__c(
            Source_Object__c = objectName, Source_Record_Id__c = rootId,
            Status__c = 'Queued', Result__c = 'Awaiting transfer.');
        insert run;
        System.enqueueJob(new DataTrainWorker(run.Id, rootId, objectName, relationships));
        return run.Id;
    }

    @AuraEnabled(cacheable=false)
    public static Data_Train_Run__c status(Id runId) {
        return [SELECT Id, Status__c, Result__c, Destination_Record_Id__c
                FROM Data_Train_Run__c WHERE Id = :runId WITH USER_MODE LIMIT 1];
    }

    public static Schema.DescribeSObjectResult describeLocal(String name) {
        Schema.SObjectType type = Schema.getGlobalDescribe().get(name);
        if (type == null) throw new AuraHandledException('Unknown source object.');
        Schema.DescribeSObjectResult d = type.getDescribe();
        if (!d.isAccessible() || !d.isQueryable()) throw new AuraHandledException('No access to source object.');
        return d;
    }

    public static Map<String, Object> destinationDescribe(String objectName) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(DESTINATION + API + '/sobjects/' + EncodingUtil.urlEncode(objectName, 'UTF-8') + '/describe');
        req.setMethod('GET');
        req.setTimeout(30000);
        HttpResponse response = new Http().send(req);
        if (response.getStatusCode() != 200)
            throw new AuraHandledException('Destination describe failed (' + response.getStatusCode() + '): ' + response.getBody().left(500));
        return (Map<String, Object>) JSON.deserializeUntyped(response.getBody());
    }

    public static Preview compatibleFields(Schema.DescribeSObjectResult source, Map<String, Object> destination, String parentField) {
        Preview result = new Preview();
        Map<String, Map<String, Object>> targetFields = new Map<String, Map<String, Object>>();
        for (Object raw : (List<Object>) destination.get('fields')) {
            Map<String, Object> field = (Map<String, Object>) raw;
            targetFields.put((String) field.get('name'), field);
        }
        Map<String, Schema.SObjectField> sourceFields = source.fields.getMap();
        for (String name : sourceFields.keySet()) {
            Schema.DescribeFieldResult sf = sourceFields.get(name).getDescribe();
            Map<String, Object> tf = targetFields.get(name);
            if (!sf.isAccessible() || !sf.isCreateable() || tf == null || tf.get('createable') != true) {
                if (sf.isAccessible() && sf.isCreateable() && tf == null) result.unavailableFields.add(name);
                continue;
            }
            if (sf.getType() == Schema.DisplayType.REFERENCE && name != parentField) {
                result.skippedReferences.add(name);
                continue;
            }
            result.fields.add(name);
        }
        // Required fields with defaults (including owner, record type, and auto-number) are handled by the destination.
        for (String name : targetFields.keySet()) {
            Map<String, Object> tf = targetFields.get(name);
            if (tf.get('createable') == true && tf.get('nillable') == false &&
                tf.get('defaultedOnCreate') == false && !result.fields.contains(name))
                result.missingRequired.add(name);
        }
        result.supported = destination.get('createable') == true && result.missingRequired.isEmpty() &&
            (parentField == null || result.fields.contains(parentField));
        result.fields.sort();
        result.missingRequired.sort();
        result.skippedReferences.sort();
        return result;
    }
}
