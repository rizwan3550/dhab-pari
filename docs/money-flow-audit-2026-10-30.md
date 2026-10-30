# Money-flow audit: advances, travel charges, live billing, wallets, return alerts

Date: 2026-10-30. Source: the **live function bodies** (`pg_get_functiondef` on a local replay of migrations 001–775), not just the migration files, plus the rider, driver and admin screens that call them. Nothing here has been run against production.

Contents:
1. Advance payments (shadi and machinery)
2. Distance / fuel charges for shadi, machinery, tractor and loader
3. Live billing for hourly and rental
4. Driver wallet, rider and committee: the money-flow map
5. Return-trip alerts after a one-way trip
6. Findings by severity and the order to fix them

---

## 1. Advance payments

### 1a. Shadi (wedding): it exists and works end to end

| Step | Who | Screen | Function | Money |
|---|---|---|---|---|
| 1. Book | Rider | `marketplace/(mobility)/shadi` | `create_shadi_event` (pick vehicles) or `create_shadi_fleet_event` (by type) | none |
| 2. Accept | Each driver | `my-vehicle/shadi` | `respond_shadi_request` / `claim_shadi_slot` | none |
| 3. Pay advance | Rider uploads a payment slip | `marketplace/(mobility)/shadi/[eventId]` | `announce_shadi_advance` | **amount set by the server**: `marketplace_shadi_advance_pct` (now **20%**) × the sum of the accepted vehicles' full-day rates |
| 4. Verify | Committee | `admin/shadi-bookings` | `confirm_shadi_advance` / `reject_shadi_advance` | contra voucher: cash/bank `MKT-1001/1002` → liability **`MKT-5004` "Shadi Advances Payable to Vehicles"**. Each vehicle's share goes to `advance_share_pkr`. Drivers are told "Rs X held for you, collect the remaining Rs Y on the day". Requests nobody answered are auto-cancelled. |
| 5. Wedding day | Driver | none | none | The driver collects **the balance in cash, off the books** |
| 6. After the date | Automatic | runs when the driver or admin opens a shadi page | `sweep_due_shadi_advances` | contra voucher: `MKT-5004` → **the vehicle's wallet account**, plus the notification "Advance released" |
| Back-out | Driver | `my-vehicle/shadi` | `withdraw_shadi_request` → `invite_shadi_replacement` | The withdrawn driver's share stays in `MKT-5004` and moves to the replacement vehicle. With no replacement, it stays parked there. |

This is verified working, but there are gaps:
- **S1. The committee earns nothing from shadi.** No commission is charged, even for per-order vehicles. Migration 480 says this was deliberate ("the committee earns nothing from it"). Every other service charges 10–15%. This needs confirming as policy.
- **S2. The released advance lands in the prepaid commission wallet, and there is no cash-out.** The driver can only "spend" it against future commission (see §4). A driver who mostly does weddings builds up a balance they can never withdraw.
- **S3. The sweep only runs when someone opens a shadi page.** If nobody opens one, an advance stays held after the wedding. There is no scheduled job.
- **S4. A booking can't be cancelled after confirmation, and no-shows aren't handled.** A driver can withdraw, but if they simply don't turn up, the sweep still pays them. The rider has no "vehicle did not come" button before the sweep runs; the dispute flow (485) is the only path.
- **S5. A missing setting means a zero advance.** If `marketplace_shadi_advance_pct` isn't set for a new tenant, the advance is Rs 0, yet the rider must still upload a slip.

### 1b. Machinery, tractor and loader: no advance exists

`create_equipment_booking` → `respond_equipment_booking` → `start_equipment_job` (PIN) → `complete_equipment_job` → `confirm_equipment_booking` (commission). **None of these steps collects an advance.** The only extra charge is `machinery_mobilization_fee_pkr`: one flat amount per vehicle, added to the bill at completion. Tractors and loaders have no extra charge at all.

**Proposed equipment advance.** This mirrors shadi, so the committee and drivers already know the pattern:
1. The driver accepts, and the booking moves to a new `advance_due` state. The job cannot be started (no PIN start) until the advance is confirmed.
2. The rider sees "Pay advance Rs X to confirm". X = `marketplace_equipment_advance_pct` (proposed 20–25%) × the estimated total, **including the travel charge in §2**. The rider uploads a slip. New function: `announce_equipment_advance`.
3. The committee confirms. The money is held in a new liability account **`MKT-5005` "Equipment Advances Payable"**, and the booking moves to `accepted`.
4. At settlement (`confirm_equipment_booking`), the advance moves from `MKT-5005` to the vehicle's wallet in the same voucher batch. The driver's screen shows "Collect Rs (total − advance)".
5. **Cancellation:**
   - rider cancels before the scheduled date: the advance is refunded, minus an optional `equipment_cancel_fee_pct`;
   - rider no-show or cancellation on the day: the advance goes to the driver;
   - driver declines or withdraws after confirmation: the advance is refunded in full.

   This is the same rule shape `city_purchase_cancellation_fee` (772) already uses.
