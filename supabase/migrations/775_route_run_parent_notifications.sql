-- Migration 775: tell a monthly-seat holder what happened to their rider
-- on today's run — the "school van" case, 2026-10-30 audit.
--
-- The monthly "Teacher Van" route (723/724/727) is how a parent books a
-- standing seat for a child who has no phone of their own, so the parent's
-- phone is the only place anyone can learn that the child actually got on
-- and actually got there. Only one moment ever notified: start_route_run
-- ("The van is on its way"). The three moments a parent cares about most
-- were silent:
--   - take_attendance  — the driver marks who is on board. Present or
--     absent, nothing reached the subscriber (who is billed per day
--     present, so this is also the moment a charge is added).
--   - mark_run_arrived — the van reached the destination (school/office).
--   - end_route_run    — the run ended (on a return leg: back home).
-- Each now inserts a portal_notifications row, which already fans out to
-- push via trg_dispatch_push_portal — same mechanism start_route_run uses.
--
-- Attendance only notifies a subscription whose mark is NEW or CHANGED,
-- so a driver re-saving the same roster doesn't spam anyone.
--
-- Bodies are otherwise unchanged from the live definitions (724 / 727,
-- read back via pg_get_functiondef). Same DROP + recreate discipline as
-- 770-772; grants restored to exactly what pg_proc showed before (default
-- PUBLIC, which a recreate restores, plus authenticated). Dry-run tested in
-- a rolled-back transaction against a local replay of 001-774.

DROP FUNCTION IF EXISTS take_attendance(uuid, date, uuid[]);
CREATE OR REPLACE FUNCTION take_attendance(p_route_id uuid, p_run_date date, p_present_subscription_ids uuid[]) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r route_subscriptions%ROWTYPE;
  v_existing route_run_attendance%ROWTYPE;
  v_new_present boolean;
  v_changed boolean;
  v_daily_share numeric;
  v_month int := extract(month FROM p_run_date)::int;
  v_year int := extract(year FROM p_run_date)::int;
  v_route vehicle_routes%ROWTYPE;
BEGIN
  IF NOT is_route_owner(p_route_id) THEN RAISE EXCEPTION 'You can only manage your own route.' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO v_route FROM vehicle_routes WHERE id = p_route_id;

  FOR r IN SELECT * FROM route_subscriptions WHERE route_id = p_route_id AND status IN ('active', 'pending_cancellation') LOOP
    v_new_present := r.id = ANY(p_present_subscription_ids);
    v_daily_share := round(r.monthly_fee_pkr / scheduled_days_in_month(p_route_id, v_month, v_year));
    v_changed := false;

    SELECT * INTO v_existing FROM route_run_attendance WHERE subscription_id = r.id AND run_date = p_run_date;

    IF NOT FOUND THEN
      INSERT INTO route_run_attendance (route_id, subscription_id, run_date, present, marked_by)
      VALUES (p_route_id, r.id, p_run_date, v_new_present, current_portal_user_id());
      v_changed := true;

      IF v_new_present THEN
        INSERT INTO route_subscription_charges (subscription_id, month, year, amount_pkr)
        VALUES (r.id, v_month, v_year, v_daily_share)
        ON CONFLICT (subscription_id, month, year) DO UPDATE SET amount_pkr = route_subscription_charges.amount_pkr + v_daily_share
          WHERE route_subscription_charges.status = 'due';
      END IF;
    ELSIF v_existing.present != v_new_present THEN
      UPDATE route_run_attendance SET present = v_new_present, marked_at = now(), marked_by = current_portal_user_id() WHERE id = v_existing.id;
      UPDATE route_subscription_charges SET amount_pkr = greatest(0, amount_pkr + (CASE WHEN v_new_present THEN v_daily_share ELSE -v_daily_share END))
        WHERE subscription_id = r.id AND month = v_month AND year = v_year AND status = 'due';
      v_changed := true;
    END IF;

    IF v_changed THEN
      INSERT INTO portal_notifications (portal_user_id, event_type, title, body, link)
      VALUES (r.portal_user_id, 'route_attendance_marked',
        CASE WHEN v_new_present THEN 'On board' ELSE 'Marked absent today' END,
        v_route.origin || ' → ' || v_route.destination || ' · ' || to_char(p_run_date, 'DD Mon')
          || CASE WHEN v_new_present THEN ' — the driver has marked your seat present.' ELSE ' — the driver marked this seat absent. If that''s wrong, message the driver.' END,
        '/portal/marketplace/route/' || p_route_id);
    END IF;
  END LOOP;
