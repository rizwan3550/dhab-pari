-- Migration 774: commission audit across hourly / rental / equipment,
-- 2026-10-30, checked against the reference path — completed ride-dispatch
-- trips settle through complete_trip_booking (709, restored by 765), which
-- takes its rate from the vehicle's own category card
-- (vehicle_category_commission_pct) and only falls back to the older
-- flat lookup when the vehicle has no category yet.
--
-- What the live functions actually did (pg_get_functiondef, not the
-- migration files):
--
--   confirm_hourly_booking (662) — flat site_settings
--     'marketplace_hourly_commission_pct', ignoring the vehicle's category.
--     A Rickshaw and a Prado paid the same %, unlike every trip/dispatch/
--     equipment job. Tenant scoping itself was already correct.
--
--   confirm_rental_booking (662) — same flat-% gap, PLUS no tenant scoping
--     at all: the MKT-4050 commission and MKT-1001 cash accounts and the
--     rate setting were looked up by code only. Every tenant owns its own
--     copy of those accounts (633), so with more than one village the
--     lookup returns whichever row comes first and a rental's commission
--     can land in another village's ledger.
--
--   confirm_equipment_booking (709) — already category-aware, but 709's
--     rewrite dropped the tenant filters 662 had, so it has the same
--     cross-tenant account lookup as rental.
--
-- Fix: all three take the rate from the vehicle's category card when set
-- (classification 'intercity', same as equipment in 709 — none of these
-- three verticals records an out-of-city flag), else their existing
-- per-vertical site setting, so a vehicle with no category is charged
-- exactly what it was before. Every account/setting lookup is scoped to
-- the VEHICLE's tenant: rental_bookings and equipment_bookings never got a
-- tenant_id column of their own, and the vehicle is what the money is
-- actually tied to. An admin may only settle a booking on a vehicle in
-- their own tenant; the keeper path already implies it (they own it).
--
-- Also found in the dry run: the keeper/admin guard could be bypassed.
-- v_is_keeper compared v.portal_user_id to current_portal_user_id(), which
-- is NULL for any signed-in account without an active portal_users row
-- (staff without post_transactions, a deactivated villager). NULL there
-- made the whole guard NULL, and IF NULL never raises — so on the live
-- rental and equipment functions such a caller could settle someone
-- else's booking and post commission (reproduced locally: a caller with
-- no portal row confirmed a rental and got {"commission": 500}). Hourly
-- was only shielded by accident, through its tenant-filtered booking
-- lookup. Both flags are now COALESCEd to a real boolean.
--
-- Same DROP + recreate discipline as 770-772; grants restored to exactly
-- what pg_proc showed before (authenticated only). Dry-run tested in a
-- rolled-back transaction against a full local replay of 001-773 — see
-- the PR description for the cases exercised.

