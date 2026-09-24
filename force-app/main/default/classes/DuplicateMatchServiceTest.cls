@isTest
private class DuplicateMatchServiceTest {

    private static Sciagen_Account__c hcp(String first, String last, String phone, String email, String city, String pin, String spec, String lic) {
        return new Sciagen_Account__c(Id = fakeId(), Type__c = 'HCP', Name = 'Dr. ' + first + ' ' + last, First_Name__c = first, Last_Name__c = last,
            Phone__c = phone, Email__c = email, Billing_City__c = city, Billing_Postal_Code__c = pin, Specialty__c = spec, License_Number__c = lic);
    }

    private static Integer counter = 1;
    /** A syntactically valid Sciagen_Account__c Id, so pairs can be scored without inserting anything. */
    private static Id fakeId() {
        String n = String.valueOf(counter++);
        return (Id) (Sciagen_Account__c.SObjectType.getDescribe().getKeyPrefix() + '000000000' + n.leftPad(3, '0'));
    }

    private static Sciagen_Account__c hco(String name, Decimal lat, Decimal lon, String pin, String city) {
        return new Sciagen_Account__c(Id = fakeId(), Type__c = 'HCO', Name = name, Billing_City__c = city, Billing_Postal_Code__c = pin,
            Geolocation__Latitude__s = lat, Geolocation__Longitude__s = lon);
    }

    // ------------------------------------------------------------ text utilities

    @isTest static void nameTokensDropTitlesAndDegrees() {
        System.assertEquals(new List<String>{ 'farhan', 'ahmed' }, DuplicateText.nameTokens('Dr. Farhan Ahmed, MBBS MD'));
    }

    @isTest static void phoneticCollapsesSpellingVariants() {
        System.assertEquals(DuplicateText.phonetic('Badhwar'), DuplicateText.phonetic('Badwar'));
        System.assertEquals(DuplicateText.phonetic('Yashwanth'), DuplicateText.phonetic('Yeshwanth'));
        System.assertEquals(DuplicateText.phonetic('Mohd'), DuplicateText.phonetic('Mohammed'));
        System.assertNotEquals(DuplicateText.phonetic('Malhotra'), DuplicateText.phonetic('Mehra'));
    }

    @isTest static void identifierKeysNormalise() {
        System.assertEquals('9820000001', DuplicateText.phoneKey('+91-98200 00001'));
        System.assertEquals(null, DuplicateText.phoneKey('12345'));
        System.assertEquals('MCIKA201045678', DuplicateText.licenseKey('MCI-KA-2010-45678'));
        System.assertEquals('a@b.com', DuplicateText.emailKey(' A@B.com '));
        System.assertEquals(true, DuplicateText.isGenericMailbox('info@clinic.com'));
        System.assertEquals(false, DuplicateText.isGenericMailbox('neeraj@clinic.com'));
        System.assertEquals('sunshine.com', DuplicateText.websiteHost('https://www.sunshine.com/about'));
        System.assertEquals(null, DuplicateText.websiteHost('https://facebook.com/sunshine'));
    }

    @isTest static void similarityMeasures() {
        System.assertEquals(1, DuplicateText.jaroWinkler('abc', 'abc'));
        System.assert(DuplicateText.jaroWinkler('martha', 'marhta') > 0.95);
        System.assert(DuplicateText.levenshteinRatio('kitten', 'sitting') > 0.5);
        System.assertEquals(0, DuplicateText.jaroWinkler('abc', 'xyz'));
    }

    @isTest static void geoDistanceAndCells() {
        Decimal d = DuplicateText.distanceMetres(28.548, 77.243, 28.5482, 77.2431);
        System.assert(d > 15 && d < 40, 'about 25 m, got ' + d);
        System.assertEquals(9, DuplicateText.geoCellsAround(28.548, 77.243).size());
        System.assertEquals(null, DuplicateText.geoCell(0, 0));
    }

    // ------------------------------------------------------------ HCP scoring

    @isTest static void sameDoctorTwoSpellingsSharedPhoneIsFlagged() {
        Sciagen_Account__c a = hcp('Farhan', 'Ahmed', '9820000003', 'farhan.ahmed@example.com', 'Noida', null, null, null);
        Sciagen_Account__c b = hcp('Farhan', 'Ahmad', '+91 98200 00003', null, 'Noida', null, null, null);
        DuplicateMatchService.Result r = DuplicateMatchService.compare(a, b, null);
        System.assert(r.isCandidate, 'score ' + r.score + '\n' + r.reasonText());
        System.assertEquals(true, r.strongIdentifier);
        System.assert(r.reasonText().contains('Same phone'));
    }

    @isTest static void swappedNamesWithInitialAreTheSamePerson() {
        Sciagen_Account__c a = hcp('Sanjiv', 'Badhwar', null, null, 'Mumbai', '400056', 'Pulmonology', null);
        Sciagen_Account__c b = hcp('Badhwar', 'Sanjiv B', null, null, 'Mumbai', '400056', 'Pulmonology', null);
        DuplicateMatchService.Result r = DuplicateMatchService.compare(a, b, null);
        System.assert(r.isCandidate, 'score ' + r.score + '\n' + r.reasonText());
    }

