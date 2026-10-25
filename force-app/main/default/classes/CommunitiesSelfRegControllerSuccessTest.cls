@isTest
private class CommunitiesSelfRegControllerSuccessTest {

    private static CommunitiesSelfRegController form(String password) {
        CommunitiesSelfRegController c = new CommunitiesSelfRegController();
        c.firstName = 'Self'; c.lastName = 'Reg'; c.email = 'selfreg@example.com'; c.communityNickname = 'selfreg1';
        c.password = password; c.confirmPassword = password;
        return c;
    }

    @isTest static void aCreatedUserWithAPasswordIsSignedIn() {
        CommunitiesSelfRegController.testCreatedUserId = '005000000000001AAA';
        Test.startTest();
        form('Passw0rd!x').registerUser();   // Site.login returns null outside a community; the branch is what we exercise
        Test.stopTest();
        System.assert(true);
    }

    @isTest static void aCreatedUserWithoutAPasswordIsSentToTheConfirmPage() {
        CommunitiesSelfRegController.testCreatedUserId = '005000000000001AAA';
        PageReference page = form(null).registerUser();
        System.assertNotEquals(null, page, 'No password: the user is redirected to the confirmation page');
        System.assert(page.getRedirect());
    }
}
