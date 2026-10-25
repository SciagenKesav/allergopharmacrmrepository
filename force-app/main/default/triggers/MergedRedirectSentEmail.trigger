/** Re-points references to a merged (losing) HCP/HCO to the surviving record. */
trigger MergedRedirectSentEmail on Sent_Email__c (before insert, before update) {
    MergedReferenceRedirectService.redirect(Trigger.new, new List<String>{ 'HCP__c' });
}