@isTest
private class SampleLimitGuardServiceTest {

    // Same pattern as SampleDropServiceTest/UCPMPComplianceControllerTest —
    // FeatureManagement.checkPermission() doesn't reliably see a
    // PermissionSetAssignment created in the same transaction it's checked in.
    @testSetup
    static void users() {
        Profile std = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        Profile sysAdmin = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        User rep = new User(FirstName = 'No', LastName = 'GuardPermTest', Alias = 'noguard', Email = 'no.perm.guard@sciagen-test.invalid',
            Username = 'no.perm.guard@sciagen-new-dev.invalid', TimeZoneSidKey = 'Asia/Kolkata', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', ProfileId = std.Id, IsActive = true);
        User admin = new User(FirstName = 'Sample', LastName = 'AdminGuardTest', Alias = 'sadmg', Email = 'sample.admin.guard@sciagen-test.invalid',
            Username = 'sample.admin.guard@sciagen-new-dev.invalid', TimeZoneSidKey = 'Asia/Kolkata', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', ProfileId = sysAdmin.Id, IsActive = true);
        insert new List<User>{ rep, admin };
        insert new PermissionSetAssignment(AssigneeId = rep.Id, PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Sciagen_Mobile_App_Access'].Id);
        insert new PermissionSetAssignment(AssigneeId = admin.Id, PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Sciagen_Sample_Admin'].Id);
    }

    static User repNoPermission() { return [SELECT Id FROM User WHERE Username = 'no.perm.guard@sciagen-new-dev.invalid']; }
    static User sampleAdminUser() { return [SELECT Id FROM User WHERE Username = 'sample.admin.guard@sciagen-new-dev.invalid']; }

    @isTest
    static void regulatoryLimitCanNotChangeScopePeriodOrProduct() {
        Product__c p1 = SampleTestData.product('Guard SKU One');
        Product__c p2 = SampleTestData.product('Guard SKU Two');
        Sample_Limit__c reg = new Sample_Limit__c(Name = 'Guard reg limit', Limit_Scope__c = 'HCP_Product', Product__c = p1.Id, Limit_Quantity__c = 12,
            Limit_Period__c = 'Financial_Year', Hard_Block__c = true, Is_Regulatory__c = true, Regulatory_Reference__c = SampleLimitChecker.UCPMP_REF);
        insert reg;

        reg.Limit_Scope__c = 'HCP_All';
        System.assert(!Database.update(reg, false).isSuccess(), 'scope can not change');
        reg.Limit_Scope__c = 'HCP_Product';

        reg.Limit_Period__c = 'Monthly';
        System.assert(!Database.update(reg, false).isSuccess(), 'period can not change');
        reg.Limit_Period__c = 'Financial_Year';

        reg.Product__c = p2.Id;
        Database.SaveResult productChange = Database.update(reg, false);
        System.assert(!productChange.isSuccess(), 'product can not change');
        System.assert(productChange.getErrors()[0].getMessage().contains('scope, period and product'), productChange.getErrors()[0].getMessage());
        reg.Product__c = p1.Id;

        System.assert(Database.update(reg, false).isSuccess(), 'reverting back to the original values is allowed');
    }

    @isTest
    static void companyLimitScopePeriodProductAreFreeToChange() {
        Product__c p1 = SampleTestData.product('Guard Company SKU One');
        Product__c p2 = SampleTestData.product('Guard Company SKU Two');
        Sample_Limit__c company = new Sample_Limit__c(Name = 'Guard company limit', Limit_Scope__c = 'HCP_Product', Product__c = p1.Id,
            Limit_Quantity__c = 20, Limit_Period__c = 'Monthly', Hard_Block__c = false);
        insert company;
        company.Limit_Scope__c = 'Rep_Product';
        company.Product__c = p2.Id;
        company.Limit_Period__c = 'Weekly';
        System.assert(Database.update(company, false).isSuccess(), 'only regulatory limits are locked down');
    }

    @isTest
    static void overrideActivationRequiresAManagerAndStampsApproval() {
        Product__c p = SampleTestData.product('Guard Override SKU');
        Sciagen_Account__c d = SampleTestData.doctor('Dr Guard Override');
        Sample_Limit__c company = new Sample_Limit__c(Name = 'Guard override limit', Limit_Scope__c = 'HCP_Product', Product__c = p.Id,
            Limit_Quantity__c = 6, Limit_Period__c = 'Financial_Year', Hard_Block__c = false);
        insert company;
        Sample_Limit_Override__c pending = new Sample_Limit_Override__c(Sample_Limit__c = company.Id, Override_Type__c = 'Increase', Override_Value__c = 10,
            Target_Account__c = d.Id, Reason__c = 'test', Status__c = 'Pending');
        insert pending;

        System.runAs(repNoPermission()) {
            Sample_Limit_Override__c attempt = [SELECT Id, Status__c, Sample_Limit__c, Target_Account__c FROM Sample_Limit_Override__c WHERE Id = :pending.Id];
            attempt.Status__c = 'Active';
            Database.SaveResult r = Database.update(attempt, false);
            System.assert(!r.isSuccess(), 'a rep without Manage_Sample_Inventory can not approve an override');
            System.assert(r.getErrors()[0].getMessage().contains('sample manager'), r.getErrors()[0].getMessage());
        }

        System.runAs(sampleAdminUser()) {
            Sample_Limit_Override__c attempt = [SELECT Id, Status__c FROM Sample_Limit_Override__c WHERE Id = :pending.Id];
            attempt.Status__c = 'Active';
            update attempt;
        }
        Sample_Limit_Override__c activated = [SELECT Status__c, Approved_By__c, Approved_At__c FROM Sample_Limit_Override__c WHERE Id = :pending.Id];
        System.assertEquals('Active', activated.Status__c);
        System.assertEquals(sampleAdminUser().Id, activated.Approved_By__c);
        System.assertNotEquals(null, activated.Approved_At__c);
    }

    @isTest
    static void regulatoryLimitsCanNotBeOverriddenEvenByAManager() {
        Product__c p = SampleTestData.product('Guard No Override SKU');
        Sciagen_Account__c d = SampleTestData.doctor('Dr Guard No Override');
        Sample_Limit__c reg = new Sample_Limit__c(Name = 'Guard no-override limit', Limit_Scope__c = 'HCP_Product', Product__c = p.Id, Limit_Quantity__c = 12,
            Limit_Period__c = 'Financial_Year', Hard_Block__c = true, Is_Regulatory__c = true, Regulatory_Reference__c = SampleLimitChecker.UCPMP_REF);
        insert reg;
        Database.SaveResult r;
        System.runAs(sampleAdminUser()) {
            r = Database.insert(new Sample_Limit_Override__c(Sample_Limit__c = reg.Id, Override_Type__c = 'Exempt', Target_Account__c = d.Id,
                Reason__c = 'x', Status__c = 'Active'), false);
        }
        System.assert(!r.isSuccess());
        System.assert(r.getErrors()[0].getMessage().contains('can\'t be overridden'), r.getErrors()[0].getMessage());
    }

    @isTest
    static void regulatoryLimitCanNotBeDeleted() {
        Product__c p = SampleTestData.product('Guard No Delete SKU');
        Sample_Limit__c reg = new Sample_Limit__c(Name = 'Guard no-delete limit', Limit_Scope__c = 'HCP_Product', Product__c = p.Id, Limit_Quantity__c = 12,
            Limit_Period__c = 'Financial_Year', Hard_Block__c = true, Is_Regulatory__c = true, Regulatory_Reference__c = SampleLimitChecker.UCPMP_REF);
        insert reg;
        Database.DeleteResult r = Database.delete(reg, false);
        System.assert(!r.isSuccess());
        System.assert(r.getErrors()[0].getMessage().contains('can\'t be deleted'), r.getErrors()[0].getMessage());
    }
}
