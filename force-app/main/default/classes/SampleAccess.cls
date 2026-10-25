/**
 * Whether the running user holds Manage_Sample_Inventory (sample-manager actions: approving an
 * override, releasing a manager hold, bulk stock changes, UCPMP config). A thin wrapper around
 * FeatureManagement.checkPermission() rather than calling it directly everywhere, because that
 * platform check is known to be unreliable in Apex tests when the permission was granted via a
 * PermissionSetAssignment inserted earlier in the SAME test transaction (it can intermittently
 * read as false once many test classes run together, e.g. under RunLocalTests) -- the same class
 * of platform quirk PlannedCallScheduleGuardService.testBackdateLimitDays works around for the
 * backdate limit. Tests should set testIsManager instead of relying on FeatureManagement timing.
 */
public class SampleAccess {
    @TestVisible private static Boolean testIsManager;

    public static Boolean isManager() {
        if (testIsManager != null) return testIsManager;
        return FeatureManagement.checkPermission('Manage_Sample_Inventory');
    }
}