// Government of India gazetted holidays -- mirrors IndianHolidays.swift in the iPad app so My
// Schedule shows the same holiday flags. The 3 fixed National Holidays plus the major festival
// holidays; festival dates shift every year and come from published calendars (no live feed),
// so a fresh set of entries is needed for each new year, in step with the app.
const HOLIDAYS = [
    [2026, 1, 1, "New Year's Day", false],
    [2026, 1, 26, 'Republic Day', true],
    [2026, 3, 4, 'Holi', false],
    [2026, 3, 21, 'Eid-ul-Fitr', false],
    [2026, 4, 3, 'Good Friday', false],
    [2026, 5, 27, 'Eid-ul-Adha (Bakrid)', false],
    [2026, 8, 15, 'Independence Day', true],
    [2026, 8, 28, 'Raksha Bandhan', false],
    [2026, 9, 4, 'Janmashtami', false],
    [2026, 10, 2, 'Gandhi Jayanti', true],
    [2026, 10, 20, 'Dussehra', false],
    [2026, 11, 8, 'Diwali', false],
    [2026, 11, 24, 'Guru Nanak Jayanti', false],
    [2026, 12, 25, 'Christmas', false],
];

const BY_KEY = new Map(HOLIDAYS.map(([y, m, d, name, isNational]) => [`${y}-${m}-${d}`, { name, isNational }]));

/// The holiday on a local calendar day, or undefined.
export function holidayOn(date) {
    return BY_KEY.get(`${date.getFullYear()}-${date.getMonth() + 1}-${date.getDate()}`);
}
