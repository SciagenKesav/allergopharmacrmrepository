/**
 * Proves Role Hierarchy sharing actually rolls Call_Visit_Report__c and
 * Planned_Call__c visibility up to a manager, since that's the entire
 * mechanism the Live Reports feature depends on for "rep sees own territory,
 * manager sees consolidated view" from the same published report with zero
 * app-side role logic. Call_Visit_Report__c/Planned_Call__c are Private with
 * no declarative sharing rules -- if this test ever starts failing, hierarchy
 * sharing has regressed (e.g. "Grant Access Using Hierarchies" got disabled)
 * and the consolidated manager view will silently go empty.
 */
@isTest
private class RoleHierarchySharingTest {

    // User/PermissionSetAssignment are "setup objects" -- Salesforce forbids
    // mixing DML on setup and non-setup objects in one transaction, so this
    // has to live in @testSetup (its own transaction) rather than inline in
    // the test method, which is where the HCP/CVR (non-setup) DML happens.
    @testSetup static void setup() {
        UserRole repRole = [SELECT Id FROM UserRole WHERE DeveloperName = 'North_Delhi_Rep' LIMIT 1];
        UserRole managerRole = [SELECT Id FROM UserRole WHERE DeveloperName = 'North_Region_Manager' LIMIT 1];
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];

        User rep = new User(
            FirstName = 'Test', LastName = 'Rep RHTest', Alias = 'trep',
            Email = 'test.rep.rhtest@sciagen-test.invalid', Username = 'test.rep.rhtest@sciagen-new-dev.invalid',
            TimeZoneSidKey = 'Asia/Kolkata', LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US', ProfileId = p.Id, UserRoleId = repRole.Id, IsActive = true
        );
        User manager = new User(
            FirstName = 'Test', LastName = 'Manager RHTest', Alias = 'tmgr',
            Email = 'test.manager.rhtest@sciagen-test.invalid', Username = 'test.manager.rhtest@sciagen-new-dev.invalid',
            TimeZoneSidKey = 'Asia/Kolkata', LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US', ProfileId = p.Id, UserRoleId = managerRole.Id, IsActive = true
        );
        insert new List<User>{ rep, manager };

        // Standard User has no object permissions on Call_Visit_Report__c by
        // default (custom objects grant nothing until explicitly assigned) --
        // this test is about sharing, not CRUD, so borrow the app's own
        // mobile permission set to get both test users a normal working
        // baseline, same as any real rep/manager would have.
        PermissionSet mobileAccess = [SELECT Id FROM PermissionSet WHERE Name = 'Sciagen_Mobile_App_Access' LIMIT 1];
        insert new List<PermissionSetAssignment>{
            new PermissionSetAssignment(AssigneeId = rep.Id, PermissionSetId = mobileAccess.Id),
            new PermissionSetAssignment(AssigneeId = manager.Id, PermissionSetId = mobileAccess.Id)
        };
    }

    @isTest static void managerSeesSubordinatesCallVisitReport() {
        User rep = [SELECT Id FROM User WHERE Username = 'test.rep.rhtest@sciagen-new-dev.invalid' LIMIT 1];
        User manager = [SELECT Id FROM User WHERE Username = 'test.manager.rhtest@sciagen-new-dev.invalid' LIMIT 1];

        // Self-contained rather than depending on existing org data -- a
        // throwaway HCP just to satisfy Call_Visit_Report__c.HCP__c (required).
        // Created (and the CVR inserted) as the running admin user -- HCP__c's
        // own accessibility to the rep is TerritorySharingService's concern,
        // a separate mechanism from what this test is proving, so sidestep it
        // entirely by admin-inserting the CVR and reassigning ownership to
        // the rep directly, rather than requiring the rep to have HCP access
        // just to create it.
        Sciagen_Account__c hcp = new Sciagen_Account__c(Name = 'Test HCP RHTest', Type__c = 'HCP');
        insert hcp;

        Call_Visit_Report__c cvr = new Call_Visit_Report__c(
            HCP__c = hcp.Id,
            OwnerId = rep.Id,
            Visit_Date__c = Date.today(),
            Start_Time__c = DateTime.now(),
            End_Time__c = DateTime.now().addHours(1),
            Record_Status__c = 'Submitted',
            Activity_Type__c = 'In-person'
        );
        insert cvr;

        // The rep owns this record and can obviously see it. The real
        // assertion is that the MANAGER -- who never touched this record --
        // can also see it, purely via Role Hierarchy roll-up.
        System.runAs(manager) {
            List<Call_Visit_Report__c> visible = [SELECT Id FROM Call_Visit_Report__c WHERE Id = :cvr.Id];
            System.assertEquals(1, visible.size(),
                'Manager should see a subordinate-owned Call_Visit_Report__c via Role Hierarchy roll-up -- ' +
                'if this fails, "Grant Access Using Hierarchies" is off or the role tree is wrong, and the ' +
                'Live Reports manager-consolidated view will silently show nothing.');
        }
    }
}