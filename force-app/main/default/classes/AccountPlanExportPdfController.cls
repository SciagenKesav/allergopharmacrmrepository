public with sharing class AccountPlanExportPdfController {
    // Visualforce EL binding (`{!p.title}`) only resolves true getter/setter
    // properties, not the plain @AuraEnabled public fields PlanListItem uses
    // for its LWC callers — hence this separate property-style row type
    // instead of exposing PlanListItem to the page directly (confirmed live:
    // binding straight to PlanListItem fails deployment with "Unknown
    // property ...PlanListItem.title").
    public class Row {
        public String title { get; set; }
        public String accountName { get; set; }
        public String status { get; set; }
        public String stage { get; set; }
        public String health { get; set; }
        public String ownerName { get; set; }
    }

    public List<Row> plans { get; private set; }
    public String generatedOn { get; private set; }

    // Reuses AccountPlanHomeDashboardController.searchAccountPlans directly —
    // same filters, same query, same results the KAM Dashboard list already
    // shows — so the PDF always matches whatever's currently on screen
    // instead of drifting out of sync with a second copy of the query.
    public AccountPlanExportPdfController() {
        Map<String, String> params = ApexPages.currentPage().getParameters();
        List<AccountPlanHomeDashboardController.PlanListItem> items = AccountPlanHomeDashboardController.searchAccountPlans(
            params.get('searchTerm'), params.get('statusFilter'), params.get('stageFilter'));
        plans = new List<Row>();
        for (AccountPlanHomeDashboardController.PlanListItem item : items) {
            Row r = new Row();
            r.title = item.title;
            r.accountName = item.accountName;
            r.status = item.status;
            r.stage = item.stage;
            r.health = item.health;
            r.ownerName = item.ownerName;
            plans.add(r);
        }
        generatedOn = DateTime.now().format('MMM d, yyyy h:mm a');
    }
}