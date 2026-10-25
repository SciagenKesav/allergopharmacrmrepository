@isTest
private class SciagenAccountSeederGuardTest {

    @isTest static void refusesInProduction() {
        Sciagen_Account__c keep = new Sciagen_Account__c(Name = 'Real Doctor', Type__c = 'HCP');
        insert keep;
        SciagenAccountSeeder.simulateProduction = true;
        for (Integer i = 0; i < 5; i++) {
            String error;
            try {
                if (i == 0) SciagenAccountSeeder.cleanup();
                if (i == 1) SciagenAccountSeeder.seed();
                if (i == 2) SciagenAccountSeeder.seedAllergyFocusSpecialists();
                if (i == 3) SciagenAccountSeeder.seedAllergyFocusAccountPlans();
                if (i == 4) SciagenAccountSeeder.seedTodaysMapRoute();
            } catch (SciagenAccountSeeder.SeederException e) {
                error = e.getMessage();
            }
            System.assert(error != null && error.contains('sandbox'), 'entry point ' + i + ' must refuse: ' + error);
        }
        System.assertEquals(1, [SELECT COUNT() FROM Sciagen_Account__c WHERE Id = :keep.Id], 'nothing deleted');
    }

    @isTest static void refusesWithoutModifyAllData() {
        User rep = SciagenTestUsers.mobileRep('seedrep');
        String error;
        System.runAs(rep) {
            try { SciagenAccountSeeder.cleanup(); } catch (SciagenAccountSeeder.SeederException e) { error = e.getMessage(); }
        }
        Organization org = [SELECT IsSandbox, OrganizationType FROM Organization LIMIT 1];
        String expected = (org.IsSandbox || org.OrganizationType == 'Developer Edition') ? 'Modify All Data' : 'sandbox';
        System.assert(error != null && error.contains(expected), error);
    }

    @isTest static void allowsAnAdminInANonProductionOrg() {
        Organization org = [SELECT IsSandbox, OrganizationType FROM Organization LIMIT 1];
        Boolean ok = true;
        try { SciagenAccountSeeder.requireNonProductionAdmin(); } catch (SciagenAccountSeeder.SeederException e) { ok = false; }
        System.assertEquals(org.IsSandbox || org.OrganizationType == 'Developer Edition', ok);
    }
}