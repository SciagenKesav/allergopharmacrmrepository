/**
 * Test-only time helpers. Planned_Call__c inserts must satisfy
 * PlannedCallScheduleGuard (no Sundays, 09:00-18:00 in the running user's
 * time zone), so fixtures built from Datetime.now() passed or failed
 * depending on the hour the tests happened to run.
 */
@isTest
public class SciagenTestTime {
    /// 11:00 local on the next day that isn't a Sunday.
    public static Datetime nextBusinessSlot() {
        Date d = Date.today().addDays(1);
        while (Datetime.newInstance(d, Time.newInstance(11, 0, 0, 0)).format('EEEE') == 'Sunday') {
            d = d.addDays(1);
        }
        return Datetime.newInstance(d, Time.newInstance(11, 0, 0, 0));
    }
}