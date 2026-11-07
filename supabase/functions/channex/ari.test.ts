import test from "node:test";
import assert from "node:assert/strict";
import { availabilityValues, fullSyncValues, minorToRate, responseWarnings, restrictionValues } from "./ari.ts";

const P = "716305c4-561a-4561-a187-7f5b8aeb5920";
const TWIN = "78b44110-0020-4651-8885-3e0f23b4fb67";
const DOUBLE = "af4f140f-1fe1-4447-b4d7-c127aafc8a73";
const ROOM = "11111111-2222-4333-8444-555555555555";

test("rates are decimal strings and never lose cents", () => {
  assert.equal(minorToRate(31266), "312.66");
  assert.equal(minorToRate(11100), "111.00");
  assert.equal(minorToRate(5), "0.05");
  assert.throws(() => minorToRate(0));
});

test("single date, single rate: one value with only the rate", () => {
  const v = restrictionValues(P, [{ rate_plan_id: TWIN, date_from: "2027-11-22", rate_minor: 33300 }]);
  assert.deepEqual(v, [{ property_id: P, rate_plan_id: TWIN, date: "2027-11-22", rate: "333.00" }]);
});

test("multiple date range keeps the exact range and decimals", () => {
  const v = restrictionValues(P, [{ rate_plan_id: DOUBLE, date_from: "2027-11-10", date_to: "2027-11-16", rate_minor: 31266 }]);
  assert.deepEqual(v[0], { property_id: P, rate_plan_id: DOUBLE, date_from: "2027-11-10", date_to: "2027-11-16", rate: "312.66" });
});

test("min stay is an integer and carries nothing else", () => {
  const [v] = restrictionValues(P, [{ rate_plan_id: TWIN, date_from: "2027-11-23", min_stay: 3 }]);
  assert.deepEqual(v, { property_id: P, rate_plan_id: TWIN, date: "2027-11-23", min_stay_arrival: 3 });
  assert.throws(() => restrictionValues(P, [{ rate_plan_id: TWIN, date_from: "2027-11-23", min_stay: 0 }]));
  assert.throws(() => restrictionValues(P, [{ rate_plan_id: TWIN, date_from: "2027-11-23", min_stay: 1.5 }]));
});

test("stop sell is a boolean; false is kept", () => {
  const v = restrictionValues(P, [{ rate_plan_id: TWIN, date_from: "2027-11-20", stop_sell: false }]);
  assert.equal(v[0].stop_sell, false);
});

test("a change with nothing to change, or a bad range, is rejected", () => {
  assert.throws(() => restrictionValues(P, [{ rate_plan_id: TWIN, date_from: "2027-11-20" }]), /at least one value/);
  assert.throws(() => restrictionValues(P, [{ rate_plan_id: TWIN, date_from: "2027-11-20", date_to: "2027-11-19", stop_sell: true }]), /before the start/);
  assert.throws(() => restrictionValues(P, [{ rate_plan_id: "nope", date_from: "2027-11-20", stop_sell: true }]), /rate plan/);
});

test("multiple restrictions update: several plans, one value each", () => {
  const v = restrictionValues(P, [
    { rate_plan_id: TWIN, date_from: "2027-11-01", date_to: "2027-11-10", min_stay: 1, max_stay: 6 },
    { rate_plan_id: DOUBLE, date_from: "2027-11-10", date_to: "2027-11-16", min_stay: 2, stop_sell: true },
  ]);
  assert.equal(v.length, 2);
  assert.equal(v[0].min_stay_arrival, 1); assert.equal(v[0].max_stay, 6);
  assert.equal(v[1].stop_sell, true);
});

test("availability: zero is sent, ranges are kept", () => {
  assert.deepEqual(availabilityValues(P, [{ room_type_id: ROOM, date_from: "2027-11-25", availability: 0 }]),
    [{ property_id: P, room_type_id: ROOM, date: "2027-11-25", availability: 0 }]);
  assert.deepEqual(availabilityValues(P, [{ room_type_id: ROOM, date_from: "2027-11-10", date_to: "2027-11-16", availability: 3 }])[0],
    { property_id: P, room_type_id: ROOM, date_from: "2027-11-10", date_to: "2027-11-16", availability: 3 });
  assert.throws(() => availabilityValues(P, [{ room_type_id: ROOM, date_from: "2027-11-10", availability: -1 }]));
});

test("full sync: every restriction on every object, merged into ranges", () => {
  const nights = [];
  for (const d of ["2027-11-01", "2027-11-02", "2027-11-03"]) {
    nights.push({ room_type_id: ROOM, rate_plan_id: TWIN, date: d, availability: 4, rate: 12000, min_stay: 1 });
    nights.push({ room_type_id: ROOM, rate_plan_id: DOUBLE, date: d, availability: 4, rate: d === "2027-11-03" ? 15000 : 14000, min_stay: 2 });
  }
  const { availability, restrictions } = fullSyncValues(P, nights);
  assert.equal(availability.length, 1);
  assert.deepEqual(availability[0], { property_id: P, room_type_id: ROOM, availability: 4, date_from: "2027-11-01", date_to: "2027-11-03" });
  assert.equal(restrictions.length, 3);
  for (const r of restrictions) {
    assert.ok("min_stay_arrival" in r && Number.isInteger(r.min_stay_arrival));
    assert.equal(r.stop_sell, false);
    assert.match(r.rate, /^\d+\.\d{2}$/);
  }
});

test("200 OK responses with warnings are detected", () => {
  assert.deepEqual(responseWarnings({ meta: { message: "Success" }, data: [] }), []);
  assert.equal(responseWarnings({ meta: { warnings: [{ warning: { rate: ["must be greater than 0"] } }] } }).length, 1);
});
