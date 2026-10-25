/**
 * CVR_Detail_Priority__c (the iPad Call Report's Detailing Priority list):
 * a rep holding only Sciagen_Mobile_App_Access can create, reorder and
 * remove priorities while the call is a Draft; once it is Submitted they are
 * locked with it (CallReportLockService.guardChildren via
 * CVRDetailPriorityLockGuard), with the same exemptions as the other
 * children. Client_Id__c is the upsert key the iPad pushes on, so it must be
 * unique.
 */
@isTest
private class CVRDetailPriorityTest {

    private static User rep() { return SciagenTestUsers.mobileRep('dprep'); }

    private static Call_Visit_Report__c draftCall(User rep, String doctorName) {
        Call_Visit_Report__c c;
        System.runAs(rep) {
            Sciagen_Account__c hcp = SampleTestData.doctor(doctorName);
            c = new Call_Visit_Report__c(HCP__c = hcp.Id, Visit_Date__c = Date.today(), Start_Time__c = Datetime.now(),
                Call_Type__c = 'Detailing', Call_Status__c = 'Completed', Record_Status__c = 'Draft');
            insert c;
        }
        return c;
    }

    private static CVR_Detail_Priority__c priority(Id cvrId, String product, Integer rank, String source, String clientId) {
        return new CVR_Detail_Priority__c(CVR__c = cvrId, Product_Name__c = product, Priority__c = rank, Source__c = source,
            Time_Spent_Sec__c = source == 'CLM' ? 60 * rank : null, Slides_Shown__c = source == 'CLM' ? rank + 1 : null,
            Client_Id__c = clientId);
    }

    @isTest static void repCreatesReordersAndRemovesPrioritiesOnADraft() {
        User r = rep();
        Call_Visit_Report__c c = draftCall(r, 'Dr Priority A');
        Product__c emrok = new Product__c(Product_Code__c = 'T-CVRDPT-1', Name = 'Emrok', Brand_Name__c = 'Emrok', Level__c = 'Brand', Is_Detail_Product__c = true);
        insert emrok;
        Test.startTest();
        System.runAs(r) {
            CVR_Detail_Priority__c first = priority(c.Id, 'Emrok', 1, 'CLM', 'dp-local-1');
            first.Product__c = emrok.Id;
            CVR_Detail_Priority__c second = priority(c.Id, 'Glaritus', 2, 'CLM', 'dp-local-2');
            CVR_Detail_Priority__c third = priority(c.Id, 'Miqnaf', 3, 'Manual', 'dp-local-3');
            insert new List<CVR_Detail_Priority__c>{ first, second, third };

            // The rep drags Glaritus to the top and removes Miqnaf.
            update new List<CVR_Detail_Priority__c>{
                new CVR_Detail_Priority__c(Id = second.Id, Priority__c = 1),
                new CVR_Detail_Priority__c(Id = first.Id, Priority__c = 2)
            };
            delete third;

            // The iPad's retry after a lost response upserts on Client_Id__c instead of inserting twice.
            CVR_Detail_Priority__c retried = new CVR_Detail_Priority__c(Client_Id__c = 'dp-local-2', Product_Name__c = 'Glaritus', Priority__c = 1);
            Database.UpsertResult ur = Database.upsert(retried, CVR_Detail_Priority__c.Client_Id__c, true);
            System.assertEquals(false, ur.isCreated(), 'an existing Client_Id__c must update, not insert');
        }
        Test.stopTest();
        List<CVR_Detail_Priority__c> rows = [SELECT Product_Name__c, Priority__c, Source__c, Product__c, Name
                                             FROM CVR_Detail_Priority__c WHERE CVR__c = :c.Id ORDER BY Priority__c];
        System.assertEquals(2, rows.size());
        System.assertEquals('Glaritus', rows[0].Product_Name__c);
        System.assertEquals('Emrok', rows[1].Product_Name__c);
        System.assertEquals(emrok.Id, rows[1].Product__c);
        System.assert(rows[0].Name.startsWith('CDP-'), rows[0].Name);
    }

