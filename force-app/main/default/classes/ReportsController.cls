/** Thin @AuraEnabled facade over ReportsService (read-only). */
public with sharing class ReportsController {
    @AuraEnabled(cacheable=true)
    public static ReportsService.ReportResult getReport(String reportKey, String paramsJson) {
        return ReportsService.getReport(reportKey, parse(paramsJson));
    }
    @AuraEnabled(cacheable=true)
    public static ReportsService.FilterOptions getFilterOptions(String startDate, String endDate, String repUserId, String territoryId) {
        return ReportsService.getFilterOptions(Date.valueOf(startDate), Date.valueOf(endDate), String.isBlank(repUserId) ? null : (Id) repUserId, String.isBlank(territoryId) ? null : (Id) territoryId);
    }
    @AuraEnabled(cacheable=true)
    public static ReportsService.ScopeOptions getScopeOptions() {
        return ReportsService.getScopeOptions();
    }
    @AuraEnabled(cacheable=true)
    public static List<ReportsService.HcpRow> getGroupDoctors(String paramsJson, String dim, String value) {
        return ReportsService.groupDoctors(parse(paramsJson), dim, value);
    }
    @AuraEnabled(cacheable=true)
    public static ReportsService.HcpDetail getHcpDetail(String hcpId, String startDate, String endDate, String repUserId, String territoryId) {
        return ReportsService.getHcpDetail((Id) hcpId, Date.valueOf(startDate), Date.valueOf(endDate), String.isBlank(repUserId) ? null : (Id) repUserId, String.isBlank(territoryId) ? null : (Id) territoryId);
    }
    @AuraEnabled(cacheable=true)
    public static Map<String, String> getLibrary(String startDate, String endDate, String repUserId, String territoryId, String nonce) {
        return ReportsService.getLibrary(Date.valueOf(startDate), Date.valueOf(endDate), String.isBlank(repUserId) ? null : (Id) repUserId, String.isBlank(territoryId) ? null : (Id) territoryId);
    }
    @AuraEnabled(cacheable=true)
    public static ReportsService.ReportResult getSales(String paramsJson) {
        return ReportsService.getSales(parse(paramsJson));
    }
    @AuraEnabled(cacheable=true)
    public static ReportsService.Tbl getSalesDrill(String paramsJson, String key) {
        return ReportsService.getSalesDrill(parse(paramsJson), key);
    }
    @AuraEnabled(cacheable=true)
    public static ReportsService.ReportResult getSamples(String paramsJson) {
        return ReportsService.getSamples(parse(paramsJson));
    }
    private static Map<String, Object> parse(String j) {
        return String.isBlank(j) ? new Map<String, Object>() : (Map<String, Object>) JSON.deserializeUntyped(j);
    }
}