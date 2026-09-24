/**
 * Inbound REST API serving the currently-active picklist values for
 * Sciagen_Account__c's HCO/HCP Type and Specialty/Speciality fields, so the
 * iPad app's New HCP/HCO request pickers stay in sync with whatever an admin
 * configures in Setup — instead of a hardcoded Swift array silently drifting
 * out of date every time someone adds or renames a picklist value.
 *
 * GET /services/apexrest/sciagen/v1/picklists
 *
 * Read-only, `with sharing`, and returns only currently-ACTIVE values (an
 * inactive/retired picklist value is deliberately excluded, matching what a
 * rep would see if they opened this field directly in Salesforce).
 */
@RestResource(urlMapping='/sciagen/v1/picklists')
global with sharing class SciagenPicklistService {

    global class PicklistOptions {
        global List<String> hcoTypes;
        global List<String> hcpTypes;
        global List<String> hcoSpecialties;
        global List<String> hcpSpecialties;
    }

    @HttpGet
    global static PicklistOptions getPicklists() {
        PicklistOptions options = new PicklistOptions();
        options.hcoTypes = activeValues('Sciagen_Account__c', 'HCO_Type__c');
        options.hcpTypes = activeValues('Sciagen_Account__c', 'HCP_Type__c');
        options.hcoSpecialties = activeValues('Sciagen_Account__c', 'Speciality__c');
        options.hcpSpecialties = activeValues('Sciagen_Account__c', 'Specialty__c');
        return options;
    }

    private static List<String> activeValues(String objectName, String fieldName) {
        List<String> values = new List<String>();
        Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
        Schema.SObjectType sType = globalDescribe.get(objectName);
        if (sType == null) return values;
        Schema.SObjectField field = sType.getDescribe().fields.getMap().get(fieldName);
        if (field == null) return values;
        for (Schema.PicklistEntry entry : field.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                values.add(entry.getValue());
            }
        }
        return values;
    }
}