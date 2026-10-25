/**
 * Shared, per-transaction access facts used by the server-side guards
 * (CallReportLockService, SampleTransactionService, DeviceResetRequestHandler).
 */
public without sharing class SciagenAccess {

    /**
     * True while DuplicateMergeService is re-pointing children from a losing
     * HCP/HCO to the survivor (or back, on undo). Guards that would otherwise
     * reject changes to locked records let account re-pointing through.
     */
    public static Boolean mergeInProgress = false;

    private static Map<Id, Boolean> modifyAllDataByUser = new Map<Id, Boolean>();

    /** The running user has Modify All Data (profile or permission set). */
    public static Boolean hasModifyAllData() {
        Id uid = UserInfo.getUserId();
        if (!modifyAllDataByUser.containsKey(uid)) {
            // PermissionSetAssignment includes each user's profile-owned permission set.
            modifyAllDataByUser.put(uid, [
                SELECT COUNT() FROM PermissionSetAssignment
                WHERE AssigneeId = :uid AND PermissionSet.PermissionsModifyAllData = true
            ] > 0);
        }
        return modifyAllDataByUser.get(uid);
    }
}