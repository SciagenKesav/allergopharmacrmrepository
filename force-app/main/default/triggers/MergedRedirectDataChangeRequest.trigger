/** Re-points references to a merged (losing) HCP/HCO to the surviving record. */
trigger MergedRedirectDataChangeRequest on Data_Change_Request__c (before insert, before update) {
    MergedReferenceRedirectService.redirect(Trigger.new, new List<String>{ 'Subject_Account__c', 'Related_HCO__c' });
}