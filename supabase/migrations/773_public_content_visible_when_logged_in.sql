-- Migration 773: the rest of the "public content vanishes once you log
-- in" bug that 695 fixed for video_content and 696 fixed for three more
-- tables.
--
-- Real report: the committee announcement card on the homepage kept
-- disappearing in the Android app, and only came back after clearing the
-- app's data. Clearing data also clears the Supabase session cookie, so
-- the visitor goes back to being `anon` -- that's the whole mechanism.
--
-- 622 restricted each table's public-read policy to `anon`, on the
-- assumption that a separate tenant-scoped policy already covered
-- `authenticated`. On these ten tables the only authenticated policy is
-- the staff/admin write policy (FOR ALL ... where the caller is an
-- active admin_users row / has a permission), so an ordinary logged-in
-- villager matches nothing and reads zero rows. 696's audit looked for
-- tables with NO authenticated policy at all and so missed every table
-- whose only authenticated policy is admin-only.
--
-- Same shape as 695/696: a separate authenticated SELECT policy carrying
-- each table's own anon condition unchanged, with my_tenant_id() first in
-- the coalesce so a logged-in user still only reads their own tenant.

CREATE POLICY committee_notes_authenticated_read ON committee_notes
  FOR SELECT TO authenticated
  USING (
    tenant_id = COALESCE(my_tenant_id(), request_tenant_id(), 'bf9e4815-4104-472a-ab32-114171b7e34d'::uuid)
    AND is_published = true
  );

CREATE POLICY village_events_authenticated_read ON village_events
  FOR SELECT TO authenticated
  USING (
    tenant_id = COALESCE(my_tenant_id(), request_tenant_id(), 'bf9e4815-4104-472a-ab32-114171b7e34d'::uuid)
    AND is_active = true
  );

CREATE POLICY village_landmarks_authenticated_read ON village_landmarks
  FOR SELECT TO authenticated
  USING (
    tenant_id = COALESCE(my_tenant_id(), request_tenant_id(), 'bf9e4815-4104-472a-ab32-114171b7e34d'::uuid)
    AND is_active = true
  );

CREATE POLICY crop_prices_authenticated_read ON crop_prices
  FOR SELECT TO authenticated
  USING (
    tenant_id = COALESCE(my_tenant_id(), request_tenant_id(), 'bf9e4815-4104-472a-ab32-114171b7e34d'::uuid)
  );

CREATE POLICY ag_schemes_authenticated_read ON ag_schemes
  FOR SELECT TO authenticated
  USING (
    tenant_id = COALESCE(my_tenant_id(), request_tenant_id(), 'bf9e4815-4104-472a-ab32-114171b7e34d'::uuid)
    AND is_active = true
  );

CREATE POLICY ag_disease_guides_authenticated_read ON ag_disease_guides
  FOR SELECT TO authenticated
  USING (
    tenant_id = COALESCE(my_tenant_id(), request_tenant_id(), 'bf9e4815-4104-472a-ab32-114171b7e34d'::uuid)
    AND is_active = true
  );

CREATE POLICY ag_help_centers_authenticated_read ON ag_help_centers
  FOR SELECT TO authenticated
  USING (
    tenant_id = COALESCE(my_tenant_id(), request_tenant_id(), 'bf9e4815-4104-472a-ab32-114171b7e34d'::uuid)
    AND is_active = true
  );

CREATE POLICY ag_livestock_guides_authenticated_read ON ag_livestock_guides
  FOR SELECT TO authenticated
  USING (
    tenant_id = COALESCE(my_tenant_id(), request_tenant_id(), 'bf9e4815-4104-472a-ab32-114171b7e34d'::uuid)
    AND is_active = true
  );

CREATE POLICY addas_authenticated_read ON addas
  FOR SELECT TO authenticated
  USING (
    tenant_id = COALESCE(my_tenant_id(), request_tenant_id(), 'bf9e4815-4104-472a-ab32-114171b7e34d'::uuid)
  );

CREATE POLICY wedding_functions_authenticated_read ON wedding_functions
  FOR SELECT TO authenticated
  USING (
    tenant_id = COALESCE(my_tenant_id(), request_tenant_id(), 'bf9e4815-4104-472a-ab32-114171b7e34d'::uuid)
    AND EXISTS (
      SELECT 1 FROM village_events
      WHERE village_events.id = wedding_functions.event_id AND village_events.is_active = true
    )
  );
