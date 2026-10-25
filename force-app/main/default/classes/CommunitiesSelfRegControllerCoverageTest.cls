@isTest
private class CommunitiesSelfRegControllerCoverageTest {

    @isTest
    static void experienceIdParameterIsAccepted() {
        PageReference pr = new PageReference('/CommunitiesSelfReg');
        pr.getParameters().put('expid', '0DM000000000000');
        Test.setCurrentPage(pr);
        try {
            new CommunitiesSelfRegController();
        } catch (System.RequiredFeatureMissingException e) {
            System.assert(e.getMessage().contains('community'));   // Site.setExperienceId only works inside an Experience site
        }
    }

    @isTest
    static void mismatchedPasswordsAddAnError() {
        Test.setCurrentPage(new PageReference('/CommunitiesSelfReg'));
        CommunitiesSelfRegController c = new CommunitiesSelfRegController();
        c.password = ' abcd1234 ';
        c.confirmPassword = 'different';
        c.communityNickname = ' nick ';
        System.assertEquals('abcd1234', c.password);
        System.assertEquals('nick', c.communityNickname);
        System.assertEquals(null, c.registerUser());
        System.assert(ApexPages.hasMessages(ApexPages.Severity.ERROR));
    }

    @isTest
    static void registrationOutsideASiteReturnsNull() {
        Test.setCurrentPage(new PageReference('/CommunitiesSelfReg'));
        CommunitiesSelfRegController c = new CommunitiesSelfRegController();
        c.firstName = 'First';
        c.lastName = 'Last';
        c.email = 'selfreg.coverage@sciagen-test.invalid';
        c.communityNickname = 'selfregcov';
        c.password = 'Abcd1234xyz';
        c.confirmPassword = 'Abcd1234xyz';
        System.assertEquals(null, c.registerUser());
        c.password = null;
        c.confirmPassword = null;
        System.assertEquals(null, c.registerUser());
    }
}
