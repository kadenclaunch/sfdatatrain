@IsTest
private class DataTrainGraphTest {
    private class DestinationMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            String url = request.getEndpoint();
            if (url.endsWith('/sobjects/Account/describe')) {
                response.setStatusCode(200);
                response.setBody('{"createable":true,"fields":[{"name":"Name","createable":true,"updateable":true,"nillable":false,"defaultedOnCreate":false}]}');
            } else if (url.endsWith('/sobjects/Contact/describe')) {
                response.setStatusCode(200);
                response.setBody('{"createable":true,"fields":[{"name":"LastName","createable":true,"updateable":true,"nillable":false,"defaultedOnCreate":false},{"name":"AccountId","createable":true,"updateable":true,"nillable":true,"defaultedOnCreate":false}]}');
            } else if (url.endsWith('/sobjects/ContentVersion/describe')) {
                response.setStatusCode(200);
                response.setBody('{"createable":true,"fields":[{"name":"Title","createable":true},{"name":"PathOnClient","createable":true},{"name":"VersionData","createable":true},{"name":"FirstPublishLocationId","createable":true}]}');
            } else if (url.endsWith('/sobjects/Attachment/describe')) {
                response.setStatusCode(200);
                response.setBody('{"createable":true,"fields":[{"name":"Name","createable":true},{"name":"ParentId","createable":true},{"name":"Body","createable":true}]}');
            } else if (request.getMethod() == 'POST' && url.endsWith('/sobjects/Account')) {
                response.setStatusCode(201);
                response.setBody('{"id":"001000000000001","success":true,"errors":[]}');
            } else if (request.getMethod() == 'POST' && url.endsWith('/sobjects/Contact')) {
                System.assert(request.getBody().contains('001000000000001'), 'Child must point to destination Account.');
                response.setStatusCode(201);
                response.setBody('{"id":"003000000000001","success":true,"errors":[]}');
            } else if (request.getMethod() == 'POST' && url.endsWith('/sobjects/ContentVersion')) {
                System.assert(request.getBody().contains('001000000000001'), 'File must link to destination Account.');
                System.assert(request.getBody().contains('aGVsbG8='), 'File bytes must be transferred.');
                response.setStatusCode(201);
                response.setBody('{"id":"068000000000001","success":true,"errors":[]}');
            } else if (request.getMethod() == 'POST' && url.endsWith('/sobjects/Attachment')) {
                System.assert(request.getBody().contains('001000000000001'), 'Attachment must have new parent.');
                System.assert(request.getBody().contains('b2xk'), 'Attachment bytes must be transferred.');
                response.setStatusCode(201);
                response.setBody('{"id":"00P000000000001","success":true,"errors":[]}');
            } else if (request.getMethod() == 'PATCH' && url.contains('/knowledgeManagement/articleVersions/masterVersions/')) {
                System.assert(request.getBody().contains('"publishStatus":"Online"'));
                response.setStatusCode(204);
            } else {
                response.setStatusCode(400);
                response.setBody('[{"message":"Unexpected callout"}]');
            }
            return response;
        }
    }

    @IsTest
    static void copiesAccountAndContactWithRemappedParent() {
        Account parent = new Account(Name = 'Data Train Test');
        insert parent;
        Contact child = new Contact(LastName = 'Passenger', AccountId = parent.Id);
        insert child;
        Data_Train_Run__c run = new Data_Train_Run__c(
            Source_Object__c = 'Account', Source_Record_Id__c = parent.Id,
            Status__c = 'Queued', Result__c = 'Pending');
        insert run;
        Test.setMock(HttpCalloutMock.class, new DestinationMock());
        Test.startTest();
        System.enqueueJob(new DataTrainWorker(run.Id, parent.Id, 'Account', new List<String>{'Contact:AccountId'}));
        Test.stopTest();
        Data_Train_Run__c result = [SELECT Status__c, Destination_Record_Id__c, Result__c
                                    FROM Data_Train_Run__c WHERE Id = :run.Id];
        System.assertEquals('Completed', result.Status__c, result.Result__c);
        System.assertEquals('001000000000001', result.Destination_Record_Id__c);
        System.assert(result.Result__c.contains('003000000000001'), 'Contact destination ID logged.');
    }

    @IsTest
    static void copiesFileAndLinksToDestinationAccount() {
        Account parent = new Account(Name = 'Data Train File Test');
        insert parent;
        ContentVersion file = new ContentVersion(Title = 'hello', PathOnClient = 'hello.txt',
            VersionData = Blob.valueOf('hello'), FirstPublishLocationId = parent.Id);
        insert file;
        ContentDocumentLink link = [SELECT Id FROM ContentDocumentLink WHERE LinkedEntityId = :parent.Id LIMIT 1];
        Data_Train_Run__c run = new Data_Train_Run__c(Source_Object__c = 'Account',
            Source_Record_Id__c = parent.Id, Status__c = 'Queued', Result__c = 'Pending');
        insert run;
        Test.setMock(HttpCalloutMock.class, new DestinationMock());
        Test.startTest();
        System.enqueueJob(new DataTrainWorker(run.Id, parent.Id, 'Account',
            new List<String>{'ContentDocumentLink:LinkedEntityId'}));
        Test.stopTest();
        Data_Train_Run__c result = [SELECT Status__c, Result__c FROM Data_Train_Run__c WHERE Id = :run.Id];
        System.assertEquals('Completed', result.Status__c, result.Result__c);
        System.assert(result.Result__c.contains('068000000000001'), 'Destination file version ID logged.');
    }

    @IsTest
    static void copiesLegacyAttachment() {
        Account parent = new Account(Name = 'Data Train Attachment Test');
        insert parent;
        insert new Attachment(ParentId = parent.Id, Name = 'old.txt', Body = Blob.valueOf('old'));
        Data_Train_Run__c run = new Data_Train_Run__c(Source_Object__c = 'Account',
            Source_Record_Id__c = parent.Id, Status__c = 'Queued', Result__c = 'Pending');
        insert run;
        Test.setMock(HttpCalloutMock.class, new DestinationMock());
        Test.startTest();
        System.enqueueJob(new DataTrainWorker(run.Id, parent.Id, 'Account', new List<String>{'Attachment:ParentId'}));
        Test.stopTest();
        Data_Train_Run__c result = [SELECT Status__c, Result__c FROM Data_Train_Run__c WHERE Id = :run.Id];
        System.assertEquals('Completed', result.Status__c, result.Result__c);
        System.assert(result.Result__c.contains('00P000000000001'));
    }

    @IsTest
    static void callsKnowledgePublicationEndpoint() {
        Test.setMock(HttpCalloutMock.class, new DestinationMock());
        DataTrainWorker.publish(UserInfo.getUserId());
    }
}
