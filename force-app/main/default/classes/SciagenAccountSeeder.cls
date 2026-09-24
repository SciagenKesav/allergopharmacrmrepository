/**
 * One-time sample-data loader for the Sciagen CRM demo, built on Sciagen_Account__c
 * (the custom Account object that replaced Standard Account in the Custom Account
 * Object migration). Invoke via anonymous Apex: SciagenAccountSeeder.seed();
 * Not test-covered on purpose — this is a data-loading utility, not shipped logic.
 * @isTest marks it as exactly that to Salesforce: its 466 lines are excluded from
 * the org-wide code coverage calculation entirely, instead of silently counting
 * as uncovered "shipped" code and dragging every real deploy's coverage gate down
 * (this alone was the difference between 70% and 75%+ org-wide coverage).
 * Anonymous Apex can still invoke its public static methods same as before.
 */
@isTest
public with sharing class SciagenAccountSeeder {

    /** Deletes everything this seeder creates, in reverse dependency order, so seed() can be re-run cleanly. */
    public static void cleanup() {
        delete [SELECT Id FROM POB_Line__c];
        delete [SELECT Id FROM RCPA_Competitor__c];
        delete [SELECT Id FROM RCPA_Line__c];
        delete [SELECT Id FROM RCPA_Audit__c];
        delete [SELECT Id FROM Leave_Request__c];
        delete [SELECT Id FROM Monthly_Claim_Bill__c];
        delete [SELECT Id FROM Monthly_Claim__c];
        delete [SELECT Id FROM Expense_Patch__c];
        delete [SELECT Id FROM Daily_Expense_Bill__c];
        delete [SELECT Id FROM Daily_Expense__c];
        delete [SELECT Id FROM Data_Change_Request__c];
        delete [SELECT Id FROM Consent_Product__c];
        delete [SELECT Id FROM Consent_Email__c];
        delete [SELECT Id FROM Consent_Channel__c];
        delete [SELECT Id FROM Consent__c];
        delete [SELECT Id FROM Sent_Email_Attachment__c];
        delete [SELECT Id FROM Sent_Email__c];
        delete [SELECT Id FROM Email_Template_Content__c];
        delete [SELECT Id FROM Email_Template__c];
        delete [SELECT Id FROM Slide_Event__c];
        delete [SELECT Id FROM Presentation_Session__c];
        delete [SELECT Id FROM Approved_Content__c];
        delete [SELECT Id FROM Content_Alert__c];
        delete [SELECT Id FROM Presentation_Favorite__c];
        delete [SELECT Id FROM Slide__c];
        delete [SELECT Id FROM Presentation__c];
        delete [SELECT Id FROM Promo_Drop__c];
        delete [SELECT Id FROM Sample_Drop__c];
        delete [SELECT Id FROM Key_Message__c];
        delete [SELECT Id FROM CVR_Internal_Attendee__c];
        delete [SELECT Id FROM CVR_Attendee__c];
        delete [SELECT Id FROM Call_Visit_Report__c];
        delete [SELECT Id FROM Planned_Call__c];
        delete [SELECT Id FROM Product_Strategy__c];
        delete [SELECT Id FROM Product_Plan_Template__c];
        delete [SELECT Id FROM Action_Item__c];
        delete [SELECT Id FROM Plan_Activity__c];
        delete [SELECT Id FROM Account_Team_Member__c];
        delete [SELECT Id FROM Plan_Stakeholder__c];
        delete [SELECT Id FROM Plan_Strategy__c];
        delete [SELECT Id FROM Plan_Goal__c];
        delete [SELECT Id FROM Account_Plan__c];
        delete [SELECT Id FROM Segmentation_Product__c];
        delete [SELECT Id FROM Segmentation__c];
        delete [SELECT Id FROM Publication__c];
        delete [SELECT Id FROM Congress_Event__c];
        delete [SELECT Id FROM Clinical_Trial__c];
        delete [SELECT Id FROM Influence_Peer__c];
        delete [SELECT Id FROM Office_Window__c];
        delete [SELECT Id FROM Custom_List_Member__c];
        delete [SELECT Id FROM Affiliation__c];
        delete [SELECT Id FROM Account_Territory__c];
        delete [SELECT Id FROM Sciagen_Account__c];
        delete [SELECT Id FROM Product__c];
        delete [SELECT Id FROM Territory__c];
        System.debug('OK: cleanup complete');
    }

    public static void seed() {
        List<String> errors = new List<String>();

        // ============================================================
        // 1. TERRITORY HIERARCHY
        // ============================================================
        Map<String, Id> territoryIdByName = new Map<String, Id>();
        try {
            Territory__c india = new Territory__c(Name = 'India', Territory_Code__c = 'IN', Type__c = 'Country');
            insert india;

            Territory__c north = new Territory__c(Name = 'North Region', Territory_Code__c = 'NR', Type__c = 'Region', Parent_Territory__c = india.Id);
            Territory__c south = new Territory__c(Name = 'South Region', Territory_Code__c = 'SR', Type__c = 'Region', Parent_Territory__c = india.Id);
            insert new List<Territory__c>{ north, south };

            Territory__c northDelhi = new Territory__c(Name = 'North Delhi', Territory_Code__c = 'ND', Type__c = 'Territory', Parent_Territory__c = north.Id);
            Territory__c westDelhi = new Territory__c(Name = 'West Delhi', Territory_Code__c = 'WD', Type__c = 'Territory', Parent_Territory__c = north.Id);
            Territory__c southDelhi = new Territory__c(Name = 'South Delhi', Territory_Code__c = 'SD', Type__c = 'Territory', Parent_Territory__c = south.Id);
            insert new List<Territory__c>{ northDelhi, westDelhi, southDelhi };

            territoryIdByName.put('India', india.Id);
            territoryIdByName.put('North Region', north.Id);
            territoryIdByName.put('South Region', south.Id);
            territoryIdByName.put('North Delhi', northDelhi.Id);
            territoryIdByName.put('West Delhi', westDelhi.Id);
            territoryIdByName.put('South Delhi', southDelhi.Id);
            System.debug('OK: Territories = ' + territoryIdByName.size());
        } catch (Exception e) {
            errors.add('Territories: ' + e.getMessage());
        }

        // ============================================================
        // 2. PRODUCTS
        // ============================================================
        Map<String, Id> productIdByBrand = new Map<String, Id>();
        try {
            List<Product__c> products = new List<Product__c>{
                new Product__c(Name = 'Emrok', Brand_Name__c = 'Emrok', SKU_Code__c = 'EMROK-SKU-1', Division__c = 'Cardiology', Active__c = true),
                new Product__c(Name = 'Glaritus', Brand_Name__c = 'Glaritus', SKU_Code__c = 'GLAR-SKU-1', Division__c = 'Diabetes', Active__c = true),
                new Product__c(Name = 'Miqnaf', Brand_Name__c = 'Miqnaf', SKU_Code__c = 'MIQ-SKU-1', Division__c = 'Respiratory', Active__c = true),
                new Product__c(Name = 'Cardiace', Brand_Name__c = 'Cardiace', SKU_Code__c = 'CARD-SKU-1', Division__c = 'Cardiology', Active__c = true),
                new Product__c(Name = 'Neutraline', Brand_Name__c = 'Neutraline', SKU_Code__c = 'NEUT-SKU-1', Division__c = 'Immunology', Active__c = true)
            };
            insert products;
            for (Product__c p : products) {
                productIdByBrand.put(p.Brand_Name__c, p.Id);
            }
            System.debug('OK: Products = ' + products.size());
        } catch (Exception e) {
            errors.add('Products: ' + e.getMessage());
        }

        // ============================================================
        // 3. HCP / HCO SCIAGEN ACCOUNTS
        // ============================================================
        List<Sciagen_Account__c> hcpAccounts = new List<Sciagen_Account__c>();
        List<Sciagen_Account__c> hcoAccounts = new List<Sciagen_Account__c>();
        try {
            List<Object[]> hcpData = new List<Object[]>{
                new Object[]{ 'Dr.', 'Anita', 'Rao', 'Cardiology', 'Physician', 'Interventional Cardiology' },
                new Object[]{ 'Dr.', 'Vikram', 'Mehta', 'Endocrinology', 'Consultant', 'Diabetes Management' },
                new Object[]{ 'Dr.', 'Sunita', 'Sharma', 'Oncology', 'Consultant', 'Medical Oncology' },
                new Object[]{ 'Dr.', 'Rajesh', 'Kumar', 'Pulmonology', 'Physician', 'Respiratory Medicine' },
                new Object[]{ 'Dr.', 'Priya', 'Nair', 'Immunology', 'Physician', 'Clinical Immunology' },
                new Object[]{ 'Dr.', 'Amit', 'Verma', 'General Physician', 'General Practitioner', 'Family Medicine' },
                new Object[]{ 'Dr.', 'Kavita', 'Joshi', 'Internal Medicine', 'Physician', 'Internal Medicine' },
                new Object[]{ 'Dr.', 'Sanjay', 'Gupta', 'Nephrology', 'Consultant', 'Renal Medicine' },
                new Object[]{ 'Dr.', 'Meena', 'Iyer', 'Neurology', 'Consultant', 'Neurology' },
                new Object[]{ 'Dr.', 'Arjun', 'Singh', 'Cardiology', 'Surgeon', 'Cardiac Surgery' },
                new Object[]{ 'Dr.', 'Deepa', 'Reddy', 'Endocrinology', 'Physician', 'Thyroid Disorders' },
                new Object[]{ 'Dr.', 'Ravi', 'Chandran', 'Oncology', 'Surgeon', 'Surgical Oncology' }
            };
            Integer i = 0;
            for (Object[] row : hcpData) {
                i++;
                hcpAccounts.add(new Sciagen_Account__c(
                    Type__c = 'HCP',
                    Name = (String) row[0] + ' ' + (String) row[1] + ' ' + (String) row[2],
                    Prefix__c = (String) row[0], First_Name__c = (String) row[1], Last_Name__c = (String) row[2],
                    Specialty__c = (String) row[3], HCP_Type__c = (String) row[4], Focus_Area__c = (String) row[5],
                    Phone__c = '98' + String.valueOf(10000000 + i).right(8),
                    Email__c = ((String) row[1]).toLowerCase() + '.' + ((String) row[2]).toLowerCase() + '@example.com',
                    License_Number__c = 'LIC-' + String.valueOf(1000 + i),
                    Licensing_Body__c = 'MCI'
                ));
            }
            // Enrichment: qualifications, digital presence, scientific impact — so the
            // Account Details page (both iPad and Salesforce web) has real demo data to
            // show beyond bare contact info, rather than the mostly-blank fields a plain
            // insert leaves behind. Deterministic-but-varied via index math, not random,
            // so re-running the seeder produces the same data every time.
            List<String> sampleDegrees = new List<String>{ 'MBBS', 'MD', 'MS', 'DM', 'MCh', 'DNB' };
            List<String> reachFlags = new List<String>{ 'Local', 'Regional', 'Global' };
            Integer hi = 0;
            for (Sciagen_Account__c hcp : hcpAccounts) {
                hi++;
                hcp.Age__c = 38 + Math.mod(hi * 3, 22);
                hcp.Experience_Years__c = 8 + Math.mod(hi * 2, 20);
                hcp.Degree_1__c = sampleDegrees[Math.mod(hi, sampleDegrees.size())];
                if (Math.mod(hi, 3) == 0) {
                    hcp.Degree_2__c = 'FRCS';
                }
                hcp.Graduation_Year__c = 1995 + Math.mod(hi * 2, 20);
                hcp.Licensing_Year__c = hcp.Graduation_Year__c.intValue() + 1;
                if (Math.mod(hi, 2) == 0) {
                    hcp.LinkedIn_URL__c = 'https://linkedin.com/in/dr-' + hi;
                }
                if (Math.mod(hi, 4) == 0) {
                    hcp.Twitter_URL__c = 'https://twitter.com/dr_rep' + hi;
                }
                Integer articles = Math.mod(hi * 5, 40);
                hcp.Total_Articles__c = articles;
                hcp.Total_Citations__c = articles * (10 + Math.mod(hi, 15));
                hcp.Avg_Citations_Per_Article__c = articles > 0
                    ? (Decimal.valueOf(hcp.Total_Citations__c.intValue()) / articles).setScale(1)
                    : 0;
                hcp.Avg_Coauthors_Per_Article__c = 2 + Math.mod(hi, 4);
                hcp.Unique_Journal_Count__c = 1 + Math.mod(hi, 8);
                hcp.Guideline_Count__c = Math.mod(hi, 3);
                hcp.Actively_Published_Years__c = 3 + Math.mod(hi, 12);
                hcp.Emerging_Expert__c = Math.mod(hi, 3) == 0;
                hcp.Reach_Flag__c = reachFlags[Math.mod(hi, reachFlags.size())];
                hcp.External_Ids__c = '{"MCI":"MCI-' + (9000 + hi) + '","NPI":"' + (1000000000L + hi) + '"}';
            }

            insert hcpAccounts;
            System.debug('OK: HCPs = ' + hcpAccounts.size());

            List<Object[]> hcoData = new List<Object[]>{
                new Object[]{ 'Apollo Hospital Delhi', 'Hospital', 'Cardiology', 'Sarita Vihar' },
                new Object[]{ 'Fortis Escorts Heart Institute', 'Hospital', 'Cardiology', 'Okhla Road' },
                new Object[]{ 'Max Super Speciality Hospital', 'Hospital', 'Oncology', 'Saket' },
                new Object[]{ 'AIIMS Delhi', 'Hospital', 'Other', 'Ansari Nagar' },
                new Object[]{ 'City Diabetes Clinic', 'Clinic', 'Endocrinology', 'Karol Bagh' },
                new Object[]{ 'Lotus Respiratory Clinic', 'Clinic', 'Pulmonology', 'Rohini' },
                new Object[]{ 'Wellness Pharmacy', 'Pharmacy', 'Other', 'Lajpat Nagar' },
                new Object[]{ 'MedPlus Chemist', 'Chemist Shop', 'Other', 'Dwarka' }
            };
            // New Delhi bounding box, spread deterministically per record so each HCO
            // gets a distinct-but-plausible geolocation instead of all sharing one point.
            for (Object[] row : hcoData) {
                Integer oi = hcoAccounts.size();
                Decimal lat = 28.55 + (oi * 0.02);
                Decimal lng = 77.15 + (oi * 0.03);
                hcoAccounts.add(new Sciagen_Account__c(
                    Type__c = 'HCO',
                    Name = (String) row[0],
                    HCO_Type__c = (String) row[1], Speciality__c = (String) row[2],
                    Billing_Street__c = (String) row[3], Billing_City__c = 'New Delhi', Billing_State__c = 'Delhi',
                    Billing_Country__c = 'India', Billing_Postal_Code__c = '110001',
                    Phone__c = '9111' + String.valueOf(100000 + hcoAccounts.size()).right(6),
                    Email__c = 'info@' + ((String) row[0]).deleteWhitespace().toLowerCase() + '.example.com',
                    Website__c = 'https://www.' + ((String) row[0]).deleteWhitespace().toLowerCase() + '.example.com',
                    Plus_Code__c = '7JVW+' + String.valueOf(20 + oi) + ' New Delhi',
                    Geolocation__Latitude__s = lat,
                    Geolocation__Longitude__s = lng,
                    External_Ids__c = '{"GST":"07AABCS' + (1234 + oi) + 'Z1","NABH":"NABH-' + (500 + oi) + '"}'
                ));
            }
            insert hcoAccounts;
            System.debug('OK: HCOs = ' + hcoAccounts.size());
        } catch (Exception e) {
            errors.add('HCP/HCO Sciagen Accounts: ' + e.getMessage());
        }

        // ============================================================
        // 4. TERRITORY ASSIGNMENTS + AFFILIATIONS
        // ============================================================
        try {
            List<Account_Territory__c> assignments = new List<Account_Territory__c>();
            List<String> terrCycle = new List<String>{ 'North Delhi', 'South Delhi', 'West Delhi' };
            for (Integer i = 0; i < hcpAccounts.size(); i++) {
                assignments.add(new Account_Territory__c(Name = 'Assignment', Account__c = hcpAccounts[i].Id, Territory__c = territoryIdByName.get(terrCycle[Math.mod(i, 3)])));
            }
            for (Integer i = 0; i < hcoAccounts.size(); i++) {
                assignments.add(new Account_Territory__c(Name = 'Assignment', Account__c = hcoAccounts[i].Id, Territory__c = territoryIdByName.get(terrCycle[Math.mod(i, 3)])));
            }
            insert assignments;
            System.debug('OK: Account_Territory__c = ' + assignments.size());

            List<Affiliation__c> affiliations = new List<Affiliation__c>();
            for (Integer i = 0; i < 8; i++) {
                affiliations.add(new Affiliation__c(Name = 'Affiliation', HCP__c = hcpAccounts[Math.mod(i, hcpAccounts.size())].Id, HCO__c = hcoAccounts[Math.mod(i, hcoAccounts.size())].Id));
            }
            insert affiliations;
            System.debug('OK: Affiliation__c = ' + affiliations.size());
        } catch (Exception e) {
            errors.add('Territory assignments/Affiliations: ' + e.getMessage());
        }

        // ============================================================
        // 5. SEGMENTATION
        // ============================================================
        try {
            List<Segmentation__c> segs = new List<Segmentation__c>();
            List<String> classifications = new List<String>{ 'A', 'B', 'C', 'A', 'B' };
            List<String> tiers = new List<String>{ 'Gold', 'Silver', 'Bronze', 'Gold', 'Silver' };
            List<String> priorities = new List<String>{ 'Priority 1', 'Priority 2', 'Priority 3', 'Priority 1', 'Priority 2' };
            List<String> potentials = new List<String>{ 'High', 'Medium', 'Low', 'High', 'Medium' };
            for (Integer i = 0; i < 5; i++) {
                segs.add(new Segmentation__c(
                    Name = 'Segmentation - ' + hcpAccounts[i].Name,
                    HCP__c = hcpAccounts[i].Id, Classification__c = classifications[i], Tier__c = tiers[i],
                    Priority__c = priorities[i], Potential__c = potentials[i], Is_KOL__c = (Math.mod(i, 2) == 0)
                ));
            }
            insert segs;
            System.debug('OK: Segmentation__c = ' + segs.size());

            List<Segmentation_Product__c> segProducts = new List<Segmentation_Product__c>();
            List<Id> productIds = productIdByBrand.values();
            for (Integer i = 0; i < segs.size(); i++) {
                segProducts.add(new Segmentation_Product__c(Name = 'Product Classification', Segmentation__c = segs[i].Id, Product__c = productIds[Math.mod(i, productIds.size())], Classification__c = classifications[i]));
            }
            insert segProducts;
            System.debug('OK: Segmentation_Product__c = ' + segProducts.size());
        } catch (Exception e) {
            errors.add('Segmentation: ' + e.getMessage());
        }

        // ============================================================
        // 6. ACCOUNT PLANS + full hierarchy
        // ============================================================
        try {
            List<Account_Plan__c> plans = new List<Account_Plan__c>();
            for (Integer i = 0; i < 3; i++) {
                plans.add(new Account_Plan__c(
                    Name = 'Plan ' + (i + 1), Plan_Title__c = 'FY26 Plan - ' + hcoAccounts[i].Name,
                    Status__c = 'Active', Division__c = 'Cardiology', HCO__c = hcoAccounts[i].Id, HCP__c = hcpAccounts[i].Id,
                    Start_Date__c = Date.newInstance(2026, 1, 1), End_Date__c = Date.newInstance(2026, 12, 31),
                    Objective__c = 'Grow share of voice and Rx volume in the account.',
                    Applied_Products__c = 'Emrok, Cardiace'
                ));
            }
            insert plans;
            System.debug('OK: Account_Plan__c = ' + plans.size());

            List<Plan_Goal__c> goals = new List<Plan_Goal__c>();
            List<Plan_Strategy__c> strategies = new List<Plan_Strategy__c>();
            List<Plan_Stakeholder__c> stakeholders = new List<Plan_Stakeholder__c>();
            List<Account_Team_Member__c> teamMembers = new List<Account_Team_Member__c>();
            for (Account_Plan__c plan : plans) {
                goals.add(new Plan_Goal__c(Name = 'Increase Rx Share', Title__c = 'Increase Rx Share', Plan__c = plan.Id, Metric__c = 'Rx Volume', Target__c = 500, Current__c = 320, Unit__c = 'units', Due_Date__c = Date.newInstance(2026, 12, 31)));
                goals.add(new Plan_Goal__c(Name = 'HCP Engagement', Title__c = 'HCP Engagement', Plan__c = plan.Id, Metric__c = 'Visits per Quarter', Target__c = 12, Current__c = 6, Unit__c = 'visits', Due_Date__c = Date.newInstance(2026, 9, 30)));
                strategies.add(new Plan_Strategy__c(Name = 'Detailing Focus', Strategy_Name__c = 'Detailing Focus', Plan__c = plan.Id, Detail__c = 'Weekly detailing visits with updated clinical data.'));
                strategies.add(new Plan_Strategy__c(Name = 'Peer Influence', Strategy_Name__c = 'Peer Influence', Plan__c = plan.Id, Detail__c = 'Leverage KOL advocacy for adoption.'));
                stakeholders.add(new Plan_Stakeholder__c(Name = 'Primary KOL', Stakeholder_Name__c = 'Primary KOL', Plan__c = plan.Id, Role__c = 'KOL', Specialty__c = 'Cardiology', Influence__c = 'High', Strength__c = 'Strong', Last_Graded__c = Date.today()));
                stakeholders.add(new Plan_Stakeholder__c(Name = 'Department Head', Stakeholder_Name__c = 'Department Head', Plan__c = plan.Id, Role__c = 'Decision Maker', Specialty__c = 'Cardiology', Influence__c = 'Critical', Strength__c = 'Developing', Last_Graded__c = Date.today()));
                teamMembers.add(new Account_Team_Member__c(Name = 'KAM Lead', Member_Name__c = 'KAM Lead', Plan__c = plan.Id, Role__c = 'KAM', Access__c = 'Write'));
            }
            insert goals;
            insert strategies;
            insert stakeholders;
            insert teamMembers;
            System.debug('OK: Plan_Goal__c=' + goals.size() + ' Plan_Strategy__c=' + strategies.size() + ' Plan_Stakeholder__c=' + stakeholders.size() + ' Account_Team_Member__c=' + teamMembers.size());

            List<Plan_Activity__c> activities = new List<Plan_Activity__c>();
            for (Plan_Strategy__c strat : strategies) {
                activities.add(new Plan_Activity__c(Name = 'Schedule Visit', Activity_Name__c = 'Schedule Visit', Strategy__c = strat.Id, Detail__c = 'Book next detailing visit.'));
            }
            insert activities;
            System.debug('OK: Plan_Activity__c = ' + activities.size());

            List<Action_Item__c> actionItems = new List<Action_Item__c>();
            for (Plan_Activity__c act : activities) {
                actionItems.add(new Action_Item__c(Name = 'Follow up', Title__c = 'Follow up with HCP', Activity__c = act.Id, Status__c = 'Open', Due_Date__c = Date.today().addDays(14)));
            }
            insert actionItems;
            System.debug('OK: Action_Item__c = ' + actionItems.size());

            Product_Plan_Template__c template = new Product_Plan_Template__c(Name = 'Emrok FY26 Template', Product_Name__c = 'Emrok', Summary__c = 'Standard product plan template for Emrok.');
            insert template;
            List<Product_Strategy__c> prodStrategies = new List<Product_Strategy__c>{
                new Product_Strategy__c(Name = 'Launch Strategy', Strategy_Name__c = 'Launch Strategy', Template__c = template.Id, Key_Messages__c = 'Superior efficacy\nFavorable safety profile', Tactics__c = 'Detailing\nCLM presentations'),
                new Product_Strategy__c(Name = 'Retention Strategy', Strategy_Name__c = 'Retention Strategy', Template__c = template.Id, Key_Messages__c = 'Long-term outcomes data', Tactics__c = 'Peer programs')
            };
            insert prodStrategies;
            System.debug('OK: Product_Plan_Template__c=1 Product_Strategy__c=' + prodStrategies.size());
        } catch (Exception e) {
            errors.add('Account Plan hierarchy: ' + e.getMessage());
        }

        // ============================================================
        // 7. PLANNED CALLS ("My Schedule")
        // ============================================================
        try {
            List<Planned_Call__c> plannedCalls = new List<Planned_Call__c>();
            List<String> callTypes = new List<String>{ 'Detailing', 'Sampling', 'Follow-up', 'Introductory', 'Visit' };
            for (Integer i = 0; i < 6; i++) {
                plannedCalls.add(new Planned_Call__c(
                    Name = 'Planned Call ' + (i + 1),
                    Event_Title__c = 'Visit - ' + hcpAccounts[Math.mod(i, hcpAccounts.size())].Name,
                    // Fixed at 11 AM, not DateTime.now() — office hours
                    // (PlannedCallOfficeHoursValidator) would otherwise
                    // randomly reject this insert depending on what time of
                    // day the seeder happens to run.
                    Call_DateTime__c = Datetime.newInstance(Date.today().addDays(i + 1), Time.newInstance(11, 0, 0, 0)),
                    HCP__c = hcpAccounts[Math.mod(i, hcpAccounts.size())].Id,
                    HCO__c = hcoAccounts[Math.mod(i, hcoAccounts.size())].Id,
                    Call_Type__c = callTypes[Math.mod(i, callTypes.size())],
                    Status__c = 'Planned'
                ));
            }
            insert plannedCalls;
            System.debug('OK: Planned_Call__c = ' + plannedCalls.size());
        } catch (Exception e) {
            errors.add('Planned_Call__c: ' + e.getMessage());
        }

        // ============================================================
        // 8. CALL VISIT REPORTS + children + presentation sessions
        // ============================================================
        List<Call_Visit_Report__c> cvrs = new List<Call_Visit_Report__c>();
        try {
            List<String> callTypes2 = new List<String>{ 'Detailing', 'Sampling', 'Follow-up', 'Introductory', 'Visit' };
            for (Integer i = 0; i < 5; i++) {
                cvrs.add(new Call_Visit_Report__c(
                    Name = 'CVR ' + (i + 1),
                    HCP__c = hcpAccounts[i].Id, HCO__c = hcoAccounts[Math.mod(i, hcoAccounts.size())].Id,
                    Visit_Date__c = Date.today().addDays(-i),
                    Territory__c = territoryIdByName.get('North Delhi'),
                    Call_Type__c = callTypes2[Math.mod(i, callTypes2.size())],
                    Activity_Type__c = 'In-person', Call_Status__c = 'Completed', Record_Status__c = 'Submitted',
                    Start_Time__c = DateTime.now().addDays(-i).addHours(-2), End_Time__c = DateTime.now().addDays(-i).addHours(-1),
                    Pre_Call_Notes__c = 'Discuss latest clinical data.', Discussion_Summary__c = 'Positive reception to new efficacy data.',
                    Next_Visit_Date__c = Date.today().addDays(14)
                ));
            }
            insert cvrs;
            System.debug('OK: Call_Visit_Report__c = ' + cvrs.size());

            List<CVR_Attendee__c> cvrAttendees = new List<CVR_Attendee__c>();
            List<CVR_Internal_Attendee__c> cvrInternal = new List<CVR_Internal_Attendee__c>();
            List<Key_Message__c> keyMessages = new List<Key_Message__c>();
            List<Sample_Drop__c> sampleDrops = new List<Sample_Drop__c>();
            List<Promo_Drop__c> promoDrops = new List<Promo_Drop__c>();
            List<Id> productIdList = productIdByBrand.values();
            Id currentUserId = UserInfo.getUserId();
            for (Integer i = 0; i < cvrs.size(); i++) {
                cvrAttendees.add(new CVR_Attendee__c(Name = 'Attendee', CVR__c = cvrs[i].Id, HCP__c = hcpAccounts[i].Id));
                cvrInternal.add(new CVR_Internal_Attendee__c(Name = 'Internal Attendee', CVR__c = cvrs[i].Id, User__c = currentUserId));
                keyMessages.add(new Key_Message__c(Name = 'Key Message', CVR__c = cvrs[i].Id, Message__c = 'Highlighted superior efficacy data.', Product__c = 'Emrok', Reaction__c = 'Positive'));
                sampleDrops.add(new Sample_Drop__c(Name = 'Sample Drop', CVR__c = cvrs[i].Id, Product__c = productIdList[Math.mod(i, productIdList.size())], Qty__c = 5));
                promoDrops.add(new Promo_Drop__c(Name = 'Promo Item', CVR__c = cvrs[i].Id, Item__c = 'Branded Notepad', Qty__c = 2));
            }
            insert cvrAttendees;
            insert cvrInternal;
            insert keyMessages;
            insert sampleDrops;
            insert promoDrops;
            System.debug('OK: CVR_Attendee__c=' + cvrAttendees.size() + ' CVR_Internal_Attendee__c=' + cvrInternal.size()
                + ' Key_Message__c=' + keyMessages.size() + ' Sample_Drop__c=' + sampleDrops.size() + ' Promo_Drop__c=' + promoDrops.size());
        } catch (Exception e) {
            errors.add('Call_Visit_Report__c + children: ' + e.getMessage());
        }

        // ============================================================
        // 9. PRESENTATIONS (CLM) + slides + favorites + alerts + sessions
        // ============================================================
        List<Presentation__c> presentations = new List<Presentation__c>();
        try {
            List<String> brands = new List<String>{ 'Emrok', 'Glaritus', 'Miqnaf' };
            for (Integer i = 0; i < 3; i++) {
                presentations.add(new Presentation__c(
                    Name = 'Presentation ' + (i + 1), Presentation_Name__c = brands[i] + ' - Clinical Overview',
                    Product__c = productIdByBrand.get(brands[i]), Brand__c = brands[i],
                    Approval_Status__c = 'Approved Promotional', Version__c = 'v1.0',
                    Expiry_Date__c = Date.today().addMonths(6), MLR_Reference__c = 'MLR-2026-' + String.valueOf(100 + i)
                ));
            }
            insert presentations;
            System.debug('OK: Presentation__c = ' + presentations.size());

            List<Slide__c> slides = new List<Slide__c>();
            for (Presentation__c pres : presentations) {
                for (Integer s = 1; s <= 3; s++) {
                    slides.add(new Slide__c(Name = 'Slide ' + s, Slide_Name__c = 'Slide ' + s, Slide_No__c = s, Presentation__c = pres.Id, File_Type__c = 'PDF', Brand__c = pres.Brand__c));
                }
            }
            insert slides;
            System.debug('OK: Slide__c = ' + slides.size());

            List<Presentation_Favorite__c> favorites = new List<Presentation_Favorite__c>();
            List<Content_Alert__c> alerts = new List<Content_Alert__c>();
            for (Presentation__c pres : presentations) {
                favorites.add(new Presentation_Favorite__c(Name = 'Favorite', Presentation__c = pres.Id, User_Id__c = UserInfo.getUserId()));
                alerts.add(new Content_Alert__c(Name = 'New Content', Title__c = pres.Presentation_Name__c + ' updated', Presentation__c = pres.Id, Kind__c = 'Updated'));
            }
            insert favorites;
            insert alerts;
            System.debug('OK: Presentation_Favorite__c=' + favorites.size() + ' Content_Alert__c=' + alerts.size());

            List<Approved_Content__c> approvedContent = new List<Approved_Content__c>();
            for (Integer i = 0; i < 3; i++) {
                approvedContent.add(new Approved_Content__c(Name = 'Content ' + (i + 1), Content_Name__c = brands[i] + ' Leave Behind', Product__c = productIdByBrand.get(brands[i]), Kind__c = 'PDF'));
            }
            insert approvedContent;
            System.debug('OK: Approved_Content__c = ' + approvedContent.size());

            List<Presentation_Session__c> sessions = new List<Presentation_Session__c>();
            for (Integer i = 0; i < 2; i++) {
                sessions.add(new Presentation_Session__c(Name = 'Session ' + (i + 1), CVR__c = cvrs[i].Id, Presentation__c = presentations[i].Id, Brand__c = presentations[i].Brand__c, Start_Time__c = DateTime.now(), End_Time__c = DateTime.now().addMinutes(15), Total_Slides__c = 3));
            }
            insert sessions;
            System.debug('OK: Presentation_Session__c = ' + sessions.size());

            List<Slide_Event__c> slideEvents = new List<Slide_Event__c>();
            for (Presentation_Session__c sess : sessions) {
                for (Integer s = 1; s <= 2; s++) {
                    slideEvents.add(new Slide_Event__c(Name = 'View', Session__c = sess.Id, Slide_No__c = s, Sequence__c = s, Time_Spent_Sec__c = 30 * s));
                }
            }
            insert slideEvents;
            System.debug('OK: Slide_Event__c = ' + slideEvents.size());
        } catch (Exception e) {
            errors.add('Presentations/CLM: ' + e.getMessage());
        }

        // ============================================================
        // 10. EMAIL TEMPLATES + SENT EMAILS
        // ============================================================
        try {
            List<Email_Template__c> templates = new List<Email_Template__c>();
            List<String> brands2 = new List<String>{ 'Emrok', 'Glaritus', 'Miqnaf' };
            for (Integer i = 0; i < 3; i++) {
                templates.add(new Email_Template__c(
                    Name = brands2[i] + ' Template', Template_Name__c = brands2[i] + ' Introductory Email',
                    Subject__c = 'New clinical data for ' + brands2[i], Product__c = productIdByBrand.get(brands2[i]),
                    Brand__c = brands2[i], Language__c = 'English', Body__c = 'Dear Doctor, please find attached the latest clinical data.'
                ));
            }
            insert templates;
            System.debug('OK: Email_Template__c = ' + templates.size());

            List<Sent_Email__c> sentEmails = new List<Sent_Email__c>();
            List<String> folders = new List<String>{ 'Sent', 'Sent', 'Draft', 'Sent', 'Inbox' };
            for (Integer i = 0; i < 5; i++) {
                sentEmails.add(new Sent_Email__c(
                    Name = 'Email ' + (i + 1), HCP__c = hcpAccounts[i].Id, Template__c = templates[Math.mod(i, templates.size())].Id,
                    Subject__c = 'Clinical Update', Folder__c = folders[i], Language__c = 'English', Verified_Via__c = 'Email OTP',
                    To_Email__c = hcpAccounts[i].Email__c, Sent_At__c = DateTime.now().addDays(-i), Signed__c = true
                ));
            }
            insert sentEmails;
            System.debug('OK: Sent_Email__c = ' + sentEmails.size());
        } catch (Exception e) {
            errors.add('Email Templates/Sent Emails: ' + e.getMessage());
        }

        // ============================================================
        // 11. CONSENT CAPTURE
        // ============================================================
        try {
            List<Consent__c> consents = new List<Consent__c>();
            for (Integer i = 0; i < 5; i++) {
                consents.add(new Consent__c(
                    Name = 'Consent - ' + hcpAccounts[i].Name, HCP__c = hcpAccounts[i].Id, Signer_Name__c = hcpAccounts[i].Name,
                    Mobile_Number__c = hcpAccounts[i].Phone__c, Mobile_Opt_In__c = true, Mobile_Verified__c = true,
                    Email_Verified__c = true, Signed__c = true, Captured_At__c = DateTime.now(), Signed_At__c = DateTime.now()
                ));
            }
            insert consents;
            System.debug('OK: Consent__c = ' + consents.size());

            List<Consent_Channel__c> channels = new List<Consent_Channel__c>();
            List<Consent_Email__c> consentEmails = new List<Consent_Email__c>();
            List<Consent_Product__c> consentProducts = new List<Consent_Product__c>();
            List<Id> productIdList2 = productIdByBrand.values();
            for (Integer i = 0; i < consents.size(); i++) {
                channels.add(new Consent_Channel__c(Name = 'SMS', Consent__c = consents[i].Id, Channel_Name__c = 'SMS', Subscribed__c = true));
                channels.add(new Consent_Channel__c(Name = 'WhatsApp', Consent__c = consents[i].Id, Channel_Name__c = 'WhatsApp', Subscribed__c = true));
                consentEmails.add(new Consent_Email__c(Name = 'Primary Email', Consent__c = consents[i].Id, Email__c = hcpAccounts[i].Email__c, Opted_In__c = true));
                consentProducts.add(new Consent_Product__c(Name = 'Product Consent', Consent__c = consents[i].Id, Product__c = productIdList2[Math.mod(i, productIdList2.size())], Subscribed__c = true));
            }
            insert channels;
            insert consentEmails;
            insert consentProducts;
            System.debug('OK: Consent_Channel__c=' + channels.size() + ' Consent_Email__c=' + consentEmails.size() + ' Consent_Product__c=' + consentProducts.size());
        } catch (Exception e) {
            errors.add('Consent Capture: ' + e.getMessage());
        }

        // ============================================================
        // 12. RCPA
        // ============================================================
        try {
            List<RCPA_Audit__c> audits = new List<RCPA_Audit__c>();
            for (Integer i = 0; i < 3; i++) {
                audits.add(new RCPA_Audit__c(
                    Name = 'RCPA Audit ' + (i + 1), Chemist__c = hcoAccounts[6 + Math.mod(i, 2)].Id,
                    Audit_Date__c = Date.today().addDays(-i * 7), Territory__c = territoryIdByName.get('North Delhi'),
                    Status__c = 'Submitted', POB_Units__c = 20
                ));
            }
            insert audits;
            System.debug('OK: RCPA_Audit__c = ' + audits.size());

            List<RCPA_Line__c> lines = new List<RCPA_Line__c>();
            List<String> molecules = new List<String>{ 'Levonadifloxacin', 'Insulin Glargine', 'Antifungal Topical' };
            for (RCPA_Audit__c audit : audits) {
                for (Integer m = 0; m < molecules.size(); m++) {
                    lines.add(new RCPA_Line__c(Name = molecules[m], Audit__c = audit.Id, Molecule__c = molecules[m], Own_Brand__c = 'Emrok', Own_Units_Per_Week__c = 30, Prescriber__c = hcpAccounts[Math.mod(m, hcpAccounts.size())].Id, Trend__c = 'Growing'));
                }
            }
            insert lines;
            System.debug('OK: RCPA_Line__c = ' + lines.size());

            List<RCPA_Competitor__c> competitors = new List<RCPA_Competitor__c>();
            for (RCPA_Line__c line : lines) {
                competitors.add(new RCPA_Competitor__c(Name = 'Competitor Brand', Line__c = line.Id, Brand__c = 'CompetitorX', Company__c = 'Rival Pharma', Units_Per_Week__c = 15));
            }
            insert competitors;
            System.debug('OK: RCPA_Competitor__c = ' + competitors.size());

            List<POB_Line__c> pobLines = new List<POB_Line__c>();
            List<Id> productIdList3 = productIdByBrand.values();
            for (Integer i = 0; i < audits.size(); i++) {
                pobLines.add(new POB_Line__c(Name = 'POB Line', Audit__c = audits[i].Id, SKU__c = productIdList3[Math.mod(i, productIdList3.size())], Qty__c = 10));
            }
            insert pobLines;
            System.debug('OK: POB_Line__c = ' + pobLines.size());
        } catch (Exception e) {
            errors.add('RCPA: ' + e.getMessage());
        }

        // ============================================================
        // 13. DATA CHANGE REQUESTS
        // ============================================================
        try {
            List<Data_Change_Request__c> dcrs = new List<Data_Change_Request__c>{
                new Data_Change_Request__c(Name = 'DCR - New HCP', Subject_Name__c = 'New HCP - Dr. Neha Kapoor', Type__c = 'New HCP', Status__c = 'Pending Approval', Summary__c = 'New cardiologist met at conference.', Submitted_At__c = DateTime.now()),
                new Data_Change_Request__c(Name = 'DCR - Edit HCP', Subject_Name__c = hcpAccounts[0].Name, Subject_Account__c = hcpAccounts[0].Id, Type__c = 'Edit HCP', Status__c = 'Approved', Summary__c = 'Updated phone number.', Submitted_At__c = DateTime.now().addDays(-3))
            };
            insert dcrs;
            System.debug('OK: Data_Change_Request__c = ' + dcrs.size());
        } catch (Exception e) {
            errors.add('Data_Change_Request__c: ' + e.getMessage());
        }

        // ============================================================
        // 14. EXPENSES
        // ============================================================
        try {
            List<Daily_Expense__c> dailyExpenses = new List<Daily_Expense__c>();
            for (Integer i = 0; i < 8; i++) {
                dailyExpenses.add(new Daily_Expense__c(
                    Name = 'Expense ' + (i + 1), Expense_Date__c = Date.today().addDays(-i), Status__c = 'Submitted',
                    Day_Type__c = 'Field Working', Place_Of_Work__c = 'New Delhi', Worked_Areas__c = 'North Delhi, West Delhi',
                    Inter_Patch_Mode__c = '4W', Inter_Patch_KM__c = 45
                ));
            }
            insert dailyExpenses;
            System.debug('OK: Daily_Expense__c = ' + dailyExpenses.size());

            List<Daily_Expense_Bill__c> dailyBills = new List<Daily_Expense_Bill__c>();
            List<Expense_Patch__c> patches = new List<Expense_Patch__c>();
            List<String> categories = new List<String>{ 'Fuel', 'Toll', 'Lodging', 'Mobile-Internet', 'Miscellaneous' };
            for (Integer i = 0; i < dailyExpenses.size(); i++) {
                dailyBills.add(new Daily_Expense_Bill__c(Name = 'Bill', Daily_Expense__c = dailyExpenses[i].Id, Title__c = categories[Math.mod(i, categories.size())] + ' Bill', Category__c = categories[Math.mod(i, categories.size())], Amount__c = 500 + (i * 25)));
                patches.add(new Expense_Patch__c(Name = 'Patch ' + (i + 1), Patch_Name__c = 'Patch ' + (i + 1), Daily_Expense__c = dailyExpenses[i].Id, Station_Type__c = 'HQ', Travel_Mode__c = '4W', One_Way_KM__c = 22.5));
            }
            insert dailyBills;
            insert patches;
            System.debug('OK: Daily_Expense_Bill__c=' + dailyBills.size() + ' Expense_Patch__c=' + patches.size());

            List<Monthly_Claim__c> monthlyClaims = new List<Monthly_Claim__c>{
                new Monthly_Claim__c(Name = 'Claim - Jul 2026', Month_Anchor__c = Date.newInstance(2026, 7, 1), Status__c = 'HO Passed', Petrol__c = 3200, Mobile_Internet__c = 800),
                new Monthly_Claim__c(Name = 'Claim - Aug 2026', Month_Anchor__c = Date.newInstance(2026, 8, 1), Status__c = 'Submitted', Petrol__c = 2900, Mobile_Internet__c = 800)
            };
            insert monthlyClaims;
            List<Monthly_Claim_Bill__c> monthlyBills = new List<Monthly_Claim_Bill__c>();
            for (Monthly_Claim__c claim : monthlyClaims) {
                monthlyBills.add(new Monthly_Claim_Bill__c(Name = 'Bill', Monthly_Claim__c = claim.Id, Title__c = 'Fuel Reimbursement', Category__c = 'Fuel', Amount__c = 1500));
            }
            insert monthlyBills;
            System.debug('OK: Monthly_Claim__c=' + monthlyClaims.size() + ' Monthly_Claim_Bill__c=' + monthlyBills.size());
        } catch (Exception e) {
            errors.add('Expenses: ' + e.getMessage());
        }

        // ============================================================
        // 15. LEAVE
        // ============================================================
        try {
            List<Leave_Request__c> leaveRequests = new List<Leave_Request__c>{
                new Leave_Request__c(Name = 'Leave 1', Type__c = 'Casual Leave', From_Date__c = Date.today().addDays(10), To_Date__c = Date.today().addDays(11), Status__c = 'Pending', Reason__c = 'Personal work'),
                new Leave_Request__c(Name = 'Leave 2', Type__c = 'Sick Leave', From_Date__c = Date.today().addDays(-5), To_Date__c = Date.today().addDays(-4), Status__c = 'Approved', Reason__c = 'Fever'),
                new Leave_Request__c(Name = 'Leave 3', Type__c = 'Earned / Privilege', From_Date__c = Date.today().addDays(30), To_Date__c = Date.today().addDays(35), Status__c = 'Pending', Reason__c = 'Family vacation'),
                new Leave_Request__c(Name = 'Leave 4', Type__c = 'Compensatory Off', From_Date__c = Date.today().addDays(3), To_Date__c = Date.today().addDays(3), Status__c = 'Approved', Reason__c = 'Worked on Sunday')
            };
            insert leaveRequests;
            System.debug('OK: Leave_Request__c = ' + leaveRequests.size());
        } catch (Exception e) {
            errors.add('Leave: ' + e.getMessage());
        }

        // ============================================================
        // 16. SCIENTIFIC EXPERT LAYER (Publications, Congress Events, Clinical Trials)
        // ============================================================
        try {
            List<Publication__c> pubs = new List<Publication__c>{
                new Publication__c(Name = 'Publication 1', HCP__c = hcpAccounts[0].Id, Title__c = 'Outcomes in Interventional Cardiology', PMID__c = '38412001', Publication_Date__c = '2026-01-15', Citations__c = 24,
                    Publication_Type__c = 'Journal Article', Link__c = 'https://pubmed.ncbi.nlm.nih.gov/38412001', Coauthors__c = 'Dr. Vikram Mehta, Dr. Sunita Sharma', Mesh_Terms__c = 'Cardiology; Angioplasty'),
                new Publication__c(Name = 'Publication 2', HCP__c = hcpAccounts[2].Id, Title__c = 'Advances in Medical Oncology', PMID__c = '38412002', Publication_Date__c = '2026-02-20', Citations__c = 41,
                    Publication_Type__c = 'Review', Link__c = 'https://pubmed.ncbi.nlm.nih.gov/38412002', Coauthors__c = 'Dr. Ravi Chandran', Mesh_Terms__c = 'Oncology; Chemotherapy')
            };
            insert pubs;

            List<Congress_Event__c> events = new List<Congress_Event__c>{
                new Congress_Event__c(Name = 'CardioCon 2026', HCP__c = hcpAccounts[0].Id, Event_Name__c = 'CardioCon 2026', Start_Date__c = '2026-03-10', End_Date__c = '2026-03-12', Location__c = 'Mumbai', Role__c = 'Speaker',
                    Organized_By__c = 'Cardiological Society of India', Topic__c = 'Minimally Invasive Cardiac Procedures', Link__c = 'https://cardiocon.example.com/2026')
            };
            insert events;

            List<Clinical_Trial__c> trials = new List<Clinical_Trial__c>{
                new Clinical_Trial__c(Name = 'Cardiac Outcomes Study', HCP__c = hcpAccounts[0].Id, Title__c = 'A Study of Cardiac Outcomes', Registry_Id__c = 'NCT00000001', Registry__c = 'ClinicalTrials.gov', Phase__c = 'Phase III', Sponsor__c = 'Test Sponsor',
                    Study_Type__c = 'Interventional', Condition__c = 'Coronary Artery Disease', Start_Date__c = '2025-06-01', Completion_Date__c = '2027-06-01', Locations__c = 'AIIMS Delhi, Apollo Hospital Delhi', Endpoints__c = 'Major adverse cardiac events at 12 months')
            };
            insert trials;
            System.debug('OK: Publication__c=' + pubs.size() + ' Congress_Event__c=' + events.size() + ' Clinical_Trial__c=' + trials.size());
        } catch (Exception e) {
            errors.add('Scientific expert layer: ' + e.getMessage());
        }

        // ============================================================
        // SUMMARY
        // ============================================================
        if (errors.isEmpty()) {
            System.debug('=== ALL SECTIONS SUCCEEDED ===');
        } else {
            System.debug('=== ERRORS (' + errors.size() + ') ===');
            for (String err : errors) {
                System.debug('ERROR: ' + err);
            }
        }
    }
}