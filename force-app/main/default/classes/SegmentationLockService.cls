/**
 * Segmentation is locked for the month once the rep freezes that month's call
 * plan (Sciagen App Config -> Lock Segmentation On Freeze, on by default).
 * While the rep's current-month Monthly_Call_Plan__c is Frozen, changes to the
 * segmentation of their doctors -- class, potential, priority, tier, KOL, tags
 * and the per-product class -- are rejected. It opens again next month, or when
 * a Business Admin unlocks the plan. A Business Admin (Unlock_Monthly_Plans or
 * Modify All Data) can still edit a locked segment.
 */
public without sharing class SegmentationLockService {

    /** Set by code that must write segmentation regardless (e.g. duplicate merge). */
    public static Boolean bypass = false;

    private static final List<String> LOCKED_FIELDS = new List<String>{
        'Classification__c', 'Potential__c', 'Priority__c', 'Tier__c', 'Is_KOL__c', 'Tags__c', 'AIT_Preference__c'
    };

    public static void guardSegments(List<Segmentation__c> rows, Map<Id, Segmentation__c> oldMap, Boolean isDelete) {
        if (!active()) return;
        List<Segmentation__c> touched = new List<Segmentation__c>();
        for (Segmentation__c s : rows) {
            if (isDelete || oldMap == null || changed(s, oldMap.get(s.Id))) touched.add(s);
        }
        if (touched.isEmpty()) return;
        Set<Id> owners = new Set<Id>();
        for (Segmentation__c s : touched) owners.add(s.OwnerId != null ? s.OwnerId : UserInfo.getUserId());
        Map<Id, String> lockedMonth = lockedMonthByOwner(owners);
        for (Segmentation__c s : touched) {
            String month = lockedMonth.get(s.OwnerId != null ? s.OwnerId : UserInfo.getUserId());
            if (month != null) s.addError(message(month));
        }
    }

    public static void guardProducts(List<Segmentation_Product__c> rows, Map<Id, Segmentation_Product__c> oldMap, Boolean isDelete) {
        if (!active()) return;
        List<Segmentation_Product__c> touched = new List<Segmentation_Product__c>();
        Set<Id> parentIds = new Set<Id>();
        for (Segmentation_Product__c p : rows) {
            Segmentation_Product__c o = oldMap == null ? null : oldMap.get(p.Id);
            if (isDelete || o == null || p.Classification__c != o.Classification__c || p.Product__c != o.Product__c) {
                touched.add(p);
                parentIds.add(p.Segmentation__c);
            }
        }
        if (touched.isEmpty()) return;
        Map<Id, Id> ownerByParent = new Map<Id, Id>();
        for (Segmentation__c s : [SELECT Id, OwnerId FROM Segmentation__c WHERE Id IN :parentIds]) ownerByParent.put(s.Id, s.OwnerId);
        Map<Id, String> lockedMonth = lockedMonthByOwner(new Set<Id>(ownerByParent.values()));
        for (Segmentation_Product__c p : touched) {
            String month = lockedMonth.get(ownerByParent.get(p.Segmentation__c));
            if (month != null) p.addError(message(month));
        }
    }

    /** Owner -> "September 2026" for owners whose current month's plan is frozen. */
    @TestVisible
    private static Map<Id, String> lockedMonthByOwner(Set<Id> owners) {
        Map<Id, String> result = new Map<Id, String>();
        owners.remove(null);
        if (owners.isEmpty()) return result;
        Date today = Date.today();
        Map<String, Id> ownerByKey = new Map<String, Id>();
        for (Id o : owners) ownerByKey.put(MonthlyCallPlanService.planKey(o, today), o);
        String label = Datetime.newInstance(today.toStartOfMonth(), Time.newInstance(12, 0, 0, 0)).format('MMMM yyyy');
        for (Monthly_Call_Plan__c p : [SELECT Plan_Key__c FROM Monthly_Call_Plan__c
                                       WHERE Plan_Key__c IN :ownerByKey.keySet() AND Status__c = :MonthlyCallPlanService.FROZEN]) {
            result.put(ownerByKey.get(p.Plan_Key__c), label);
        }
        return result;
    }

    private static Boolean active() {
        return !bypass && SciagenAppConfig.lockSegmentationOnFreeze() && !MonthlyCallPlanService.canUnlock();
    }

    private static Boolean changed(Segmentation__c n, Segmentation__c o) {
        if (o == null) return true;
        for (String f : LOCKED_FIELDS) {
            if (n.get(f) != o.get(f)) return true;
        }
        return false;
    }

    private static String message(String month) {
        return 'Segmentation is locked for ' + month + ' because the monthly plan is frozen. '
            + 'Ask your Business Admin to unlock the plan to change it.';
    }
}