/**
 * Apex controller for the deviceResetAdmin LWC. Returns reset requests
 * with their owner and manager names for the admin console, filtered by
 * Status__c. Runs in USER_MODE so FLS is respected — the admin's profile
 * must have read access to Device_Reset_Request__c and OTP__c to see codes.
 */
public with sharing class DeviceResetAdminController {

    @AuraEnabled(cacheable=false)
    public static List<Device_Reset_Request__c> getResetRequests(String statusFilter) {
        String q =
            'SELECT Id, Name, Status__c, OTP__c, OTP_Expires__c, Verified__c, ' +
            '       Reason__c, CreatedDate, OwnerId, Owner.Name, ' +
            '       Manager__c, Manager__r.Name ' +
            'FROM Device_Reset_Request__c ';
        if (String.isNotBlank(statusFilter) && statusFilter != 'All') {
            q += 'WHERE Status__c = \'' + String.escapeSingleQuotes(statusFilter) + '\' ';
        }
        q += 'ORDER BY CreatedDate DESC LIMIT 200 WITH USER_MODE';
        return Database.query(q);
    }
}