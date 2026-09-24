/**
 * Inbound REST API serving the currently-active picklist values for every
 * business-object dropdown the mobile app presents to a rep (Leave, Expense,
 * RCPA, Account Plan, Segmentation, Office Windows, Call Visit Report,
 * Planned Call) — so an admin can add, rename, or retire an option in
 * Salesforce Setup and have it reach the app on the next sync, with no app
 * release. Mirrors SciagenPicklistService's pattern (same activeValues
 * approach), scoped to the business objects rather than the New HCP/HCO
 * request flow.
 *
 * GET /services/apexrest/sciagen/v1/business-picklists
 *
 * Read-only, `with sharing`, and returns only currently-ACTIVE values.
 */
@RestResource(urlMapping='/sciagen/v1/business-picklists')
global with sharing class SciagenBusinessPicklistService {

    global class BusinessPicklists {
        global List<String> leaveTypes;
        global List<String> leaveStatuses;
        global List<String> expenseDayTypes;
        global List<String> expenseStatuses;
        global List<String> expenseNonFieldActivities;
        global List<String> expenseInterPatchModes;
        global List<String> expensePatchStationTypes;
        global List<String> expensePatchTravelModes;
        global List<String> expenseBillCategories;
        global List<String> monthlyClaimBillCategories;
        global List<String> rcpaTrends;
        global List<String> accountPlanStatuses;
        global List<String> accountPlanStages;
        global List<String> accountPlanHealths;
        global List<String> accountPlanTypes;
        global List<String> accountPlanRecordTypes;
        global List<String> actionItemStatuses;
        global List<String> stakeholderInfluences;
        global List<String> relationshipStrengths;
        global List<String> stakeholderRoles;
        global List<String> teamAccessLevels;
        global List<String> teamMemberRoles;
        global List<String> segmentationClassifications;
        global List<String> segmentationPotentials;
        global List<String> segmentationPriorities;
        global List<String> segmentationTiers;
        global List<String> officeWindowPreferences;
        global List<String> keyMessageReactions;
        global List<String> cvrActivityTypes;
        global List<String> cvrCallStatuses;
        global List<String> cvrCallTypes;
        global List<String> cvrRecordStatuses;
        global List<String> plannedCallCallTypes;
        global List<String> plannedCallProgramTypes;
        global List<String> plannedCallStatuses;
    }

    @HttpGet
    global static BusinessPicklists getBusinessPicklists() {
        BusinessPicklists p = new BusinessPicklists();
        p.leaveTypes = activeValues('Leave_Request__c', 'Type__c');
        p.leaveStatuses = activeValues('Leave_Request__c', 'Status__c');
        p.expenseDayTypes = activeValues('Daily_Expense__c', 'Day_Type__c');
        p.expenseStatuses = activeValues('Daily_Expense__c', 'Status__c');
        p.expenseNonFieldActivities = activeValues('Daily_Expense__c', 'Non_Field_Activity__c');
        p.expenseInterPatchModes = activeValues('Daily_Expense__c', 'Inter_Patch_Mode__c');
        p.expensePatchStationTypes = activeValues('Expense_Patch__c', 'Station_Type__c');
        p.expensePatchTravelModes = activeValues('Expense_Patch__c', 'Travel_Mode__c');
        p.expenseBillCategories = activeValues('Daily_Expense_Bill__c', 'Category__c');
        p.monthlyClaimBillCategories = activeValues('Monthly_Claim_Bill__c', 'Category__c');
        p.rcpaTrends = activeValues('RCPA_Line__c', 'Trend__c');
        p.accountPlanStatuses = activeValues('Account_Plan__c', 'Status__c');
        p.accountPlanStages = activeValues('Account_Plan__c', 'Stage__c');
        p.accountPlanHealths = activeValues('Account_Plan__c', 'Health__c');
        p.accountPlanTypes = activeValues('Account_Plan__c', 'Type__c');
        p.accountPlanRecordTypes = activeValues('Account_Plan__c', 'Plan_Record_Type__c');
        p.actionItemStatuses = activeValues('Action_Item__c', 'Status__c');
        p.stakeholderInfluences = activeValues('Plan_Stakeholder__c', 'Influence__c');
        p.relationshipStrengths = activeValues('Plan_Stakeholder__c', 'Strength__c');
        p.stakeholderRoles = activeValues('Plan_Stakeholder__c', 'Role__c');
        p.teamAccessLevels = activeValues('Account_Team_Member__c', 'Access__c');
        p.teamMemberRoles = activeValues('Account_Team_Member__c', 'Role__c');
        p.segmentationClassifications = activeValues('Segmentation__c', 'Classification__c');
        p.segmentationPotentials = activeValues('Segmentation__c', 'Potential__c');
        p.segmentationPriorities = activeValues('Segmentation__c', 'Priority__c');
        p.segmentationTiers = activeValues('Segmentation__c', 'Tier__c');
        p.officeWindowPreferences = activeValues('Office_Window__c', 'Preference__c');
        p.keyMessageReactions = activeValues('Key_Message__c', 'Reaction__c');
        p.cvrActivityTypes = activeValues('Call_Visit_Report__c', 'Activity_Type__c');
        p.cvrCallStatuses = activeValues('Call_Visit_Report__c', 'Call_Status__c');
        p.cvrCallTypes = activeValues('Call_Visit_Report__c', 'Call_Type__c');
        p.cvrRecordStatuses = activeValues('Call_Visit_Report__c', 'Record_Status__c');
        p.plannedCallCallTypes = activeValues('Planned_Call__c', 'Call_Type__c');
        p.plannedCallProgramTypes = activeValues('Planned_Call__c', 'Program_Type__c');
        p.plannedCallStatuses = activeValues('Planned_Call__c', 'Status__c');
        return p;
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