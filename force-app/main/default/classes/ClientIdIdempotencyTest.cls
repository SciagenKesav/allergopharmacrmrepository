/**
 * QA-32: the iPad creates call reports, planned calls and sample lines with
 * PATCH /sobjects/<Object>/Client_Id__c/<local UUID>. A retried push (lost
 * response) is an upsert of the same key and must update the same record,
 * never create a second one or move stock twice.
 */
@isTest
private class ClientIdIdempotencyTest {

    private static Decimal avail(Id lotId) { return [SELECT Available_Quantity__c FROM Sample_Lot__c WHERE Id = :lotId].Available_Quantity__c; }

    private static Call_Visit_Report__c cvrPayload(Id hcpId, String clientId, String status) {
        return new Call_Visit_Report__c(Client_Id__c = clientId, HCP__c = hcpId, Visit_Date__c = Date.today(),
            Start_Time__c = Datetime.newInstance(Date.today(), Time.newInstance(10, 0, 0, 0)), Call_Type__c = 'Detailing',
            Call_Status__c = 'Completed', Record_Status__c = status, Discussion_Summary__c = 'Same text', Signature_Captured__c = true);
    }

    @isTest static void retriedCallReportAndSampleLineUpsertsAreNoOps() {
        User rep = SciagenTestUsers.mobileRep('idrep1');
        Product__c p = SampleTestData.product('Idem SKU');
        Sample_Lot__c lot = new Sample_Lot__c(Product__c = p.Id, Lot_Number__c = 'I-1', Expiry_Date__c = Date.today().addDays(200),
            Initial_Quantity__c = 20, Available_Quantity__c = 20, Owner_User__c = rep.Id);
        insert lot;
        Test.startTest();
        System.runAs(rep) {
            Sciagen_Account__c d = SampleTestData.doctor('Dr Idem');
            String cvrKey = 'c1f0a3d2-0000-4000-8000-000000000001';
            Database.UpsertResult first = Database.upsert(cvrPayload(d.Id, cvrKey, 'Submitted'), Call_Visit_Report__c.Client_Id__c);
            System.assert(first.isCreated());
            // The same push again (the first response was lost).
            Database.UpsertResult again = Database.upsert(cvrPayload(d.Id, cvrKey, 'Submitted'), Call_Visit_Report__c.Client_Id__c);
            System.assert(again.isSuccess(), String.valueOf(again.getErrors()));
            System.assertEquals(false, again.isCreated());
            System.assertEquals(first.getId(), again.getId());

            String dropKey = 'd2f0a3d2-0000-4000-8000-000000000002';
            Sample_Drop__c line = new Sample_Drop__c(Client_Id__c = dropKey, Name = 'Sample Drop', CVR__c = first.getId(), Product__c = p.Id, Qty__c = 3, Unit_Value__c = 10, Pack_Size__c = 4);
            System.assert(Database.upsert(line, Sample_Drop__c.Client_Id__c).isCreated());
            // The iPad's retry omits CVR__c (a non-reparentable master-detail can't be written on update).
            Sample_Drop__c retry = new Sample_Drop__c(Client_Id__c = dropKey, Name = 'Sample Drop', Product__c = p.Id, Qty__c = 3, Unit_Value__c = 10.0, Pack_Size__c = 4);
            Database.UpsertResult r2 = Database.upsert(retry, Sample_Drop__c.Client_Id__c);
            System.assert(r2.isSuccess(), String.valueOf(r2.getErrors()));
            System.assertEquals(false, r2.isCreated());

            // A real change to a line already in the ledger is refused.
            Sample_Drop__c more = new Sample_Drop__c(Client_Id__c = dropKey, Product__c = p.Id, Qty__c = 30);
            System.assertEquals(false, Database.upsert(more, Sample_Drop__c.Client_Id__c, false).isSuccess());
        }
        Test.stopTest();
        System.assertEquals(1, [SELECT COUNT() FROM Call_Visit_Report__c WHERE Client_Id__c = 'c1f0a3d2-0000-4000-8000-000000000001']);
        System.assertEquals(1, [SELECT COUNT() FROM Sample_Drop__c WHERE Client_Id__c = 'd2f0a3d2-0000-4000-8000-000000000002']);
        System.assertEquals(1, [SELECT COUNT() FROM Sample_Transaction__c WHERE Sample_Lot__c = :lot.Id], 'one hand-out, one transaction');
        System.assertEquals(17, avail(lot.Id), 'stock moved once');
    }

    @isTest static void draftLineCanOnlyShrinkWithoutReAdding() {
        User rep = SciagenTestUsers.mobileRep('idrep2');
        Product__c p = SampleTestData.product('Shrink SKU');
        Product__c other = SampleTestData.product('Other SKU');
        insert new Sample_Lot__c(Product__c = p.Id, Lot_Number__c = 'S-1', Expiry_Date__c = Date.today().addDays(200),
            Initial_Quantity__c = 20, Available_Quantity__c = 20, Owner_User__c = rep.Id);
        System.runAs(rep) {
            Sciagen_Account__c d = SampleTestData.doctor('Dr Shrink');
            Call_Visit_Report__c call = SampleTestData.call(d, 'Draft');
            Sample_Drop__c line = new Sample_Drop__c(Name = 'Sample Drop', CVR__c = call.Id, Product__c = p.Id, Qty__c = 4);
            insert line;
            System.assert(Database.update(new Sample_Drop__c(Id = line.Id, Qty__c = 2), false).isSuccess(), 'fewer packs is fine');
            System.assertEquals(false, Database.update(new Sample_Drop__c(Id = line.Id, Qty__c = 9), false).isSuccess(), 'more packs must be re-added');
            System.assertEquals(false, Database.update(new Sample_Drop__c(Id = line.Id, Product__c = other.Id), false).isSuccess());
            System.assertEquals(false, Database.update(new Sample_Drop__c(Id = line.Id, Eligibility_Message__c = 'Forged by client'), false).isSuccess(), 'server-owned fields');
        }
    }

    @isTest static void plannedCallUpsertIsIdempotentAndKeysAreCaseSensitive() {
        User rep = SciagenTestUsers.mobileRep('idrep3');
        Datetime slot = SciagenTestTime.nextBusinessSlot();
        System.runAs(rep) {
            Sciagen_Account__c d = SampleTestData.doctor('Dr Plan');
            Planned_Call__c a = new Planned_Call__c(Client_Id__c = 'abc-UUID', HCP__c = d.Id, Call_DateTime__c = slot, Status__c = 'Planned');
            System.assert(Database.upsert(a, Planned_Call__c.Client_Id__c).isCreated());
            Planned_Call__c retry = new Planned_Call__c(Client_Id__c = 'abc-UUID', HCP__c = d.Id, Call_DateTime__c = slot, Status__c = 'Planned');
            System.assertEquals(false, Database.upsert(retry, Planned_Call__c.Client_Id__c).isCreated());
            Planned_Call__c differentCase = new Planned_Call__c(Client_Id__c = 'ABC-uuid', HCP__c = d.Id, Call_DateTime__c = slot, Status__c = 'Planned');
            System.assert(Database.upsert(differentCase, Planned_Call__c.Client_Id__c).isCreated(), 'Client_Id__c is case-sensitive');
        }
        System.assertEquals(2, [SELECT COUNT() FROM Planned_Call__c WHERE HCP__r.Name = 'Dr Plan']);
    }
}