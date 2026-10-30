'use client'

// The listing half of the hourly / rental / equipment driver pages: one
// compact row per booking, grouped by what the driver has to do next, and
// tapping a row opens that booking's BookingLifecycleSheet. Every action
// (accept, PIN start, finish, confirm payment, rate) lives in the sheet,
// so these pages no longer stack a full card, its own map and its own
// buttons per booking — the per-booking maps alone made a page with four
// bookings nearly 1,800px tall on a phone.

import { useState } from 'react'
import { ChevronRight, Radio } from 'lucide-react'
import { useLocale } from '@/lib/i18n/LocaleProvider'
import { BookingLifecycleSheet, type LifecycleKind } from '@/components/mobility/BookingLifecycleSheet'

export interface LifecycleListItem {
  id: string; status: string; status_confirmed: boolean
  customer_name: string; subtitle: string; amount: number | null
  meta: string // "4h", "240km", "5h · 4,500/hr"
  live?: string // shown on an in-progress row: "18km", "1.4h"
}

function fmt(n: number) { return Number(n ?? 0).toLocaleString(undefined, { maximumFractionDigits: 0 }) }

export function LifecycleBookingsList({ kind, vehicleId, commissionMode, items, onChanged, emptyText, trackLocation = true }: {
  kind: LifecycleKind; vehicleId: string; commissionMode: string
  items: LifecycleListItem[]; onChanged: () => void; emptyText: string
  trackLocation?: boolean
}) {
  const { t, isUrdu } = useLocale()
  const [openId, setOpenId] = useState<string | null>(null)

  const sections = [
    { key: 'new', title: t('vp.newRequestsHeading'), rows: items.filter((b) => b.status === 'requested'), accent: '#D4AF37' },
    { key: 'live', title: t('vp.inProgressHeading'), rows: items.filter((b) => b.status === 'in_progress'), accent: '#166534' },
    { key: 'ready', title: t('vp.readyToStartHeading'), rows: items.filter((b) => b.status === 'accepted'), accent: null },
    { key: 'settle', title: t('vp.awaitingSettlementHeading'), rows: items.filter((b) => b.status === 'completed' && !b.status_confirmed), accent: '#D4AF37' },
    { key: 'history', title: t('vp.historyHeading'), rows: items.filter((b) => (b.status === 'completed' && b.status_confirmed) || b.status === 'declined' || b.status === 'cancelled'), accent: null },
  ].filter((s) => s.rows.length > 0)

  const statusText = (s: string) => t(kind === 'equipment' ? `vp.equipmentStatus.${s}` : `vp.hourlyStatus.${s}`)

  return (
    <>
      {sections.length === 0 && <p className="text-center py-10 text-[#94a3b8] text-[14px]">{emptyText}</p>}

      {sections.map((s) => (
        <div key={s.key}>
          <p className="font-sans text-[11px] font-bold uppercase tracking-[0.06em] text-[#64748b] mb-2">{s.title} <span className="ltr-num">({s.rows.length})</span></p>
          <div className="flex flex-col gap-2">
            {s.rows.map((b) => {
              const past = s.key === 'history'
              return (
                <button key={b.id} onClick={() => setOpenId(b.id)}
                  className={`w-full flex items-center gap-3 bg-white rounded-2xl p-3 text-start cursor-pointer active:scale-[0.99] transition-transform ${s.key === 'live' ? 'border-2 border-[#166534]' : 'border border-[#e5e2d0]'} ${past ? 'opacity-70' : ''}`}
                  style={s.accent && s.key !== 'live' ? { borderInlineStartWidth: 4, borderInlineStartColor: s.accent } : undefined}>
                  <span className="flex-1 min-w-0">
                    <span className="block font-sans text-[14px] font-bold text-[#1e293b] truncate">{b.customer_name}</span>
                    <span className="block font-sans text-[12px] text-[#64748b] truncate mt-0.5">{b.subtitle}</span>
                    {s.key === 'live' ? (
                      <span className="inline-flex items-center gap-1 mt-1 font-sans text-[11.5px] font-bold text-[#166534]">
                        <Radio size={11} className="animate-pulse" /> {t('cm.rideInProgressLabel')}{b.live ? ` · ${b.live}` : ''}
                      </span>
                    ) : past ? (
                      <span className="block mt-1 font-sans text-[10.5px] font-bold" style={{ color: b.status === 'declined' ? '#b91c1c' : b.status === 'cancelled' ? '#64748b' : '#166534' }}>{statusText(b.status)}</span>
                    ) : null}
                  </span>
                  <span className="shrink-0 text-end">
                    {/* ltr-num on an inner span: the Urdu stylesheet makes .ltr-num
                        inline-block, which would put these two on one line. */}
                    <span className="block font-sans text-[11px] text-[#64748b]"><span className="ltr-num">{b.meta}</span></span>
                    {b.amount != null && <span className="block font-sans text-[15px] font-extrabold text-[#166534]"><span className="ltr-num">{fmt(b.amount)}</span></span>}
                  </span>
                  <ChevronRight size={16} className={`shrink-0 text-[#94a3b8] ${isUrdu ? 'rotate-180' : ''}`} />
                </button>
              )
            })}
          </div>
        </div>
      ))}

      {openId && (
        <BookingLifecycleSheet
          kind={kind} bookingId={openId} vehicleId={vehicleId} commissionMode={commissionMode}
          trackLocation={trackLocation}
          onClose={() => setOpenId(null)}
          onChanged={onChanged}
        />
      )}
    </>
  )
}