DROP FUNCTION IF EXISTS confirm_hourly_booking(uuid);
CREATE OR REPLACE FUNCTION confirm_hourly_booking(p_booking_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  b hourly_bookings%ROWTYPE; v vehicles%ROWTYPE;
  v_vehicle_account uuid; v_cash_account uuid; v_commission_account uuid;
  v_commission_pct decimal; v_commission_amount decimal;
  v_gross_voucher_id uuid; v_gross_voucher_no varchar; v_commission_voucher_id uuid;
  v_is_keeper boolean; v_is_admin boolean;
BEGIN
  SELECT * INTO b FROM hourly_bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Booking not found.' USING ERRCODE = 'P0001'; END IF;
  IF b.status <> 'completed' THEN RAISE EXCEPTION 'This trip has not been completed yet.' USING ERRCODE = 'P0001'; END IF;
  IF b.status_confirmed THEN RAISE EXCEPTION 'This booking has already been settled.' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO v FROM vehicles WHERE id = b.vehicle_id;

  -- COALESCE both to a real boolean: a caller with no active portal_users
  -- row makes current_portal_user_id() NULL, and NOT (false OR NULL) is
  -- NULL, which IF treats as "don't raise" — see the header.
  v_is_keeper := COALESCE(v.portal_user_id = current_portal_user_id() AND v.commission_mode = 'per_order', false);
  v_is_admin := COALESCE(current_admin_permission('post_transactions') AND v.tenant_id = my_tenant_id(), false);
  IF NOT (v_is_admin OR v_is_keeper) THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE = 'P0001';
  END IF;

  v_vehicle_account := ensure_vehicle_account(v.id);
  SELECT id INTO v_commission_account FROM accounts WHERE system = 'marketplace' AND code = 'MKT-4050' AND tenant_id = v.tenant_id;

  IF v.commission_mode = 'per_order' THEN
    v_commission_pct := CASE WHEN v.category_id IS NOT NULL
      THEN vehicle_category_commission_pct(v.category_id, 'intercity')
      ELSE COALESCE((SELECT value::decimal FROM site_settings WHERE key = 'marketplace_hourly_commission_pct' AND tenant_id = v.tenant_id), 0) END;
    v_commission_amount := round(b.total_amount_pkr * v_commission_pct / 100, 2);

    IF v_commission_amount > 0 THEN
      INSERT INTO vouchers (system, voucher_type, voucher_date, particular, amount_pkr, from_account_id, to_account_id, party_name)
      VALUES ('marketplace', 'income', (now() AT TIME ZONE 'Asia/Karachi')::date,
        'Marketplace commission — hourly rental (' || b.hours || 'h, paid directly to driver)', v_commission_amount, v_commission_account, v_vehicle_account, v.owner_name)
      RETURNING id INTO v_commission_voucher_id;
    END IF;

    UPDATE hourly_bookings SET status_confirmed = true, commission_voucher_id = v_commission_voucher_id WHERE id = p_booking_id;
    PERFORM check_seller_balance_notify('vehicle', v.id);
    RETURN jsonb_build_object('amount', b.total_amount_pkr, 'commission', v_commission_amount);
  END IF;

  IF NOT v_is_admin THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE = 'P0001';
  END IF;
  SELECT id INTO v_cash_account FROM accounts WHERE system = 'marketplace' AND code = 'MKT-1001' AND tenant_id = v.tenant_id;

  INSERT INTO vouchers (system, voucher_type, voucher_date, particular, amount_pkr, from_account_id, to_account_id, party_name)
  VALUES ('marketplace', 'income', (now() AT TIME ZONE 'Asia/Karachi')::date,
    'Hourly rental (' || b.hours || 'h) — confirmed', b.total_amount_pkr, v_vehicle_account, v_cash_account, v.owner_name)
  RETURNING id, voucher_no INTO v_gross_voucher_id, v_gross_voucher_no;

  UPDATE hourly_bookings SET status_confirmed = true, gross_voucher_id = v_gross_voucher_id WHERE id = p_booking_id;
  RETURN jsonb_build_object('voucher_no', v_gross_voucher_no, 'amount', b.total_amount_pkr);
END;
$$;
REVOKE ALL ON FUNCTION confirm_hourly_booking(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION confirm_hourly_booking(uuid) TO authenticated;

DROP FUNCTION IF EXISTS confirm_rental_booking(uuid);
CREATE OR REPLACE FUNCTION confirm_rental_booking(p_booking_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  b rental_bookings%ROWTYPE; v vehicles%ROWTYPE;
  v_vehicle_account uuid; v_cash_account uuid; v_commission_account uuid;
  v_commission_pct decimal; v_commission_amount decimal;
  v_gross_voucher_id uuid; v_gross_voucher_no varchar; v_commission_voucher_id uuid;
  v_is_keeper boolean; v_is_admin boolean;
BEGIN
  SELECT * INTO b FROM rental_bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Booking not found.' USING ERRCODE = 'P0001'; END IF;
  IF b.status <> 'completed' THEN RAISE EXCEPTION 'This trip has not been completed yet.' USING ERRCODE = 'P0001'; END IF;
  IF b.status_confirmed THEN RAISE EXCEPTION 'This booking has already been settled.' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO v FROM vehicles WHERE id = b.vehicle_id;

  -- COALESCE both to a real boolean: a caller with no active portal_users
  -- row makes current_portal_user_id() NULL, and NOT (false OR NULL) is
  -- NULL, which IF treats as "don't raise" — see the header.
  v_is_keeper := COALESCE(v.portal_user_id = current_portal_user_id() AND v.commission_mode = 'per_order', false);
  v_is_admin := COALESCE(current_admin_permission('post_transactions') AND v.tenant_id = my_tenant_id(), false);
  IF NOT (v_is_admin OR v_is_keeper) THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE = 'P0001';
  END IF;

  v_vehicle_account := ensure_vehicle_account(v.id);
  SELECT id INTO v_commission_account FROM accounts WHERE system = 'marketplace' AND code = 'MKT-4050' AND tenant_id = v.tenant_id;

  IF v.commission_mode = 'per_order' THEN
    v_commission_pct := CASE WHEN v.category_id IS NOT NULL
      THEN vehicle_category_commission_pct(v.category_id, 'intercity')
      ELSE COALESCE((SELECT value::decimal FROM site_settings WHERE key = 'marketplace_rental_commission_pct' AND tenant_id = v.tenant_id), 0) END;
    v_commission_amount := round(b.total_amount_pkr * v_commission_pct / 100, 2);

    IF v_commission_amount > 0 THEN
      INSERT INTO vouchers (system, voucher_type, voucher_date, particular, amount_pkr, from_account_id, to_account_id, party_name)
      VALUES ('marketplace', 'income', (now() AT TIME ZONE 'Asia/Karachi')::date,
        'Marketplace commission — vehicle rental (' || round(b.km) || 'km, paid directly to driver)', v_commission_amount, v_commission_account, v_vehicle_account, v.owner_name)
      RETURNING id INTO v_commission_voucher_id;
    END IF;

    UPDATE rental_bookings SET status_confirmed = true, commission_voucher_id = v_commission_voucher_id WHERE id = p_booking_id;
    PERFORM check_seller_balance_notify('vehicle', v.id);
    RETURN jsonb_build_object('amount', b.total_amount_pkr, 'commission', v_commission_amount);
  END IF;

  IF NOT v_is_admin THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE = 'P0001';
  END IF;
  SELECT id INTO v_cash_account FROM accounts WHERE system = 'marketplace' AND code = 'MKT-1001' AND tenant_id = v.tenant_id;

  INSERT INTO vouchers (system, voucher_type, voucher_date, particular, amount_pkr, from_account_id, to_account_id, party_name)
  VALUES ('marketplace', 'income', (now() AT TIME ZONE 'Asia/Karachi')::date,
    'Vehicle rental (' || round(b.km) || 'km) — confirmed', b.total_amount_pkr, v_vehicle_account, v_cash_account, v.owner_name)
  RETURNING id, voucher_no INTO v_gross_voucher_id, v_gross_voucher_no;

  UPDATE rental_bookings SET status_confirmed = true, gross_voucher_id = v_gross_voucher_id WHERE id = p_booking_id;
  RETURN jsonb_build_object('voucher_no', v_gross_voucher_no, 'amount', b.total_amount_pkr);
END;
$$;
REVOKE ALL ON FUNCTION confirm_rental_booking(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION confirm_rental_booking(uuid) TO authenticated;

DROP FUNCTION IF EXISTS confirm_equipment_booking(uuid);
CREATE OR REPLACE FUNCTION confirm_equipment_booking(p_booking_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  b equipment_bookings%ROWTYPE; v vehicles%ROWTYPE;
  v_vehicle_account uuid; v_cash_account uuid; v_commission_account uuid;
  v_commission_pct decimal; v_commission_amount decimal;
  v_gross_voucher_id uuid; v_gross_voucher_no varchar; v_commission_voucher_id uuid;
  v_is_keeper boolean; v_is_admin boolean;
BEGIN
  SELECT * INTO b FROM equipment_bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Booking not found.' USING ERRCODE = 'P0001'; END IF;
  IF b.status <> 'completed' THEN RAISE EXCEPTION 'This job has not been completed yet.' USING ERRCODE = 'P0001'; END IF;
  IF b.status_confirmed THEN RAISE EXCEPTION 'This booking has already been settled.' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO v FROM vehicles WHERE id = b.vehicle_id;

  -- COALESCE both to a real boolean: a caller with no active portal_users
  -- row makes current_portal_user_id() NULL, and NOT (false OR NULL) is
  -- NULL, which IF treats as "don't raise" — see the header.
  v_is_keeper := COALESCE(v.portal_user_id = current_portal_user_id() AND v.commission_mode = 'per_order', false);
  v_is_admin := COALESCE(current_admin_permission('post_transactions') AND v.tenant_id = my_tenant_id(), false);
  IF NOT (v_is_admin OR v_is_keeper) THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE = 'P0001';
  END IF;

  v_vehicle_account := ensure_vehicle_account(v.id);
  SELECT id INTO v_commission_account FROM accounts WHERE system = 'marketplace' AND code = 'MKT-4050' AND tenant_id = v.tenant_id;

  IF v.commission_mode = 'per_order' THEN
    v_commission_pct := CASE WHEN v.category_id IS NOT NULL
      THEN vehicle_category_commission_pct(v.category_id, 'intercity')
      ELSE COALESCE((SELECT value::decimal FROM site_settings WHERE key = 'marketplace_equipment_commission_pct' AND tenant_id = v.tenant_id), 0) END;
    v_commission_amount := round(b.total_amount_pkr * v_commission_pct / 100, 2);

    IF v_commission_amount > 0 THEN
      INSERT INTO vouchers (system, voucher_type, voucher_date, particular, amount_pkr, from_account_id, to_account_id, party_name)
      VALUES ('marketplace', 'income', (now() AT TIME ZONE 'Asia/Karachi')::date,
        'Marketplace commission — ' || b.kind || ' (paid directly to driver)', v_commission_amount, v_commission_account, v_vehicle_account, v.owner_name)
      RETURNING id INTO v_commission_voucher_id;
    END IF;

    UPDATE equipment_bookings SET status_confirmed = true, commission_voucher_id = v_commission_voucher_id WHERE id = p_booking_id;
    PERFORM check_seller_balance_notify('vehicle', v.id);
    RETURN jsonb_build_object('amount', b.total_amount_pkr, 'commission', v_commission_amount);
  END IF;

  IF NOT v_is_admin THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE = 'P0001';
  END IF;
  SELECT id INTO v_cash_account FROM accounts WHERE system = 'marketplace' AND code = 'MKT-1001' AND tenant_id = v.tenant_id;

  INSERT INTO vouchers (system, voucher_type, voucher_date, particular, amount_pkr, from_account_id, to_account_id, party_name)
  VALUES ('marketplace', 'income', (now() AT TIME ZONE 'Asia/Karachi')::date,
    initcap(b.kind) || ' booking — confirmed', b.total_amount_pkr, v_vehicle_account, v_cash_account, v.owner_name)
  RETURNING id, voucher_no INTO v_gross_voucher_id, v_gross_voucher_no;

  UPDATE equipment_bookings SET status_confirmed = true, gross_voucher_id = v_gross_voucher_id WHERE id = p_booking_id;
  RETURN jsonb_build_object('voucher_no', v_gross_voucher_no, 'amount', b.total_amount_pkr);
END;
$$;
REVOKE ALL ON FUNCTION confirm_equipment_booking(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION confirm_equipment_booking(uuid) TO authenticated;
