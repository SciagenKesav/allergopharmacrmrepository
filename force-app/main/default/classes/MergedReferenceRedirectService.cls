/**
 * A rep's iPad may still hold the id of a record that has since been merged away. When it pushes a
 * call report, consent or planned call against that old id, this re-points the reference to the
 * surviving record before it is saved, so nothing new ever attaches to a merged (hidden) record.
 */
public without sharing class MergedReferenceRedirectService {

    public static void redirect(List<SObject> records, List<String> fields) {
        Set<Id> refs = new Set<Id>();
        for (SObject r : records) {
            for (String f : fields) {
                Object v = r.get(f);
                if (v != null) refs.add((Id) v);
            }
        }
        if (refs.isEmpty()) return;
        Map<Id, Id> winnerOf = new Map<Id, Id>();
        for (Sciagen_Account__c a : [SELECT Id, Merged_Into__c FROM Sciagen_Account__c WHERE Id IN :refs AND Is_Merged__c = true AND Merged_Into__c != null]) {
            winnerOf.put(a.Id, a.Merged_Into__c);
        }
        if (winnerOf.isEmpty()) return;
        // Follow a chain (A merged into B, B later merged into C) to the record that survived.
        for (Integer hop = 0; hop < 5; hop++) {
            Set<Id> next = new Set<Id>();
            for (Id target : winnerOf.values()) if (!winnerOf.containsKey(target)) next.add(target);
            if (next.isEmpty()) break;
            for (Sciagen_Account__c a : [SELECT Id, Merged_Into__c FROM Sciagen_Account__c WHERE Id IN :next AND Is_Merged__c = true AND Merged_Into__c != null]) {
                winnerOf.put(a.Id, a.Merged_Into__c);
            }
        }
        for (SObject r : records) {
            for (String f : fields) {
                Object v = r.get(f);
                if (v == null) continue;
                Id cur = (Id) v;
                Integer guard = 0;
                while (winnerOf.containsKey(cur) && guard++ < 6) cur = winnerOf.get(cur);
                if (cur != (Id) v) r.put(f, cur);
            }
        }
    }
}