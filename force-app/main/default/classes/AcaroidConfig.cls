/**
 * Reads Acaroid_Scoring_Setting__c (Hierarchy custom setting) with the Acaroid
 * field specification's own numbers as defaults for any field left blank —
 * mirrors SampleConfig's pattern for UCPMP_Tenant_Config__c. Every weight,
 * tier threshold, point-table value, recommended-call count and the
 * "experienced physician" specialty list is tunable from Setup > Custom
 * Settings > Acaroid Scoring Setting > Manage (or the Acaroid Scoring Model
 * tab's Weights & Thresholds panel), without an Apex change or redeploy.
 */
public with sharing class AcaroidConfig {
    /** One row of a threshold table: score `points` when the input is >= `min`. */
    public class Band {
        public Decimal minValue;
        public Decimal points;
        public Band(Decimal minValue, Decimal points) { this.minValue = minValue; this.points = points; }
    }

    // HCP sub-score weights (should sum to 1).
    public Decimal wPatientPotential = 0.35;
    public Decimal wAitReadiness = 0.30;
    public Decimal wAccess = 0.20;
    public Decimal wInfluence = 0.15;

    // HCP target tier thresholds (minimum Total Score).
    public Decimal hcpTierAMin = 70;
    public Decimal hcpTierBMin = 50;
    public Decimal hcpTierCMin = 30;
    public Integer callsTierA = 4;
    public Integer callsTierB = 2;
    public Integer callsTierC = 1;
    public Integer callsReferral = 0;

    // HCO tier thresholds (minimum Potential Score).
    public Decimal hcoTier1MinScore = 70;
    public Decimal hcoTier2MinScore = 45;

    // HCO score weights.
    public Decimal hcoWOpd = 0.30;
    public Decimal hcoWAitOffered = 0.25;
    public Decimal hcoWDepts = 0.15;
    public Decimal hcoWAffordability = 0.15;
    public Decimal hcoWTargetHcps = 0.15;
    public Integer hcoDeptPointsEach = 25;
    public Integer hcoMaxDepts = 4;

    // --------------------------------------------------- HCP Patient Potential
    public List<Band> hcpVolumeBands = new List<Band>{
        new Band(50, 100), new Band(25, 70), new Band(10, 40), new Band(0, 10)
    };
    public Decimal hcpDecileWeight = 0.6;
    public Decimal hcpVolumeWeight = 0.4;

    // ------------------------------------------------------ HCP AIT Readiness
    public Map<String, Decimal> hcpPractisesAitPoints = new Map<String, Decimal>{
        'SCIT' => 100, 'SCIT + SLIT' => 100, 'SLIT' => 70
    };
    public Map<String, Decimal> hcpTestingFreqPoints = new Map<String, Decimal>{
        'Regularly' => 100, 'Occasionally' => 50
    };
    public Map<String, Decimal> hcpScitAttitudePoints = new Map<String, Decimal>{
        'Advocate' => 100, 'Positive' => 75, 'Neutral' => 50, 'Unaware' => 30, 'Sceptic' => 20
    };
    public Decimal hcpPractisesWeight = 0.5;
    public Decimal hcpTestingWeight = 0.3;
    public Decimal hcpAttitudeWeight = 0.2;

    // -------------------------------------------------------------- HCP Access
    public Map<String, Decimal> hcpAccessPoints = new Map<String, Decimal>{ 'Yes' => 100, 'Conditional' => 50 };

    // ----------------------------------------------------------- HCP Influence
    public Map<String, Decimal> hcpInfluencePoints = new Map<String, Decimal>{
        'National' => 100, 'Regional' => 70, 'Local' => 40
    };
    public Decimal hcpInfluenceDefaultPoints = 10;

    // ------------------------------------------------------------ HCP Segment
    public Decimal hcpSegmentHighVolumeDecileMin = 7;
    public Decimal hcpSegmentHighVolumeWeeklyMin = 50;

    // ------------------------------------------------------------------ HCO OPD
    public List<Band> hcoOpdBands = new List<Band>{
        new Band(500, 100), new Band(200, 70), new Band(50, 40), new Band(0, 10)
    };

    // ------------------------------------------------------------ HCO AIT Offered
    public Map<String, Decimal> hcoAitOfferedPoints = new Map<String, Decimal>{
        'SCIT' => 100, 'SCIT + SLIT' => 100, 'SLIT' => 60
    };
    public Decimal hcoAitOfferedDefaultPoints = 20;

    // ------------------------------------------------------- HCO Affordability
    public Map<String, Decimal> hcoAffordabilityPoints = new Map<String, Decimal>{
        'High' => 100, 'Medium' => 60, 'Low' => 20
    };

    // ------------------------------------------------------------ HCO Target HCPs
    public List<Band> hcoTargetHcpBands = new List<Band>{
        new Band(5, 100), new Band(3, 70), new Band(1, 40), new Band(0, 0)
    };
    /** Which HCP Target Tier values count toward an HCO's Count of Target HCPs. */
    public Set<String> hcoTargetHcpCountingTiers = new Set<String>{ 'A', 'B' };

    /** Affiliation__c.Acaroid_Affiliation_Status__c values treated as "active" for network recomputation. */
    public Set<String> activeAffiliationStatuses = new Set<String>{ 'Active' };

    /**
     * Acaroid_Target_Tier__c -> Segmentation__c.Potential__c, applied to every rep's
     * existing segmentation row for an HCP whenever it's (re)scored -- see
     * AcaroidAffiliationService.syncSegmentationPotential.
     */
    public Map<String, String> hcpTierToPotentialMap = new Map<String, String>{
        'A' => 'High', 'B' => 'Medium', 'C' => 'Low', 'Referral' => 'Low', 'Not Targeted' => 'Unknown'
    };

    /** Specialties that make an affiliated HCP count toward an HCO's "Experienced Physician On-site" gate. */
    public Set<String> experiencedPhysicianSpecialties = new Set<String>{
        'Allergist / Clinical Immunologist', 'Pulmonologist / Chest Physician', 'Paediatric Pulmonologist',
        'Paediatrician', 'ENT Surgeon'
    };

    /**
     * Display name for this targeting feature, e.g. the "Acaroid Targeting" card title
     * and section headers on both the LWC and the iPad app. Sourced from the Product
     * master (Product__c, Level__c = 'Brand') via Brand_Product__c below, never hardcoded
     * in UI markup — see SciagenAccountController.getAcaroidBrandName().
     */
    public String brandName = 'Acaroid';

    public Acaroid_Scoring_Setting__c row;

    /** score `points` for `value` >= the highest band minValue it meets; bands need not be pre-sorted. */
    public static Decimal bandScore(Decimal value, List<Band> bands) {
        Decimal val = value == null ? 0 : value;
        Band best;
        for (Band b : bands) {
            if (val >= b.minValue && (best == null || b.minValue > best.minValue)) best = b;
        }
        return best == null ? 0 : best.points;
    }

    /** score points for `key` from a value:points map, or `defaultPoints` if `key` isn't in it. */
    public static Decimal mapScore(String key, Map<String, Decimal> points, Decimal defaultPoints) {
        if (key == null || !points.containsKey(key)) return defaultPoints;
        return points.get(key);
    }

    private static List<Band> parseBandTable(String raw, List<Band> fallback) {
        if (String.isBlank(raw)) return fallback;
        List<Band> bands = new List<Band>();
        for (String entry : raw.split(';')) {
            if (String.isBlank(entry)) continue;
            List<String> parts = entry.split(':');
            if (parts.size() != 2) continue;
            try {
                bands.add(new Band(Decimal.valueOf(parts[0].trim()), Decimal.valueOf(parts[1].trim())));
            } catch (Exception e) {
                // malformed entry -- skip it rather than fail the whole table
            }
        }
        return bands.isEmpty() ? fallback : bands;
    }

    private static Map<String, Decimal> parsePointMap(String raw, Map<String, Decimal> fallback) {
        if (String.isBlank(raw)) return fallback;
        Map<String, Decimal> points = new Map<String, Decimal>();
        for (String entry : raw.split(';')) {
            if (String.isBlank(entry)) continue;
            Integer sep = entry.lastIndexOf(':');
            if (sep < 0) continue;
            try {
                points.put(entry.substring(0, sep).trim(), Decimal.valueOf(entry.substring(sep + 1).trim()));
            } catch (Exception e) {
                // malformed entry -- skip it rather than fail the whole map
            }
        }
        return points.isEmpty() ? fallback : points;
    }

    private static Map<String, String> parseStringMap(String raw, Map<String, String> fallback) {
        if (String.isBlank(raw)) return fallback;
        Map<String, String> result = new Map<String, String>();
        for (String entry : raw.split(';')) {
            if (String.isBlank(entry)) continue;
            Integer sep = entry.lastIndexOf(':');
            if (sep < 0) continue;
            String key = entry.substring(0, sep).trim();
            String value = entry.substring(sep + 1).trim();
            if (String.isNotBlank(key) && String.isNotBlank(value)) result.put(key, value);
        }
        return result.isEmpty() ? fallback : result;
    }

    private static Set<String> parseStringSet(String raw, Set<String> fallback) {
        if (String.isBlank(raw)) return fallback;
        Set<String> values = new Set<String>();
        for (String s : raw.split(';')) {
            if (String.isNotBlank(s)) values.add(s.trim());
        }
        return values.isEmpty() ? fallback : values;
    }

    public static AcaroidConfig load() {
        AcaroidConfig c = new AcaroidConfig();
        Acaroid_Scoring_Setting__c r = Acaroid_Scoring_Setting__c.getOrgDefaults();
        if (r != null && r.Id != null) {
            c.row = r;
            if (r.W_Patient_Potential__c != null) c.wPatientPotential = r.W_Patient_Potential__c;
            if (r.W_AIT_Readiness__c != null) c.wAitReadiness = r.W_AIT_Readiness__c;
            if (r.W_Access__c != null) c.wAccess = r.W_Access__c;
            if (r.W_Influence__c != null) c.wInfluence = r.W_Influence__c;

            if (r.HCP_Tier_A_Min__c != null) c.hcpTierAMin = r.HCP_Tier_A_Min__c;
            if (r.HCP_Tier_B_Min__c != null) c.hcpTierBMin = r.HCP_Tier_B_Min__c;
            if (r.HCP_Tier_C_Min__c != null) c.hcpTierCMin = r.HCP_Tier_C_Min__c;
            if (r.Calls_Tier_A__c != null) c.callsTierA = r.Calls_Tier_A__c.intValue();
            if (r.Calls_Tier_B__c != null) c.callsTierB = r.Calls_Tier_B__c.intValue();
            if (r.Calls_Tier_C__c != null) c.callsTierC = r.Calls_Tier_C__c.intValue();
            if (r.Calls_Referral__c != null) c.callsReferral = r.Calls_Referral__c.intValue();

            if (r.HCO_Tier1_Min_Score__c != null) c.hcoTier1MinScore = r.HCO_Tier1_Min_Score__c;
            if (r.HCO_Tier2_Min_Score__c != null) c.hcoTier2MinScore = r.HCO_Tier2_Min_Score__c;

            if (r.HCO_W_OPD__c != null) c.hcoWOpd = r.HCO_W_OPD__c;
            if (r.HCO_W_AIT_Offered__c != null) c.hcoWAitOffered = r.HCO_W_AIT_Offered__c;
            if (r.HCO_W_Depts__c != null) c.hcoWDepts = r.HCO_W_Depts__c;
            if (r.HCO_W_Affordability__c != null) c.hcoWAffordability = r.HCO_W_Affordability__c;
            if (r.HCO_W_Target_HCPs__c != null) c.hcoWTargetHcps = r.HCO_W_Target_HCPs__c;
            if (r.HCO_Dept_Points_Each__c != null) c.hcoDeptPointsEach = r.HCO_Dept_Points_Each__c.intValue();
            if (r.HCO_Max_Depts__c != null) c.hcoMaxDepts = r.HCO_Max_Depts__c.intValue();

            c.hcpVolumeBands = parseBandTable(r.HCP_Volume_Band_Table__c, c.hcpVolumeBands);
            if (r.HCP_Decile_Weight__c != null) c.hcpDecileWeight = r.HCP_Decile_Weight__c;
            if (r.HCP_Volume_Weight__c != null) c.hcpVolumeWeight = r.HCP_Volume_Weight__c;

            c.hcpPractisesAitPoints = parsePointMap(r.HCP_Practises_AIT_Points__c, c.hcpPractisesAitPoints);
            c.hcpTestingFreqPoints = parsePointMap(r.HCP_Testing_Freq_Points__c, c.hcpTestingFreqPoints);
            c.hcpScitAttitudePoints = parsePointMap(r.HCP_SCIT_Attitude_Points__c, c.hcpScitAttitudePoints);
            if (r.HCP_Practises_Weight__c != null) c.hcpPractisesWeight = r.HCP_Practises_Weight__c;
            if (r.HCP_Testing_Weight__c != null) c.hcpTestingWeight = r.HCP_Testing_Weight__c;
            if (r.HCP_Attitude_Weight__c != null) c.hcpAttitudeWeight = r.HCP_Attitude_Weight__c;

            c.hcpAccessPoints = parsePointMap(r.HCP_Access_Points__c, c.hcpAccessPoints);

            c.hcpInfluencePoints = parsePointMap(r.HCP_Influence_Points__c, c.hcpInfluencePoints);
            if (r.HCP_Influence_Default_Points__c != null) c.hcpInfluenceDefaultPoints = r.HCP_Influence_Default_Points__c;

            if (r.HCP_Segment_High_Volume_Decile_Min__c != null) c.hcpSegmentHighVolumeDecileMin = r.HCP_Segment_High_Volume_Decile_Min__c;
            if (r.HCP_Segment_High_Volume_Weekly_Min__c != null) c.hcpSegmentHighVolumeWeeklyMin = r.HCP_Segment_High_Volume_Weekly_Min__c;

            c.hcoOpdBands = parseBandTable(r.HCO_OPD_Band_Table__c, c.hcoOpdBands);

            c.hcoAitOfferedPoints = parsePointMap(r.HCO_AIT_Offered_Points__c, c.hcoAitOfferedPoints);
            if (r.HCO_AIT_Offered_Default_Points__c != null) c.hcoAitOfferedDefaultPoints = r.HCO_AIT_Offered_Default_Points__c;

            c.hcoAffordabilityPoints = parsePointMap(r.HCO_Affordability_Points__c, c.hcoAffordabilityPoints);

            c.hcoTargetHcpBands = parseBandTable(r.HCO_Target_HCP_Band_Table__c, c.hcoTargetHcpBands);
            c.hcoTargetHcpCountingTiers = parseStringSet(r.HCO_Target_HCP_Counting_Tiers__c, c.hcoTargetHcpCountingTiers);

            c.activeAffiliationStatuses = parseStringSet(r.Active_Affiliation_Statuses__c, c.activeAffiliationStatuses);
            c.hcpTierToPotentialMap = parseStringMap(r.HCP_Tier_To_Potential_Map__c, c.hcpTierToPotentialMap);

            if (String.isNotBlank(r.Experienced_Physician_Specialties__c)) {
                Set<String> specialties = new Set<String>();
                for (String s : r.Experienced_Physician_Specialties__c.split(';')) {
                    if (String.isNotBlank(s)) specialties.add(s.trim());
                }
                if (!specialties.isEmpty()) c.experiencedPhysicianSpecialties = specialties;
            }

            if (String.isNotBlank(r.Brand_Product__c)) {
                try {
                    Id productId = Id.valueOf(r.Brand_Product__c.trim());
                    List<Product__c> brand = [SELECT Brand_Name__c, Name FROM Product__c WHERE Id = :productId LIMIT 1];
                    if (!brand.isEmpty()) {
                        String name = String.isNotBlank(brand[0].Brand_Name__c) ? brand[0].Brand_Name__c : brand[0].Name;
                        if (String.isNotBlank(name)) c.brandName = name;
                    }
                } catch (Exception e) {
                    // Brand_Product__c holds something other than a valid Product__c Id -- keep the default.
                }
            }
        }
        return c;
    }
}