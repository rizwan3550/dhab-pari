'use client'

// The driver's side of the full accept/decline/start/end lifecycle
// (475/477) — requested bookings get Accept/Decline (decline asks for a
// reason, same as every other reject flow in this app), an accepted one
// gets Start Trip (the moment GPS tracking actually begins — never
// earlier), an in-progress one shows the live distance and Ends Trip,
// and a completed-but-unsettled per_order booking gets a Confirm
// Payment button once the driver's actually been paid in person.
//
// Only one booking for this vehicle can ever be in_progress at a time
// (enforced server-side too, 477) — a vehicle can't physically be on
// two trips, so Start Trip is simply not offered on a second accepted
// booking while one is already running.
//
// Phase 5: re-skinned to the new Mobility design — same RPCs, reached
// from the Jobs tab's hourly rows rather than its own nav tab.
//
// 2026-10-30: every step above now happens in the booking's own popup
// (BookingLifecycleSheet); this page is the grouped list. The trip GPS
// stays here at page level so distance keeps counting whether or not
// that popup is open — the popup is told not to ping a second time.

import { useEffect, useState } from 'react'
import { Clock3, AlertCircle } from 'lucide-react'
import { createClient } from '@/lib/supabase/client'
import { usePortalUser } from '@/hooks/usePortalUser'
import { useLocale } from '@/lib/i18n/LocaleProvider'
import { useLiveLocation } from '@/hooks/useLiveLocation'
import { LoadingDots } from '@/components/shared/LoadingDots'
import { LifecycleBookingsList } from '@/components/mobility/LifecycleBookingsList'

interface Vehicle { id: string; owner_name: string; commission_mode: string }
interface Booking {
  id: string; hours: number; status: string; status_confirmed: boolean; pickup_address: string
  base_amount_pkr: number; total_amount_pkr: number | null; distance_km: number; customer_name: string
}

function fmt(n: number) {
  return Number(n || 0).toLocaleString(undefined, { maximumFractionDigits: 0 })
}

export default function MyHourlyBookingsPage() {
  const { t } = useLocale()
  const { user, loading: userLoading } = usePortalUser()
  const supabase = createClient()

  const [vehicle, setVehicle] = useState<Vehicle | null>(null)
  const [bookings, setBookings] = useState<Booking[]>([])
  const [loading, setLoading] = useState(true)

  const loadBookings = (vehicleId: string) =>
    supabase.rpc('vehicle_hourly_bookings', { p_vehicle_id: vehicleId }).then(({ data }) => setBookings((data ?? []) as Booking[]))

  useEffect(() => {
    if (!user) return
    supabase.from('vehicles').select('id, owner_name, commission_mode').eq('portal_user_id', user.id).maybeSingle().then(async ({ data }) => {
      setVehicle(data)
      if (data) await loadBookings(data.id)
      setLoading(false)
    })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [user])

  const activeTrip = bookings.find((b) => b.status === 'in_progress') ?? null

  // GPS only ever runs while a trip is actually in_progress — the toggle
  // is implicit (tied to activeTrip existing), not a separate switch the
  // driver could forget to flip.
  const { error: locError } = useLiveLocation({
    enabled: !!activeTrip,
    minIntervalMs: 12000,
    backgroundTitle: t('vp.hourlyTrackingNotifTitle'),
    backgroundMessage: t('vp.hourlyTrackingNotifBody'),
    onFix: async ({ lat, lng }) => {
      if (!activeTrip) return
      const { error } = await supabase.rpc('ping_hourly_trip_location', { p_booking_id: activeTrip.id, p_lat: lat, p_lng: lng })
      // Raises once the trip's no longer in_progress (ended elsewhere,
      // e.g. a second device) — refresh so the UI catches up instead of
      // silently retrying a ping that will never succeed.
      if (error && vehicle) loadBookings(vehicle.id)
    },
  })

  // Distance ticking up live while a trip runs — re-poll only then.
  useEffect(() => {
    if (!vehicle || !activeTrip) return
    const id = setInterval(() => loadBookings(vehicle.id), 10000)
    return () => clearInterval(id)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [vehicle, activeTrip?.id])

  if (userLoading || loading) return <div className="text-center py-12"><LoadingDots /></div>
  if (!vehicle) return <div className="text-center py-12 text-[#64748b] text-[14px]">{t('cm.noVehicleLinked')}</div>

  return (
    <div className="flex flex-col gap-3">
      <div>
        <h1 className="font-bold text-[20px] sm:text-[22px] text-dp-primary flex items-center gap-2"><Clock3 size={19} /> {t('vp.myHourlyBookingsHeading')}</h1>
        <p className="text-[12.5px] text-[#64748b] mt-0.5">{t('vp.myHourlyBookingsSubtitle')}</p>
      </div>

      {/* Was the raw browser error ("User denied Geolocation") in red —
          shown in the reader's language now, and as a fixable warning. */}
      {activeTrip && locError && (
        <div className="flex items-center gap-1.5 bg-amber-50 border border-amber-200 rounded-xl p-2.5">
          <AlertCircle size={13} className="text-amber-700 shrink-0" />
          <p className="font-sans text-[11.5px] text-amber-900">{t('cm.geoErrorMsg')}</p>
        </div>
      )}

      <LifecycleBookingsList
        kind="hourly" vehicleId={vehicle.id} commissionMode={vehicle.commission_mode}
        emptyText={t('vp.noHourlyBookingsYetHint')}
        trackLocation={false}
        onChanged={() => loadBookings(vehicle.id)}
        items={bookings.map((b) => ({
          id: b.id, status: b.status, status_confirmed: b.status_confirmed, customer_name: b.customer_name,
          subtitle: b.pickup_address, amount: b.total_amount_pkr ?? b.base_amount_pkr,
          meta: `${b.hours}h`, live: `${fmt(b.distance_km)}km`,
        }))}
      />
    </div>
  )
}
