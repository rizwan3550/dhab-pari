'use client'

// Real ask, 2026-10-30: "all these types of requests will be saved in
// floating buttons and there may be multiple as well, so be careful."
// Every request a rider has sent that is still waiting on someone —
// a driver to accept, the rider to approve or pay, the committee — sits
// here as one floating pill, on every portal screen, so leaving the page
// never loses it. Tapping a pill reopens that request's own popup (the
// live RequestWaitingSheet for hourly / rental / machinery / seats) or
// its own live screen (ride, city purchase). Several can be open at
// once: up to three pills show, the rest fold into "+N".
//
// Bottom-LEFT on purpose: the right edge already holds the WhatsApp and
// ongoing-ride buttons (OngoingRideFab), and one crowded column would
// cover them.

import { useCallback, useEffect, useState } from 'react'
import { useRouter } from 'next/navigation'
import { ChevronDown, X as XIcon } from 'lucide-react'
import { createClient } from '@/lib/supabase/client'
import { usePortalUser } from '@/hooks/usePortalUser'
import { useLocale } from '@/lib/i18n/LocaleProvider'
import { vehicleDisplayName } from '@/lib/vehicleDisplayName'
import { RequestWaitingSheet, type WaitingKind, type WaitingSummary } from '@/components/mobility/RequestWaitingSheet'

interface DockItem {
  key: string
  emoji: string
  label: string
  state: 'searching' | 'action' | 'waiting'
  since: string
  // Either reopen the live waiting popup...
  sheet?: { kind: WaitingKind; id: string; summary: WaitingSummary; viewHref: string }
  // ...or go to the request's own live screen.
  href?: string
}

const MAX_VISIBLE = 3

