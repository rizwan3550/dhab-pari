-- Migration 777: City Purchase — one-way "carry back" pricing for drivers
-- already in / heading to the city, a delivery window, an urgency premium
-- that compensates an early return, round-trip detour fuel only when the
-- shop is off the driver's route, a two-stage deal confirmation, and
-- saved requests that ring the next driver who goes to that city.
--
-- Real ask, 2026-10-30: "currently the fare is calculated two way — when
-- the driver is already in the city the calculation should be one way;
-- he can wait there, collect as many requests as he can and carry them
-- home, within a maximum of 3-4 hours at the normal fee. If the rider
-- wants urgent delivery he offers more money to convince the driver to
-- come back early... both users should remain happy... for the two-way
-- ride nothing changes (the rider knowingly sends a driver from the
-- village)... a saved/scheduled request is sent to a driver whenever he
-- goes to that city... if the shop is on his route a fixed fee with no
-- fuel, if far from it the fuel is driver destination -> shop -> back to
-- driver destination... both parties must confirm in two stages."
--
-- Pricing (computed at accept, by the server, per accepting vehicle):
--   leg            = round_to_10(city.distance_km * vehicle.per_km_pkr)
--   trip_mode      = 'carry_back' when the invitation came from the
--                    driver's own route / trip offer / city check-in
--                    (he is going home anyway), else 'dedicated'
--   distance_fare  = carry_back: 1 x leg      dedicated: 2 x leg (unchanged)
--   urgency_premium= carry_back only: leg x setting % (2hr 25 / 1hr 50 /
--                    urgent 75) — pays the driver for cutting his city
--                    stay short and losing the other carries he'd have
--                    collected; a dedicated trip already gets both legs
--   detour_fuel    = distance from the driver's own destination in the
--                    city (his route / trip offer pin, else the city's
--                    reference point) to the shop; within
--                    city_purchase_detour_free_km it is "on his route" =
--                    0, otherwise round_to_10(km x 2 x per_km) — there
--                    and back to his destination (was one-way)
--   total          = distance_fare + urgency_premium + detour_fuel +
--                    driver's service fee (committee band) + rider tip
--
-- Delivery window (deliver_by, set when the deal is locked): standard =
-- city_purchase_carry_max_hours (4), 2hr = 2h, 1hr / urgent = 1h.
--
-- Two-stage confirmation: (1) the driver accepts with his fee -> the
-- rider reviews the full breakdown and approves (approve_city_purchase_
-- price, unchanged); (2) the driver locks the deal
-- (confirm_city_purchase_deal) — only then can he mark it purchased.
--
-- Saved requests: a request nobody could take ('no_answer') is kept, and
-- rings any vehicle that later checks in to that city or opens a trip
-- offer to it (AFTER INSERT triggers), using the same candidate rules
-- (online, delivery-eligible, trust floor, urgency tier).
--
-- Dry-run on a local replay inside BEGIN ... ROLLBACK; not applied to
-- production by the author.

-- ─── Columns + settings ────────────────────────────────────────────────

ALTER TABLE city_purchase_requests ADD COLUMN IF NOT EXISTS trip_mode varchar CHECK (trip_mode IS NULL OR trip_mode IN ('carry_back', 'dedicated'));
ALTER TABLE city_purchase_requests ADD COLUMN IF NOT EXISTS urgency_premium_pkr numeric NOT NULL DEFAULT 0;
ALTER TABLE city_purchase_requests ADD COLUMN IF NOT EXISTS detour_km numeric;
ALTER TABLE city_purchase_requests ADD COLUMN IF NOT EXISTS driver_confirmed_at timestamptz;
ALTER TABLE city_purchase_requests ADD COLUMN IF NOT EXISTS deliver_by timestamptz;
ALTER TABLE city_purchase_invitations ADD COLUMN IF NOT EXISTS reference_distance_km numeric;

INSERT INTO site_settings (key, value, description, tenant_id)
SELECT s.key, s.value, s.description, t.id
FROM tenants t CROSS JOIN (VALUES
  ('city_purchase_carry_max_hours', '4', 'City purchase: hours a carry-back driver has to deliver at the normal fee'),
  ('city_purchase_urgency_premium_pct_2hr', '25', 'City purchase: % of one leg added for a 2-hour carry-back (early return)'),
  ('city_purchase_urgency_premium_pct_1hr', '50', 'City purchase: % of one leg added for a 1-hour carry-back (early return)'),
  ('city_purchase_urgency_premium_pct_urgent', '75', 'City purchase: % of one leg added for an urgent carry-back (early return)')
) AS s(key, value, description)
WHERE NOT EXISTS (SELECT 1 FROM site_settings x WHERE x.key = s.key AND x.tenant_id = t.id);