6. The existing **20-day stale sweep** (711) must refund held advances, not just cancel the booking.

**Decisions needed from you:**
- the advance %;
- whether the advance is per kind (machinery yes, tractor/loader optional);
- the cancellation fee %.

---

## 2. Distance / fuel ("travel charge") for shadi, machinery, tractor and loader

### What exists today

| Service | Distance used? | How |
|---|---|---|
| Shadi, picking specific vehicles | **No.** `distance_km` is "purely informational" (478) | flat `shadi_full_day_rate_pkr`, whatever the distance |
| Shadi, booking by vehicle type | **Yes** | class `full_day_rate_pkr + max(0, distance − free_km 40) × per_extra_km_pkr`. **The distance is typed by the rider** (`p_distance_km`), so the rider can enter 0. |
| Machinery | no | flat `mobilization_fee_pkr`, same at 2 km or 80 km |
| Tractor | no | service rate × hours only |
| Loader | no | flat rate × trips. A 3 km trip and a 40 km trip cost the same. |
| Rental | yes, from the server | `haversine × 1.3`; one-way trips are priced at **1.5×**, which pays for the empty return; return trips at **2×**, plus waiting hours |
| Hourly | yes, from live GPS | km included per hour, then an extra charge per km (see §3) |

### Proposed logic: one "travel charge" rule for every on-site service

Every booking that brings a vehicle **to a site** (shadi venue, machinery/tractor site, loader pickup) gets the same three-part price. The server always computes it; the client never sends the distance.

```
base            = today's rate (full-day rate / rate × hours / rate × trips)
road_km         = round(haversine(vehicle base → site) × 1.3)        -- same factor rental already uses
travel_km       = max(0, road_km − free_radius_km)                     -- free radius per service
travel_charge   = travel_km × 2 × travel_rate_per_km                    -- ×2 = there AND back (empty return)
night_halt      = (road_km > overnight_km) ? night_halt_pkr × days : 0 -- shadi / multi-day machinery only
total           = base + travel_charge + night_halt
```

**Where each input comes from:**
- **Vehicle base.**
  - Today, vehicles have no saved home location.
  - **Proposal:** add `vehicles.base_lat / base_lng`, set once by the committee or the driver with the existing map picker.
  - Until a vehicle has one, fall back to the tenant's home city (`cities.is_home_city`).
- **Site.**
  - Shadi uses `venue_lat/lng`, which the rider already picks on the map. Make it required and stop asking the rider to type a distance.
  - Equipment uses `site_lat/lng`, which already exists.
  - Loader uses `pickup_lat/lng` → `site_lat/lng`, and that leg is charged per trip.
- **Free radius, per service, set by the committee:**
  - shadi 40 km (already the fleet default);
  - machinery 10 km;
  - tractor 5 km (farm work is local);
  - loader 10 km.
- **Travel rate per km**, set by the committee in Vehicle Categories next to the commission %. It reflects fuel for that class: a tractor on the road burns very differently from a Corolla. Excavators that need a low-bed trailer get a much higher rate, or a flat mobilization fee as now, whichever is higher.
- **Maximum radius (`max_service_km`), per service.** Beyond it, the vehicle is **not offered to that rider at all**, and the list says "Too far for this vehicle — ask the committee for a custom quote". This answers "what happens when the distance is too much".
- **Overnight:** above `overnight_km` (e.g. 150 km for shadi), add a night-halt charge for the driver's food and stay. Above `max_service_km`, the booking isn't allowed.
- **Full-day rent covers:**
  - the driver, plus fuel within the free radius;
  - up to `full_day_hours` (proposed 12 h);
  - decoration is not included.

  Past those hours, `extra_hour_pkr` applies per started hour. The driver records it on the day, and the rider confirms it with the PIN, the same pattern as hourly.

**What the rider sees:** before sending, a breakdown: Base · Travel (N km × 2) · Night halt · **Total** · Advance due now.

**What the driver sees:** the same breakdown on the request card, so they know why a far job pays more.

**Commission:** charged on base + travel, the same as today's commission on the total.

**Decisions needed from you:**
- free radius, travel rate per km, maximum radius and overnight limit, for each service;
- whether the travel charge counts toward the advance;
- whether commission applies to travel.

