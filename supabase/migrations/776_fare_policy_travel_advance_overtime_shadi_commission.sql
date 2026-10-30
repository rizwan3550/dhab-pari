-- Migration 776: committee fare policy per service — travel charge,
-- maximum distance, 20% advances, hourly overtime, and commission on
-- wedding bookings.
--
-- Real ask, 2026-10-30, after the money-flow audit
-- (docs/money-flow-audit-2026-10-30.md):
--   "everything will work as per committee set commission so nothing
--    will be free, even shadi will pay the commission too — 20%
--    machinery advance and shadi vehicle advance — and everything is
--    set per service: travel rate per km and maximum distance; if it's
--    not there you need to build it — overtime rule for hourly — and
--    proper fare rules displayed in the booking window of every kind of
--    booking, from the fare policy in the backend."
--
-- What this adds:
--
-- 1. service_fare_policies — one row per tenant per service (hourly,
--    rental, machinery, tractor, loader, shadi). The committee edits it
--    (set_service_fare_policy, admin 'manage_parties'); riders and
--    drivers read it (service_fare_policies_list) to show the fare rules
--    in every booking window. Seeded below with STARTING values for the
--    committee to review — they are placeholders, not decisions.
--
-- 2. Travel charge + maximum distance, computed by the SERVER, never
--    sent by the client:
--      road_km       = round(haversine(base -> site) * 1.3)   (rental's factor)
--      travel_km     = max(0, road_km - free_radius_km)
--      travel_charge = travel_km * 2 * travel_rate_per_km_pkr  (there and back)
--    The base is vehicles.base_lat/base_lng (new; set by the driver or
--    committee) or, until set, the tenant's home city. Above
--    max_distance_km the booking is refused with "ask the committee for
--    a custom quote". Applied by BEFORE INSERT triggers so the existing
--    create_* RPCs (and their idempotency/notification logic) don't
--    have to be rewritten:
--      equipment_bookings      travel charge + max distance + 20% advance due
--      shadi_vehicle_requests  travel charge per hand-picked vehicle (added
--                              into its full_day_rate_pkr) + max distance
--      shadi_events            server distance from home city for the
--                              by-type flow + max distance
--      hourly_bookings         pickup must be within max distance
--      rental_bookings         trip km must be within max distance
--
-- 3. Equipment advance (machinery/tractor/loader), mirroring the shadi
--    advance the committee already runs: after the driver accepts, the
--    rider pays advance_pct of the estimate (rate x hours/trips +
--    delivery fee + travel) with a slip; the committee confirms it into
--    a new liability MKT-5005; the job cannot be started (PIN) until
--    then; at settlement it is released to the vehicle's wallet, and the
--    driver collects only the remainder. If the booking is cancelled or
--    declined after the advance was confirmed it becomes 'refund_due'
--    and the committee refunds it (refund_equipment_advance).
--
-- 4. Hourly overtime: end_hourly_trip now bills time past the booked
--    hours — after overtime_grace_minutes, each started
--    overtime_block_minutes block at overtime_rate_pct of the hourly
--    rate, pro-rata. Shown live to both sides from the same policy.
--
-- 5. Commission on weddings: sweep_due_shadi_advances, which already
--    releases each vehicle's advance after the wedding date, now also
--    charges a per_order vehicle the committee's commission on its full
--    day rate (category card when set, else marketplace_shadi_commission_pct)
--    — the same rule every other service already follows. Lump-sum
--    vehicles pay their fixed fee instead, as everywhere else.
--
-- 6. announce_shadi_advance reads the shadi advance % from the policy
--    (falling back to the old marketplace_shadi_advance_pct setting).
--
-- Every replaced function keeps its exact signature (CREATE OR REPLACE
-- keeps its grants). Dry-run on a local replay inside BEGIN ... ROLLBACK
-- before review; NOT applied to production by the author.

-- ─── 1. Policy table ───────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS service_fare_policies (
  tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  service_key varchar NOT NULL CHECK (service_key IN ('hourly', 'rental', 'machinery', 'tractor', 'loader', 'shadi')),
  free_radius_km numeric NOT NULL DEFAULT 0 CHECK (free_radius_km >= 0),
  travel_rate_per_km_pkr numeric NOT NULL DEFAULT 0 CHECK (travel_rate_per_km_pkr >= 0),
  max_distance_km numeric CHECK (max_distance_km IS NULL OR max_distance_km > 0),
  advance_pct numeric NOT NULL DEFAULT 0 CHECK (advance_pct >= 0 AND advance_pct <= 100),
  overtime_grace_minutes int NOT NULL DEFAULT 10 CHECK (overtime_grace_minutes >= 0),
  overtime_block_minutes int NOT NULL DEFAULT 30 CHECK (overtime_block_minutes > 0),
  overtime_rate_pct numeric NOT NULL DEFAULT 100 CHECK (overtime_rate_pct >= 0),
  full_day_hours numeric CHECK (full_day_hours IS NULL OR full_day_hours > 0),
  notes_en text,
  notes_ur text,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, service_key)
);
ALTER TABLE service_fare_policies ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "service_fare_policies_read" ON service_fare_policies;
CREATE POLICY "service_fare_policies_read" ON service_fare_policies FOR SELECT USING (true);

-- Starting values for the committee to review (admin → Fare policies).
CREATE OR REPLACE FUNCTION fare_policy_default(p_service varchar) RETURNS service_fare_policies
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE r service_fare_policies;
BEGIN
  r.service_key := p_service;
  r.free_radius_km := 0; r.travel_rate_per_km_pkr := 0; r.max_distance_km := NULL; r.advance_pct := 0;
  r.overtime_grace_minutes := 10; r.overtime_block_minutes := 30; r.overtime_rate_pct := 100; r.full_day_hours := NULL;
  r.updated_at := now();
  CASE p_service
    WHEN 'hourly'    THEN r.max_distance_km := 30;
    WHEN 'rental'    THEN r.max_distance_km := 600;
    WHEN 'machinery' THEN r.free_radius_km := 10; r.travel_rate_per_km_pkr := 80; r.max_distance_km := 80;  r.advance_pct := 20;
    WHEN 'tractor'   THEN r.free_radius_km := 5;  r.travel_rate_per_km_pkr := 50; r.max_distance_km := 40;  r.advance_pct := 20;
    WHEN 'loader'    THEN r.free_radius_km := 10; r.travel_rate_per_km_pkr := 60; r.max_distance_km := 60;  r.advance_pct := 20;
    WHEN 'shadi'     THEN r.free_radius_km := 40; r.travel_rate_per_km_pkr := 40; r.max_distance_km := 250; r.advance_pct := 20; r.full_day_hours := 12;
    ELSE NULL;
  END CASE;
  RETURN r;
END;
$$;

INSERT INTO service_fare_policies (tenant_id, service_key, free_radius_km, travel_rate_per_km_pkr, max_distance_km, advance_pct,
  overtime_grace_minutes, overtime_block_minutes, overtime_rate_pct, full_day_hours)
SELECT t.id, d.service_key, d.free_radius_km, d.travel_rate_per_km_pkr, d.max_distance_km,
  CASE WHEN s.key = 'shadi' THEN COALESCE((SELECT value::numeric FROM site_settings WHERE key = 'marketplace_shadi_advance_pct' AND tenant_id = t.id), d.advance_pct) ELSE d.advance_pct END,
  d.overtime_grace_minutes, d.overtime_block_minutes, d.overtime_rate_pct, d.full_day_hours
FROM tenants t
CROSS JOIN (VALUES ('hourly'), ('rental'), ('machinery'), ('tractor'), ('loader'), ('shadi')) AS s(key)
CROSS JOIN LATERAL fare_policy_default(s.key) d
ON CONFLICT (tenant_id, service_key) DO NOTHING;

-- Same committee-set commission rule for weddings as every other service.
INSERT INTO site_settings (key, value, description, tenant_id)
SELECT 'marketplace_shadi_commission_pct', '10', 'Commission % on wedding (shadi) bookings for per-order vehicles without a category card', t.id
FROM tenants t
WHERE NOT EXISTS (SELECT 1 FROM site_settings s WHERE s.key = 'marketplace_shadi_commission_pct' AND s.tenant_id = t.id);

