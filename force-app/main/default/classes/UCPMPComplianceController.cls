/** Backend for the UCPMP Compliance dashboard page. */
public with sharing class UCPMPComplianceController {

    public class ConfigDTO {
        @AuraEnabled public String financialYear;
        @AuraEnabled public Decimal domesticSalesInr;
        @AuraEnabled public Decimal domesticSalesCrore;
        @AuraEnabled public String companyName;
        @AuraEnabled public String cin;
        @AuraEnabled public String address;
        @AuraEnabled public String email;
        @AuraEnabled public String pan;
        @AuraEnabled public String designation;
        @AuraEnabled public String dinOrPan;
        @AuraEnabled public String mobile;
        @AuraEnabled public String signEmail;
        @AuraEnabled public Boolean canEdit;
    }

    public class FileDTO {
        @AuraEnabled public Id documentId;
        @AuraEnabled public String downloadPath;
        @AuraEnabled public String title;
    }

    @AuraEnabled(cacheable=false) public static List<String> getFinancialYears() { return UCPMPComplianceService.financialYears(); }
    @AuraEnabled(cacheable=false) public static UCPMPComplianceService.UCPMPSummary getSummary(String fy) { return UCPMPComplianceService.getExpenditureSummary(fy); }
    @AuraEnabled(cacheable=false) public static List<UCPMPComplianceService.HCPReport> getHcpReport(String fy) { return UCPMPComplianceService.getHCPReport(fy); }
    @AuraEnabled(cacheable=false) public static UCPMPComplianceService.RestrictedReport getRestricted() { return UCPMPComplianceService.getRestrictedReport(90); }

    @AuraEnabled(cacheable=false)
    public static ConfigDTO getConfig() {
        SampleConfig cfg = SampleConfig.load();
        UCPMP_Tenant_Config__c r = UCPMP_Tenant_Config__c.getOrgDefaults();
        ConfigDTO d = new ConfigDTO();
        d.financialYear = String.isBlank(cfg.financialYear) ? SampleLimitChecker.financialYear(Date.today()) : cfg.financialYear;
        d.domesticSalesInr = cfg.domesticSalesInr;
        d.domesticSalesCrore = cfg.domesticSalesInr == null ? null : (cfg.domesticSalesInr / UCPMPComplianceService.CRORE).setScale(2);
        d.companyName = r.Company_Name__c; d.cin = r.Company_CIN__c; d.address = r.Company_Address__c; d.email = r.Company_Email__c; d.pan = r.Company_PAN__c;
        d.designation = r.Signatory_Designation__c; d.dinOrPan = r.Signatory_DIN_or_PAN__c; d.mobile = r.Signatory_Mobile__c; d.signEmail = r.Signatory_Email__c;
        d.canEdit = FeatureManagement.checkPermission('Manage_Sample_Inventory');
        return d;
    }

    @AuraEnabled
    public static ConfigDTO saveConfig(String financialYear, Decimal domesticSalesCrore, String companyName, String cin, String address, String email, String pan,
                                       String designation, String dinOrPan, String mobile, String signEmail) {
        if (!FeatureManagement.checkPermission('Manage_Sample_Inventory')) throw new AuraHandledException('Only a sample manager can change the UCPMP settings.');
        if (domesticSalesCrore != null && domesticSalesCrore < 0) throw new AuraHandledException('Domestic sales can not be negative.');
        UCPMP_Tenant_Config__c r = UCPMP_Tenant_Config__c.getOrgDefaults();
        if (r.Id == null) {
            r.SetupOwnerId = UserInfo.getOrganizationId();
            r.UCPMP_Compliance_Enabled__c = true;
            r.Enforce_Sample_Rules__c = true;
            r.Sample_Opt_In_Months__c = 12;
        }
        r.Financial_Year__c = financialYear;
        r.Domestic_Sales_Revenue_INR__c = domesticSalesCrore == null ? null : domesticSalesCrore * UCPMPComplianceService.CRORE;
        r.Company_Name__c = companyName; r.Company_CIN__c = cin; r.Company_Address__c = address; r.Company_Email__c = email; r.Company_PAN__c = pan;
        r.Signatory_Designation__c = designation; r.Signatory_DIN_or_PAN__c = dinOrPan; r.Signatory_Mobile__c = mobile; r.Signatory_Email__c = signEmail;
        upsert r;
        return getConfig();
    }

    /** Builds the Annexure PDF for the year, saves it as a File and returns where to download it. */
    @AuraEnabled
    public static FileDTO generateDisclosure(String fy) {
        Blob pdf = UCPMPComplianceService.generateDisclosureForm(fy);
        String title = 'UCPMP Disclosure FY ' + fy;
        ContentVersion cv = new ContentVersion(Title = title, PathOnClient = title + '.pdf', VersionData = pdf);
        insert cv;
        cv = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id];
        FileDTO f = new FileDTO();
        f.documentId = cv.ContentDocumentId;
        f.downloadPath = '/sfc/servlet.shepherd/document/download/' + cv.ContentDocumentId;
        f.title = title;
        return f;
    }
}