// Shared color tokens and pill-styling helper, mirrored from the iPad app's
// own design system (SciagenCRM/Theme.swift) and its per-enum `.color`
// properties (ABC classification, Tier, DCRStatus, RxTrend, CVR record
// status) — so status/trend colors read the same on Salesforce as they do
// on the iPad app, not an independently-invented palette.

export const BRAND = {
    primary: '4F46E5', // Theme.swift Brand.primary (indigo 600)
    violet: '7C3AED',  // Theme.swift Brand.violet
    accent: '059669',  // Theme.swift Brand.accent (emerald 600)
    amber: 'F59E0B',   // Theme.swift Brand.amber
    red: 'DC2626',
    ink: '0F172A',
    subtle: '64748B',
    bg: 'F3F4FB',
    hairline: 'E2E8F0',
    gold: 'D4A017',
    silver: '8E8E93',
    bronze: 'B87333',
};

// Matches the iOS `Chip` component: a translucent tint background with the
// same color as opaque text — SwiftUI's `.opacity(0.13)` on the fill.
export function pillStyle(hex) {
    if (!hex) return `background-color:#${BRAND.subtle}22;color:#${BRAND.subtle};`;
    return `background-color:#${hex}22;color:#${hex};`;
}

// Segmentation__c.Classification__c — matches enum ABC in UserModels.swift
export const CLASSIFICATION_COLOR = { V3: BRAND.accent, V2: BRAND.primary, V1: BRAND.amber, A: BRAND.accent, B: BRAND.primary, C: BRAND.amber, Unclassified: BRAND.subtle };

// Segmentation__c.Tier__c — matches enum Tier in UserModels.swift
export const TIER_COLOR = { Gold: BRAND.gold, Silver: BRAND.silver, Bronze: BRAND.bronze, None: BRAND.subtle };

// Data_Change_Request__c.Status__c — matches enum DCRStatus in UserModels.swift
export const DCR_STATUS_COLOR = { 'Pending Approval': BRAND.amber, Approved: BRAND.accent, Rejected: BRAND.red };

// Sciagen_Alert__c.Priority__c — matches enum AlertPriority on the iPad app.
export const ALERT_PRIORITY_COLOR = { Urgent: BRAND.red, Important: BRAND.amber, Normal: BRAND.subtle };

// Sciagen_Alert__c.Type__c — matches enum SciagenAlertType on the iPad app.
export const ALERT_TYPE_COLOR = { Company: BRAND.primary, Content: BRAND.violet, DCR: BRAND.accent };

// RCPA_Line__c.Trend__c — matches enum RxTrend in RCPAModels.swift
export const TREND_COLOR = {
    'New Rx': BRAND.violet,
    Growing: BRAND.accent,
    Stable: BRAND.primary,
    Declining: BRAND.amber,
    'Switched to competitor': BRAND.red,
};

// Office_Window__c.Preference__c — matches enum MeetPreference in UserModels.swift
export const PREFERENCE_COLOR = { Best: BRAND.accent, Good: BRAND.amber, Avoid: BRAND.red };

export const ACAROID_READINESS_COLOR = { Ready: BRAND.accent, Conditional: BRAND.amber, 'Not Ready': BRAND.red };
export const ACAROID_CAN_ADMINISTER_COLOR = { Yes: BRAND.accent, Conditional: BRAND.amber, 'No - Referral only': BRAND.red };
export const ACAROID_TIER_COLOR = {
    A: BRAND.accent, B: BRAND.primary, C: BRAND.amber, Referral: BRAND.subtle,
    'Tier 1 - AIT Centre of Excellence': BRAND.accent, 'Tier 2 - Specialty AIT Site': BRAND.primary,
    'Tier 3 - Referral Site': BRAND.amber, 'Not Targeted': BRAND.subtle,
};


