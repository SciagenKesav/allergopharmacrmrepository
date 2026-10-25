@isTest
private class SegmentationTerritorySharingServiceTest {

    private static User kam(String last) {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Key Account Manager' LIMIT 1];
        String uniq = 'segshare.' + last.toLowerCase() + '.' + Datetime.now().getTime();
        return new User(FirstName = 'Seg', LastName = last, Email = uniq + '@sciagen.invalid', Username = uniq + '@sciagen.invalid',
            Alias = 'sg' + last.left(4).toLowerCase(), TimeZoneSidKey = 'Asia/Kolkata', LocaleSidKey = 'en_IN',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', ProfileId = p.Id);
    }

    @isTest
    static void kamInTheHcpsTerritoryGetsEditAccessToItsSegmentation() {
        User repA = kam('RepA');
        User repB = kam('RepB');
        System.runAs(new User(Id = UserInfo.getUserId())) { insert new List<User>{ repA, repB }; }

        Territory__c tA = new Territory__c(Name = 'SegShare A', Territory_Code__c = 'SSA', Type__c = 'Territory');
        Territory__c tB = new Territory__c(Name = 'SegShare B', Territory_Code__c = 'SSB', Type__c = 'Territory');
        insert new List<Territory__c>{ tA, tB };
        Sciagen_Account__c hcp = new Sciagen_Account__c(Name = 'Dr. Seg Share', Type__c = 'HCP');
        insert hcp;
        insert new Account_Territory__c(Account__c = hcp.Id, Territory__c = tA.Id);
        // Segmentation owned by the admin running the test, like the real seeded rows.
        Segmentation__c seg = new Segmentation__c(HCP__c = hcp.Id, Classification__c = 'A');
        insert seg;
        insert new List<User_Territory__c>{
            new User_Territory__c(User__c = repA.Id, Territory__c = tA.Id),
            new User_Territory__c(User__c = repB.Id, Territory__c = tB.Id)
        };

        List<Segmentation__Share> shares = [SELECT UserOrGroupId, AccessLevel FROM Segmentation__Share WHERE ParentId = :seg.Id AND RowCause = 'Manual'];
        System.assertEquals(1, shares.size(), 'Only the KAM assigned to the HCP\'s territory gets a share');
        System.assertEquals(repA.Id, shares[0].UserOrGroupId);
        System.assertEquals('Edit', shares[0].AccessLevel);

        // Access is revoked when the territory assignment goes away.
        delete [SELECT Id FROM User_Territory__c WHERE User__c = :repA.Id];
        System.assertEquals(0, [SELECT COUNT() FROM Segmentation__Share WHERE ParentId = :seg.Id AND RowCause = 'Manual']);
    }

    @isTest
    static void newSegmentationIsSharedAtCreation() {
        User repA = kam('RepC');
        System.runAs(new User(Id = UserInfo.getUserId())) { insert repA; }
        Territory__c tA = new Territory__c(Name = 'SegShare C', Territory_Code__c = 'SSC', Type__c = 'Territory');
        insert tA;
        Sciagen_Account__c hcp = new Sciagen_Account__c(Name = 'Dr. Seg Share Two', Type__c = 'HCP');
        insert hcp;
        insert new Account_Territory__c(Account__c = hcp.Id, Territory__c = tA.Id);
        insert new User_Territory__c(User__c = repA.Id, Territory__c = tA.Id);

        Segmentation__c seg = new Segmentation__c(HCP__c = hcp.Id, Classification__c = 'B');
        insert seg;
        System.assertEquals(1, [SELECT COUNT() FROM Segmentation__Share WHERE ParentId = :seg.Id AND UserOrGroupId = :repA.Id AND RowCause = 'Manual']);
    }
}