    @isTest static void prioritiesAreLockedOnceTheCallIsSubmitted() {
        User r = rep();
        Call_Visit_Report__c c = draftCall(r, 'Dr Priority B');
        Id lockedId;
        Test.startTest();
        System.runAs(r) {
            CVR_Detail_Priority__c p = priority(c.Id, 'Emrok', 1, 'CLM', 'dp-lock-1');
            insert p;
            lockedId = p.Id;
            update new Call_Visit_Report__c(Id = c.Id, Record_Status__c = 'Submitted');

            // Identical re-save from the iPad passes.
            update new CVR_Detail_Priority__c(Id = p.Id, Priority__c = 1, Product_Name__c = 'Emrok');
            Database.SaveResult changed = Database.update(new CVR_Detail_Priority__c(Id = p.Id, Priority__c = 2), false);
            System.assertEquals(false, changed.isSuccess(), 'reordering a submitted call must be blocked');
            System.assert(changed.getErrors()[0].getMessage().contains('Priority__c'), changed.getErrors()[0].getMessage());
            System.assertEquals(false, Database.update(new CVR_Detail_Priority__c(Id = p.Id, Product_Name__c = 'Other'), false).isSuccess());
            System.assertEquals(false, Database.delete(p.Id, false).isSuccess(), 'removing from a submitted call must be blocked');
            // Same as the other children: the iPad may still push a line after the report itself.
            System.assert(Database.insert(priority(c.Id, 'Glaritus', 2, 'Manual', 'dp-lock-2'), false).isSuccess());
        }
        Test.stopTest();
        CVR_Detail_Priority__c after = [SELECT Priority__c, Product_Name__c FROM CVR_Detail_Priority__c WHERE Id = :lockedId];
        System.assertEquals(1, after.Priority__c);
        System.assertEquals('Emrok', after.Product_Name__c);
    }

    @isTest static void supportUnlockReopensPrioritiesForEditing() {
        User r = rep();
        User agent = SciagenTestUsers.rep('dpagent', new List<String>{ 'Sciagen_Mobile_App_Access', 'Sciagen_Support_Agent' });
        Call_Visit_Report__c c = draftCall(r, 'Dr Priority C');
        CVR_Detail_Priority__c p = priority(c.Id, 'Emrok', 1, 'CLM', 'dp-unlock-1');
        Id requestId;
        System.runAs(r) {
            insert p;
            update new Call_Visit_Report__c(Id = c.Id, Record_Status__c = 'Submitted');
            requestId = SupportController.createRequest('Wrong order', 'Please unlock', 'Unlock Submitted Call', 'High', c.Id, null);
        }
        Test.startTest();
        System.runAs(agent) { SupportConsoleController.unlockCall(requestId, null); }
        Test.stopTest();
        System.runAs(r) {
            System.assert(Database.update(new CVR_Detail_Priority__c(Id = p.Id, Priority__c = 2), false).isSuccess(), 'unlocked call is editable again');
            System.assert(Database.delete(p.Id, false).isSuccess());
        }
    }

    @isTest static void modifyAllDataUserCanCorrectASubmittedCallsPriorities() {
        User r = rep();
        Call_Visit_Report__c c = draftCall(r, 'Dr Priority D');
        CVR_Detail_Priority__c p = priority(c.Id, 'Emrok', 1, 'CLM', 'dp-admin-1');
        System.runAs(r) {
            insert p;
            update new Call_Visit_Report__c(Id = c.Id, Record_Status__c = 'Submitted');
        }
        User admin = SciagenTestUsers.make('dpadmin', 'System Administrator', null, null);
        System.runAs(admin) {
            System.assert(Database.update(new CVR_Detail_Priority__c(Id = p.Id, Priority__c = 3), false).isSuccess());
        }
        System.assertEquals(3, [SELECT Priority__c FROM CVR_Detail_Priority__c WHERE Id = :p.Id].Priority__c);
    }

    @isTest static void clientIdIsUniqueAndSourceIsRestricted() {
        User r = rep();
        Call_Visit_Report__c c = draftCall(r, 'Dr Priority E');
        System.runAs(r) {
            insert priority(c.Id, 'Emrok', 1, 'CLM', 'dp-dup-1');
            Database.SaveResult dup = Database.insert(priority(c.Id, 'Glaritus', 2, 'CLM', 'dp-dup-1'), false);
            System.assertEquals(false, dup.isSuccess(), 'Client_Id__c must be unique');
            System.assertEquals(StatusCode.DUPLICATE_VALUE, dup.getErrors()[0].getStatusCode());
            // Case-sensitive: a different-case UUID is a different record.
            System.assert(Database.insert(priority(c.Id, 'Glaritus', 2, 'CLM', 'DP-DUP-1'), false).isSuccess());
            Database.SaveResult badSource = Database.insert(priority(c.Id, 'Miqnaf', 3, 'Guess', 'dp-dup-3'), false);
            System.assertEquals(false, badSource.isSuccess(), 'Source__c is a restricted picklist');
            Database.SaveResult noName = Database.insert(new CVR_Detail_Priority__c(CVR__c = c.Id, Priority__c = 4), false);
            System.assertEquals(false, noName.isSuccess(), 'Product_Name__c is required');
        }
    }
}