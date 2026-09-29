@IsTest
private class DataTrainGraphTest {
    private class DestinationMock implements HttpCalloutMock {
        public Boolean publicationCalled = false;
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            String url = request.getEndpoint();
            if (url.endsWith('/sobjects/Account/describe')) {
                response.setStatusCode(200);
                response.setBody('{"createable":true,"fields":[{"name":"Name","createable":true,"updateable":true,"nillable":false,"defaultedOnCreate":false},{"name":"ParentId","createable":true,"updateable":true,"nillable":true,"defaultedOnCreate":false},{"name":"OwnerId","createable":true,"updateable":true,"nillable":true,"defaultedOnCreate":true}]}');
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
                Assert.isTrue(request.getBody().contains('"publishStatus":"Online"'), 'Publication must request Online status.');
                publicationCalled = true;
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
        Assert.areEqual((Id) '001000000000001', (Id) result.Destination_Record_Id__c, 'Destination IDs should match in either format.');
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
        DestinationMock mock = new DestinationMock();
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        DataTrainWorker.publish(UserInfo.getUserId());
        Test.stopTest();
        Assert.isTrue(mock.publicationCalled, 'The publication endpoint must be called.');
    }
    @IsTest
    static void rejectsMalformedRecordId() {
        Test.startTest();
        try {
            DataTrainGraph.build('Account', 'not-an-id', null);
            Assert.fail('Malformed IDs must be rejected before discovery.');
        } catch (AuraHandledException ex) {
            Assert.isNotNull(ex, 'Invalid input should produce a handled error.');
        }
        Test.stopTest();
    }

    @IsTest
    static void rejectsMismatchedObject() {
        Test.startTest();
        try {
            DataTrainGraph.build('Account', UserInfo.getUserId(), null);
            Assert.fail('A User ID must not be accepted as an Account.');
        } catch (AuraHandledException ex) {
            Assert.isNotNull(ex, 'Mismatched object should produce a handled error.');
        }
        Test.stopTest();
    }

    @IsTest
    static void previewsCanonicalFieldNames() {
        Test.setMock(HttpCalloutMock.class, new DestinationMock());
        Test.startTest();
        DataTrainController.Preview preview = DataTrainController.preview('Account', null);
        List<DataTrainController.Option> objects = DataTrainController.objects();
        Test.stopTest();
        Assert.isTrue(preview.supported, 'Account Name should match the destination metadata.');
        Assert.isTrue(preview.fields.contains('Name'), 'Preserve canonical field capitalization.');
        Assert.areEqual(0, preview.missingRequired.size(), 'Account Name must not be omitted.');
        Set<String> names = new Set<String>();
        for (DataTrainController.Option option : objects) {
            names.add(option.value);
        }
        Assert.isTrue(names.contains('Account'), 'Readable standard objects should be offered.');
    }

    @IsTest
    static void startsAndReportsCompletedRun() {
        Account account = new Account(Name = 'Controller transfer');
        insert account;
        Test.setMock(HttpCalloutMock.class, new DestinationMock());
        Test.startTest();
        DataTrainGraph.Plan plan = DataTrainController.plan('Account', account.Id, null);
        Id runId = DataTrainController.start(account.Id, 'Account', null);
        Test.stopTest();
        Assert.isTrue(plan.ready, 'A complete account should be ready.');
        Assert.areEqual(1, plan.recordCount, 'Only the selected account is included.');
        Data_Train_Run__c status = DataTrainController.status(runId);
        Assert.areEqual('Completed', status.Status__c, status.Result__c);
    }

    @IsTest
    static void rejectsUnknownRelationship() {
        Test.startTest();
        try {
            DataTrainController.start(UserInfo.getUserId(), 'User', new List<String>{'Account:InvalidField'});
            Assert.fail('Unrecognized relationships must be rejected before callouts.');
        } catch (AuraHandledException ex) {
            Assert.isNotNull(ex, 'Invalid relationship must raise a handled error.');
        }
        Test.stopTest();
    }

    @IsTest
    static void rejectsNullRecordId() {
        Test.startTest();
        Assert.isFalse(DataTrainController.isValidRecordId(null), 'Null IDs are invalid.');
        Test.stopTest();
    }

    @IsTest
    static void boundsParentTraversal() {
        Account first = new Account(Name = 'First');
        insert first;
        Account second = new Account(Name = 'Second', ParentId = first.Id);
        insert second;
        Account third = new Account(Name = 'Third', ParentId = second.Id);
        insert third;
        Account fourth = new Account(Name = 'Fourth', ParentId = third.Id);
        insert fourth;
        Account fifth = new Account(Name = 'Fifth', ParentId = fourth.Id);
        insert fifth;
        Test.setMock(HttpCalloutMock.class, new DestinationMock());
        Test.startTest();
        DataTrainGraph.Plan plan = DataTrainGraph.build('Account', fifth.Id, null);
        Test.stopTest();
        Assert.areEqual(4, plan.recordCount, 'Root plus three parent levels should be included.');
        Assert.isTrue(String.join(plan.warnings, ';').contains('beyond depth'), 'Skipped parents must be reported.');
    }

    @IsTest
    static void blocksTruncatedChildList() {
        Account parent = new Account(Name = 'Large family');
        insert parent;
        List<Contact> children = new List<Contact>();
        for (Integer i = 0; i < 30; i++) {
            children.add(new Contact(LastName = 'Child ' + i, AccountId = parent.Id));
        }
        insert children;
        Test.setMock(HttpCalloutMock.class, new DestinationMock());
        Test.startTest();
        DataTrainGraph.Plan plan = DataTrainGraph.build('Account', parent.Id, new List<String>{'Contact:AccountId'});
        Test.stopTest();
        Assert.isFalse(plan.ready, 'A child list exceeding the record bound must block transfer.');
        Assert.isTrue(String.join(plan.blockers, ';').contains('more records'), 'Explain the volume limit.');
    }

    @IsTest
    static void plansSelectedFileWithParent() {
        Account parent = new Account(Name = 'File parent');
        insert parent;
        ContentVersion file = new ContentVersion(Title = 'root', PathOnClient = 'root.txt',
            VersionData = Blob.valueOf('hello'), FirstPublishLocationId = parent.Id);
        insert file;
        Test.setMock(HttpCalloutMock.class, new DestinationMock());
        Test.startTest();
        DataTrainGraph.Plan plan = DataTrainGraph.build('ContentVersion', file.Id, null);
        Test.stopTest();
        Assert.isTrue(plan.ready, String.join(plan.blockers, ';'));
        Assert.areEqual(2, plan.recordCount, 'A selected file should discover its parent.');
    }

    @IsTest
    static void blocksUnknownPlanRelationship() {
        Account parent = new Account(Name = 'Invalid relationship');
        insert parent;
        Test.setMock(HttpCalloutMock.class, new DestinationMock());
        Test.startTest();
        DataTrainGraph.Plan plan = DataTrainGraph.build('Account', parent.Id, new List<String>{'Bad:Field'});
        Test.stopTest();
        Assert.isFalse(plan.ready, 'Unknown relationships must block the plan.');
        Assert.isTrue(String.join(plan.blockers, ';').contains('Unknown related list'), 'Explain the invalid selection.');
    }

}
