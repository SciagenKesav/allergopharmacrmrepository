@isTest
private class PromoDropServiceTest {

    /// The new fields/objects aren't on any profile; run as a user who gets them
    /// through a permission set, the same way Sciagen_Mobile_App_Access does in real orgs.
    private static User testUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Business Admin' LIMIT 1];
        User u = new User(FirstName = 'Promo', LastName = 'Tester', Alias = 'promot', Email = 'promo.tester@sciagen-test.invalid',
            Username = 'promo.tester@sciagen-new-dev.invalid', TimeZoneSidKey = 'Asia/Kolkata', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', ProfileId = p.Id, IsActive = true);
        insert u;
        PermissionSet ps = new PermissionSet(Name = 'PromoDropTestAccess', Label = 'PromoDropTestAccess');
        insert ps;
        List<FieldPermissions> fps = new List<FieldPermissions>();
        for (String f : new List<String>{
            'Promotional_Item__c.Item_Code__c', 'Promotional_Item__c.Description__c', 'Promotional_Item__c.Product__c',
            'Promotional_Item__c.Unit_Cost__c', 'Promotional_Item__c.Max_Qty_Per_Call__c', 'Promotional_Item__c.Active__c',
            'Promotional_Item__c.Valid_From__c', 'Promotional_Item__c.Valid_To__c',
            'Promo_Drop__c.Promotional_Item__c'
        }) {
            fps.add(new FieldPermissions(ParentId = ps.Id, SobjectType = f.substringBefore('.'), Field = f, PermissionsRead = true, PermissionsEdit = true));
        }
        insert fps;
        insert new List<ObjectPermissions>{
            new ObjectPermissions(ParentId = ps.Id, SobjectType = 'Promotional_Item__c', PermissionsCreate = true, PermissionsRead = true, PermissionsEdit = true, PermissionsDelete = true),
            new ObjectPermissions(ParentId = ps.Id, SobjectType = 'Promo_Drop__c', PermissionsCreate = true, PermissionsRead = true, PermissionsEdit = true, PermissionsDelete = true),
            // Promo_Drop__c's Read depends on its Master-Detail parent's Read.
            new ObjectPermissions(ParentId = ps.Id, SobjectType = 'Call_Visit_Report__c', PermissionsCreate = true, PermissionsRead = true, PermissionsEdit = true, PermissionsDelete = true)
        };
        insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
        return u;
    }

    private static Id cvrId() {
        Sciagen_Account__c hcp = new Sciagen_Account__c(Type__c = 'HCP', Name = 'Dr. Promo Test', Last_Name__c = 'Test');
        insert hcp;
        Call_Visit_Report__c c = new Call_Visit_Report__c(
            HCP__c = hcp.Id, Visit_Date__c = Date.today(), Call_Type__c = 'Detailing',
            Call_Status__c = 'Completed', Record_Status__c = 'Draft');
        insert c;
        return c.Id;
    }

    @isTest
    static void catalogItemNameFillsItemText() {
        User u = testUser();
        System.runAs(u) {
            Promotional_Item__c pen = new Promotional_Item__c(Name = 'Branded Pen', Item_Type__c = 'Pen', Max_Qty_Per_Call__c = 5);
            insert pen;
            Promo_Drop__c drop = new Promo_Drop__c(CVR__c = cvrId(), Promotional_Item__c = pen.Id, Qty__c = 3);
            insert drop;
            System.assertEquals('Branded Pen', [SELECT Item__c FROM Promo_Drop__c WHERE Id = :drop.Id].Item__c);
        }
    }

    @isTest
    static void qtyOverMaxIsRejected() {
        User u = testUser();
        System.runAs(u) {
            Promotional_Item__c pen = new Promotional_Item__c(Name = 'Branded Pen', Item_Type__c = 'Pen', Max_Qty_Per_Call__c = 5);
            insert pen;
            Database.SaveResult sr = Database.insert(new Promo_Drop__c(CVR__c = cvrId(), Promotional_Item__c = pen.Id, Qty__c = 6), false);
            System.assert(!sr.isSuccess(), 'Qty above Max Qty Per Call must be rejected');
        }
    }

    @isTest
    static void inactiveItemIsRejected() {
        User u = testUser();
        System.runAs(u) {
            Promotional_Item__c old = new Promotional_Item__c(Name = 'Retired Calendar', Item_Type__c = 'Calendar', Active__c = false);
            insert old;
            Database.SaveResult sr = Database.insert(new Promo_Drop__c(CVR__c = cvrId(), Promotional_Item__c = old.Id, Qty__c = 1), false);
            System.assert(!sr.isSuccess(), 'An inactive catalog item must not be selectable');
        }
    }

    @isTest
    static void legacyTextOnlyDropStillWorksAndEmptyDropIsRejected() {
        User u = testUser();
        System.runAs(u) {
            Id id = cvrId();
            insert new Promo_Drop__c(CVR__c = id, Item__c = 'Branded pen', Qty__c = 10);
            Database.SaveResult sr = Database.insert(new Promo_Drop__c(CVR__c = id, Qty__c = 1), false);
            System.assert(!sr.isSuccess(), 'A drop with neither a catalog item nor text must be rejected');
        }
    }
}