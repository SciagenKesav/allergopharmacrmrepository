/**
 * REST endpoint the iPad app uses to read the Promotional Item catalog
 * (Promotional_Item__c) — the list of pens, notepads, leaflets and gifts a rep
 * can hand over during a call. Read-only: the catalog is managed in Salesforce
 * (Promotional Item Admin permission set), never from the device.
 *
 * GET /services/apexrest/sciagen/v1/promotional-items
 *   [?since=<ISO 8601 datetime>]   delta sync: everything changed since then,
 *                                  INCLUDING items that are now inactive or
 *                                  expired, so the device can remove them
 *   [&activeOnly=true|false]       default true on a full fetch (no `since`):
 *                                  only items that are Active and inside their
 *                                  Valid From / Valid To window today
 *   [&itemType=Pen]                one Item_Type__c value
 *   [&search=pen]                  Name contains (case-insensitive)
 *   [&productId=a01...]            items related to one Product__c
 *
 * Response (a top-level JSON object, like every other iPad endpoint):
 *   { "success": true, "message": null, "serverTimestamp": "2026-10-05T09:00:00Z",
 *     "records": [ { "salesforceId", "name", "itemCode", "itemType", "description",
 *                    "productId", "productName", "unitCost", "maxQtyPerCall",
 *                    "active", "validFrom", "validTo", "available",
 *                    "lastModifiedDate" } ] }
 * `available` is true only when the item is Active and today falls inside its
 * validity window — the same rule PromoDropService enforces on save, so the
 * device can hide an item the server would reject. `maxQtyPerCall` null = no limit.
 * Echo `serverTimestamp` back as the next call's `since`.
 *
 * To log a drop, the app POSTs a Promo_Drop__c (CVR__c, Promotional_Item__c, Qty__c)
 * through the normal sObject REST API; PromoDropTrigger fills Item__c with the
 * item's name and rejects an unavailable item or a quantity over maxQtyPerCall.
 *
 * `with sharing` + USER_MODE: the caller needs the Promotional Item Access
 * permission set (or Promotional Item Admin) for the object and its fields.
 */
@RestResource(urlMapping='/sciagen/v1/promotional-items')
global with sharing class PromotionalItemRestService {

    global class PromotionalItemRecord {
        public String salesforceId;
        public String name;
        public String itemCode;
        public String itemType;
        public String description;
        public String productId;
        public String productName;
        public Decimal unitCost;
        public Integer maxQtyPerCall;
        public Boolean active;
        public String validFrom;          // yyyy-MM-dd
        public String validTo;            // yyyy-MM-dd
        public Boolean available;         // active and inside the validity window today
        public String lastModifiedDate;   // ISO 8601
    }

    global class CatalogResult {
        public Boolean success;
        public String message;
        public List<PromotionalItemRecord> records;
        public String serverTimestamp;
    }

    private static final Integer MAX_RECORDS = 2000;

    @HttpGet
    global static CatalogResult getCatalog() {
        CatalogResult result = new CatalogResult();
        try {
            result = doGet(RestContext.request.params);
        } catch (PromotionalItemRestException e) {
            result.success = false;
            result.message = e.getMessage();
            result.records = new List<PromotionalItemRecord>();
            RestContext.response.statusCode = 400;
        } catch (Exception e) {
            result.success = false;
            result.message = 'Could not load the promotional items: ' + e.getMessage();
            result.records = new List<PromotionalItemRecord>();
            RestContext.response.statusCode = 500;
        }
        return result;
    }

    @TestVisible
    private static CatalogResult doGet(Map<String, String> params) {
        String sinceParam = params.get('since');
        String itemType = params.get('itemType');
        String search = params.get('search');
        String productId = params.get('productId');
        String activeOnlyParam = params.get('activeOnly');

        Datetime since = null;
        if (String.isNotBlank(sinceParam)) {
            try {
                since = (Datetime) JSON.deserialize('"' + sinceParam + '"', Datetime.class);
            } catch (Exception e) {
                throw new PromotionalItemRestException('since must be an ISO 8601 datetime, e.g. 2026-10-05T09:00:00Z');
            }
        }
        if (String.isNotBlank(productId) && !(productId instanceof Id)) {
            throw new PromotionalItemRestException('productId must be a valid Salesforce Id');
        }

        // A full fetch defaults to the items a rep can use today; a delta fetch
        // returns everything that changed so removals reach the device too.
        Boolean activeOnly = since == null;
        if (String.isNotBlank(activeOnlyParam)) {
            activeOnly = activeOnlyParam.toLowerCase() == 'true';
        }

        Date today = Date.today();
        List<String> clauses = new List<String>();
        Map<String, Object> binds = new Map<String, Object>();
        if (activeOnly) {
            clauses.add('Active__c = true');
            clauses.add('(Valid_From__c = null OR Valid_From__c <= :today)');
            clauses.add('(Valid_To__c = null OR Valid_To__c >= :today)');
            binds.put('today', today);
        }
        if (since != null) {
            clauses.add('LastModifiedDate >= :since');
            binds.put('since', since);
        }
        if (String.isNotBlank(itemType)) {
            clauses.add('Item_Type__c = :itemType');
            binds.put('itemType', itemType);
        }
        if (String.isNotBlank(search)) {
            clauses.add('Name LIKE :searchLike');
            binds.put('searchLike', '%' + String.escapeSingleQuotes(search) + '%');
        }
        if (String.isNotBlank(productId)) {
            clauses.add('Product__c = :productId');
            binds.put('productId', productId);
        }

        String query = 'SELECT Id, Name, Item_Code__c, Item_Type__c, Description__c, Product__c, Product__r.Name, ' +
            'Unit_Cost__c, Max_Qty_Per_Call__c, Active__c, Valid_From__c, Valid_To__c, LastModifiedDate ' +
            'FROM Promotional_Item__c';
        if (!clauses.isEmpty()) {
            query += ' WHERE ' + String.join(clauses, ' AND ');
        }
        query += ' ORDER BY Name LIMIT ' + MAX_RECORDS;

        CatalogResult result = new CatalogResult();
        result.records = new List<PromotionalItemRecord>();
        for (Promotional_Item__c p : (List<Promotional_Item__c>) Database.queryWithBinds(query, binds, AccessLevel.USER_MODE)) {
            PromotionalItemRecord r = new PromotionalItemRecord();
            r.salesforceId = p.Id;
            r.name = p.Name;
            r.itemCode = p.Item_Code__c;
            r.itemType = p.Item_Type__c;
            r.description = p.Description__c;
            r.productId = p.Product__c;
            r.productName = p.Product__r != null ? p.Product__r.Name : null;
            r.unitCost = p.Unit_Cost__c;
            r.maxQtyPerCall = p.Max_Qty_Per_Call__c == null ? null : p.Max_Qty_Per_Call__c.intValue();
            r.active = p.Active__c;
            r.validFrom = p.Valid_From__c == null ? null : String.valueOf(p.Valid_From__c);
            r.validTo = p.Valid_To__c == null ? null : String.valueOf(p.Valid_To__c);
            r.available = p.Active__c == true
                && (p.Valid_From__c == null || p.Valid_From__c <= today)
                && (p.Valid_To__c == null || p.Valid_To__c >= today);
            r.lastModifiedDate = p.LastModifiedDate.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
            result.records.add(r);
        }
        result.success = true;
        result.serverTimestamp = Datetime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
        return result;
    }

    public class PromotionalItemRestException extends Exception {}
}
