/**
 * Rejects a Phone__c with more than 10 significant digits. A leading '91'
 * country code or '0' trunk prefix is stripped before counting, so existing
 * "+91-xxxxx-xxxxx" style numbers validate the same as their plain
 * 10-digit form instead of being penalized for the country code.
 */
public without sharing class SciagenAccountPhoneGuardService {

    public static void validate(List<Sciagen_Account__c> accounts) {
        for (Sciagen_Account__c acc : accounts) {
            if (String.isBlank(acc.Phone__c)) continue;
            String digits = acc.Phone__c.replaceAll('[^0-9]', '');
            if (digits.length() > 10 && digits.startsWith('91') && digits.length() - 2 <= 10) {
                digits = digits.substring(2);
            } else if (digits.length() > 10 && digits.startsWith('0')) {
                digits = digits.substring(1);
            }
            if (digits.length() > 10) {
                acc.Phone__c.addError('Phone number can\'t have more than 10 digits.');
            }
        }
    }
}