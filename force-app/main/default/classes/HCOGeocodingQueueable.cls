/**
 * Turns an HCO's billing address into Geolocation__c coordinates via the
 * Google Maps Geocoding API. Enqueued from SciagenAccountAddressSync.trigger
 * whenever an HCO's billing address is set or changes — Apex triggers can't
 * make synchronous callouts, so this runs async.
 *
 * Once this updates Geolocation__Latitude__s/Longitude__s, that same trigger
 * fires again and AffiliationSyncService cascades the new coordinates down
 * to every HCP whose primary affiliation points at this HCO — no separate
 * wiring needed here for that half.
 *
 * The API key lives in Geocoding_Config__mdt (Setup-configured, never
 * deployed) and is deliberately not granted to any rep-facing permission
 * set — only this system-mode Apex class ever reads it.
 */
public without sharing class HCOGeocodingQueueable implements Queueable, Database.AllowsCallouts {

    // Google's Geocoding API is called once per HCO in this loop — capping
    // at 100 keeps a single execution within the per-transaction callout
    // limit even if something enqueues a very large batch (e.g. a bulk
    // import touching many HCOs at once, not the normal one-record-at-a-time
    // edit this was built for).
    private static final Integer MAX_HCOS_PER_RUN = 100;

    private Set<Id> hcoIds;

    public HCOGeocodingQueueable(Set<Id> hcoIds) {
        this.hcoIds = hcoIds;
    }

    public void execute(QueueableContext context) {
        if (hcoIds == null || hcoIds.isEmpty()) return;

        List<Geocoding_Config__mdt> configs = [SELECT Google_Maps_API_Key__c FROM Geocoding_Config__mdt LIMIT 1];
        String apiKey = configs.isEmpty() ? null : configs[0].Google_Maps_API_Key__c;
        if (String.isBlank(apiKey)) {
            System.debug('[HCOGeocoding] No API key configured (Geocoding_Config__mdt.Default.Google_Maps_API_Key__c) — set it in Setup. Skipping ' + hcoIds.size() + ' HCO(s).');
            return;
        }

        Set<Id> idsToProcess = hcoIds;
        if (idsToProcess.size() > MAX_HCOS_PER_RUN) {
            System.debug('[HCOGeocoding] ' + idsToProcess.size() + ' HCOs requested, capping at ' + MAX_HCOS_PER_RUN + ' to stay within the callout limit for this run.');
            idsToProcess = new Set<Id>();
            Integer count = 0;
            for (Id hcoId : hcoIds) {
                if (count >= MAX_HCOS_PER_RUN) break;
                idsToProcess.add(hcoId);
                count++;
            }
        }

        List<Sciagen_Account__c> hcos = [
            SELECT Id, Billing_Street__c, Billing_City__c, Billing_State__c, Billing_Postal_Code__c, Billing_Country__c
            FROM Sciagen_Account__c
            WHERE Id IN :idsToProcess
        ];

        List<Sciagen_Account__c> toUpdate = new List<Sciagen_Account__c>();
        for (Sciagen_Account__c hco : hcos) {
            String fullAddress = buildAddress(hco);
            if (String.isBlank(fullAddress)) continue;

            HttpRequest req = new HttpRequest();
            req.setEndpoint('https://maps.googleapis.com/maps/api/geocode/json?address='
                + EncodingUtil.urlEncode(fullAddress, 'UTF-8') + '&key=' + apiKey);
            req.setMethod('GET');
            req.setTimeout(10000);

            try {
                HttpResponse res = new Http().send(req);
                if (res.getStatusCode() != 200) {
                    System.debug('[HCOGeocoding] HTTP ' + res.getStatusCode() + ' for ' + hco.Id);
                    continue;
                }
                Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                if (body.get('status') != 'OK') {
                    System.debug('[HCOGeocoding] status=' + body.get('status') + ' for ' + hco.Id + ' ("' + fullAddress + '")');
                    continue;
                }
                List<Object> results = (List<Object>) body.get('results');
                if (results == null || results.isEmpty()) continue;
                Map<String, Object> geometry = (Map<String, Object>) ((Map<String, Object>) results[0]).get('geometry');
                Map<String, Object> location = (Map<String, Object>) geometry.get('location');

                toUpdate.add(new Sciagen_Account__c(
                    Id = hco.Id,
                    Geolocation__Latitude__s = (Decimal) location.get('lat'),
                    Geolocation__Longitude__s = (Decimal) location.get('lng')
                ));
            } catch (Exception e) {
                // A bad address or a transient API failure for one HCO
                // shouldn't stop the rest of the batch, and geocoding is
                // best-effort enrichment — never worth failing the record
                // save that triggered it (already committed by the time
                // this async job runs anyway).
                System.debug('[HCOGeocoding] Exception geocoding ' + hco.Id + ': ' + e.getMessage());
            }
        }

        if (!toUpdate.isEmpty()) {
            Database.update(toUpdate, false);
        }
    }

    private static String buildAddress(Sciagen_Account__c hco) {
        List<String> parts = new List<String>();
        if (String.isNotBlank(hco.Billing_Street__c)) parts.add(hco.Billing_Street__c);
        if (String.isNotBlank(hco.Billing_City__c)) parts.add(hco.Billing_City__c);
        if (String.isNotBlank(hco.Billing_State__c)) parts.add(hco.Billing_State__c);
        if (String.isNotBlank(hco.Billing_Postal_Code__c)) parts.add(hco.Billing_Postal_Code__c);
        if (String.isNotBlank(hco.Billing_Country__c)) parts.add(hco.Billing_Country__c);
        return String.join(parts, ', ');
    }
}