END;
$$;
GRANT EXECUTE ON FUNCTION take_attendance(uuid, date, uuid[]) TO authenticated;

DROP FUNCTION IF EXISTS mark_run_arrived(uuid);
CREATE OR REPLACE FUNCTION mark_run_arrived(p_run_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_run route_runs%ROWTYPE; v_route vehicle_routes%ROWTYPE;
BEGIN
  SELECT * INTO v_run FROM route_runs WHERE id = p_run_id;
  IF NOT FOUND OR NOT is_route_owner(v_run.route_id) THEN RAISE EXCEPTION 'You can only manage your own route''s runs.' USING ERRCODE = 'P0001'; END IF;
  IF v_run.direction != 'outbound' THEN RAISE EXCEPTION 'Only the outbound leg has an arrival to mark.' USING ERRCODE = 'P0001'; END IF;
  IF v_run.ended_at IS NOT NULL THEN RAISE EXCEPTION 'This run has already ended.' USING ERRCODE = 'P0001'; END IF;

  UPDATE route_runs SET outbound_arrived_at = now() WHERE id = p_run_id;

  SELECT * INTO v_route FROM vehicle_routes WHERE id = v_run.route_id;
  INSERT INTO portal_notifications (portal_user_id, event_type, title, body, link)
  SELECT rp.portal_user_id, 'route_run_arrived', 'Arrived at ' || v_route.destination,
    'The van has reached ' || v_route.destination || '.',
    '/portal/marketplace/route/' || v_run.route_id
  FROM route_participants rp WHERE rp.route_id = v_run.route_id AND rp.is_active = true;
END;
$$;
GRANT EXECUTE ON FUNCTION mark_run_arrived(uuid) TO authenticated;

DROP FUNCTION IF EXISTS end_route_run(uuid);
CREATE OR REPLACE FUNCTION end_route_run(p_route_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_route vehicle_routes%ROWTYPE; v_direction varchar;
BEGIN
  IF NOT is_route_owner(p_route_id) THEN RAISE EXCEPTION 'You can only end your own route''s run.' USING ERRCODE = 'P0001'; END IF;
  UPDATE route_runs SET ended_at = now() WHERE route_id = p_route_id AND ended_at IS NULL
    RETURNING direction INTO v_direction;

  -- Nothing was running (a double tap): nothing to tell anyone.
  IF v_direction IS NULL THEN RETURN; END IF;

  SELECT * INTO v_route FROM vehicle_routes WHERE id = p_route_id;
  INSERT INTO portal_notifications (portal_user_id, event_type, title, body, link)
  SELECT rp.portal_user_id, 'route_run_ended',
    CASE WHEN v_direction = 'return' THEN 'Back at ' || v_route.origin ELSE 'Trip finished' END,
    CASE WHEN v_direction = 'return'
      THEN 'The return trip from ' || v_route.destination || ' has finished.'
      ELSE v_route.origin || ' → ' || v_route.destination || ' has finished for today.' END,
    '/portal/marketplace/route/' || p_route_id
  FROM route_participants rp WHERE rp.route_id = p_route_id AND rp.is_active = true;
END;
$$;
GRANT EXECUTE ON FUNCTION end_route_run(uuid) TO authenticated;