// Planned_Call__c.Status__c — matches PlannedCall.status in CLMModels.swift.
// Superseded by visitState() below for anywhere that shows a call's status
// to the rep (My Schedule's Agenda/Week/Month views) — this flat 3-color map
// doesn't distinguish Submitted/Saved (both read as "Completed" here) or a
// still-open Planned call from one whose date has already passed unfiled,
// which is exactly the distinction visitState() exists to make. Kept around
// only for call sites that haven't been ported to visitState() yet.
export const PLANNED_CALL_STATUS_COLOR = { Planned: BRAND.primary, Draft: BRAND.amber, Completed: BRAND.accent, Cancelled: BRAND.subtle };

// Matches CalendarPlannerView.swift's visitState(_:) color scheme exactly —
// hex-for-hex, not just conceptually — so a call reads the same color on the
// iPad and in Salesforce. Note Cancelled here is a lighter slate ('94A3B8')
// than BRAND.subtle ('64748B'): that's not a typo, it's what the app uses.
const VISIT_STATE_COLOR = {
    Submitted: '059669',
    Saved: '0EA5A5',
    Draft: BRAND.amber,
    Planned: '4F46E5',
    Past: 'DC2626',
    Cancelled: '94A3B8',
};

/// Same decision tree as CalendarPlannerView.swift's visitState(_:): a
/// cancelled call always wins; a call with a linked Call_Visit_Report__c
/// reads that report's own Record_Status__c (Submitted/Saved/else-Draft)
/// rather than the Planned_Call__c's own Status__c, since Status__c only
/// ever reaches 'Completed' once a report exists, without saying whether
/// that report was actually submitted; otherwise a past, still-"Planned"
/// call reads as overdue rather than upcoming.
/// `call` needs `status`, `callDateTime` (ISO string), `resultingCVRId`,
/// and `resultingCVRStatus` — exactly what SciagenScheduleController.
/// getMyPlannedCalls() returns.
export function visitState(call, now = new Date()) {
    if (call.status === 'Cancelled') {
        return { color: VISIT_STATE_COLOR.Cancelled, label: 'Cancelled' };
    }
    if (call.resultingCVRId) {
        if (call.resultingCVRStatus === 'Submitted') return { color: VISIT_STATE_COLOR.Submitted, label: 'Submitted' };
        if (call.resultingCVRStatus === 'Saved') return { color: VISIT_STATE_COLOR.Saved, label: 'Saved' };
        return { color: VISIT_STATE_COLOR.Draft, label: 'Draft' };
    }
    if (call.status === 'Completed') {
        return { color: VISIT_STATE_COLOR.Submitted, label: 'Completed' };
    }
    const callDate = new Date(call.callDateTime);
    const isPastNotToday = callDate.getTime() < now.getTime()
        && !(callDate.getFullYear() === now.getFullYear() && callDate.getMonth() === now.getMonth() && callDate.getDate() === now.getDate());
    if (isPastNotToday) {
        return { color: VISIT_STATE_COLOR.Past, label: 'Past — not submitted' };
    }
    return { color: VISIT_STATE_COLOR.Planned, label: 'Planned' };
}

// Presentation__c.Brand__c / Slide__c.Brand__c — CLM library brand pills.
export const CLM_BRAND_COLOR = {
    Emrok: BRAND.primary,
    Glaritus: BRAND.violet,
    Miqnaf: BRAND.accent,
    Cardiace: BRAND.red,
    Neutraline: BRAND.gold,
    Other: BRAND.subtle,
};

// Call_Visit_Report__c.Record_Status__c / RCPA_Audit__c.Status__c — matches
// the inline chip logic in CVRView.swift (Submitted=accent, Saved=primary,
// anything else i.e. Draft=amber). 'Completed' is a Planned_Call__c.Status__c
// value merged into the same Activity list (see SciagenAccountController's
// getAccountDetail) — same accent green as PLANNED_CALL_STATUS_COLOR.Completed.
export function callStatusColor(status) {
    if (status === 'Submitted') return BRAND.accent;
    if (status === 'Saved') return BRAND.primary;
    if (status === 'Completed') return BRAND.accent;
    return BRAND.amber;
}