import { LightningElement, api } from 'lwc';

/// Route map for a single day's visits — ports CalendarPlannerView.swift's
/// mapMode. Uses the lightning-map base component (Salesforce has no MapKit
/// polyline equivalent, so the stop list stands in for the route line) plus a
/// "Get Directions" Google Maps multi-stop link, functionally equivalent to
/// iOS's Apple Maps deep link. One simplification vs. iOS: only stops with a
/// directly-set HCO (and therefore real Geolocation__Latitude/Longitude__s)
/// are mappable — an HCP-only visit with no HCO isn't geocoded via the HCP's
/// affiliated HCO the way iOS resolves it, since that would require an extra
/// join the schedule controller doesn't currently make.
// LOCAL calendar-day key — never `.toISOString().slice(0,10)`, which rolls
// back a day in any negative-offset timezone (see mySchedule.js's
// localDayKey for the full explanation; confirmed live in scheduleWeekGrid).
function localDayKey(d) {
    const year = d.getFullYear();
    const month = String(d.getMonth() + 1).padStart(2, '0');
    const day = String(d.getDate()).padStart(2, '0');
    return `${year}-${month}-${day}`;
}

export default class ScheduleMap extends LightningElement {
    @api calls = [];
    @api selectedDate; // Date

    get dayKey() {
        const d = this.selectedDate instanceof Date ? this.selectedDate : new Date(this.selectedDate);
        return localDayKey(d);
    }

    get dayCalls() {
        return (this.calls || [])
            .filter((c) => localDayKey(new Date(c.callDateTime)) === this.dayKey)
            .slice()
            .sort((a, b) => a.callDateTime.localeCompare(b.callDateTime));
    }

    get stops() {
        return this.dayCalls
            .filter((c) => c.latitude != null && c.longitude != null)
            .map((c, index) => ({
                stopNumber: index + 1,
                id: c.id,
                title: `${index + 1}. ${c.isEvent ? (c.eventTitle || 'Event') : (c.hcpName || c.hcoName || 'Visit')}`,
                timeLabel: new Date(c.callDateTime).toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' }),
                subtitle: c.hcoName || '',
                latitude: c.latitude,
                longitude: c.longitude,
            }));
    }

    get hasStops() {
        return this.stops.length > 0;
    }

    get unmappedCount() {
        return this.dayCalls.length - this.stops.length;
    }

    get hasUnmapped() {
        return this.unmappedCount > 0;
    }

    get mapMarkers() {
        return this.stops.map((s) => ({
            location: { Latitude: s.latitude, Longitude: s.longitude },
            title: s.title,
            description: `${s.timeLabel}${s.subtitle ? ' · ' + s.subtitle : ''}`,
            value: s.id,
        }));
    }

    get dayLabel() {
        const d = this.selectedDate instanceof Date ? this.selectedDate : new Date(this.selectedDate);
        return d.toLocaleDateString(undefined, { weekday: 'long', month: 'short', day: 'numeric' });
    }

    handleGetDirections() {
        const stops = this.stops;
        if (stops.length === 0) { return; }
        const coord = (s) => `${s.latitude},${s.longitude}`;
        const destination = coord(stops[stops.length - 1]);
        const waypoints = stops.slice(0, -1).map(coord).join('|');
        let url = `https://www.google.com/maps/dir/?api=1&destination=${destination}`;
        if (waypoints) { url += `&waypoints=${waypoints}`; }
        window.open(url, '_blank');
    }
}