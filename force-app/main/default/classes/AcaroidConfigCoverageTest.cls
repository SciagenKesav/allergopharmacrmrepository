@isTest
private class AcaroidConfigCoverageTest {

    @isTest
    static void defaultsWhenNoSettingRowExists() {
        AcaroidConfig c = AcaroidConfig.load();
        System.assertEquals(0.35, c.wPatientPotential);
        System.assertEquals('Acaroid', c.brandName);
        System.assertEquals(null, c.row);
    }

    @isTest
    static void bandAndMapScoring() {
        List<AcaroidConfig.Band> bands = new List<AcaroidConfig.Band>{ new AcaroidConfig.Band(0, 10), new AcaroidConfig.Band(50, 100), new AcaroidConfig.Band(25, 70) };
        System.assertEquals(100, AcaroidConfig.bandScore(60, bands));
        System.assertEquals(70, AcaroidConfig.bandScore(30, bands));
        System.assertEquals(10, AcaroidConfig.bandScore(null, bands));
        System.assertEquals(0, AcaroidConfig.bandScore(-5, bands));
        Map<String, Decimal> m = new Map<String, Decimal>{ 'A' => 5 };
        System.assertEquals(5, AcaroidConfig.mapScore('A', m, 1));
        System.assertEquals(1, AcaroidConfig.mapScore('B', m, 1));
        System.assertEquals(1, AcaroidConfig.mapScore(null, m, 1));
    }

    @isTest
    static void everyConfiguredFieldOverridesTheDefault() {
        Product__c p = new Product__c(Name = 'Brand Prod', Product_Code__c = 'ACB-1', Level__c = 'Brand', Brand_Name__c = 'AcaBrand');
        insert p;
        Acaroid_Scoring_Setting__c s = new Acaroid_Scoring_Setting__c(
            W_Patient_Potential__c = 0.4, W_AIT_Readiness__c = 0.3, W_Access__c = 0.2, W_Influence__c = 0.1,
            HCP_Tier_A_Min__c = 80, HCP_Tier_B_Min__c = 60, HCP_Tier_C_Min__c = 40,
            Calls_Tier_A__c = 5, Calls_Tier_B__c = 3, Calls_Tier_C__c = 2, Calls_Referral__c = 1,
            HCO_Tier1_Min_Score__c = 75, HCO_Tier2_Min_Score__c = 50,
            HCO_W_OPD__c = 0.2, HCO_W_AIT_Offered__c = 0.2, HCO_W_Depts__c = 0.2, HCO_W_Affordability__c = 0.2, HCO_W_Target_HCPs__c = 0.2,
            HCO_Dept_Points_Each__c = 20, HCO_Max_Depts__c = 5,
            HCP_Volume_Band_Table__c = '100:100;bad;x:y;10:50;;1:2:3',
            HCP_Decile_Weight__c = 0.5, HCP_Volume_Weight__c = 0.5,
            HCP_Practises_AIT_Points__c = 'SCIT:90;SLIT:bad;nocolon;;',
            HCP_Testing_Freq_Points__c = 'Regularly:80',
            HCP_SCIT_Attitude_Points__c = 'Advocate:99',
            HCP_Practises_Weight__c = 0.4, HCP_Testing_Weight__c = 0.4, HCP_Attitude_Weight__c = 0.2,
            HCP_Access_Points__c = 'Yes:90',
            HCP_Influence_Points__c = 'National:95',
            HCP_Influence_Default_Points__c = 5,
            HCP_Segment_High_Volume_Decile_Min__c = 8, HCP_Segment_High_Volume_Weekly_Min__c = 60,
            HCO_OPD_Band_Table__c = '300:90;0:5',
            HCO_AIT_Offered_Points__c = 'SCIT:95',
            HCO_AIT_Offered_Default_Points__c = 15,
            HCO_Affordability_Points__c = 'High:90',
            HCO_Target_HCP_Band_Table__c = '4:90;0:0',
            HCO_Target_HCP_Counting_Tiers__c = 'A; B ;C;',
            Active_Affiliation_Statuses__c = 'Active;Pending',
            HCP_Tier_To_Potential_Map__c = 'A:High;B:Medium;nocolon;:blank;C:',
            Experienced_Physician_Specialties__c = 'ENT Surgeon; Paediatrician;',
            Brand_Product__c = p.Id);
        insert s;

        AcaroidConfig c = AcaroidConfig.load();
        System.assertNotEquals(null, c.row);
        System.assertEquals(0.4, c.wPatientPotential);
        System.assertEquals(80, c.hcpTierAMin);
        System.assertEquals(5, c.callsTierA);
        System.assertEquals(1, c.callsReferral);
        System.assertEquals(75, c.hcoTier1MinScore);
        System.assertEquals(5, c.hcoMaxDepts);
        System.assertEquals(2, c.hcpVolumeBands.size());
        System.assertEquals(90, c.hcpPractisesAitPoints.get('SCIT'));
        System.assertEquals(95, c.hcpInfluencePoints.get('National'));
        System.assertEquals(2, c.hcoOpdBands.size());
        System.assertEquals(3, c.hcoTargetHcpCountingTiers.size());
        System.assertEquals(2, c.activeAffiliationStatuses.size());
        System.assertEquals('High', c.hcpTierToPotentialMap.get('A'));
        System.assertEquals(2, c.experiencedPhysicianSpecialties.size());
        System.assertEquals('AcaBrand', c.brandName);
    }

    @isTest
    static void brandFallsBackToNameAndBadValuesKeepDefaults() {
        Product__c p = new Product__c(Name = 'Plain Brand', Product_Code__c = 'ACB-2', Level__c = 'Brand');
        insert p;
        Acaroid_Scoring_Setting__c s = new Acaroid_Scoring_Setting__c(
            HCP_Volume_Band_Table__c = 'bad;x:y', HCP_Practises_AIT_Points__c = 'nocolon;a:b',
            HCP_Tier_To_Potential_Map__c = 'nocolon;:', HCO_Target_HCP_Counting_Tiers__c = ' ; ',
            Experienced_Physician_Specialties__c = ' ; ', Brand_Product__c = p.Id);
        insert s;
        AcaroidConfig c = AcaroidConfig.load();
        System.assertEquals('Plain Brand', c.brandName);
        System.assertEquals(4, c.hcpVolumeBands.size(), 'all-malformed table falls back to defaults');
        System.assertEquals(100, c.hcpPractisesAitPoints.get('SCIT'));
        System.assertEquals('High', c.hcpTierToPotentialMap.get('A'));
        System.assertEquals(2, c.hcoTargetHcpCountingTiers.size());
        System.assertEquals(5, c.experiencedPhysicianSpecialties.size());
    }

    @isTest
    static void invalidOrMissingBrandProductKeepsDefaultName() {
        Acaroid_Scoring_Setting__c s = new Acaroid_Scoring_Setting__c(Brand_Product__c = 'not-an-id');
        insert s;
        System.assertEquals('Acaroid', AcaroidConfig.load().brandName);
        s.Brand_Product__c = '001000000000000AAA';
        update s;
        System.assertEquals('Acaroid', AcaroidConfig.load().brandName);
    }
}
