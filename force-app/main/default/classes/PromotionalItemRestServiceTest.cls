@isTest
private class PromotionalItemRestServiceTest {

    /// The new object/fields aren't on any profile; run as a user who gets them through
    /// a permission set, like the Promotional Item Access set does in real orgs.
    private static User testUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Business Admin' LIMIT 1];
        User u = new User(FirstName = 'Promo', LastName = 'RestTester', Alias = 'promrt', Email = 'promo.rest@sciagen-test.invalid',
            Username = 'promo.rest@sciagen-new-dev.invalid', TimeZoneSidKey = 'Asia/Kolkata', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', ProfileId = p.Id, IsActive = true);
        insert u;
        PermissionSet ps = new PermissionSet(Name = 'PromoRestTestAccess', Label = 'PromoRestTestAccess');
        insert ps;
        List<FieldPermissions> fps = new List<FieldPermissions>();
        for (String f : new List<String>{
            'Promotional_Item__c.Item_Code__c', 'Promotional_Item__c.Description__c', 'Promotional_Item__c.Product__c',
            'Promotional_Item__c.Unit_Cost__c', 'Promotional_Item__c.Max_Qty_Per_Call__c', 'Promotional_Item__c.Active__c',
            'Promotional_Item__c.Valid_From__c', 'Promotional_Item__c.Valid_To__c'
        }) {
            fps.add(new FieldPermissions(ParentId = ps.Id, SobjectType = f.substringBefore('.'), Field = f, PermissionsRead = true, PermissionsEdit = true));
        }
        insert fps;
        insert new List<ObjectPermissions>{
            new ObjectPermissions(ParentId = ps.Id, SobjectType = 'Promotional_Item__c', PermissionsCreate = true, PermissionsRead = true, PermissionsEdit = true, PermissionsDelete = true),
            new ObjectPermissions(ParentId = ps.Id, SobjectType = 'Product__c', PermissionsRead = true)
        };
        insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
        return u;
    }

    private static void seed() {
        insert new List<Promotional_Item__c>{
            new Promotional_Item__c(Name = 'Branded Pen', Item_Code__c = 'T-PEN', Item_Type__c = 'Pen', Active__c = true, Max_Qty_Per_Call__c = 5, Unit_Cost__c = 12.5),
            new Promotional_Item__c(Name = 'Desk Notepad', Item_Code__c = 'T-PAD', Item_Type__c = 'Notepad', Active__c = true),
            new Promotional_Item__c(Name = 'Retired Calendar', Item_Code__c = 'T-CAL', Item_Type__c = 'Calendar', Active__c = false),
            new Promotional_Item__c(Name = 'Expired Bag', Item_Code__c = 'T-BAG', Item_Type__c = 'Bag', Active__c = true, Valid_To__c = Date.today().addDays(-1)),
            new Promotional_Item__c(Name = 'Future Torch', Item_Code__c = 'T-TRC', Item_Type__c = 'Gift Item', Active__c = true, Valid_From__c = Date.today().addDays(5))
        };
    }

    private static List<String> names(PromotionalItemRestService.CatalogResult r) {
        List<String> n = new List<String>();
        for (PromotionalItemRestService.PromotionalItemRecord x : r.records) n.add(x.name);
        n.sort();
        return n;
    }

    @isTest
    static void fullFetchReturnsOnlyAvailableItems() {
        User u = testUser();
        System.runAs(u) {
            seed();
            PromotionalItemRestService.CatalogResult r = PromotionalItemRestService.doGet(new Map<String, String>());
            System.assert(r.success);
            System.assertEquals(new List<String>{ 'Branded Pen', 'Desk Notepad' }, names(r));
            PromotionalItemRestService.PromotionalItemRecord pen;
            for (PromotionalItemRestService.PromotionalItemRecord x : r.records) if (x.name == 'Branded Pen') pen = x;
            System.assertEquals('T-PEN', pen.itemCode);
            System.assertEquals(5, pen.maxQtyPerCall);
            System.assertEquals(12.5, pen.unitCost);
            System.assertEquals(true, pen.available);
            System.assertNotEquals(null, r.serverTimestamp);
        }
    }

    @isTest
    static void sinceReturnsEverythingChangedIncludingUnavailableItems() {
        User u = testUser();
        System.runAs(u) {
            seed();
            PromotionalItemRestService.CatalogResult r = PromotionalItemRestService.doGet(new Map<String, String>{ 'since' => '2000-01-01T00:00:00Z' });
            System.assertEquals(5, r.records.size());
            Integer unavailable = 0;
            for (PromotionalItemRestService.PromotionalItemRecord x : r.records) if (x.available == false) unavailable++;
            System.assertEquals(3, unavailable, 'Inactive, expired and not-yet-valid items must come back flagged unavailable');
        }
    }

    @isTest
    static void filtersByTypeSearchAndActiveOnlyOverride() {
        User u = testUser();
        System.runAs(u) {
            seed();
            System.assertEquals(new List<String>{ 'Branded Pen' },
                names(PromotionalItemRestService.doGet(new Map<String, String>{ 'itemType' => 'Pen' })));
            System.assertEquals(new List<String>{ 'Desk Notepad' },
                names(PromotionalItemRestService.doGet(new Map<String, String>{ 'search' => 'note' })));
            System.assertEquals(5, PromotionalItemRestService.doGet(new Map<String, String>{ 'activeOnly' => 'false' }).records.size());
        }
    }

    @isTest
    static void badInputIsRejectedWith400() {
        User u = testUser();
        System.runAs(u) {
            RestRequest req = new RestRequest();
            req.requestUri = '/services/apexrest/sciagen/v1/promotional-items';
            req.httpMethod = 'GET';
            req.params.put('since', 'not-a-date');
            RestContext.request = req;
            RestContext.response = new RestResponse();
            PromotionalItemRestService.CatalogResult r = PromotionalItemRestService.getCatalog();
            System.assertEquals(400, RestContext.response.statusCode);
            System.assertEquals(false, r.success);
            System.assert(r.message.contains('ISO 8601'));

            req.params.clear();
            req.params.put('productId', 'bad');
            RestContext.request = req;
            RestContext.response = new RestResponse();
            PromotionalItemRestService.getCatalog();
            System.assertEquals(400, RestContext.response.statusCode);
        }
    }

    @isTest
    static void restEntryPointReturnsTheCatalog() {
        User u = testUser();
        System.runAs(u) {
            seed();
            RestRequest req = new RestRequest();
            req.requestUri = '/services/apexrest/sciagen/v1/promotional-items';
            req.httpMethod = 'GET';
            RestContext.request = req;
            RestContext.response = new RestResponse();
            PromotionalItemRestService.CatalogResult r = PromotionalItemRestService.getCatalog();
            System.assertEquals(true, r.success);
            System.assertEquals(2, r.records.size());
        }
    }
}