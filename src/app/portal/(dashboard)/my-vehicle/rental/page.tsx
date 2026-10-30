'use client'

// The driver's side of the point-to-point rental accept/decline/start/
// end lifecycle (653): requested bookings get Accept/Decline, an
// accepted one gets Start Trip (PIN-gated — the rider shows a 4-digit
// code), an in-progress one gets End Trip, and a completed per_order
// booking gets a Confirm Payment button. No live GPS here: unlike
// hourly, both ends of the trip are fixed at request time, so there's
// no distance to track live — modeled on my-vehicle/hourly/page.tsx
// minus that piece.
//
// 2026-10-30: every one of those steps now happens in the booking's own
// popup (BookingLifecycleSheet) — this page is just the grouped list.

import { useEffect, useState } from 'react'
import { Navigation } from 'lucide-react'
import { createClient } from '@/lib/supabase/client'
import { usePortalUser } from '@/hooks/usePortalUser'
import { useLocale } from '@/lib/i18n/LocaleProvider'
import { FarePolicyCard } from '@/components/mobility/FarePolicyCard'
import { LoadingDots } from '@/components/shared/LoadingDots'
import { LifecycleBookingsList } from '@/components/mobility/LifecycleBookingsList'

interface Vehicle { id: string; owner_name: string; commission_mode: string }
interface Booking {
  id: string; from_address: string; to_address: string; trip_type: 'one' | 'return'; wait_hours: number; km: number
  status: string; status_confirmed: boolean; total_amount_pkr: number; customer_name: string
}

export default function MyRentalBookingsPage() {
  const { t } = useLocale()
  const { user, loading: userLoading } = usePortalUser()
  const supabase = createClient()

  const [vehicle, setVehicle] = useState<Vehicle | null>(null)
  const [bookings, setBookings] = useState<Booking[]>([])
  const [loading, setLoading] = useState(true)

  const loadBookings = (vehicleId: string) =>
    supabase.rpc('vehicle_rental_bookings', { p_vehicle_id: vehicleId }).then(({ data }) => setBookings((data ?? []) as Booking[]))

  useEffect(() => {
    if (!user) return
    supabase.from('vehicles').select('id, owner_name, commission_mode').eq('portal_user_id', user.id).maybeSingle().then(async ({ data }) => {
      setVehicle(data)
      if (data) await loadBookings(data.id)
      setLoading(false)
    })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [user])

  useEffect(() => {
    if (!vehicle || !bookings.some((b) => ['requested', 'accepted', 'in_progress'].includes(b.status))) return
    const id = setInterval(() => loadBookings(vehicle.id), 10000)
    return () => clearInterval(id)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [vehicle, bookings])

  if (userLoading || loading) return <div className="text-center py-12"><LoadingDots /></div>
  if (!vehicle) return <div className="text-center py-12 text-[#64748b] text-[14px]">{t('cm.noVehicleLinked')}</div>

  return (
    <div className="flex flex-col gap-3">
      <div>
        <h1 className="font-bold text-[20px] sm:text-[22px] text-dp-primary flex items-center gap-2"><Navigation size={19} /> {t('vp.myRentalBookingsHeading')}</h1>
        <p className="text-[12.5px] text-[#64748b] mt-0.5">{t('vp.myRentalBookingsSubtitle')}</p>
      </div>
      <div><FarePolicyCard service="rental" audience="driver" defaultOpen={false} /></div>

      <LifecycleBookingsList
        kind="rental" vehicleId={vehicle.id} commissionMode={vehicle.commission_mode}
        emptyText={t('vp.noRentalBookingsYetHint')}
        onChanged={() => loadBookings(vehicle.id)}
        items={bookings.map((b) => ({
          id: b.id, status: b.status, status_confirmed: b.status_confirmed, customer_name: b.customer_name,
          subtitle: `${b.from_address} → ${b.to_address}`, amount: b.total_amount_pkr,
          meta: `${Math.round(b.km)}km${b.trip_type === 'return' ? ' ↺' : ''}`,
        }))}
      />
    </div>
  )
}