    @isTest static void sameLicenceAndEmailIsHighConfidence() {
        Sciagen_Account__c a = hcp('Priya', 'Sharma', '9876543210', 'dr.priya@apex.com', 'Bengaluru', '560001', 'Cardiology', 'MCI-KA-2010-45678');
        Sciagen_Account__c b = hcp('Priya', 'Sharma', null, 'dr.priya@apex.com', 'Bengaluru', null, null, 'MCI KA 2010 45678');
        DuplicateMatchService.Result r = DuplicateMatchService.compare(a, b, null);
        System.assertEquals('High', r.confidence, r.reasonText());
    }

    @isTest static void similarSurnamesInTheSameCityAreNotFlagged() {
        Sciagen_Account__c a = hcp('Rohit', 'Malhotra', null, null, 'Gurugram', '122003', 'Paediatrics', null);
        Sciagen_Account__c b = hcp('Rohit', 'Mehra', null, null, 'Gurugram', '122003', 'Paediatrics', null);
        DuplicateMatchService.Result r = DuplicateMatchService.compare(a, b, null);
        System.assert(!r.isCandidate, 'Malhotra vs Mehra must not be flagged, score ' + r.score + '\n' + r.reasonText());
    }

    @isTest static void sameNameInDifferentCitiesIsNotFlagged() {
        Sciagen_Account__c a = hcp('Rajesh', 'Kumar', null, null, 'Delhi', '110001', 'Cardiology', null);
        Sciagen_Account__c b = hcp('Rajesh', 'Kumar', null, null, 'Chennai', '600001', 'Neurology', null);
        System.assert(!DuplicateMatchService.compare(a, b, null).isCandidate);
    }

    @isTest static void differentLicenceNumbersOverrideEverythingElse() {
        Sciagen_Account__c a = hcp('Anil', 'Gupta', '9811111111', 'anil@x.com', 'Delhi', '110001', 'ENT', 'LIC-100');
        Sciagen_Account__c b = hcp('Anil', 'Gupta', '9811111111', 'anil@x.com', 'Delhi', '110001', 'ENT', 'LIC-200');
        DuplicateMatchService.Result r = DuplicateMatchService.compare(a, b, null);
        System.assert(r.reasonText().contains('Different licence numbers'));
        System.assert(r.score < 100);
    }

    @isTest static void sharedClinicLineAloneIsCappedAndNotHighConfidence() {
        DuplicateMatchService.Context ctx = new DuplicateMatchService.Context();
        ctx.phoneFreq.put('1140000000', 6);
        Sciagen_Account__c a = hcp('Asha', 'Rao', '011-4000-0000', null, 'Delhi', '110001', 'ENT', null);
        Sciagen_Account__c b = hcp('Vikram', 'Sethi', '011-4000-0000', null, 'Delhi', '110001', 'ENT', null);
        DuplicateMatchService.Result r = DuplicateMatchService.compare(a, b, ctx);
        System.assert(r.score < 55, 'a shared line must not link two different doctors, score ' + r.score + '\n' + r.reasonText());
    }

    @isTest static void differentTypesNeverMatch() {
        Sciagen_Account__c a = hcp('Farhan', 'Ahmed', '9820000003', null, 'Noida', null, null, null);
        Sciagen_Account__c b = hco('Farhan Ahmed', 28.5, 77.2, '110001', 'Noida');
        System.assertEquals('None', DuplicateMatchService.compare(a, b, null).confidence);
    }

    // ------------------------------------------------------------ HCO scoring

    @isTest static void sameClinicWithDifferentNameFormatIsHighConfidence() {
        Sciagen_Account__c a = hco('Sunshine ENT & Allergy Clinic', 28.5480, 77.2430, '110048', 'South Delhi');
        Sciagen_Account__c b = hco('Sunshine ENT and Allergy Clinic Pvt Ltd', 28.5482, 77.2431, '110048', 'South Delhi');
        DuplicateMatchService.Result r = DuplicateMatchService.compare(a, b, null);
        System.assertEquals('High', r.confidence, r.reasonText());
    }

    @isTest static void differentBranchesOfTheSameBrandAreNotFlagged() {
        Sciagen_Account__c a = hco('Max Super Speciality Hospital', 28.5273, 77.2100, '110092', 'Delhi');
        Sciagen_Account__c b = hco('Nanavati Max Super Speciality Hospital', 28.7196, 77.1909, '110005', 'North Delhi');
        DuplicateMatchService.Result r = DuplicateMatchService.compare(a, b, null);
        System.assert(!r.isCandidate, 'different branches must not be flagged, score ' + r.score + '\n' + r.reasonText());
    }

    @isTest static void hospitalAndItsOwnDepartmentAreNotDuplicates() {
        Sciagen_Account__c parent = hco('Apex Care Hospital', 12.9716, 77.5946, '560001', 'Bengaluru');
        Sciagen_Account__c dept = hco('Apex Care Hospital', 12.9716, 77.5946, '560001', 'Bengaluru');
        dept.Parent_Account__c = parent.Id;
        DuplicateMatchService.Result r = DuplicateMatchService.compare(parent, dept, null);
        System.assert(r.reasonText().contains('parent of the other'), r.reasonText());
        System.assert(r.score < 100);
    }

    @isTest static void externalIdsParseFromJsonLinesAndBareValues() {
        System.assertEquals(new Set<String>{ 'N1123' + '' }.size(), DuplicateMatchService.externalIdValues('{"NABH":"N-1123"}').size());
        System.assert(DuplicateMatchService.sharedExternalIds('NABH:N-1123\nGST:22AAAAA', 'gst=22aaaaa').contains('22AAAAA'));
        System.assert(DuplicateMatchService.sharedExternalIds('MERGED_FROM:001', 'MERGED_FROM:001').isEmpty());
    }
}