export function ActiveRequestsDock() {
  const { t, isUrdu } = useLocale()
  const { user } = usePortalUser()
  const router = useRouter()
  const [items, setItems] = useState<DockItem[]>([])
  const [openSheet, setOpenSheet] = useState<DockItem['sheet'] | null>(null)
  const [expanded, setExpanded] = useState(false)

  const load = useCallback(async () => {
    const supabase = createClient()
    const [hourly, rental, equipment, seats, rides, purchases] = await Promise.all([
      supabase.rpc('my_hourly_bookings'),
      supabase.rpc('my_rental_bookings'),
      supabase.rpc('my_equipment_bookings'),
      supabase.from('ride_bookings').select('id, seats, travel_date, total_amount_pkr, created_at, vehicle_routes(origin, origin_ur, destination, destination_ur), adda_queue_entries(addas(name, name_ur))').eq('portal_user_id', user!.id).eq('status', 'announced'),
      supabase.from('ride_dispatch_requests').select('id, pickup_label, dropoff_label, fare_pkr, created_at').eq('initiator_portal_user_id', user!.id).eq('status', 'open'),
      supabase.rpc('my_city_purchase_requests'),
    ])
    const out: DockItem[] = []
    const nm = (en: string | null | undefined, ur: string | null | undefined) => (isUrdu && ur ? ur : en) ?? ''

    for (const b of (hourly.data ?? []) as { id: string; status: string; hours: number; pickup_address: string; base_amount_pkr: number; total_amount_pkr: number | null; requested_at: string; owner_name: string; vehicle_type: string; model: string | null }[]) {
      if (b.status !== 'requested') continue
      out.push({ key: `h-${b.id}`, emoji: '⏱️', label: `${t('rq.kind.hourly')} · ${vehicleDisplayName(b.vehicle_type, b.model)}`, state: 'searching', since: b.requested_at,
        sheet: { kind: 'hourly', id: b.id, viewHref: '/portal/marketplace/hourly', summary: { vehicleLabel: vehicleDisplayName(b.vehicle_type, b.model), driverName: b.owner_name, from: b.pickup_address, amount: b.total_amount_pkr ?? b.base_amount_pkr, facts: [t('rw.hours').replace('{n}', String(b.hours))] } } })
    }
    for (const b of (rental.data ?? []) as { id: string; status: string; from_address: string; to_address: string; total_amount_pkr: number; requested_at: string; owner_name: string; vehicle_type: string; model: string | null }[]) {
      if (b.status !== 'requested') continue
      out.push({ key: `r-${b.id}`, emoji: '🚗', label: `${t('rq.kind.rental')} · ${b.to_address}`, state: 'searching', since: b.requested_at,
        sheet: { kind: 'rental', id: b.id, viewHref: '/portal/marketplace/rental', summary: { vehicleLabel: vehicleDisplayName(b.vehicle_type, b.model), driverName: b.owner_name, from: b.from_address, to: b.to_address, amount: b.total_amount_pkr } } })
    }
    for (const b of (equipment.data ?? []) as { id: string; kind: 'machinery' | 'tractor' | 'loader'; status: string; site_address: string; rate_pkr: number; total_amount_pkr: number | null; requested_at: string; owner_name: string; vehicle_type: string; model: string | null; advance_status?: string }[]) {
      const payAdvance = b.status === 'accepted' && ['due', 'rejected'].includes(b.advance_status ?? '')
      if (b.status !== 'requested' && !payAdvance) continue
      out.push({ key: `e-${b.id}`, emoji: b.kind === 'tractor' ? '🚜' : b.kind === 'loader' ? '🚚' : '🏗️', label: `${t(`rq.kind.equipment.${b.kind}`)} · ${payAdvance ? t('eqa.payBtn') : b.site_address}`,
        state: payAdvance ? 'action' : 'searching', since: b.requested_at,
        sheet: { kind: 'equipment', id: b.id, viewHref: `/portal/marketplace/${b.kind}`, summary: { vehicleLabel: vehicleDisplayName(b.vehicle_type, b.model), driverName: b.owner_name, from: b.site_address, amount: b.total_amount_pkr ?? b.rate_pkr } } })
    }
    for (const b of (seats.data ?? []) as unknown as { id: string; seats: number; travel_date: string; total_amount_pkr: number; created_at: string; vehicle_routes: { origin: string; origin_ur: string | null; destination: string; destination_ur: string | null } | null; adda_queue_entries: { addas: { name: string; name_ur: string | null } | null } | null }[]) {
      const r = b.vehicle_routes
      const adda = b.adda_queue_entries?.addas
      const title = r ? `${nm(r.origin, r.origin_ur)} → ${nm(r.destination, r.destination_ur)}` : nm(adda?.name, adda?.name_ur)
      out.push({ key: `s-${b.id}`, emoji: '🚌', label: `${t('rq.kind.route')} · ${title}`, state: 'waiting', since: b.created_at,
        sheet: { kind: 'seat', id: b.id, viewHref: '/portal/marketplace/trips', summary: { vehicleLabel: title, from: r ? nm(r.origin, r.origin_ur) : nm(adda?.name, adda?.name_ur), to: r ? nm(r.destination, r.destination_ur) : null, amount: b.total_amount_pkr, facts: [b.travel_date, t('rw.seats').replace('{n}', String(b.seats))] } } })
    }
    for (const d of (rides.data ?? []) as { id: string; pickup_label: string; dropoff_label: string; fare_pkr: number; created_at: string }[]) {
      out.push({ key: `d-${d.id}`, emoji: '🚕', label: `${t('rq.kind.ride_dispatch')} · ${d.dropoff_label}`, state: 'searching', since: d.created_at, href: `/portal/marketplace/ride-dispatch/${d.id}` })
    }
    for (const c of (purchases.data ?? []) as { id: string; item: string; status: string; created_at: string; as_role: string }[]) {
      if (c.as_role !== 'user' || !['ringing', 'no_answer', 'priced'].includes(c.status)) continue
      out.push({ key: `c-${c.id}`, emoji: '🛍️', label: `${t('rq.kind.city_purchase')} · ${c.item}`, state: c.status === 'priced' ? 'action' : c.status === 'no_answer' ? 'waiting' : 'searching',
        since: c.created_at, href: `/portal/marketplace/city-purchase/${c.id}` })
    }
    // Needs-you first, then newest.
    out.sort((a, b) => (a.state === 'action' ? 0 : 1) - (b.state === 'action' ? 0 : 1) || b.since.localeCompare(a.since))
    setItems(out)
  }, [user, t, isUrdu])

  useEffect(() => {
    if (!user) return
    let live = true
    const run = () => { if (live) load() }
    const first = setTimeout(run, 0)
    const iv = setInterval(run, 20000)
    const onVisible = () => { if (document.visibilityState === 'visible') run() }
    document.addEventListener('visibilitychange', onVisible)
    return () => { live = false; clearTimeout(first); clearInterval(iv); document.removeEventListener('visibilitychange', onVisible) }
  }, [user, load])

  const renderSheet = () => {
    if (!openSheet) return null
    return (
      <RequestWaitingSheet kind={openSheet.kind} bookingId={openSheet.id} summary={openSheet.summary}
        onClose={() => { setOpenSheet(null); load() }}
        onViewBooking={() => { const href = openSheet.viewHref; setOpenSheet(null); router.push(href) }} />
    )
  }

  if (!user || items.length === 0) return openSheet ? renderSheet() : null

  const visible = expanded ? items : items.slice(0, MAX_VISIBLE)
  const hidden = items.length - visible.length

  const open = (it: DockItem) => {
    setExpanded(false)
    if (it.sheet) setOpenSheet(it.sheet)
    else if (it.href) router.push(it.href)
  }

  return (
    <>
      <div dir={isUrdu ? 'rtl' : 'ltr'} className="fixed z-[65] left-3 bottom-[88px] md:bottom-6 md:left-auto md:right-24 flex flex-col-reverse items-start gap-2 print:hidden max-w-[230px]">
        {visible.map((it) => (
          <button key={it.key} onClick={() => open(it)} title={it.label}
            className="relative flex items-center gap-2 h-11 ps-1.5 pe-3.5 rounded-full bg-white shadow-[0_6px_18px_-6px_rgba(15,23,42,0.45)] border border-[#e5e7eb] active:scale-95 transition-transform cursor-pointer max-w-full">
            <span className="relative shrink-0 w-8 h-8 rounded-full flex items-center justify-center text-[16px]" style={{ background: it.state === 'action' ? '#fef3c7' : '#dcfce7' }}>
              {it.state === 'searching' && <span className="absolute inset-0 rounded-full border-2 border-[#16a34a]/50 animate-ping [animation-duration:2s]" />}
              {it.emoji}
            </span>
            <span className="min-w-0 text-start">
              <span className="block font-sans text-[9.5px] font-bold uppercase tracking-[0.04em] leading-none" style={{ color: it.state === 'action' ? '#b45309' : '#16a34a' }}>
                {t(`dock.state.${it.state}`)}
              </span>
              <span className="block font-sans text-[12px] font-semibold text-[#0f172a] truncate leading-tight mt-0.5"><bdi>{it.label}</bdi></span>
            </span>
            {it.state === 'action' && <span className="absolute -top-0.5 -end-0.5 w-3 h-3 rounded-full bg-[#f59e0b] border-2 border-white" />}
          </button>
        ))}
        {hidden > 0 && (
          <button onClick={() => setExpanded(true)} className="h-9 px-3 rounded-full bg-[#0f172a] text-white font-sans text-[12px] font-bold shadow-lg cursor-pointer flex items-center gap-1">
            +{hidden} <span className="font-semibold text-white/80">{t('dock.more')}</span>
          </button>
        )}
        {expanded && items.length > MAX_VISIBLE && (
          <button onClick={() => setExpanded(false)} aria-label="Collapse" className="w-9 h-9 rounded-full bg-[#0f172a] text-white shadow-lg cursor-pointer flex items-center justify-center">
            {hidden > 0 ? <ChevronDown size={16} /> : <XIcon size={15} />}
          </button>
        )}
      </div>
      {renderSheet()}
    </>
  )
}