CREATE OR REPLACE FUNCTION fare_policy(p_tenant_id uuid, p_service varchar) RETURNS service_fare_policies
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE r service_fare_policies;
BEGIN
  SELECT * INTO r FROM service_fare_policies WHERE tenant_id = p_tenant_id AND service_key = p_service;
  IF FOUND THEN RETURN r; END IF;
  r := fare_policy_default(p_service);
  r.tenant_id := p_tenant_id;
  RETURN r;
END;
$$;

CREATE OR REPLACE FUNCTION service_fare_policies_list() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE(jsonb_agg(to_jsonb(p) - 'tenant_id' ORDER BY array_position(ARRAY['hourly','rental','machinery','tractor','loader','shadi'], s.key)), '[]'::jsonb)
  FROM unnest(ARRAY['hourly','rental','machinery','tractor','loader','shadi']) AS s(key)
  CROSS JOIN LATERAL fare_policy(my_tenant_id(), s.key) p;
$$;
GRANT EXECUTE ON FUNCTION service_fare_policies_list() TO authenticated, anon;

CREATE OR REPLACE FUNCTION set_service_fare_policy(
  p_service varchar, p_free_radius_km numeric, p_travel_rate_per_km_pkr numeric, p_max_distance_km numeric, p_advance_pct numeric,
  p_overtime_grace_minutes int, p_overtime_block_minutes int, p_overtime_rate_pct numeric, p_full_day_hours numeric,
  p_notes_en text, p_notes_ur text
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT COALESCE(current_admin_permission('manage_parties'), false) THEN RAISE EXCEPTION 'Not authorized' USING ERRCODE = 'P0001'; END IF;
  IF p_service NOT IN ('hourly', 'rental', 'machinery', 'tractor', 'loader', 'shadi') THEN RAISE EXCEPTION 'Unknown service.' USING ERRCODE = 'P0001'; END IF;
  INSERT INTO service_fare_policies AS sp (tenant_id, service_key, free_radius_km, travel_rate_per_km_pkr, max_distance_km, advance_pct,
    overtime_grace_minutes, overtime_block_minutes, overtime_rate_pct, full_day_hours, notes_en, notes_ur, updated_at)
  VALUES (my_tenant_id(), p_service, COALESCE(p_free_radius_km, 0), COALESCE(p_travel_rate_per_km_pkr, 0), p_max_distance_km, COALESCE(p_advance_pct, 0),
    COALESCE(p_overtime_grace_minutes, 10), COALESCE(p_overtime_block_minutes, 30), COALESCE(p_overtime_rate_pct, 100), p_full_day_hours,
    NULLIF(trim(coalesce(p_notes_en, '')), ''), NULLIF(trim(coalesce(p_notes_ur, '')), ''), now())
  ON CONFLICT (tenant_id, service_key) DO UPDATE SET
    free_radius_km = EXCLUDED.free_radius_km, travel_rate_per_km_pkr = EXCLUDED.travel_rate_per_km_pkr, max_distance_km = EXCLUDED.max_distance_km,
    advance_pct = EXCLUDED.advance_pct, overtime_grace_minutes = EXCLUDED.overtime_grace_minutes, overtime_block_minutes = EXCLUDED.overtime_block_minutes,
    overtime_rate_pct = EXCLUDED.overtime_rate_pct, full_day_hours = EXCLUDED.full_day_hours, notes_en = EXCLUDED.notes_en, notes_ur = EXCLUDED.notes_ur,
    updated_at = now();
END;
$$;
REVOKE ALL ON FUNCTION set_service_fare_policy(varchar, numeric, numeric, numeric, numeric, int, int, numeric, numeric, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION set_service_fare_policy(varchar, numeric, numeric, numeric, numeric, int, int, numeric, numeric, text, text) TO authenticated;

-- ─── 2. Vehicle base + travel quote ────────────────────────────────────

ALTER TABLE vehicles ADD COLUMN IF NOT EXISTS base_lat numeric;
ALTER TABLE vehicles ADD COLUMN IF NOT EXISTS base_lng numeric;

CREATE OR REPLACE FUNCTION tenant_home_point(p_tenant_id uuid, OUT lat numeric, OUT lng numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT c.lat, c.lng FROM cities c
  WHERE c.tenant_id = p_tenant_id AND c.is_home_city AND c.lat IS NOT NULL AND c.lng IS NOT NULL
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION set_vehicle_base(p_vehicle_id uuid, p_lat numeric, p_lng numeric) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v vehicles%ROWTYPE;
BEGIN
  SELECT * INTO v FROM vehicles WHERE id = p_vehicle_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Vehicle not found.' USING ERRCODE = 'P0001'; END IF;
  IF NOT (COALESCE(current_admin_permission('manage_parties'), false) OR COALESCE(v.portal_user_id = current_portal_user_id(), false)) THEN
    RAISE EXCEPTION 'You do not manage this vehicle.' USING ERRCODE = 'P0001';
  END IF;
  UPDATE vehicles SET base_lat = p_lat, base_lng = p_lng WHERE id = p_vehicle_id;
END;
$$;
REVOKE ALL ON FUNCTION set_vehicle_base(uuid, numeric, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION set_vehicle_base(uuid, numeric, numeric) TO authenticated;

-- Core travel calculation from an explicit start point. known=false
-- (no charge, no limit) when either end has no coordinates — the
-- booking still goes through rather than being blocked by missing data.
CREATE OR REPLACE FUNCTION fare_travel_between(
  p_service varchar, p_tenant_id uuid, p_from_lat numeric, p_from_lng numeric, p_to_lat numeric, p_to_lng numeric
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE pol service_fare_policies; v_road numeric; v_travel numeric; v_charge numeric;
BEGIN
  pol := fare_policy(p_tenant_id, p_service);
  IF p_from_lat IS NULL OR p_from_lng IS NULL OR p_to_lat IS NULL OR p_to_lng IS NULL THEN
    RETURN jsonb_build_object('known', false, 'road_km', NULL, 'free_radius_km', pol.free_radius_km, 'travel_km', 0,
      'travel_rate_per_km_pkr', pol.travel_rate_per_km_pkr, 'travel_charge_pkr', 0, 'max_distance_km', pol.max_distance_km, 'too_far', false);
  END IF;
  v_road := round(haversine_km(p_from_lat, p_from_lng, p_to_lat, p_to_lng) * 1.3);
  v_travel := greatest(0, v_road - pol.free_radius_km);
  v_charge := round(v_travel * 2 * pol.travel_rate_per_km_pkr);
  RETURN jsonb_build_object('known', true, 'road_km', v_road, 'free_radius_km', pol.free_radius_km, 'travel_km', v_travel,
    'travel_rate_per_km_pkr', pol.travel_rate_per_km_pkr, 'travel_charge_pkr', v_charge, 'max_distance_km', pol.max_distance_km,
    'too_far', pol.max_distance_km IS NOT NULL AND v_road > pol.max_distance_km);
END;
$$;

-- What a rider sees in the booking sheet for one chosen vehicle + site.
CREATE OR REPLACE FUNCTION fare_travel_quote(p_service varchar, p_vehicle_id uuid, p_lat numeric, p_lng numeric) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v vehicles%ROWTYPE; h record;
BEGIN
  IF p_vehicle_id IS NULL THEN
    SELECT * INTO h FROM tenant_home_point(my_tenant_id());
    RETURN fare_travel_between(p_service, my_tenant_id(), h.lat, h.lng, p_lat, p_lng);
  END IF;
  SELECT * INTO v FROM vehicles WHERE id = p_vehicle_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Vehicle not found.' USING ERRCODE = 'P0001'; END IF;
  IF v.base_lat IS NOT NULL AND v.base_lng IS NOT NULL THEN
    RETURN fare_travel_between(p_service, v.tenant_id, v.base_lat, v.base_lng, p_lat, p_lng);
  END IF;
  SELECT * INTO h FROM tenant_home_point(v.tenant_id);
  RETURN fare_travel_between(p_service, v.tenant_id, h.lat, h.lng, p_lat, p_lng);
END;
$$;
GRANT EXECUTE ON FUNCTION fare_travel_quote(varchar, uuid, numeric, numeric) TO authenticated, anon;

CREATE OR REPLACE FUNCTION fare_too_far_error(p_road_km numeric, p_max_km numeric) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'This place is about % km away — the limit for this service is % km. Please ask the committee for a custom quote.',
    round(p_road_km), round(p_max_km) USING ERRCODE = 'P0001';
END;
$$;

-- ─── 3. Equipment: travel, max distance, advance ───────────────────────

ALTER TABLE equipment_bookings ADD COLUMN IF NOT EXISTS travel_km numeric NOT NULL DEFAULT 0;
ALTER TABLE equipment_bookings ADD COLUMN IF NOT EXISTS travel_charge_pkr numeric NOT NULL DEFAULT 0;
ALTER TABLE equipment_bookings ADD COLUMN IF NOT EXISTS road_km numeric;
ALTER TABLE equipment_bookings ADD COLUMN IF NOT EXISTS advance_pct numeric NOT NULL DEFAULT 0;
ALTER TABLE equipment_bookings ADD COLUMN IF NOT EXISTS advance_amount_pkr numeric NOT NULL DEFAULT 0;
ALTER TABLE equipment_bookings ADD COLUMN IF NOT EXISTS advance_status varchar NOT NULL DEFAULT 'none'
  CHECK (advance_status IN ('none', 'due', 'announced', 'rejected', 'confirmed', 'released', 'refund_due', 'refunded'));
ALTER TABLE equipment_bookings ADD COLUMN IF NOT EXISTS advance_method varchar;
ALTER TABLE equipment_bookings ADD COLUMN IF NOT EXISTS advance_proof_url text;
ALTER TABLE equipment_bookings ADD COLUMN IF NOT EXISTS advance_announced_at timestamptz;
ALTER TABLE equipment_bookings ADD COLUMN IF NOT EXISTS advance_confirmed_at timestamptz;
ALTER TABLE equipment_bookings ADD COLUMN IF NOT EXISTS advance_rejected_reason text;
ALTER TABLE equipment_bookings ADD COLUMN IF NOT EXISTS advance_voucher_id uuid REFERENCES vouchers(id);
ALTER TABLE equipment_bookings ADD COLUMN IF NOT EXISTS advance_release_voucher_id uuid REFERENCES vouchers(id);
ALTER TABLE equipment_bookings ADD COLUMN IF NOT EXISTS advance_refund_voucher_id uuid REFERENCES vouchers(id);

-- Liability for equipment advances held for vehicles, per tenant.
INSERT INTO accounts (code, name, name_ur, type, system, description, is_protected, tenant_id)
SELECT 'MKT-5005', 'Equipment Advances Payable to Vehicles', 'مشینری ایڈوانس واجب الادا', 'liability', 'marketplace',
  'Machinery/tractor/loader booking advances collected from customers, released to the vehicle at settlement or refunded on cancellation', true, t.id
FROM tenants t
WHERE NOT EXISTS (SELECT 1 FROM accounts a WHERE a.tenant_id = t.id AND a.system = 'marketplace' AND a.code = 'MKT-5005');

CREATE OR REPLACE FUNCTION ensure_equipment_advance_account(p_tenant_id uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid;
BEGIN
  SELECT id INTO v_id FROM accounts WHERE tenant_id = p_tenant_id AND system = 'marketplace' AND code = 'MKT-5005';
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  INSERT INTO accounts (code, name, name_ur, type, system, description, is_protected, tenant_id)
  VALUES ('MKT-5005', 'Equipment Advances Payable to Vehicles', 'مشینری ایڈوانس واجب الادا', 'liability', 'marketplace',
    'Machinery/tractor/loader booking advances collected from customers, released to the vehicle at settlement or refunded on cancellation', true, p_tenant_id)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION trg_equipment_booking_fare() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v vehicles%ROWTYPE; q jsonb; pol service_fare_policies; v_estimate numeric;
BEGIN
  SELECT * INTO v FROM vehicles WHERE id = NEW.vehicle_id;
  -- A loader drives to the goods pickup first; machinery/tractor to the site.
  q := fare_travel_quote(NEW.kind,
    NEW.vehicle_id,
    CASE WHEN NEW.kind = 'loader' AND NEW.pickup_lat IS NOT NULL THEN NEW.pickup_lat ELSE NEW.site_lat END,
    CASE WHEN NEW.kind = 'loader' AND NEW.pickup_lng IS NOT NULL THEN NEW.pickup_lng ELSE NEW.site_lng END);
  IF (q->>'too_far')::boolean THEN PERFORM fare_too_far_error((q->>'road_km')::numeric, (q->>'max_distance_km')::numeric); END IF;
  NEW.road_km := (q->>'road_km')::numeric;
  NEW.travel_km := COALESCE((q->>'travel_km')::numeric, 0);
  NEW.travel_charge_pkr := COALESCE((q->>'travel_charge_pkr')::numeric, 0);

  pol := fare_policy(v.tenant_id, NEW.kind);
  v_estimate := CASE WHEN NEW.kind = 'loader'
      THEN NEW.rate_pkr * GREATEST(COALESCE(NEW.trip_count, 1), 1)
      ELSE NEW.rate_pkr * GREATEST(COALESCE(NEW.requested_hours, 0), 1) + COALESCE(NEW.mobilization_fee_pkr, 0) END
    + NEW.travel_charge_pkr;
  NEW.advance_pct := pol.advance_pct;
  NEW.advance_amount_pkr := round(v_estimate * pol.advance_pct / 100);
  NEW.advance_status := CASE WHEN NEW.advance_amount_pkr > 0 THEN 'due' ELSE 'none' END;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS equipment_booking_fare ON equipment_bookings;
CREATE TRIGGER equipment_booking_fare BEFORE INSERT ON equipment_bookings FOR EACH ROW EXECUTE FUNCTION trg_equipment_booking_fare();

-- A confirmed advance on a booking that ends up cancelled/declined is
-- owed back to the customer — flag it for the committee to refund.
CREATE OR REPLACE FUNCTION trg_equipment_booking_advance_refund() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status IN ('cancelled', 'declined') AND OLD.status NOT IN ('cancelled', 'declined') THEN
    IF OLD.advance_status = 'confirmed' THEN NEW.advance_status := 'refund_due';
    ELSIF OLD.advance_status IN ('due', 'announced', 'rejected') THEN NEW.advance_status := 'none';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS equipment_booking_advance_refund ON equipment_bookings;
CREATE TRIGGER equipment_booking_advance_refund BEFORE UPDATE OF status ON equipment_bookings FOR EACH ROW EXECUTE FUNCTION trg_equipment_booking_advance_refund();

CREATE OR REPLACE FUNCTION announce_equipment_advance(p_booking_id uuid, p_method varchar, p_proof_url text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE b equipment_bookings%ROWTYPE;
BEGIN
  SELECT * INTO b FROM equipment_bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Booking not found.' USING ERRCODE = 'P0001'; END IF;
  IF NOT COALESCE(b.portal_user_id = current_portal_user_id(), false) THEN RAISE EXCEPTION 'This is not your booking.' USING ERRCODE = 'P0001'; END IF;
  IF b.status <> 'accepted' THEN RAISE EXCEPTION 'The owner has to accept this booking before you pay the advance.' USING ERRCODE = 'P0001'; END IF;
  IF b.advance_status NOT IN ('due', 'rejected') THEN RAISE EXCEPTION 'This booking is not awaiting an advance.' USING ERRCODE = 'P0001'; END IF;
  IF p_proof_url IS NULL OR trim(p_proof_url) = '' THEN RAISE EXCEPTION 'Upload your payment slip.' USING ERRCODE = 'P0001'; END IF;
  UPDATE equipment_bookings SET advance_status = 'announced', advance_method = COALESCE(p_method, 'bank'), advance_proof_url = p_proof_url,
    advance_announced_at = now(), advance_rejected_reason = NULL
  WHERE id = p_booking_id;
  RETURN jsonb_build_object('amount', b.advance_amount_pkr);
END;
$$;
REVOKE ALL ON FUNCTION announce_equipment_advance(uuid, varchar, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION announce_equipment_advance(uuid, varchar, text) TO authenticated;

CREATE OR REPLACE FUNCTION confirm_equipment_advance(p_booking_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE b equipment_bookings%ROWTYPE; v vehicles%ROWTYPE; booker portal_users%ROWTYPE;
  v_liability uuid; v_cash uuid; v_voucher_id uuid; v_voucher_no varchar;
BEGIN
  SELECT * INTO b FROM equipment_bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Booking not found.' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO v FROM vehicles WHERE id = b.vehicle_id;
  IF NOT COALESCE(current_admin_permission('post_transactions') AND v.tenant_id = my_tenant_id(), false) THEN RAISE EXCEPTION 'Not authorized' USING ERRCODE = 'P0001'; END IF;
  IF b.advance_status <> 'announced' THEN RAISE EXCEPTION 'This advance is not awaiting confirmation.' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO booker FROM portal_users WHERE id = b.portal_user_id;

  v_liability := ensure_equipment_advance_account(v.tenant_id);
  SELECT id INTO v_cash FROM accounts WHERE system = 'marketplace' AND tenant_id = v.tenant_id
    AND code = (CASE WHEN b.advance_method = 'cash' THEN 'MKT-1001' ELSE 'MKT-1002' END);

  INSERT INTO vouchers (system, voucher_type, voucher_date, particular, amount_pkr, from_account_id, to_account_id, party_name)
  VALUES ('marketplace', 'contra', (now() AT TIME ZONE 'Asia/Karachi')::date,
    initcap(b.kind) || ' booking advance held — ' || booker.full_name, b.advance_amount_pkr, v_liability, v_cash, booker.full_name)
  RETURNING id, voucher_no INTO v_voucher_id, v_voucher_no;

  UPDATE equipment_bookings SET advance_status = 'confirmed', advance_confirmed_at = now(), advance_voucher_id = v_voucher_id WHERE id = p_booking_id;

  IF v.portal_user_id IS NOT NULL THEN
    INSERT INTO portal_notifications (portal_user_id, event_type, title, body, link, tenant_id)
    VALUES (v.portal_user_id, 'equipment_advance_confirmed', 'Advance received — job confirmed',
      'Rs ' || round(b.advance_amount_pkr) || ' advance is held for you. You can start the job with the customer''s PIN.', '/portal/my-vehicle/equipment', v.tenant_id);
  END IF;
  INSERT INTO portal_notifications (portal_user_id, event_type, title, body, link, tenant_id)
  VALUES (b.portal_user_id, 'equipment_advance_confirmed', 'Advance confirmed', 'Your booking is confirmed.', '/portal/marketplace/trips', v.tenant_id);

  RETURN jsonb_build_object('voucher_no', v_voucher_no, 'amount', b.advance_amount_pkr);
END;
$$;
REVOKE ALL ON FUNCTION confirm_equipment_advance(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION confirm_equipment_advance(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION reject_equipment_advance(p_booking_id uuid, p_reason text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE b equipment_bookings%ROWTYPE; v vehicles%ROWTYPE;
BEGIN
  SELECT * INTO b FROM equipment_bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Booking not found.' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO v FROM vehicles WHERE id = b.vehicle_id;
  IF NOT COALESCE(current_admin_permission('post_transactions') AND v.tenant_id = my_tenant_id(), false) THEN RAISE EXCEPTION 'Not authorized' USING ERRCODE = 'P0001'; END IF;
  IF b.advance_status <> 'announced' THEN RAISE EXCEPTION 'This advance is not awaiting confirmation.' USING ERRCODE = 'P0001'; END IF;
  UPDATE equipment_bookings SET advance_status = 'rejected', advance_rejected_reason = NULLIF(trim(coalesce(p_reason, '')), '') WHERE id = p_booking_id;
  INSERT INTO portal_notifications (portal_user_id, event_type, title, body, link, tenant_id)
  VALUES (b.portal_user_id, 'equipment_advance_rejected', 'Advance not accepted',
    COALESCE(NULLIF(trim(coalesce(p_reason, '')), ''), 'Please check your payment slip and send it again.'), '/portal/marketplace/trips', v.tenant_id);
END;
$$;
REVOKE ALL ON FUNCTION reject_equipment_advance(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION reject_equipment_advance(uuid, text) TO authenticated;

CREATE OR REPLACE FUNCTION refund_equipment_advance(p_booking_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE b equipment_bookings%ROWTYPE; v vehicles%ROWTYPE; booker portal_users%ROWTYPE;
  v_liability uuid; v_cash uuid; v_voucher_id uuid; v_voucher_no varchar;
BEGIN
  SELECT * INTO b FROM equipment_bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Booking not found.' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO v FROM vehicles WHERE id = b.vehicle_id;
  IF NOT COALESCE(current_admin_permission('post_transactions') AND v.tenant_id = my_tenant_id(), false) THEN RAISE EXCEPTION 'Not authorized' USING ERRCODE = 'P0001'; END IF;
  IF b.advance_status <> 'refund_due' THEN RAISE EXCEPTION 'This advance is not awaiting a refund.' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO booker FROM portal_users WHERE id = b.portal_user_id;
  v_liability := ensure_equipment_advance_account(v.tenant_id);
  SELECT id INTO v_cash FROM accounts WHERE system = 'marketplace' AND tenant_id = v.tenant_id
    AND code = (CASE WHEN b.advance_method = 'cash' THEN 'MKT-1001' ELSE 'MKT-1002' END);

  INSERT INTO vouchers (system, voucher_type, voucher_date, particular, amount_pkr, from_account_id, to_account_id, party_name)
  VALUES ('marketplace', 'contra', (now() AT TIME ZONE 'Asia/Karachi')::date,
    initcap(b.kind) || ' booking advance refunded — ' || booker.full_name, b.advance_amount_pkr, v_cash, v_liability, booker.full_name)
  RETURNING id, voucher_no INTO v_voucher_id, v_voucher_no;

  UPDATE equipment_bookings SET advance_status = 'refunded', advance_refund_voucher_id = v_voucher_id WHERE id = p_booking_id;
  INSERT INTO portal_notifications (portal_user_id, event_type, title, body, link, tenant_id)
  VALUES (b.portal_user_id, 'equipment_advance_refunded', 'Advance refunded', 'Rs ' || round(b.advance_amount_pkr) || ' has been refunded to you.', '/portal/marketplace/trips', v.tenant_id);
  RETURN jsonb_build_object('voucher_no', v_voucher_no, 'amount', b.advance_amount_pkr);
END;
$$;
REVOKE ALL ON FUNCTION refund_equipment_advance(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION refund_equipment_advance(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION admin_equipment_advances() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT COALESCE(current_admin_permission('post_transactions'), false) THEN RAISE EXCEPTION 'Not authorized' USING ERRCODE = 'P0001'; END IF;
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'id', b.id, 'kind', b.kind, 'status', b.status, 'site_address', b.site_address, 'scheduled_date', b.scheduled_date,
      'advance_status', b.advance_status, 'advance_amount_pkr', b.advance_amount_pkr, 'advance_pct', b.advance_pct,
      'advance_method', b.advance_method, 'advance_proof_url', b.advance_proof_url, 'advance_announced_at', b.advance_announced_at,
      'advance_rejected_reason', b.advance_rejected_reason, 'estimate_pkr', b.advance_amount_pkr * 100 / NULLIF(b.advance_pct, 0),
      'customer_name', pu.full_name, 'customer_mobile', pu.mobile, 'owner_name', v.owner_name, 'vehicle_type', v.vehicle_type, 'model', v.model
    ) ORDER BY (b.advance_status IN ('announced', 'refund_due')) DESC, b.advance_announced_at DESC NULLS LAST, b.requested_at DESC)
    FROM equipment_bookings b JOIN vehicles v ON v.id = b.vehicle_id JOIN portal_users pu ON pu.id = b.portal_user_id
    WHERE v.tenant_id = my_tenant_id() AND b.advance_status IN ('announced', 'refund_due', 'rejected', 'confirmed', 'released', 'refunded')
      AND (b.advance_status IN ('announced', 'refund_due') OR b.requested_at > now() - interval '60 days')
  ), '[]'::jsonb);
END;
$$;
REVOKE ALL ON FUNCTION admin_equipment_advances() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION admin_equipment_advances() TO authenticated;

CREATE OR REPLACE FUNCTION public.start_equipment_job(p_booking_id uuid, p_pin character varying)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE b equipment_bookings%ROWTYPE; v vehicles%ROWTYPE;
BEGIN
  SELECT * INTO b FROM equipment_bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Booking not found.' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO v FROM vehicles WHERE id = b.vehicle_id;
  IF NOT (COALESCE(current_admin_permission('manage_parties'), false) OR v.portal_user_id = current_portal_user_id()) THEN
    RAISE EXCEPTION 'You do not manage this vehicle.' USING ERRCODE = 'P0001';
  END IF;
  IF b.status <> 'accepted' THEN RAISE EXCEPTION 'This booking is not ready to start.' USING ERRCODE = 'P0001'; END IF;
  IF b.advance_status NOT IN ('none', 'confirmed') THEN
    RAISE EXCEPTION 'The customer''s advance has not been confirmed by the committee yet.' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM equipment_bookings other WHERE other.vehicle_id = b.vehicle_id AND other.id <> b.id AND other.status = 'in_progress') THEN
    RAISE EXCEPTION 'This vehicle is already on another job — complete that one first.' USING ERRCODE = 'P0001';
  END IF;
  IF b.pin IS NOT NULL AND trim(COALESCE(p_pin, '')) <> b.pin THEN
    RAISE EXCEPTION 'Incorrect PIN — ask the customer for the 4-digit code shown in their app.' USING ERRCODE = 'P0001';
  END IF;
  UPDATE equipment_bookings SET status = 'in_progress', started_at = now() WHERE id = p_booking_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.complete_equipment_job(p_booking_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE b equipment_bookings%ROWTYPE; v vehicles%ROWTYPE; v_hours numeric; v_total numeric;
BEGIN
  SELECT * INTO b FROM equipment_bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Booking not found.' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO v FROM vehicles WHERE id = b.vehicle_id;
  IF NOT (COALESCE(current_admin_permission('manage_parties'), false) OR v.portal_user_id = current_portal_user_id()) THEN
    RAISE EXCEPTION 'You do not manage this vehicle.' USING ERRCODE = 'P0001';
  END IF;
  IF b.status <> 'in_progress' THEN RAISE EXCEPTION 'This job is not in progress.' USING ERRCODE = 'P0001'; END IF;

  v_hours := GREATEST(COALESCE(b.requested_hours, 0), 1);
  v_total := CASE WHEN b.kind = 'loader' THEN b.rate_pkr * GREATEST(COALESCE(b.trip_count, 1), 1) ELSE b.rate_pkr * v_hours + COALESCE(b.mobilization_fee_pkr, 0) END
    + COALESCE(b.travel_charge_pkr, 0);

  UPDATE equipment_bookings SET status = 'completed', ended_at = now(), actual_hours = v_hours, total_amount_pkr = v_total WHERE id = p_booking_id;
  PERFORM close_booking_thread('equipment_booking', p_booking_id, 'agreed');

  RETURN jsonb_build_object('total_amount_pkr', v_total,
    'advance_pkr', CASE WHEN b.advance_status = 'confirmed' THEN b.advance_amount_pkr ELSE 0 END,
    'collect_pkr', v_total - CASE WHEN b.advance_status = 'confirmed' THEN b.advance_amount_pkr ELSE 0 END);
END;
$function$;

-- Settlement (774's tenant-safe version) + releases a confirmed advance
-- from MKT-5005 into the vehicle's wallet, since the driver only
-- collected the remainder in cash.
CREATE OR REPLACE FUNCTION public.confirm_equipment_booking(p_booking_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  b equipment_bookings%ROWTYPE; v vehicles%ROWTYPE;
  v_vehicle_account uuid; v_cash_account uuid; v_commission_account uuid;
  v_commission_pct decimal; v_commission_amount decimal;
  v_gross_voucher_id uuid; v_gross_voucher_no varchar; v_commission_voucher_id uuid;
  v_is_keeper boolean; v_is_admin boolean; v_release_voucher_id uuid;
BEGIN
  SELECT * INTO b FROM equipment_bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Booking not found.' USING ERRCODE = 'P0001'; END IF;
  IF b.status <> 'completed' THEN RAISE EXCEPTION 'This job has not been completed yet.' USING ERRCODE = 'P0001'; END IF;
  IF b.status_confirmed THEN RAISE EXCEPTION 'This booking has already been settled.' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO v FROM vehicles WHERE id = b.vehicle_id;

  v_is_keeper := COALESCE(v.portal_user_id = current_portal_user_id() AND v.commission_mode = 'per_order', false);
  v_is_admin := COALESCE(current_admin_permission('post_transactions') AND v.tenant_id = my_tenant_id(), false);
  IF NOT (v_is_admin OR v_is_keeper) THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE = 'P0001';
  END IF;

  v_vehicle_account := ensure_vehicle_account(v.id);
  SELECT id INTO v_commission_account FROM accounts WHERE system = 'marketplace' AND code = 'MKT-4050' AND tenant_id = v.tenant_id;

  IF b.advance_status = 'confirmed' AND b.advance_amount_pkr > 0 THEN
    INSERT INTO vouchers (system, voucher_type, voucher_date, particular, amount_pkr, from_account_id, to_account_id, party_name)
    VALUES ('marketplace', 'contra', (now() AT TIME ZONE 'Asia/Karachi')::date,
      initcap(b.kind) || ' booking advance released — ' || v.owner_name, b.advance_amount_pkr, v_vehicle_account, ensure_equipment_advance_account(v.tenant_id), v.owner_name)
    RETURNING id INTO v_release_voucher_id;
    UPDATE equipment_bookings SET advance_status = 'released', advance_release_voucher_id = v_release_voucher_id WHERE id = p_booking_id;
  END IF;

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
    RETURN jsonb_build_object('amount', b.total_amount_pkr, 'commission', v_commission_amount,
      'advance_released', CASE WHEN v_release_voucher_id IS NOT NULL THEN b.advance_amount_pkr ELSE 0 END);
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
  RETURN jsonb_build_object('voucher_no', v_gross_voucher_no, 'amount', b.total_amount_pkr,
    'advance_released', CASE WHEN v_release_voucher_id IS NOT NULL THEN b.advance_amount_pkr ELSE 0 END);
END;
$function$;

CREATE OR REPLACE FUNCTION public.my_equipment_bookings()
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', b.id, 'kind', b.kind, 'service_key', b.service_key, 'site_address', b.site_address, 'site_lat', b.site_lat, 'site_lng', b.site_lng, 'material', b.material,
    'requested_hours', b.requested_hours, 'status', b.status, 'decline_reason', b.decline_reason, 'rate_pkr', b.rate_pkr, 'mobilization_fee_pkr', b.mobilization_fee_pkr, 'pin', b.pin,
    'actual_hours', b.actual_hours, 'total_amount_pkr', b.total_amount_pkr,
    'notes', b.notes, 'payment_method', b.payment_method,
    'pickup_address', b.pickup_address, 'pickup_lat', b.pickup_lat, 'pickup_lng', b.pickup_lng, 'trip_count', b.trip_count,
    'scheduled_date', b.scheduled_date, 'scheduled_time', b.scheduled_time,
    'requested_at', b.requested_at, 'started_at', b.started_at, 'ended_at', b.ended_at,
    'vehicle_id', b.vehicle_id, 'owner_name', v.owner_name, 'owner_mobile', v.owner_mobile, 'vehicle_type', v.vehicle_type, 'model', v.model, 'color', v.color
  ) || jsonb_build_object(
    'road_km', b.road_km, 'travel_km', b.travel_km, 'travel_charge_pkr', b.travel_charge_pkr,
    'advance_pct', b.advance_pct, 'advance_amount_pkr', b.advance_amount_pkr, 'advance_status', b.advance_status,
    'advance_rejected_reason', b.advance_rejected_reason
  ) ORDER BY b.requested_at DESC), '[]'::jsonb)
  FROM equipment_bookings b JOIN vehicles v ON v.id = b.vehicle_id
  WHERE b.portal_user_id = current_portal_user_id();
$function$;

CREATE OR REPLACE FUNCTION public.vehicle_equipment_bookings(p_vehicle_id uuid)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_result jsonb;
BEGIN
  IF NOT (COALESCE(current_admin_permission('manage_parties'), false) OR EXISTS (SELECT 1 FROM vehicles v WHERE v.id = p_vehicle_id AND v.portal_user_id = current_portal_user_id())) THEN
    RAISE EXCEPTION 'You do not manage this vehicle.' USING ERRCODE = 'P0001';
  END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', b.id, 'kind', b.kind, 'service_key', b.service_key, 'site_address', b.site_address, 'site_lat', b.site_lat, 'site_lng', b.site_lng, 'material', b.material,
    'requested_hours', b.requested_hours, 'status', b.status, 'decline_reason', b.decline_reason, 'rate_pkr', b.rate_pkr, 'mobilization_fee_pkr', b.mobilization_fee_pkr,
    'actual_hours', b.actual_hours, 'total_amount_pkr', b.total_amount_pkr, 'status_confirmed', b.status_confirmed,
    'notes', b.notes, 'payment_method', b.payment_method,
    'pickup_address', b.pickup_address, 'pickup_lat', b.pickup_lat, 'pickup_lng', b.pickup_lng, 'trip_count', b.trip_count,
    'scheduled_date', b.scheduled_date, 'scheduled_time', b.scheduled_time,
    'requested_at', b.requested_at, 'started_at', b.started_at, 'ended_at', b.ended_at,
    'customer_portal_user_id', pu.id, 'customer_name', pu.full_name, 'customer_mobile', pu.mobile
  ) || jsonb_build_object(
    'road_km', b.road_km, 'travel_km', b.travel_km, 'travel_charge_pkr', b.travel_charge_pkr,
    'advance_pct', b.advance_pct, 'advance_amount_pkr', b.advance_amount_pkr, 'advance_status', b.advance_status
  ) ORDER BY b.requested_at DESC), '[]'::jsonb) INTO v_result
  FROM equipment_bookings b JOIN portal_users pu ON pu.id = b.portal_user_id
  WHERE b.vehicle_id = p_vehicle_id;
  RETURN v_result;
END;
$function$;

-- ─── 4. Shadi: travel per vehicle, server distance, max distance ──────

ALTER TABLE shadi_vehicle_requests ADD COLUMN IF NOT EXISTS road_km numeric;
ALTER TABLE shadi_vehicle_requests ADD COLUMN IF NOT EXISTS travel_km numeric NOT NULL DEFAULT 0;
ALTER TABLE shadi_vehicle_requests ADD COLUMN IF NOT EXISTS travel_charge_pkr numeric NOT NULL DEFAULT 0;
ALTER TABLE shadi_vehicle_requests ADD COLUMN IF NOT EXISTS commission_voucher_id uuid REFERENCES vouchers(id);
ALTER TABLE shadi_vehicle_requests ADD COLUMN IF NOT EXISTS commission_pkr numeric;

-- The by-type flow prices on the event's distance: compute it from the
-- venue pin (home city -> venue) instead of trusting a typed number,
-- and refuse venues beyond the shadi limit.
CREATE OR REPLACE FUNCTION trg_shadi_event_distance() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE h record; q jsonb; v_tenant uuid;
BEGIN
  v_tenant := COALESCE(NEW.tenant_id, my_tenant_id());
  SELECT * INTO h FROM tenant_home_point(v_tenant);
  q := fare_travel_between('shadi', v_tenant, h.lat, h.lng, NEW.venue_lat, NEW.venue_lng);
  IF (q->>'known')::boolean THEN
    IF (q->>'too_far')::boolean THEN PERFORM fare_too_far_error((q->>'road_km')::numeric, (q->>'max_distance_km')::numeric); END IF;
    NEW.distance_km := (q->>'road_km')::numeric;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS shadi_event_distance ON shadi_events;
CREATE TRIGGER shadi_event_distance BEFORE INSERT ON shadi_events FOR EACH ROW EXECUTE FUNCTION trg_shadi_event_distance();

-- A hand-picked vehicle's day price = its full-day rate + travel from
-- its own base to the venue beyond the free radius (there and back).
-- Fleet 'open' slots (no vehicle yet) are priced by their class instead.
CREATE OR REPLACE FUNCTION trg_shadi_request_travel() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE e shadi_events%ROWTYPE; v vehicles%ROWTYPE; q jsonb; pol service_fare_policies; v_road numeric; v_travel numeric;
BEGIN
  IF NEW.vehicle_id IS NULL OR NEW.status = 'open' THEN RETURN NEW; END IF;
  SELECT * INTO e FROM shadi_events WHERE id = NEW.event_id;
  SELECT * INTO v FROM vehicles WHERE id = NEW.vehicle_id;
  q := fare_travel_quote('shadi', NEW.vehicle_id, e.venue_lat, e.venue_lng);
  IF (q->>'known')::boolean THEN
    IF (q->>'too_far')::boolean THEN PERFORM fare_too_far_error((q->>'road_km')::numeric, (q->>'max_distance_km')::numeric); END IF;
    NEW.road_km := (q->>'road_km')::numeric;
    NEW.travel_km := (q->>'travel_km')::numeric;
    NEW.travel_charge_pkr := (q->>'travel_charge_pkr')::numeric;
  ELSIF e.distance_km IS NOT NULL THEN
    -- No pin to measure from: fall back to the event's distance.
    pol := fare_policy(v.tenant_id, 'shadi');
    v_road := e.distance_km;
    IF pol.max_distance_km IS NOT NULL AND v_road > pol.max_distance_km THEN PERFORM fare_too_far_error(v_road, pol.max_distance_km); END IF;
    v_travel := greatest(0, v_road - pol.free_radius_km);
    NEW.road_km := v_road;
    NEW.travel_km := v_travel;
    NEW.travel_charge_pkr := round(v_travel * 2 * pol.travel_rate_per_km_pkr);
  END IF;
  NEW.full_day_rate_pkr := NEW.full_day_rate_pkr + NEW.travel_charge_pkr;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS shadi_request_travel ON shadi_vehicle_requests;
CREATE TRIGGER shadi_request_travel BEFORE INSERT ON shadi_vehicle_requests FOR EACH ROW EXECUTE FUNCTION trg_shadi_request_travel();

-- By-type flow: price on the distance the event trigger measured.
CREATE OR REPLACE FUNCTION public.create_shadi_fleet_event(p_event_date date, p_venue_address text, p_distance_km numeric, p_notes text, p_fleet jsonb, p_venue_lat numeric DEFAULT NULL::numeric, p_venue_lng numeric DEFAULT NULL::numeric)
 RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_portal_user_id uuid := current_portal_user_id();
  v_event_id uuid;
  v_distance numeric;
  v_item jsonb;
  v_class shadi_vehicle_classes%ROWTYPE;
  v_qty int;
  v_price decimal;
  v_i int;
  v_total_qty int := 0;
BEGIN
  IF v_portal_user_id IS NULL THEN RAISE EXCEPTION 'Sign in first.' USING ERRCODE = 'P0001'; END IF;
  IF p_event_date IS NULL OR p_event_date < (now() AT TIME ZONE 'Asia/Karachi')::date THEN
    RAISE EXCEPTION 'Pick a wedding date that has not already passed.' USING ERRCODE = 'P0001';
  END IF;
  IF p_venue_address IS NULL OR trim(p_venue_address) = '' THEN RAISE EXCEPTION 'Enter the venue address.' USING ERRCODE = 'P0001'; END IF;
  IF p_distance_km IS NULL OR p_distance_km < 0 THEN RAISE EXCEPTION 'Enter the approximate distance.' USING ERRCODE = 'P0001'; END IF;
  IF p_fleet IS NULL OR jsonb_array_length(p_fleet) = 0 THEN RAISE EXCEPTION 'Choose at least one vehicle.' USING ERRCODE = 'P0001'; END IF;

  INSERT INTO shadi_events (portal_user_id, event_date, venue_address, venue_lat, venue_lng, distance_km, notes)
  VALUES (v_portal_user_id, p_event_date, trim(p_venue_address), p_venue_lat, p_venue_lng, p_distance_km, NULLIF(trim(p_notes), ''))
  RETURNING id, distance_km INTO v_event_id, v_distance;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_fleet) LOOP
    SELECT * INTO v_class FROM shadi_vehicle_classes WHERE class_key = (v_item->>'class_key') AND is_active;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown vehicle type.' USING ERRCODE = 'P0001'; END IF;
    v_qty := COALESCE((v_item->>'qty')::int, 0);
    IF v_qty <= 0 THEN CONTINUE; END IF;
    v_total_qty := v_total_qty + v_qty;
    v_price := v_class.full_day_rate_pkr + round(greatest(0, v_distance - v_class.free_km) * v_class.per_extra_km_pkr, 2);
    FOR v_i IN 1..v_qty LOOP
      INSERT INTO shadi_vehicle_requests (event_id, class_key, full_day_rate_pkr, status) VALUES (v_event_id, v_class.class_key, v_price, 'open');
    END LOOP;
  END LOOP;

  IF v_total_qty = 0 THEN RAISE EXCEPTION 'Choose at least one vehicle.' USING ERRCODE = 'P0001'; END IF;

  RETURN v_event_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.announce_shadi_advance(p_event_id uuid, p_method character varying, p_proof_url text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE e shadi_events%ROWTYPE; v_accepted_count int; v_pct decimal; v_amount decimal;
BEGIN
  SELECT * INTO e FROM shadi_events WHERE id = p_event_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Event not found.' USING ERRCODE = 'P0001'; END IF;
  IF e.portal_user_id <> current_portal_user_id() THEN RAISE EXCEPTION 'This is not your booking.' USING ERRCODE = 'P0001'; END IF;
  IF e.status <> 'collecting' THEN RAISE EXCEPTION 'This booking is not awaiting an advance.' USING ERRCODE = 'P0001'; END IF;
  IF p_proof_url IS NULL OR trim(p_proof_url) = '' THEN RAISE EXCEPTION 'Upload your payment slip.' USING ERRCODE = 'P0001'; END IF;

  SELECT count(*) INTO v_accepted_count FROM shadi_vehicle_requests WHERE event_id = p_event_id AND status = 'accepted';
  IF v_accepted_count = 0 THEN RAISE EXCEPTION 'At least one vehicle must accept before you can pay the advance.' USING ERRCODE = 'P0001'; END IF;

  -- The committee's shadi policy; the old setting only as a fallback.
  v_pct := COALESCE(
    (SELECT advance_pct FROM service_fare_policies WHERE tenant_id = e.tenant_id AND service_key = 'shadi'),
    (SELECT value::decimal FROM site_settings WHERE key = 'marketplace_shadi_advance_pct' AND tenant_id = e.tenant_id),
    (fare_policy_default('shadi')).advance_pct);
  SELECT round(sum(full_day_rate_pkr) * v_pct / 100, 2) INTO v_amount FROM shadi_vehicle_requests WHERE event_id = p_event_id AND status = 'accepted';

  UPDATE shadi_events SET status = 'advance_announced', advance_pct = v_pct, advance_amount_pkr = v_amount,
    advance_method = p_method, advance_proof_url = p_proof_url, advance_announced_at = now(), advance_rejected_reason = NULL
  WHERE id = p_event_id;

  RETURN jsonb_build_object('amount', v_amount, 'pct', v_pct);
END;
$function$;

-- Release each vehicle's advance after the wedding date (unchanged) and
-- now also charge per_order vehicles the committee's commission on the
-- full day rate — weddings are no longer commission-free.
CREATE OR REPLACE FUNCTION public.sweep_due_shadi_advances()
 RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  r RECORD; v_count int := 0; v_liability_account uuid; v_vehicle_account uuid; v_voucher_id uuid;
  v_commission_account uuid; v_commission_pct decimal; v_commission_amount decimal; v_commission_voucher_id uuid;
BEGIN
  FOR r IN
    SELECT sr.id AS request_id, sr.vehicle_id, sr.advance_share_pkr, sr.full_day_rate_pkr, se.event_date,
      v.owner_name, v.portal_user_id, v.tenant_id, v.commission_mode, v.category_id
    FROM shadi_vehicle_requests sr
    JOIN shadi_events se ON se.id = sr.event_id
    JOIN vehicles v ON v.id = sr.vehicle_id
    WHERE sr.status = 'accepted' AND se.status = 'confirmed' AND se.event_date < (now() AT TIME ZONE 'Asia/Karachi')::date
      AND sr.payout_voucher_id IS NULL AND sr.advance_share_pkr IS NOT NULL AND sr.advance_share_pkr > 0
    FOR UPDATE OF sr SKIP LOCKED
  LOOP
    SELECT id INTO v_liability_account FROM accounts WHERE system = 'marketplace' AND code = 'MKT-5004' AND tenant_id = r.tenant_id;
    v_vehicle_account := ensure_vehicle_account(r.vehicle_id);

    INSERT INTO vouchers (system, voucher_type, voucher_date, particular, amount_pkr, from_account_id, to_account_id, party_name)
    VALUES ('marketplace', 'contra', (now() AT TIME ZONE 'Asia/Karachi')::date,
      'Shadi advance released — ' || r.owner_name || ' (' || to_char(r.event_date, 'DD Mon YYYY') || ')', r.advance_share_pkr, v_vehicle_account, v_liability_account, r.owner_name)
    RETURNING id INTO v_voucher_id;

    v_commission_amount := NULL; v_commission_voucher_id := NULL;
    IF r.commission_mode = 'per_order' THEN
      v_commission_pct := CASE WHEN r.category_id IS NOT NULL
        THEN vehicle_category_commission_pct(r.category_id, 'intercity')
        ELSE COALESCE((SELECT value::decimal FROM site_settings WHERE key = 'marketplace_shadi_commission_pct' AND tenant_id = r.tenant_id), 0) END;
      v_commission_amount := round(r.full_day_rate_pkr * COALESCE(v_commission_pct, 0) / 100, 2);
      IF v_commission_amount > 0 THEN
        SELECT id INTO v_commission_account FROM accounts WHERE system = 'marketplace' AND code = 'MKT-4050' AND tenant_id = r.tenant_id;
        INSERT INTO vouchers (system, voucher_type, voucher_date, particular, amount_pkr, from_account_id, to_account_id, party_name)
        VALUES ('marketplace', 'income', (now() AT TIME ZONE 'Asia/Karachi')::date,
          'Marketplace commission — wedding ' || to_char(r.event_date, 'DD Mon YYYY') || ' (balance paid directly to driver)', v_commission_amount, v_commission_account, v_vehicle_account, r.owner_name)
        RETURNING id INTO v_commission_voucher_id;
      END IF;
    END IF;

    UPDATE shadi_vehicle_requests SET payout_voucher_id = v_voucher_id, paid_out_at = now(),
      commission_voucher_id = v_commission_voucher_id, commission_pkr = v_commission_amount
    WHERE id = r.request_id;
    v_count := v_count + 1;

    IF r.portal_user_id IS NOT NULL THEN
      INSERT INTO portal_notifications (portal_user_id, event_type, title, body, link, tenant_id)
      VALUES (r.portal_user_id, 'shadi_advance_released', 'Advance released',
        'Rs ' || round(r.advance_share_pkr) || ' advance for the ' || to_char(r.event_date, 'DD Mon YYYY') || ' wedding has been released to your account'
          || CASE WHEN COALESCE(v_commission_amount, 0) > 0 THEN ' (commission Rs ' || round(v_commission_amount) || ' charged).' ELSE '.' END,
        '/portal/my-vehicle/shadi', r.tenant_id);
      PERFORM check_seller_balance_notify('vehicle', r.vehicle_id);
    END IF;
  END LOOP;

  RETURN v_count;
END;
$function$;

-- ─── 5. Hourly: pickup within max distance, overtime ──────────────────

ALTER TABLE hourly_bookings ADD COLUMN IF NOT EXISTS overtime_minutes int NOT NULL DEFAULT 0;
ALTER TABLE hourly_bookings ADD COLUMN IF NOT EXISTS overtime_amount_pkr numeric NOT NULL DEFAULT 0;

CREATE OR REPLACE FUNCTION trg_hourly_booking_distance() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE q jsonb;
BEGIN
  q := fare_travel_quote('hourly', NEW.vehicle_id, NEW.pickup_lat, NEW.pickup_lng);
  IF (q->>'too_far')::boolean THEN PERFORM fare_too_far_error((q->>'road_km')::numeric, (q->>'max_distance_km')::numeric); END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS hourly_booking_distance ON hourly_bookings;
CREATE TRIGGER hourly_booking_distance BEFORE INSERT ON hourly_bookings FOR EACH ROW EXECUTE FUNCTION trg_hourly_booking_distance();

CREATE OR REPLACE FUNCTION trg_rental_booking_distance() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE pol service_fare_policies; v_tenant uuid;
BEGIN
  SELECT tenant_id INTO v_tenant FROM vehicles WHERE id = NEW.vehicle_id;
  pol := fare_policy(v_tenant, 'rental');
  IF pol.max_distance_km IS NOT NULL AND NEW.km > pol.max_distance_km THEN PERFORM fare_too_far_error(NEW.km, pol.max_distance_km); END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS rental_booking_distance ON rental_bookings;
CREATE TRIGGER rental_booking_distance BEFORE INSERT ON rental_bookings FOR EACH ROW EXECUTE FUNCTION trg_rental_booking_distance();

CREATE OR REPLACE FUNCTION public.end_hourly_trip(p_booking_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  b hourly_bookings%ROWTYPE; v vehicles%ROWTYPE; pol service_fare_policies;
  v_overage_km decimal; v_overage_amount decimal; v_total decimal;
  v_elapsed_min numeric; v_over_min numeric; v_blocks int; v_overtime_min int; v_overtime_amount decimal;
BEGIN
  SELECT * INTO b FROM hourly_bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Booking not found.' USING ERRCODE = 'P0001'; END IF;
  SELECT * INTO v FROM vehicles WHERE id = b.vehicle_id;
  IF NOT (COALESCE(current_admin_permission('manage_parties'), false) OR v.portal_user_id = current_portal_user_id()) THEN
    RAISE EXCEPTION 'You do not manage this vehicle.' USING ERRCODE = 'P0001';
  END IF;
  IF b.status <> 'in_progress' THEN RAISE EXCEPTION 'This trip is not in progress.' USING ERRCODE = 'P0001'; END IF;

  v_overage_km := greatest(0, b.distance_km - b.included_km);
  v_overage_amount := round(v_overage_km * b.overage_per_km_pkr, 2);

  -- Overtime: past the booked hours plus a grace period, every started
  -- block is billed pro-rata at the committee's overtime rate.
  pol := fare_policy(v.tenant_id, 'hourly');
  v_elapsed_min := extract(epoch FROM (now() - COALESCE(b.started_at, now()))) / 60;
  v_over_min := v_elapsed_min - b.hours * 60 - pol.overtime_grace_minutes;
  IF v_over_min > 0 THEN
    v_blocks := ceil(v_over_min / pol.overtime_block_minutes);
    v_overtime_min := v_blocks * pol.overtime_block_minutes;
    v_overtime_amount := round(b.hourly_rate_pkr * v_overtime_min / 60.0 * pol.overtime_rate_pct / 100);
  ELSE
    v_overtime_min := 0;
    v_overtime_amount := 0;
  END IF;

  v_total := b.base_amount_pkr + v_overage_amount + v_overtime_amount;

  UPDATE hourly_bookings SET status = 'completed', ended_at = now(),
    overage_km = v_overage_km, overage_amount_pkr = v_overage_amount,
    overtime_minutes = v_overtime_min, overtime_amount_pkr = v_overtime_amount, total_amount_pkr = v_total
  WHERE id = p_booking_id;
  PERFORM close_booking_thread('hourly_booking', p_booking_id, 'agreed');

  INSERT INTO portal_notifications (portal_user_id, event_type, title, body, link)
  VALUES (b.portal_user_id, 'hourly_booking_completed', 'Trip completed',
    'Distance: ' || round(b.distance_km, 1) || 'km'
      || CASE WHEN v_overtime_min > 0 THEN ' — Overtime: ' || v_overtime_min || ' min' ELSE '' END
      || ' — Total: Rs ' || round(v_total), '/portal/marketplace');

  RETURN jsonb_build_object('distance_km', b.distance_km, 'overage_km', v_overage_km, 'overage_amount_pkr', v_overage_amount,
    'overtime_minutes', v_overtime_min, 'overtime_amount_pkr', v_overtime_amount, 'total_amount_pkr', v_total);
END;
$function$;

CREATE OR REPLACE FUNCTION public.my_hourly_bookings()
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', b.id, 'hours', b.hours, 'status', b.status, 'pickup_address', b.pickup_address, 'pickup_lat', b.pickup_lat, 'pickup_lng', b.pickup_lng, 'decline_reason', b.decline_reason,
    'base_amount_pkr', b.base_amount_pkr, 'total_amount_pkr', b.total_amount_pkr, 'distance_km', b.distance_km, 'pin', b.pin,
    'notes', b.notes, 'payment_method', b.payment_method,
    'requested_at', b.requested_at, 'started_at', b.started_at, 'ended_at', b.ended_at,
    'vehicle_id', b.vehicle_id, 'owner_name', v.owner_name, 'owner_mobile', v.owner_mobile, 'vehicle_type', v.vehicle_type, 'model', v.model, 'color', v.color
  ) || jsonb_build_object(
    'hourly_rate_pkr', b.hourly_rate_pkr, 'included_km', b.included_km, 'overage_per_km_pkr', b.overage_per_km_pkr,
    'overage_km', b.overage_km, 'overage_amount_pkr', b.overage_amount_pkr,
    'overtime_minutes', b.overtime_minutes, 'overtime_amount_pkr', b.overtime_amount_pkr
  ) ORDER BY b.requested_at DESC), '[]'::jsonb)
  FROM hourly_bookings b JOIN vehicles v ON v.id = b.vehicle_id
  WHERE b.portal_user_id = current_portal_user_id();
$function$;

CREATE OR REPLACE FUNCTION public.vehicle_hourly_bookings(p_vehicle_id uuid)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_result jsonb;
BEGIN
  IF NOT (COALESCE(current_admin_permission('manage_parties'), false) OR EXISTS (SELECT 1 FROM vehicles v WHERE v.id = p_vehicle_id AND v.portal_user_id = current_portal_user_id())) THEN
    RAISE EXCEPTION 'You do not manage this vehicle.' USING ERRCODE = 'P0001';
  END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', b.id, 'hours', b.hours, 'status', b.status, 'pickup_address', b.pickup_address, 'pickup_lat', b.pickup_lat, 'pickup_lng', b.pickup_lng, 'decline_reason', b.decline_reason,
    'base_amount_pkr', b.base_amount_pkr, 'total_amount_pkr', b.total_amount_pkr, 'distance_km', b.distance_km,
    'included_km', b.included_km, 'overage_km', b.overage_km, 'overage_amount_pkr', b.overage_amount_pkr,
    'notes', b.notes, 'payment_method', b.payment_method,
    'requested_at', b.requested_at, 'started_at', b.started_at, 'ended_at', b.ended_at, 'status_confirmed', b.status_confirmed,
    'customer_portal_user_id', pu.id, 'customer_name', pu.full_name, 'customer_mobile', pu.mobile, 'customer_trust', portal_user_trust(pu.id)
  ) || jsonb_build_object(
    'hourly_rate_pkr', b.hourly_rate_pkr, 'overage_per_km_pkr', b.overage_per_km_pkr,
    'overtime_minutes', b.overtime_minutes, 'overtime_amount_pkr', b.overtime_amount_pkr
  ) ORDER BY b.requested_at DESC), '[]'::jsonb) INTO v_result
  FROM hourly_bookings b JOIN portal_users pu ON pu.id = b.portal_user_id
  WHERE b.vehicle_id = p_vehicle_id;
  RETURN v_result;
END;
$function$;
