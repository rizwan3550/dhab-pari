# Vehicle system audit — 2026-10-30

Scope: rider side (`/portal/marketplace/*`), driver side (`/portal/my-vehicle/*`), the
admin screens that manage them, and the backend those call (RLS, RPCs, migrations up
to 773). Method: read the code and the **live** function definitions (a full local
replay of every migration into Postgres 16, then `pg_get_functiondef`), and drove every
screen at 390px in English and Urdu against a mock backend.

This file is meant to be kept and updated — it is the project's record of what was
checked, what was fixed, and what is still open.

---

## 1. What was fixed (open PRs)

| PR | What |
|---|---|
| #2 | 8px sideways scroll on every mobility screen (regression from the #1 padding change) |
| #3 | Hourly / rental / equipment run in **one lifecycle popup**; migration **774**: category-aware commission, tenant-scoped accounts, guard bypass closed |
| #4 | Monthly seats in **My Bookings**; drivers no longer see other people's seats there; migration **775**: parents notified on board / absent / arrived / back home |
| #5 | Route form fields labelled |

### Bugs found and their status

| # | Severity | Bug | Status |
|---|---|---|---|
| 1 | **High (money)** | `confirm_rental_booking` / `confirm_equipment_booking` look up `MKT-4050` / `MKT-1001` and the rate setting **without a tenant filter** — with a second village, commission can post into the wrong village's ledger | Fixed in 774 (#3) |
| 2 | **High (auth)** | Same two functions: a signed-in account with no active `portal_users` row makes the keeper check `NULL`, and `IF NOT (false OR NULL)` never raises — reproduced: such a caller settled someone else's rental and got `{"commission": 500}` | Fixed in 774 (#3) |
| 3 | Medium | Hourly and rental commission ignore the vehicle's category (flat site %), unlike trips/dispatch/equipment | Fixed in 774 (#3) |
| 4 | Medium (privacy) | My Bookings read `ride_bookings` with no user filter; the keeper RLS policy then shows a driver every seat booked on their routes as *their own* bookings | Fixed (#4) |
| 5 | Medium | 8px horizontal overflow on all mobility screens | Fixed (#2) |
| 6 | Medium (UX) | Finished-but-unpaid jobs filed under "Done" in Jobs — hides the one job still needing the driver | Fixed (#3) |
| 7 | Low | Hourly page showed the raw browser error "User denied Geolocation" in red, English only | Fixed (#3) |
| 8 | Low | Driver's job popup used rider wording ("Waiting for driver") | Fixed (#3) |
| 9 | Low | `WelcomeTour` and the marketplace `PortalHelp` popup are hard-coded Urdu — an English reader gets Urdu | **Open** |
| 10 | Low | `/portal/marketplace` (hub) renders the portal header *and* the mobility bottom nav — two apps' chrome on one screen | **Open** (see §3) |

Already done before this audit (verified, nothing to do): driver notifications in
`place_ride_booking` / `book_adda_seat` (725), the adda `!inner` join fix, rental and
dispatch in My Bookings, `/orders` redirect, Routes home card, routes form sections,
owner-side "Live now" in `RouteGroupPanel`.

---

## 2. How each flow works today

**Rider:** `marketplace/travel` (map + "where to") → results → a category flow
(shared ride, hourly, rental, machinery, parcel, city purchase, shadi, weekly commute,
route seat) → **My Bookings** (`marketplace/trips`) aggregates 12 sources. Trip-share and
ride-dispatch run in `RideLifecycleSheet` (live map, PIN, fare, rating). Hourly / rental /
equipment open `BookingQuickViewSheet`.

**Driver:** `my-vehicle` home (online toggle, stats, wallet, publish ride, Routes card,
city presence) → **Jobs** (all request types, New / Active / Done) → per-type popup.
Incoming requests interrupt any driver screen through `PendingRequestOverlay`.

**Monthly route ("Teacher Van", 723/724/727):** driver posts a route with *Monthly
Fixed*; riders apply for a seat (waitlist when full); driver takes attendance per run;
each day present adds `monthly_fee ÷ scheduled days` to a monthly charge; driver marks
charges paid (posts a voucher, commission deducted). Live location + per-stop ETAs while
a run is active; route group chat.

**Admin:** `admin/vehicles` (fleet, categories, commission bands, adda queue, wallet
top-ups, route bookings), `vehicle-registrations`, `marketplace-overview`,
`marketplace-reference`.

---

## 3. Making it feel like a native app

What still reads as "website":

1. **Two chromes.** The hub `/portal/marketplace` and several non-group pages (`adda`,
   `commute`, `route/[id]`, `trip/[id]`, `dispatch/[id]`, `order-city`, `pro`) render the
   portal header + sidebar, while everything in `(mobility)` renders the mobility header.
   Moving between them swaps the whole frame. → Put every rider screen under one layout;
   make `/portal/marketplace` redirect to `/travel` (search and "my orders" already live
   elsewhere).
2. **Emoji tab icons, 9px labels.** Both bottom navs use emoji (🏠🏗️🧾💬👤) and 9px labels
   (Urdu renders smaller still). Native apps use one icon set and ≥11px labels. → lucide
   icons, active pill, 11px labels; add `padding-bottom: env(safe-area-inset-bottom)`
   (the nav has none — on an iPhone it sits under the home indicator).
3. **Pages where a sheet belongs.** Done for hourly / rental / equipment (#3). Still a
   full page navigation: shadi detail, city-purchase detail, parcel detail, dispatch call,
   trip group chat. Convert to sheets over the list, the same way.
4. **Loading.** Every screen shows centred dots while *all* its queries finish (My
   Bookings waits on 12). → Skeleton rows per section, render each source as it arrives.
5. **Back behaviour.** Sheets don't close on the Android back button (no history entry),
   so back leaves the screen instead of closing the popup — the most "web" thing a
   villager will notice. → push a history state when a sheet opens, close on `popstate`.
6. **Hardware back.** There is no `popstate` or Capacitor `backButton` handling anywhere in
   the app (checked), so on the Android app back always navigates the page — see point 5.

---

## 4. Monthly vans for school and office — what Pakistani users expect

How "pick & drop" actually runs in Pakistani towns and cities:

- **Paid monthly, in advance** (typically by the 5th–10th), cash or JazzCash/Easypaisa.
  The fee buys the seat for the month whether the child rides every day or not.
- **Fee by distance/area**, quoted per child; **sibling discount** common.
- **Vacations:** summer (≈June–August) and winter breaks are the classic dispute —
  half fee, full fee, or nothing. Must be a stated policy, not argued each year.
- **Two legs a day**, timed to the school bell; morning pickup is sequential house by
  house, so "the van is 5 minutes away" matters more than "the van started".
- **Children have no phones.** The parent's phone is the only window: boarded, reached
  school, left school, dropped home.
- **"Not going today"** — parents tell the driver before pickup so he doesn't wait at the
  gate. Today this is a WhatsApp message.
- **Safety and trust:** CNIC, police verification, driver photo, female attendant for
  girls' schools, no overloading (Suzuki Carry/Bolan vans are notorious), CNG cylinder
  condition.

Against that, the current system:

| Need | Today | Recommendation |
|---|---|---|
| Fixed monthly fee in advance | 723 says "hold the seat whether they ride or not", but 724 bills **per day present** | Decide the policy explicitly. Recommended: fixed monthly charge raised on the 1st, due by a configurable day; attendance kept for records, not billing. If per-day stays, show the parent the running total. |
| Vacation months | None | Per-route "vacation months" with a % (0 / 50 / 100) the driver sets once, shown to parents before they apply |
| More than one child per parent | **Impossible** — unique index allows one live subscription per user per route | Add `passenger_name` (+ optional school/class) to `route_subscriptions`, drop the one-per-user index in favour of one-per-passenger; sibling discount % on the route |
| Driver sees who is who | Roster shows the parent's name | Show passenger name + pickup stop on the roster and attendance |
| Parent knows child boarded / arrived / home | Only "van started" was notified | **Fixed in 775**: on board / absent / arrived / back home |
| Per-child pickup ETA | Stop ETAs exist in the route panel | Notify "≈5 min away" when the van passes the stop before the child's `board_stop_id` |
| "Not going today" | Not possible | Parent taps *Absent today* before departure → driver's roster shows it, attendance pre-filled, no waiting |
| Monthly seat visible in My Bookings | Wasn't | **Fixed in #4**, with fee-due pill |
| Pay the monthly fee in-app | Driver marks cash received | Keep cash, add JazzCash/Easypaisa slip upload on the charge (same pattern as donations), driver/admin confirms |
| Female attendant / girls' route | None | Route flag "female attendant on board", filterable by parents |
| Mid-month joining | Per-day billing makes it implicit | With fixed monthly billing, pro-rate the first month |

Offices (teachers, clerks, factory staff) need the same model without the parent layer —
the subscriber *is* the rider, so passenger name defaults to the account holder.

---

## 5. Admin side — gaps

1. **No monthly-route oversight.** Admin cannot see subscriptions, waitlists, unpaid
   monthly charges or attendance. → A "Monthly routes" tab: per route, seats/waitlist,
   charges due by month, attendance %, drivers with overdue riders.
2. **No cross-type bookings monitor.** Admin sees route `ride_bookings` only. → One
   searchable list across every booking type (mirrors My Bookings), with stuck-state
   filters (accepted > 24h, in-progress > 12h, completed-unsettled > 3 days).
3. **Commission settings are split** between per-vertical site settings (hourly, rental,
   equipment, dispatch…) and the category cards. After 774 every vehicle with a category
   uses the card; show admins which vehicles still have no category (and therefore still
   use the flat settings).
4. **Disputes and frequent cancellers** (770) have no admin queue view.
5. **Driver document expiry** (licence, route permit, fitness) isn't tracked.

---

## 6. Suggested order of work

1. Merge #2 (tiny, live regression), then review #3–#5 and apply migrations 774, 775.
2. Decide the monthly billing policy (§4 first row) — everything else in §4 depends on it.
3. Multiple passengers per subscription + "absent today" + vacation policy (§4).
4. One rider chrome + native bottom nav + back-closes-sheet (§3.1, 3.2, 3.5).
5. Admin monthly-routes tab and bookings monitor (§5.1, 5.2).
