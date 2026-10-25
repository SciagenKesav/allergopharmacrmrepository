/** Re-points references to a merged (losing) HCP/HCO to the surviving record. */
trigger MergedRedirectCallVisitReport on Call_Visit_Report__c (before insert, before update) {
    MergedReferenceRedirectService.redirect(Trigger.new, new List<String>{ 'HCP__c', 'HCO__c' });
}