CREATE OR REPLACE FUNCTION city_purchase_setting(p_tenant_id uuid, p_key varchar, p_default numeric) RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE(
    (SELECT value::numeric FROM site_settings WHERE key = p_key AND tenant_id = p_tenant_id),
    (SELECT value::numeric FROM site_settings WHERE key = p_key ORDER BY (tenant_id IS NULL) DESC LIMIT 1),
    p_default);
$$;

-- ─── Where the invited driver is actually headed in the city ───────────
-- Distance from the shop to the driver's own destination (route / trip
-- offer pin) — the "is it on his way" measure. NULL when either side has
-- no pin; pricing then falls back to the city's reference point.
CREATE OR REPLACE FUNCTION trg_city_purchase_invitation_distance() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r city_purchase_requests%ROWTYPE; ci cities%ROWTYPE; v_lat numeric; v_lng numeric;
BEGIN
  SELECT * INTO r FROM city_purchase_requests WHERE id = NEW.request_id;
  IF r.pickup_lat IS NULL OR r.pickup_lng IS NULL THEN RETURN NEW; END IF;
  SELECT * INTO ci FROM cities WHERE id = r.city_id;
  IF NEW.source = 'route' THEN
    SELECT vr.destination_lat, vr.destination_lng INTO v_lat, v_lng FROM vehicle_routes vr
    WHERE vr.vehicle_id = NEW.vehicle_id AND vr.is_active AND vr.destination_lat IS NOT NULL
      AND (vr.destination ILIKE '%' || ci.name || '%' OR (ci.name_ur IS NOT NULL AND vr.destination_ur ILIKE '%' || ci.name_ur || '%'))
    LIMIT 1;
  ELSIF NEW.source = 'trip_offer' THEN
    SELECT o.dest_lat, o.dest_lng INTO v_lat, v_lng FROM vehicle_trip_offers o
    WHERE o.vehicle_id = NEW.vehicle_id AND o.status = 'open' AND o.dest_lat IS NOT NULL
      AND (o.destination ILIKE '%' || ci.name || '%' OR (ci.name_ur IS NOT NULL AND o.destination_ur ILIKE '%' || ci.name_ur || '%'))
    ORDER BY o.travel_date LIMIT 1;
  END IF;
  IF v_lat IS NULL THEN v_lat := ci.lat; v_lng := ci.lng; END IF;
  IF v_lat IS NOT NULL THEN NEW.reference_distance_km := round(haversine_km(r.pickup_lat, r.pickup_lng, v_lat, v_lng), 1); END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS city_purchase_invitation_distance ON city_purchase_invitations;
CREATE TRIGGER city_purchase_invitation_distance BEFORE INSERT ON city_purchase_invitations FOR EACH ROW EXECUTE FUNCTION trg_city_purchase_invitation_distance();

