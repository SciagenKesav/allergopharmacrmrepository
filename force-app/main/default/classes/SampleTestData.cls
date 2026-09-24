@isTest
public class SampleTestData {

    public static Product__c product(String name) {
        Product__c p = new Product__c(Name = name, Product_Code__c = 'SMP-' + Math.abs(name.hashCode()), Level__c = 'SKU', Is_Sample_Product__c = true,
            Sample_Unit_Value_INR__c = 10, Pack_Size__c = 4, Smallest_Market_Pack_Size__c = 10, Max_Packs_Per_HCP_Per_Year__c = 12);
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
}