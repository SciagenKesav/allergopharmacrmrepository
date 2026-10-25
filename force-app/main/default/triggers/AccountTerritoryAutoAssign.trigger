trigger AccountTerritoryAutoAssign on Sciagen_Account__c (after insert) {
    AccountTerritoryAutoAssignService.assignTerritories(Trigger.new);
}