-- ─── The one pricing formula (accept + the driver's preview) ───────────
CREATE OR REPLACE FUNCTION city_purchase_price(p_request_id uuid, p_vehicle_id uuid, p_addon_fee_pkr numeric) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r city_purchase_requests%ROWTYPE; v vehicles%ROWTYPE; ci cities%ROWTYPE; i city_purchase_invitations%ROWTYPE;
  v_mode varchar; v_leg numeric; v_distance numeric; v_premium_pct numeric := 0; v_premium numeric := 0;
  v_detour_km numeric; v_free numeric; v_detour numeric := 0; v_tenant uuid;
BEGIN
  SELECT * INTO r FROM city_purchase_requests WHERE id = p_request_id;
  SELECT * INTO v FROM vehicles WHERE id = p_vehicle_id;
  SELECT * INTO ci FROM cities WHERE id = r.city_id;
  SELECT * INTO i FROM city_purchase_invitations WHERE request_id = p_request_id AND vehicle_id = p_vehicle_id;
  v_tenant := COALESCE(r.tenant_id, v.tenant_id);

  v_mode := CASE WHEN i.source IN ('presence', 'trip_offer', 'route') THEN 'carry_back' ELSE 'dedicated' END;
  v_leg := round_to_10(COALESCE(ci.distance_km, 0) * COALESCE(v.per_km_pkr, 0));
  v_distance := CASE WHEN v_mode = 'carry_back' THEN v_leg ELSE v_leg * 2 END;

  IF v_mode = 'carry_back' AND r.urgency <> 'standard' THEN
    v_premium_pct := city_purchase_setting(v_tenant, 'city_purchase_urgency_premium_pct_' || r.urgency,
      CASE r.urgency WHEN '2hr' THEN 25 WHEN '1hr' THEN 50 ELSE 75 END);
    v_premium := round_to_10(v_leg * v_premium_pct / 100);
  END IF;

  v_detour_km := COALESCE(i.reference_distance_km,
    CASE WHEN r.pickup_lat IS NOT NULL AND ci.lat IS NOT NULL THEN round(haversine_km(r.pickup_lat, r.pickup_lng, ci.lat, ci.lng), 1) END);
  v_free := city_purchase_setting(v_tenant, 'city_purchase_detour_free_km', 2);
  IF v_detour_km IS NOT NULL AND v_detour_km > v_free THEN
    v_detour := round_to_10(v_detour_km * 2 * COALESCE(v.per_km_pkr, 0));
  END IF;

  RETURN jsonb_build_object(
    'trip_mode', v_mode, 'source', i.source, 'reference_destination', i.reference_destination,
    'leg_pkr', v_leg, 'distance_fare_pkr', v_distance,
    'urgency_premium_pct', v_premium_pct, 'urgency_premium_pkr', v_premium,
    'detour_km', v_detour_km, 'detour_free_km', v_free, 'on_route', v_detour_km IS NULL OR v_detour_km <= v_free, 'detour_fuel_pkr', v_detour,
    'addon_fee_pkr', COALESCE(p_addon_fee_pkr, 0), 'tip_pkr', COALESCE(r.tip_pkr, 0),
    'total_fare_pkr', v_distance + v_premium + v_detour + COALESCE(p_addon_fee_pkr, 0) + COALESCE(r.tip_pkr, 0),
    'deliver_within_hours', CASE r.urgency WHEN '2hr' THEN 2 WHEN '1hr' THEN 1 WHEN 'urgent' THEN 1
      ELSE city_purchase_setting(v_tenant, 'city_purchase_carry_max_hours', 4) END,
    'addon_min_pkr', city_purchase_setting(v_tenant, 'city_purchase_addon_min_pkr', 100),
    'addon_max_pkr', city_purchase_setting(v_tenant, 'city_purchase_addon_max_pkr', 1000)
  );
END;
$$;

-- The invited driver's own preview before accepting.
CREATE OR REPLACE FUNCTION city_purchase_quote_for_vehicle(p_request_id uuid, p_vehicle_id uuid, p_addon_fee_pkr numeric DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM vehicles WHERE id = p_vehicle_id AND portal_user_id = current_portal_user_id()) THEN
    RAISE EXCEPTION 'You do not manage this vehicle.' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM city_purchase_invitations WHERE request_id = p_request_id AND vehicle_id = p_vehicle_id) THEN
    RAISE EXCEPTION 'You were not invited to this request.' USING ERRCODE = 'P0001';
  END IF;
  RETURN city_purchase_price(p_request_id, p_vehicle_id, p_addon_fee_pkr);
