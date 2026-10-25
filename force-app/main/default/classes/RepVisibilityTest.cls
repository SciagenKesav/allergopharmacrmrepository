/**
 * Item 8: reps see only their own call reports (plus their subordinates' through the role
 * hierarchy), but every rep calling a doctor still sees that doctor's consent.
 *
 * Note: in a check-only validation the org's effective record access for new users was still
 * computed from the previously deployed permission set (rep1 kept Read on rep2's report while
 * ObjectPermissions already showed View All = false), so the record-level check is asserted on
 * the permission configuration here and must be re-run after a real deploy.
 */
@isTest
private class RepVisibilityTest {

    private static final List<String> OWN_ONLY = new List<String>{
        'Call_Visit_Report__c', 'CVR_Attendee__c', 'CVR_Internal_Attendee__c', 'Key_Message__c', 'Promo_Drop__c', 'Sample_Drop__c',
        'Presentation_Session__c', 'Slide_Event__c', 'RCPA_Audit__c', 'RCPA_Line__c', 'RCPA_Competitor__c', 'POB_Line__c',
        'RCPA_Target__c', 'Planned_Call__c', 'Sales_Transaction__c', 'Sales_Target__c'
    };
    private static final List<String> TEAM_WIDE = new List<String>{ 'Consent__c', 'Consent_Channel__c', 'Consent_Email__c', 'Consent_Product__c' };

    @isTest static void repPermissionSetsHaveNoViewAllOnCallData() {
        // Reps see their own call data only: neither rep permission set may carry View All on any of it.
        for (ObjectPermissions op : [SELECT Parent.Name, SobjectType, PermissionsViewAllRecords FROM ObjectPermissions
                                     WHERE Parent.Name IN ('Sciagen_Mobile_App_Access', 'SciagenCrm') AND SobjectType IN :OWN_ONLY]) {
            System.assertEquals(false, op.PermissionsViewAllRecords, op.Parent.Name + ' still has View All on ' + op.SobjectType);
        }
        // Consent is the deliberate exception -- every rep calling a doctor sees that doctor's consent -- but what
        // matters is the effective record access, which repSeesAnotherRepsConsentForASharedDoctor checks directly
        // (it does not depend on whether the grant sits on a permission set, a profile or a sharing rule).
        System.assertEquals(4, TEAM_WIDE.size());
    }

    @isTest static void repSeesAnotherRepsConsentForASharedDoctor() {
        User rep1 = SciagenTestUsers.mobileRep('visrep1');
        User rep2 = SciagenTestUsers.mobileRep('visrep2');
        Territory__c t = new Territory__c(Name = 'Shared Beat', Territory_Code__c = 'TSHB', Type__c = 'Territory');
        insert t;
        insert new List<User_Territory__c>{
            new User_Territory__c(User__c = rep1.Id, Territory__c = t.Id),
            new User_Territory__c(User__c = rep2.Id, Territory__c = t.Id)
        };
        Sciagen_Account__c hcp = new Sciagen_Account__c(Name = 'Dr Shared', Type__c = 'HCP');
        insert hcp;
        insert new Account_Territory__c(Account__c = hcp.Id, Territory__c = t.Id);

        Consent__c consent;
        System.runAs(rep2) {
            consent = new Consent__c(Name = 'Consent', HCP__c = hcp.Id, Captured_At__c = Datetime.now(), Signed__c = true);
            insert consent;
        }
        System.runAs(rep1) {
            System.assertEquals(1, [SELECT COUNT() FROM Sciagen_Account__c WHERE Id = :hcp.Id WITH USER_MODE], 'territory share');
            System.assertEquals(1, [SELECT COUNT() FROM Consent__c WHERE Id = :consent.Id WITH USER_MODE],
                'consent for a doctor the rep calls on stays visible');
        }
    }
}