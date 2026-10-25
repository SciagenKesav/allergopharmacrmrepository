/**
 * Test-only user factory: Standard Platform User reps (the licence field reps
 * hold) with the named permission sets, so access-sensitive tests run through
 * System.runAs as a real rep rather than as the admin running the tests.
 * Setup-object DML runs in its own runAs block to avoid MIXED_DML.
 */
@isTest
public class SciagenTestUsers {

    public static User rep(String alias, List<String> permissionSets) {
        return make(alias, 'Standard Platform User', permissionSets, null);
    }

    public static User rep(String alias, List<String> permissionSets, Id managerId) {
        return make(alias, 'Standard Platform User', permissionSets, managerId);
    }

    public static User mobileRep(String alias) {
        return rep(alias, new List<String>{ 'Sciagen_Mobile_App_Access' });
    }

    public static User make(String alias, String profileName, List<String> permissionSets, Id managerId) {
        Profile prof = [SELECT Id FROM Profile WHERE Name = :profileName LIMIT 1];
        User u = new User(
            FirstName = 'Test', LastName = 'User ' + alias, Alias = alias.left(8),
            Email = alias + '@sciagen-test.invalid', EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_IN', TimeZoneSidKey = 'Asia/Kolkata',
            ProfileId = prof.Id, ManagerId = managerId,
            Username = alias + '.' + System.currentTimeMillis() + '.' + Crypto.getRandomInteger() + '@sciagen-test.invalid'
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
            if (permissionSets != null && !permissionSets.isEmpty()) {
                List<PermissionSetAssignment> psas = new List<PermissionSetAssignment>();
                for (PermissionSet ps : [SELECT Id FROM PermissionSet WHERE Name IN :permissionSets]) {
                    psas.add(new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id));
                }
                insert psas;
            }
        }
        return u;
    }
}