END;
$$;
REVOKE ALL ON FUNCTION city_purchase_quote_for_vehicle(uuid, uuid, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION city_purchase_quote_for_vehicle(uuid, uuid, numeric) TO authenticated;

CREATE OR REPLACE FUNCTION public.accept_city_purchase_request(p_request_id uuid, p_vehicle_id uuid, p_addon_fee_pkr numeric)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v vehicles%ROWTYPE; r city_purchase_requests%ROWTYPE; q jsonb; v_committed_tier varchar;
BEGIN
  SELECT * INTO v FROM vehicles WHERE id = p_vehicle_id;
  IF NOT FOUND OR v.portal_user_id IS DISTINCT FROM current_portal_user_id() THEN
    RAISE EXCEPTION 'You do not manage this vehicle.' USING ERRCODE = 'P0001';
  END IF;
  IF v.per_km_pkr IS NULL THEN
    RAISE EXCEPTION 'Your per-km rate has not been set yet — ask the committee to set it before accepting jobs.' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO r FROM city_purchase_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Request not found.' USING ERRCODE = 'P0001'; END IF;
  IF r.status <> 'ringing' THEN RAISE EXCEPTION 'This request is no longer open.' USING ERRCODE = 'P0001'; END IF;
  IF r.initiator_portal_user_id = current_portal_user_id() THEN
    RAISE EXCEPTION 'You cannot accept your own request.' USING ERRCODE = 'P0001';
  END IF;

  q := city_purchase_price(p_request_id, p_vehicle_id, p_addon_fee_pkr);
  IF p_addon_fee_pkr IS NULL OR p_addon_fee_pkr < (q->>'addon_min_pkr')::numeric OR p_addon_fee_pkr > (q->>'addon_max_pkr')::numeric THEN
    RAISE EXCEPTION 'Your service fee must be between % and %.', q->>'addon_min_pkr', q->>'addon_max_pkr' USING ERRCODE = 'P0001';
  END IF;

  v_committed_tier := vehicle_committed_urgency_tier(p_vehicle_id);
  IF v_committed_tier IS NOT NULL AND v_committed_tier <> r.urgency THEN
    RAISE EXCEPTION 'You are committed to % deliveries right now — finish those before accepting a different urgency tier.', v_committed_tier USING ERRCODE = 'P0001';
  END IF;

  UPDATE city_purchase_invitations SET status = 'accepted', responded_at = now()
    WHERE request_id = p_request_id AND vehicle_id = p_vehicle_id AND status = 'ringing';
  IF NOT FOUND THEN RAISE EXCEPTION 'You were not invited to this request, or someone else already accepted it.' USING ERRCODE = 'P0001'; END IF;
  UPDATE city_purchase_invitations SET status = 'expired', responded_at = now()
    WHERE request_id = p_request_id AND vehicle_id <> p_vehicle_id AND status = 'ringing';

  UPDATE city_purchase_requests SET
    status = 'priced', accepted_vehicle_id = p_vehicle_id, trip_mode = q->>'trip_mode',
    distance_fare_pkr = (q->>'distance_fare_pkr')::numeric, urgency_premium_pkr = (q->>'urgency_premium_pkr')::numeric,
    detour_km = (q->>'detour_km')::numeric, detour_fuel_pkr = (q->>'detour_fuel_pkr')::numeric,
    addon_fee_pkr = p_addon_fee_pkr, total_fare_pkr = (q->>'total_fare_pkr')::numeric
  WHERE id = p_request_id;

  INSERT INTO portal_notifications (portal_user_id, event_type, title, body, link)
  VALUES (r.initiator_portal_user_id, 'city_purchase_accepted', 'City purchase accepted — please review the price',
    v.owner_name || ' — Rs ' || round((q->>'total_fare_pkr')::numeric) || CASE WHEN q->>'trip_mode' = 'carry_back' THEN ' (carry back, one way)' ELSE ' (special trip, two way)' END,
    '/portal/marketplace/city-purchase/' || p_request_id);

  RETURN city_purchase_request_detail(p_request_id);
END;
$function$;

-- Stage 2: the driver locks the deal after the rider approved the price.
CREATE OR REPLACE FUNCTION confirm_city_purchase_deal(p_request_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r city_purchase_requests%ROWTYPE; v_hours numeric;
BEGIN
  SELECT * INTO r FROM city_purchase_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Request not found.' USING ERRCODE = 'P0001'; END IF;
  IF NOT EXISTS (SELECT 1 FROM vehicles WHERE id = r.accepted_vehicle_id AND portal_user_id = current_portal_user_id()) THEN
    RAISE EXCEPTION 'You do not manage this job.' USING ERRCODE = 'P0001';
  END IF;
  IF r.status <> 'approved' THEN RAISE EXCEPTION 'The customer has not approved the price yet.' USING ERRCODE = 'P0001'; END IF;
  IF r.driver_confirmed_at IS NOT NULL THEN RAISE EXCEPTION 'You have already confirmed this deal.' USING ERRCODE = 'P0001'; END IF;
  v_hours := CASE r.urgency WHEN '2hr' THEN 2 WHEN '1hr' THEN 1 WHEN 'urgent' THEN 1
    ELSE city_purchase_setting(r.tenant_id, 'city_purchase_carry_max_hours', 4) END;
  UPDATE city_purchase_requests SET driver_confirmed_at = now(), deliver_by = now() + make_interval(mins => (v_hours * 60)::int) WHERE id = p_request_id;
  INSERT INTO portal_notifications (portal_user_id, event_type, title, body, link)
  VALUES (r.initiator_portal_user_id, 'city_purchase_deal_confirmed', 'Deal confirmed — your purchase is on the way',
    r.item || ' — delivery within ' || v_hours || ' h', '/portal/marketplace/city-purchase/' || p_request_id);
END;
$$;
REVOKE ALL ON FUNCTION confirm_city_purchase_deal(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION confirm_city_purchase_deal(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.mark_city_purchase_purchased(p_request_id uuid, p_actual_goods_cost_pkr numeric, p_bill_attachment_path text DEFAULT NULL::text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE r city_purchase_requests%ROWTYPE;
BEGIN
  SELECT * INTO r FROM city_purchase_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Request not found.' USING ERRCODE = 'P0001'; END IF;
  IF NOT EXISTS (SELECT 1 FROM vehicles WHERE id = r.accepted_vehicle_id AND portal_user_id = current_portal_user_id()) THEN
    RAISE EXCEPTION 'You do not manage this job.' USING ERRCODE = 'P0001';
  END IF;
  IF r.status <> 'approved' THEN RAISE EXCEPTION 'This job is not awaiting purchase.' USING ERRCODE = 'P0001'; END IF;
  IF r.driver_confirmed_at IS NULL THEN RAISE EXCEPTION 'Confirm the deal first, so both of you have locked the final price.' USING ERRCODE = 'P0001'; END IF;
  IF p_actual_goods_cost_pkr IS NULL OR p_actual_goods_cost_pkr < 0 THEN RAISE EXCEPTION 'Enter what you actually paid for the item.' USING ERRCODE = 'P0001'; END IF;
  UPDATE city_purchase_requests SET status = 'purchased', purchased_at = now(),
    actual_goods_cost_pkr = p_actual_goods_cost_pkr, bill_attachment_path = NULLIF(p_bill_attachment_path, '')
  WHERE id = p_request_id;
  INSERT INTO portal_notifications (portal_user_id, event_type, title, body, link)
  VALUES (r.initiator_portal_user_id, 'city_purchase_purchased', 'Item purchased', r.item, '/portal/marketplace/city-purchase/' || p_request_id);
END;
$function$;

-- ─── Rider's two prices before sending ─────────────────────────────────
CREATE OR REPLACE FUNCTION public.city_purchase_fee_estimate(p_city_id uuid, p_pickup_lat numeric, p_pickup_lng numeric, p_tip_pkr numeric DEFAULT 0, p_ride_type character varying DEFAULT 'bike'::character varying)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  ci cities%ROWTYPE; v_per_km decimal; v_free decimal; v_leg decimal; v_detour_km decimal; v_detour decimal := 0; v_tip decimal;
BEGIN
  SELECT * INTO ci FROM cities WHERE id = p_city_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'That city is not available.' USING ERRCODE = 'P0001'; END IF;
  v_per_km := city_purchase_setting(ci.tenant_id,
    CASE WHEN p_ride_type = 'car' THEN 'city_purchase_typical_per_km_car_pkr' ELSE 'city_purchase_typical_per_km_bike_pkr' END,
    CASE WHEN p_ride_type = 'car' THEN 20 ELSE 12 END);
  v_leg := round_to_10(COALESCE(ci.distance_km, 0) * v_per_km);
  IF p_pickup_lat IS NOT NULL AND p_pickup_lng IS NOT NULL AND ci.lat IS NOT NULL AND ci.lng IS NOT NULL THEN
    v_free := city_purchase_setting(ci.tenant_id, 'city_purchase_detour_free_km', 2);
    v_detour_km := round(haversine_km(p_pickup_lat, p_pickup_lng, ci.lat, ci.lng), 1);
    IF v_detour_km > v_free THEN v_detour := round_to_10(v_detour_km * 2 * v_per_km); END IF;
  END IF;
  v_tip := GREATEST(COALESCE(p_tip_pkr, 0), 0);
  RETURN jsonb_build_object(
    -- unchanged keys: the special-trip (two-way) price, the worst case
    'distance_fare_pkr', v_leg * 2, 'detour_fuel_pkr', v_detour, 'tip_pkr', v_tip,
    'total_fee_pkr', v_leg * 2 + v_detour + v_tip,
    -- new: what a driver already there / going there charges
    'leg_pkr', v_leg, 'carry_total_fee_pkr', v_leg + v_detour + v_tip,
    'detour_km', v_detour_km,
    'carry_max_hours', city_purchase_setting(ci.tenant_id, 'city_purchase_carry_max_hours', 4),
    'premium_pct_2hr', city_purchase_setting(ci.tenant_id, 'city_purchase_urgency_premium_pct_2hr', 25),
    'premium_pct_1hr', city_purchase_setting(ci.tenant_id, 'city_purchase_urgency_premium_pct_1hr', 50),
    'premium_pct_urgent', city_purchase_setting(ci.tenant_id, 'city_purchase_urgency_premium_pct_urgent', 75),
    'present_vehicles', (SELECT count(*) FROM vehicle_city_presence p JOIN vehicles v ON v.id = p.vehicle_id WHERE p.city_id = p_city_id AND p.is_active AND v.is_online)
  );
END;
$function$;

-- ─── Detail / lists carry the new fields ───────────────────────────────
CREATE OR REPLACE FUNCTION public.city_purchase_request_detail(p_request_id uuid)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT jsonb_build_object(
    'request', jsonb_build_object(
      'id', r.id, 'item', r.item, 'has_item_attachment', (r.item_attachment_path IS NOT NULL), 'pickup_label', r.pickup_label,
      'pickup_lat', r.pickup_lat, 'pickup_lng', r.pickup_lng, 'goods_budget_pkr', r.goods_budget_pkr, 'status', r.status,
      'urgency', r.urgency,
      'distance_fare_pkr', r.distance_fare_pkr, 'addon_fee_pkr', r.addon_fee_pkr, 'detour_fuel_pkr', r.detour_fuel_pkr, 'total_fare_pkr', r.total_fare_pkr,
      'tip_pkr', r.tip_pkr, 'area', r.area, 'ride_type', r.ride_type, 'estimated_fee_pkr', r.estimated_fee_pkr,
      'actual_goods_cost_pkr', r.actual_goods_cost_pkr, 'has_bill_attachment', (r.bill_attachment_path IS NOT NULL),
      'city_name', ci.name, 'city_name_ur', ci.name_ur, 'city_km', ci.distance_km,
      'accepted_vehicle_id', av.id, 'accepted_owner_name', av.owner_name, 'accepted_owner_mobile', av.owner_mobile, 'accepted_vehicle_type', av.vehicle_type,
      'initiator_portal_user_id', r.initiator_portal_user_id,
      'created_at', r.created_at
    ) || jsonb_build_object(
      'trip_mode', r.trip_mode, 'urgency_premium_pkr', r.urgency_premium_pkr, 'detour_km', r.detour_km,
      'approved_at', r.approved_at, 'driver_confirmed_at', r.driver_confirmed_at, 'deliver_by', r.deliver_by,
      'scheduled_date', r.scheduled_date, 'scheduled_time', r.scheduled_time
    ),
    'invitations', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'vehicle_id', v.id, 'owner_name', v.owner_name, 'source', i.source, 'reference_destination', i.reference_destination,
        'status', i.status, 'invited_at', i.invited_at, 'responded_at', i.responded_at, 'reference_distance_km', i.reference_distance_km
      ) ORDER BY i.invited_at)
      FROM city_purchase_invitations i JOIN vehicles v ON v.id = i.vehicle_id WHERE i.request_id = r.id
    ), '[]'::jsonb)
  )
  FROM city_purchase_requests r
  JOIN cities ci ON ci.id = r.city_id
  LEFT JOIN vehicles av ON av.id = r.accepted_vehicle_id
  WHERE r.id = p_request_id AND is_party_to_city_purchase(r.id);
$function$;

CREATE OR REPLACE FUNCTION public.my_city_purchase_invitations(p_vehicle_id uuid)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'request_id', r.id, 'item', r.item, 'goods_budget_pkr', r.goods_budget_pkr, 'pickup_label', r.pickup_label, 'urgency', r.urgency,
    'source', i.source, 'reference_destination', i.reference_destination, 'city_name', ci.name, 'city_name_ur', ci.name_ur, 'invited_at', i.invited_at
  ) || jsonb_build_object(
    'trip_mode', CASE WHEN i.source IN ('presence', 'trip_offer', 'route') THEN 'carry_back' ELSE 'dedicated' END,
    'reference_distance_km', i.reference_distance_km, 'scheduled_date', r.scheduled_date, 'scheduled_time', r.scheduled_time,
    'tip_pkr', r.tip_pkr
  ) ORDER BY i.invited_at), '[]'::jsonb)
  FROM city_purchase_invitations i
  JOIN city_purchase_requests r ON r.id = i.request_id
  JOIN cities ci ON ci.id = r.city_id
  WHERE i.vehicle_id = p_vehicle_id AND i.status = 'ringing' AND r.status = 'ringing'
    AND EXISTS (SELECT 1 FROM vehicles v WHERE v.id = p_vehicle_id AND v.portal_user_id = current_portal_user_id());
