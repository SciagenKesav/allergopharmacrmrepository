/** Re-points references to a merged (losing) HCP/HCO to the surviving record. */
trigger MergedRedirectRCPAAudit on RCPA_Audit__c (before insert, before update) {
    MergedReferenceRedirectService.redirect(Trigger.new, new List<String>{ 'Chemist__c' });
}