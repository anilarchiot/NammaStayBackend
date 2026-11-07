// Builds the exact JSON bodies Channex expects for availability and rate/restriction updates.
// Pure functions (no network) so the certification scenarios can be unit-tested: node --test backend/supabase/functions/channex/ari.test.ts
// Rules from Channex certification: one change = one value, only the fields that changed, integers for min/max stay,
// booleans for stop sell, decimal-string rates, date ranges instead of one object per day.

export type RestrictionRow = {
  rate_plan_id: string; date_from: string; date_to?: string | null;
  rate_minor?: number | null;            // minor currency units (cents / paise)
  min_stay?: number | null; max_stay?: number | null;
  stop_sell?: boolean | null; cta?: boolean | null; ctd?: boolean | null;
};
export type AvailabilityRow = { room_type_id: string; date_from: string; date_to?: string | null; availability: number };
export type Night = { room_type_id: string; rate_plan_id: string; date: string; availability: number; rate: number; min_stay: number };

const DATE = /^\d{4}-\d{2}-\d{2}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const present = (v: unknown) => v !== undefined && v !== null && v !== "";

export const isUuid = (v: unknown): v is string => typeof v === "string" && UUID.test(v);

export function minorToRate(minor: number): string {
  if (!Number.isInteger(minor) || minor <= 0) throw new Error("The rate must be greater than 0.");
  return `${Math.floor(minor / 100)}.${String(minor % 100).padStart(2, "0")}`;
}

function dates(row: { date_from: string; date_to?: string | null }, label: string) {
  if (!DATE.test(row.date_from || "")) throw new Error(`${label}: choose a valid start date.`);
  const to = row.date_to || row.date_from;
  if (!DATE.test(to)) throw new Error(`${label}: choose a valid end date.`);
  if (to < row.date_from) throw new Error(`${label}: the end date is before the start date.`);
  return to === row.date_from ? { date: row.date_from } : { date_from: row.date_from, date_to: to };
}

export function restrictionValues(propertyId: string, rows: RestrictionRow[]) {
  if (!isUuid(propertyId)) throw new Error("Invalid Channex property ID.");
  if (!rows?.length) throw new Error("Add at least one change.");
  return rows.map((r, i) => {
    const label = `Change ${i + 1}`;
    if (!isUuid(r.rate_plan_id)) throw new Error(`${label}: choose a rate plan.`);
    const v: Record<string, unknown> = { property_id: propertyId, rate_plan_id: r.rate_plan_id, ...dates(r, label) };
    let fields = 0;
    if (present(r.rate_minor)) { v.rate = minorToRate(Number(r.rate_minor)); fields++; }
    if (present(r.min_stay)) {
      if (!Number.isInteger(r.min_stay) || (r.min_stay as number) < 1) throw new Error(`${label}: minimum stay must be a whole number of 1 or more.`);
      v.min_stay_arrival = r.min_stay; fields++;
    }
    if (present(r.max_stay)) {
      if (!Number.isInteger(r.max_stay) || (r.max_stay as number) < 0) throw new Error(`${label}: maximum stay must be a whole number of 0 or more.`);
      v.max_stay = r.max_stay; fields++;
    }
    if (typeof r.stop_sell === "boolean") { v.stop_sell = r.stop_sell; fields++; }
    if (typeof r.cta === "boolean") { v.closed_to_arrival = r.cta; fields++; }
    if (typeof r.ctd === "boolean") { v.closed_to_departure = r.ctd; fields++; }
    if (!fields) throw new Error(`${label}: set at least one value to change.`);
    return v;
  });
}

export function availabilityValues(propertyId: string, rows: AvailabilityRow[]) {
  if (!isUuid(propertyId)) throw new Error("Invalid Channex property ID.");
  if (!rows?.length) throw new Error("Add at least one change.");
  return rows.map((r, i) => {
    const label = `Change ${i + 1}`;
    if (!isUuid(r.room_type_id)) throw new Error(`${label}: choose a room.`);
    if (!Number.isInteger(r.availability) || r.availability < 0) throw new Error(`${label}: enter how many rooms are available (0 or more).`);
    return { property_id: propertyId, room_type_id: r.room_type_id, ...dates(r, label), availability: r.availability };
  });
}

const nextDay = (d: string) => { const x = new Date(d + "T00:00:00Z"); x.setUTCDate(x.getUTCDate() + 1); return x.toISOString().slice(0, 10); };

// Merge consecutive nights of one key that carry identical values into date ranges.
function merge<T extends Record<string, unknown>>(nights: Night[], keyOf: (n: Night) => string, value: (n: Night) => T) {
  const sorted = [...nights].sort((a, b) => keyOf(a).localeCompare(keyOf(b)) || a.date.localeCompare(b.date));
  const out: (T & { date_from: string; date_to: string })[] = []; let lastKey = ""; let lastVal = "";
  for (const n of sorted) {
    const k = keyOf(n); const val = JSON.stringify(value(n)); const last = out[out.length - 1];
    if (last && k === lastKey && val === lastVal && nextDay(last.date_to) === n.date) last.date_to = n.date;
    else { out.push({ ...value(n), date_from: n.date, date_to: n.date }); lastKey = k; lastVal = val; }
  }
  return out;
}

// Full sync: every restriction Channex declares (rate, min_stay_arrival, stop_sell) for every rate plan and night.
export function fullSyncValues(propertyId: string, nights: Night[]) {
  const perRoom = [...new Map(nights.map((n) => [n.room_type_id + "|" + n.date, n])).values()];   // availability belongs to the room, not the rate plan
  const availability = merge(perRoom, (n) => n.room_type_id, (n) => ({ property_id: propertyId, room_type_id: n.room_type_id, availability: Math.max(0, Math.trunc(n.availability)) }));
  const restrictions = merge(nights, (n) => n.rate_plan_id, (n) => ({
    property_id: propertyId, rate_plan_id: n.rate_plan_id, rate: minorToRate(Math.max(1, Math.round(n.rate))),
    min_stay_arrival: Math.max(1, Math.trunc(n.min_stay) || 1), stop_sell: false,
  }));
  return { availability, restrictions };
}

// Channex answers 200 OK even when it rejects a value; the reasons are in meta.warnings / data.warnings.
export function responseWarnings(body: unknown): string[] {
  const b = body as { meta?: { warnings?: unknown }; data?: { warnings?: unknown } } | null;
  const raw = [b?.meta?.warnings, b?.data?.warnings].flatMap((w) => (Array.isArray(w) ? w : []));
  return raw.map((w) => (typeof w === "string" ? w : JSON.stringify((w as { warning?: unknown })?.warning ?? w)).slice(0, 300));
}
