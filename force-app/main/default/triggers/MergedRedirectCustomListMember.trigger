/** Re-points references to a merged (losing) HCP/HCO to the surviving record. */
trigger MergedRedirectCustomListMember on Custom_List_Member__c (before insert, before update) {
    MergedReferenceRedirectService.redirect(Trigger.new, new List<String>{ 'HCP__c' });
}