$function$;

-- ─── Saved requests ring the next driver who goes to that city ─────────
CREATE OR REPLACE FUNCTION ring_saved_city_purchases_for_vehicle(p_vehicle_id uuid) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r record; c record; v_count int := 0; v_portal uuid;
BEGIN
  SELECT portal_user_id INTO v_portal FROM vehicles WHERE id = p_vehicle_id;
  FOR r IN
    SELECT q.* FROM city_purchase_requests q
    WHERE q.status IN ('no_answer', 'ringing')
      AND COALESCE(q.scheduled_date, (now() AT TIME ZONE 'Asia/Karachi')::date) <= (now() AT TIME ZONE 'Asia/Karachi')::date + 1
      AND q.created_at > now() - interval '7 days'
      AND NOT EXISTS (SELECT 1 FROM city_purchase_invitations i WHERE i.request_id = q.id AND i.vehicle_id = p_vehicle_id)
      AND q.tenant_id = (SELECT tenant_id FROM vehicles WHERE id = p_vehicle_id)
  LOOP
    SELECT * INTO c FROM city_purchase_candidate_vehicles(r.city_id, r.pickup_lat, r.pickup_lng, r.urgency, r.initiator_portal_user_id) x
    WHERE x.vehicle_id = p_vehicle_id LIMIT 1;
    IF NOT FOUND THEN CONTINUE; END IF;
    INSERT INTO city_purchase_invitations (request_id, vehicle_id, source, reference_destination)
    VALUES (r.id, p_vehicle_id, c.source, c.reference_destination)
    ON CONFLICT (request_id, vehicle_id) DO NOTHING;
    UPDATE city_purchase_requests SET status = 'ringing' WHERE id = r.id AND status = 'no_answer';
    IF v_portal IS NOT NULL THEN
      INSERT INTO portal_notifications (portal_user_id, event_type, title, body, link)
      VALUES (v_portal, 'city_purchase_invited', 'Saved purchase request for this city', r.item, '/portal/marketplace/city-purchase/' || r.id);
    END IF;
    INSERT INTO portal_notifications (portal_user_id, event_type, title, body, link)
    VALUES (r.initiator_portal_user_id, 'city_purchase_driver_found', 'A driver is going to the city', 'Your saved request has been sent to a driver.', '/portal/marketplace/city-purchase/' || r.id);
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION trg_ring_saved_city_purchases() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  -- Separate branches: plpgsql resolves NEW.<field> per table, so one
  -- combined condition would fail on whichever table lacks the column.
  IF TG_TABLE_NAME = 'vehicle_city_presence' THEN
    IF NEW.is_active THEN PERFORM ring_saved_city_purchases_for_vehicle(NEW.vehicle_id); END IF;
  ELSIF TG_TABLE_NAME = 'vehicle_trip_offers' THEN
    IF NEW.status = 'open' THEN PERFORM ring_saved_city_purchases_for_vehicle(NEW.vehicle_id); END IF;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS ring_saved_city_purchases ON vehicle_city_presence;
CREATE TRIGGER ring_saved_city_purchases AFTER INSERT ON vehicle_city_presence FOR EACH ROW EXECUTE FUNCTION trg_ring_saved_city_purchases();
DROP TRIGGER IF EXISTS ring_saved_city_purchases ON vehicle_trip_offers;
CREATE TRIGGER ring_saved_city_purchases AFTER INSERT ON vehicle_trip_offers FOR EACH ROW EXECUTE FUNCTION trg_ring_saved_city_purchases();

-- Internal helpers: not callable from the API directly.
REVOKE ALL ON FUNCTION city_purchase_price(uuid, uuid, numeric) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION ring_saved_city_purchases_for_vehicle(uuid) FROM PUBLIC, anon, authenticated;
