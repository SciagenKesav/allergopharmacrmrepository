@isTest
private class RCPAMoleculeProductsTest {
    @isTest
    static void returnsDistinctCompetitor1ValuesForTheMolecule() {
        insert new List<Product__c>{
            new Product__c(Name = 'Brand A', Parent_Molecule__c = 'Mol X', Active__c = true, Product_Code__c = 'RMP-1', Competitor1__c = 'SENSIMUNE'),
            new Product__c(Name = 'Brand A2', Parent_Molecule__c = 'Mol X', Active__c = true, Product_Code__c = 'RMP-2', Competitor1__c = 'SENSIMUNE'),
            new Product__c(Name = 'Brand B', Parent_Molecule__c = 'Mol X', Active__c = true, Product_Code__c = 'RMP-3', Competitor1__c = 'ALLCURE'),
            new Product__c(Name = 'Brand C', Parent_Molecule__c = 'Mol X', Active__c = true, Product_Code__c = 'RMP-4'),
            new Product__c(Name = 'Other', Parent_Molecule__c = 'Mol Y', Active__c = true, Product_Code__c = 'RMP-5', Competitor1__c = 'ZZZ')
        };
        System.assertEquals(new List<String>{ 'ALLCURE', 'SENSIMUNE' }, RCPAMatrixController.getCompetitor1ForMolecule('Mol X'));
        System.assertEquals(0, RCPAMatrixController.getCompetitor1ForMolecule(null).size());
    }
}