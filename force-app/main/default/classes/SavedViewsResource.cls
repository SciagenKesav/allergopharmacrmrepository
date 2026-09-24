/**
 * REST endpoint the iPad app uses to fetch Saved Views, instead of a raw
 * SOQL /query call — a plain /query is strictly bound to the authenticated
 * user's own record-level sharing with no way to elevate it, so it can never
 * see a Business Admin's shared view the way the web CRM's Apex-based
 * SciagenAccountController.getSavedViews can (that method uses a `without
 * sharing` inner class to deliberately cross that boundary for
 * Business-Admin-owned rows only — see its own doc comment for why, and why
 * a plain SOQL query can't be made to do the same thing). Delegating to that
 * exact same method here means the iPad and the web CRM can never disagree
 * about who sees what.
 *
 * GET /services/apexrest/sciagen/v1/savedViews[?since=<ISO8601 datetime>]
 */
@RestResource(urlMapping='/sciagen/v1/savedViews')
global with sharing class SavedViewsResource {

    @HttpGet
    global static void getSavedViews() {
        List<SciagenAccountController.SavedViewItem> items = SciagenAccountController.getSavedViews();

        String sinceParam = RestContext.request.params.get('since');
        if (String.isNotBlank(sinceParam)) {
            Datetime since = (Datetime) JSON.deserialize('"' + sinceParam + '"', Datetime.class);
            Set<Id> ids = new Set<Id>();
            for (SciagenAccountController.SavedViewItem item : items) { ids.add(item.id); }
            Set<Id> recentIds = new Set<Id>();
            for (Saved_Filter__c f : [SELECT Id FROM Saved_Filter__c WHERE Id IN :ids AND LastModifiedDate >= :since]) {
                recentIds.add(f.Id);
            }
            List<SciagenAccountController.SavedViewItem> filtered = new List<SciagenAccountController.SavedViewItem>();
            for (SciagenAccountController.SavedViewItem item : items) {
                if (recentIds.contains(item.id)) { filtered.add(item); }
            }
            items = filtered;
        }

        // Wrapped in an object (not a bare JSON array) — the iPad app's REST
        // layer (SalesforceRestDataService.authorizedRequest) always expects
        // a top-level JSON object back, matching every other endpoint it
        // calls (a raw array response would fail to parse there).
        RestContext.response.addHeader('Content-Type', 'application/json');
        RestContext.response.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{ 'items' => items }));
    }
}