---

## 3. Live billing for hourly and rental: does each side see the meter?

### Hourly

**What happens today:**
- **Tracking.** The driver's phone pings `ping_hourly_trip_location` about every 12 s. The server adds real movement to `distance_km` and drops GPS glitches (≥ 1.5 km jumps) and jitter (< 20 m).
- **Bill.** `end_hourly_trip` bills `rate × booked hours` + `max(0, km − included_km) × overage_per_km`.

| | Driver | Rider |
|---|---|---|
| Live km | ✅ refreshed every 10 s | ✅ "Trip in progress … N km" |
| km included (e.g. "38 of 40 km included") | ❌ | ❌ The rider's function doesn't even return `included_km` |
| **Running bill** (base + overage so far) | ❌ | ❌ |
| Time used vs booked hours | ❌ | ❌ |
| Over time | **Never charged.** A 2-hour booking that runs 5 hours is billed for 2. | ❌ |

### Rental

**What happens today:**
- The price is **fixed at booking**: road km is estimated from pickup and drop-off.
- One-way is priced at 1.5×. Return is 2× plus `wait_hours × wait rate`.
- `end_rental_trip` just marks the trip complete, with no GPS and no adjustment.
- The fixed price is fair if the route goes as planned. But extra waiting beyond the booked hours, or a detour, is never charged.

### Proposed (mostly UI; one backend change)
1. **Live meter card, on both the driver's and the rider's trip screens.** It refreshes every 10 s from data that already exists:
   - `elapsed hh:mm / booked h`;
   - `km 38 / 40 included`;
   - `Bill so far: Rs base + overage`;
   - a warning near the limits ("2 km left before extra charges").

   The rider's function needs to return `included_km` and `overage_per_km_pkr`, which means adding two fields to `my_hourly_bookings`.
2. **Over time on hourly.** In `end_hourly_trip`, charge each started 30 minutes past the booked hours at `hourly_rate / 2`. The meter shows it live. **This needs your decision.**
3. **Rental waiting.** A "Waiting" toggle on the driver's popup. Waiting past the booked hours is billed at `rental_wait_hour_pkr`. Both sides see it live.

---

## 4. Money-flow map: driver wallet, rider and committee

Each tenant has its own set of ledger accounts in the `marketplace` system:

| Account | What it is |
|---|---|
| `MKT-1001` / `MKT-1002` | committee cash / bank |
| `MKT-4050` | commission income |
| `MKT-5004` | shadi advances held for vehicles (liability) |
| vehicle account (`ensure_vehicle_account`) | the driver's **prepaid wallet** |

**How each flow moves money:**

| Flow | Rider pays | Driver's wallet | Committee |
|---|---|---|---|
| Per-order ride / hourly / rental / equipment | the driver directly, in cash | **debited** the commission % when the job is settled (`confirm_*` / `complete_trip_booking`) | `MKT-4050` income |
| Lump-sum vehicle | the committee (payment slip) | none | the gross amount is recorded as income |
| Shadi | advance to the committee, the rest to the driver | **credited** the advance after the date (sweep) | none (S1) |
| Top-up | none | **credited** (`place_` / `confirm_vehicle_wallet_topup`, slip → admin) | cash in |

**Low balance:**
- At or below `marketplace_low_balance_warning_pkr` (200), the driver is warned.
- At or below `marketplace_min_balance_to_order_pkr` (0), the driver is marked **inactive** and told so.

### Findings
- **W1 (high). The balance only blocks some services.**
  - "Inactive" only applies to **adda check-in, route/adda seat booking and shop orders** (`vehicle_bookable`, `book_adda_seat`, `place_ride_booking`).
  - **Hourly, rental, machinery/tractor/loader and shadi bookings never check the balance.** A per-order driver who owes commission keeps getting those jobs, and the notification "inactive for new orders" isn't true for them.
  - **Fix:** apply the same check in `*_bookable_vehicles` and the `create_*` functions.
- **W2 (high). Money held for a driver has no way out.** Released shadi advances, and any top-up bigger than the dues, can only pay future commission. Fix: add `request_vehicle_payout`:
  1. The driver asks to withdraw an amount up to their wallet balance minus a minimum.
  2. The committee pays the driver (cash, JazzCash or Easypaisa) and confirms.
  3. A voucher moves the money from the vehicle account to cash/bank.

  This is the mirror image of top-up, and the admin queue screen can be reused.
