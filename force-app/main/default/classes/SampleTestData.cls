@isTest
public class SampleTestData {

    public static Product__c product(String name) {
        Product__c p = new Product__c(Product_Code__c = ('T-' + Math.abs(name.hashCode())).left(30), Name = name, Level__c = 'SKU', Is_Sample_Product__c = true, Sample_Unit_Value_INR__c = 10, Pack_Size__c = 4,
            Smallest_Market_Pack_Size__c = 10, Max_Packs_Per_HCP_Per_Year__c = 12);
        insert p;
        return p;
    }

    public static Sciagen_Account__c doctor(String name) {
        Sciagen_Account__c d = new Sciagen_Account__c(Name = name, Type__c = 'HCP', Speciality__c = 'Cardiology', Billing_City__c = 'Delhi',
            License_Number__c = 'MCI-' + Math.abs(name.hashCode()), License_Verification_Status__c = 'Verified',
            License_Expiry_Date__c = Date.today().addYears(2), Can_Prescribe__c = true);
        insert d;
        return d;
    }

    public static Sample_Lot__c lot(Product__c p, String lotNo, Integer qty, Integer daysToExpiry) {
        Sample_Lot__c l = new Sample_Lot__c(Product__c = p.Id, Lot_Number__c = lotNo, Expiry_Date__c = Date.today().addDays(daysToExpiry),
            Initial_Quantity__c = qty, Available_Quantity__c = qty, Owner_User__c = UserInfo.getUserId());
        insert l;
        return l;
    }

    public static Call_Visit_Report__c call(Sciagen_Account__c hcp, String status) {
        Call_Visit_Report__c c = new Call_Visit_Report__c(HCP__c = hcp.Id, Visit_Date__c = Date.today(), Start_Time__c = System.now(), Call_Type__c = 'Detailing',
            Call_Status__c = 'Completed', Record_Status__c = status);
        insert c;
        return c;
    }

    /** Completed disbursements straight into the ledger, for limit tests. */
    public static void given(Product__c p, Sample_Lot__c l, Sciagen_Account__c hcp, Integer packs) {
        insert new Sample_Transaction__c(Transaction_Type__c = 'Disbursement', Status__c = 'Completed', Product__c = p.Id, Sample_Lot__c = l.Id,
            HCP_Account__c = hcp.Id, Quantity__c = packs);
    }

    /// A disposable test user granted Sciagen_Sample_Admin (Manage_Sample_Inventory), for the
    /// duration of this test transaction only. SampleLimitGuardService/SampleDropService/
    /// SampleTransactionService/SampleAdminController all gate manager-only actions (activating
    /// an override, approving a soft-limit hold, bulk stock changes) behind that custom
    /// permission -- wrap those specific calls in System.runAs(SampleTestData.managerUser()).
    /// The User + PermissionSetAssignment inserts are setup-object DML, so they're wrapped in
    /// their own runAs to avoid MIXED_DML_OPERATION alongside a test's other (non-setup) records
    /// -- the same pattern TerritorySharingServiceTest already uses for its rep users.
    public static User managerUser() {
        String uniq = 'smgr' + Datetime.now().getTime();
        User u = new User(
            FirstName = 'Sample', LastName = 'Manager', Email = uniq + '@sciagen.invalid',
            Username = uniq + '@sciagen.invalid', Alias = uniq.left(8),
            TimeZoneSidKey = 'Asia/Kolkata', LocaleSidKey = 'en_IN',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US',
            ProfileId = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1].Id
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
            PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'Sciagen_Sample_Admin' LIMIT 1];
            insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
        }
        return u;
    }

    /// A disposable System Administrator test user, for the one gate that specifically needs real
    /// Modify All Data rather than Manage_Sample_Inventory: CallReportLockService.hasModifyAllData()
    /// (unlocking a submitted Call_Visit_Report__c directly, bypassing the Help & Support flow).
    /// SciagenAccess.hasModifyAllData() queries PermissionSetAssignment -- a setup object whose
    /// *pre-existing* rows aren't visible in test context without @isTest(SeeAllData=true), which is
    /// why even the deploying user's own (real) System Administrator access doesn't satisfy it here;
    /// a profile assigned to a User inserted inside this same test transaction does, because that
    /// PermissionSetAssignment row is freshly created, not pre-existing.
    public static User adminUser() {
        String uniq = 'sadmin' + Datetime.now().getTime();
        User u = new User(
            FirstName = 'System', LastName = 'Admin', Email = uniq + '@sciagen.invalid',
            Username = uniq + '@sciagen.invalid', Alias = uniq.left(8),
            TimeZoneSidKey = 'Asia/Kolkata', LocaleSidKey = 'en_IN',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US',
            ProfileId = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1].Id
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
        }
        return u;
    }

    /// Grants an already-inserted test user an additional permission set (e.g. layering
    /// Sciagen_Sample_Admin onto adminUser() when a single update needs to clear both
    /// CallReportLockService's Modify-All-Data gate and SampleDropService's own
    /// Manage_Sample_Inventory check on the same statement).
    public static void grant(User u, String permissionSetName) {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = :permissionSetName LIMIT 1];
            insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
        }
    }
}