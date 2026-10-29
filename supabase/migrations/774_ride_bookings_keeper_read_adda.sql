-- Migration 774: a driver could never read their own ADDA seat bookings.
--
-- Real gap found 2026-10-29 while auditing plan A1 ("unified bookings").
-- ride_bookings_keeper_read (397, tenant-scoped in 578) only matches
-- bookings through vehicle_routes:
--     EXISTS (... vehicle_routes r ... WHERE r.id = ride_bookings.route_id ...)
-- An adda-based booking (book_adda_seat, 410/725) has route_id NULL and
-- adda_queue_entry_id set instead, so that EXISTS is always false for it.
-- RLS therefore hid every adda booking from the driver who owns the
-- vehicle. The client code in my-vehicle/jobs, DriverJobsBadgeContext
-- and PendingRequestOverlay already queries
--     ride_bookings ... adda_queue_entries!inner(vehicle_id) ...
-- specifically so adda bookings show up, but under RLS those queries
-- returned zero rows for every driver. So the Jobs list, the Jobs badge
-- and the auto-popping request card all stayed silently empty for adda
-- bookings, even after 725 started sending the driver an
-- 'adda_seat_booked' notification.
--
-- Fix: the keeper read now matches EITHER ownership path. The route
-- branch is unchanged (same text as 578). The new branch is the
-- same ownership check through adda_queue_entries -> vehicles. Still
-- tenant-scoped, still SELECT-only, still authenticated-only. No write
-- path changes: confirm/reject_ride_booking are SECURITY DEFINER and
-- already resolve the adda vehicle through ride_booking_context().
--
-- DROP + CREATE (not ALTER) so a re-run is idempotent, same discipline
-- as the function migrations.

DROP POLICY IF EXISTS "ride_bookings_keeper_read" ON ride_bookings;
CREATE POLICY "ride_bookings_keeper_read" ON ride_bookings FOR SELECT TO authenticated
  USING (
    (tenant_id = my_tenant_id())
    AND (
      EXISTS (
        SELECT 1 FROM vehicle_routes r JOIN vehicles v ON v.id = r.vehicle_id
        WHERE r.id = ride_bookings.route_id AND v.portal_user_id = current_portal_user_id()
      )
      OR EXISTS (
        SELECT 1 FROM adda_queue_entries e JOIN vehicles v ON v.id = e.vehicle_id
        WHERE e.id = ride_bookings.adda_queue_entry_id AND v.portal_user_id = current_portal_user_id()
      )
    )
  );