- **W3. Released advances show as plain credit.** The earnings screen (`vehicle_wallet_statement`) lists every voucher, but a released advance looks just like any other credit. It should be labelled "Wedding advance released" or "Commission", and grouped.
- **W4. Duplicate accounts in other villages.** Hourly and rental settlement looked up `MKT-4050`/`MKT-1001` **without a tenant filter**. This could post commission into another village's ledger once a second village has accounts. **Already fixed in migration 774** (PR #3), together with the missing check that let a caller with no portal profile settle someone else's rental.
- **W5. Equipment is billed for requested hours, not actual hours.**
  - `complete_equipment_job` sets `actual_hours = requested_hours`. `started_at`/`ended_at` are stored but never used.
  - A 6-hour excavator job booked as 3 hours is billed 3.
  - **Proposal:** bill whichever is larger: the minimum hours, or the actual elapsed time rounded up to 30 minutes. Show it on the live meter, the same as §3.

---

## 5. Return-trip alerts after a one-way trip

**What exists:**
- `alert_trip_return_seat_available` (727/728) notifies up to 20 riders **only when a seat on a shared trip or route frees up** because the driver removed a no-show.
- Who gets it: riders whose past bookings (last 60 days) had an origin or destination **with the same name** as this trip's destination.
- `rider_weekly_schedules` (743) has data like "I'm in Rawalpindi, coming back Friday", but it only feeds the driver's demand card, as anonymous counts. **No rider is ever told** that a vehicle is in their city heading home.

**What's missing:** when a **one-way rental, ride-dispatch trip or one-way shared trip** ends in another city, the vehicle drives back empty, and nobody is alerted.

### Proposed: "Empty return" offer
1. **Trigger.** On `end_rental_trip` (one-way), `complete_trip_booking` (one-way leg) or ride-dispatch completion, check whether the drop-off city ≠ the vehicle's home city. If so, the driver's completion screen shows **"Going back to Dhab Pari empty? Offer your seats"**, pre-filled with the seats, a departure time (now + 30 min) and the committee's one-way return fare (the existing half fare).
2. **One tap publishes** a return-only trip offer. This reuses the `vehicle_trip_offers` row type and the `return_only` booking leg from 728, so no new booking engine is needed.
3. **Notify riders who are actually there.** Combine three sources, cap at 30, and skip anyone who opted out:
   - riders with a **weekly schedule** returning from that city today or tomorrow (743);
   - riders whose recent bookings ended in that city;
   - riders currently in that city, if they share their location.

   Message: "A vehicle is leaving Rawalpindi for Dhab Pari at 5:30 pm — 3 seats, Rs 450". Tapping it opens the booking.
4. **The money is bonus income for the driver.** Commission is charged at the normal rate. The rider who paid 1.5× for the one-way trip already covered the empty return, so the committee may decide on a **lower commission for these return fills**.

**Decisions needed from you:**
- automatic offer vs a "suggest" button;
- the return fare rule;
- commission on return fills;
- the notification cap and opt-out.

---

## 6. Findings by severity and suggested order

| # | Severity | Finding | Fix size |
|---|---|---|---|
| W1 | High | Commission balance doesn't block hourly/rental/equipment/shadi jobs | small: one check in 8 functions |
| W2 | High | No payout of wallet money held for drivers (shadi advances) | medium: function, driver button, admin queue |
| W5 | High | Equipment billed for requested hours, not hours worked | small: backend + meter |
| §1b | High | No advance for machinery/tractor/loader | medium: mirror the shadi advance |
| §2 | High | Distance ignored or typed by the rider for shadi/equipment, and no maximum distance | medium: settings, `base_lat/lng`, quote function |
| §3 | Medium | No live bill or time meter; over time and extra waiting never charged | UI small; backend small |
| S3 | Medium | Shadi payout sweep only runs when a page is opened | small: run it on a schedule |
| S4 | Medium | No rider "vehicle didn't come" before the payout | small |
| §5 | Medium | No return-trip alert after one-way trips | medium |
| S1 | Policy | No commission on shadi | your decision |
| S5 | Low | Missing advance-% setting gives a Rs 0 advance | add a default |
| W4 | Done | Commission posted to another village's accounts (hourly/rental/equipment) | migration 774 (PR #3) |

**Suggested order:**
1. Settle the policy decisions in §1b, §2, §3 and §5.
2. Then W1 + W5 (small, they stop revenue loss).
3. Then W2 (driver trust).
4. Then the equipment advance + travel charge as one migration, since they share the quote function.
5. Then the meters.
6. Then return alerts.

Every migration should follow the 770–775 discipline: dry-run in a `BEGIN … ROLLBACK` on a replay, open a PR, and have a human apply it.
