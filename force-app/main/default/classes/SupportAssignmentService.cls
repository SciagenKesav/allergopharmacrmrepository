/** Business Admins (Support Agent permission set) and least-loaded assignment. */
public without sharing class SupportAssignmentService {

    public static final String AGENT_PERMISSION_SET = 'Sciagen_Support_Agent';

    public static Map<Id, User> agents() {
        Set<Id> ids = new Set<Id>();
        for (PermissionSetAssignment a : [
            SELECT AssigneeId FROM PermissionSetAssignment WHERE PermissionSet.Name = :AGENT_PERMISSION_SET AND Assignee.IsActive = true
        ]) ids.add(a.AssigneeId);
        return new Map<Id, User>([SELECT Id, Name FROM User WHERE Id IN :ids ORDER BY Name]);
    }

    /** Give each new request to the agent with the fewest open requests. */
    public static void autoAssign(List<Support_Request__c> rows) {
        Map<Id, User> agentMap = agents();
        if (agentMap.isEmpty()) return;
        Map<Id, Integer> load = new Map<Id, Integer>();
        for (Id a : agentMap.keySet()) load.put(a, 0);
        for (AggregateResult ar : [
            SELECT Assigned_To__c a, COUNT(Id) n FROM Support_Request__c WHERE Is_Open__c = true AND Assigned_To__c IN :agentMap.keySet() GROUP BY Assigned_To__c
        ]) load.put((Id) ar.get('a'), (Integer) ar.get('n'));
        for (Support_Request__c r : rows) {
            if (r.Assigned_To__c != null) continue;
            Id best;
            for (Id a : load.keySet()) if (best == null || load.get(a) < load.get(best)) best = a;
            r.Assigned_To__c = best;
            load.put(best, load.get(best) + 1);
        }
    }
}