/** Re-points references to a merged (losing) HCP/HCO to the surviving record. */
trigger MergedRedirectRCPALine on RCPA_Line__c (before insert, before update) {
    MergedReferenceRedirectService.redirect(Trigger.new, new List<String>{ 'Prescriber__c' });
}