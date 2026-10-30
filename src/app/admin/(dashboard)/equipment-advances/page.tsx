'use client'

// Committee queue for the machinery/tractor/loader booking advance
// (migration 776) — the same check-the-slip-and-confirm step the
// committee already does for wedding advances (shadi-bookings), plus
// refunds for bookings cancelled after their advance was confirmed.

import { useEffect, useState } from 'react'
import NextImage from 'next/image'
import { createClient } from '@/lib/supabase/client'
import { toast } from 'sonner'
import { friendlyError } from '@/lib/errors'
import { useSystemAccess } from '@/hooks/useSystemAccess'
import { CheckCircle, XCircle, Wrench, CalendarDays, MapPin, RotateCcw } from 'lucide-react'
import { useLocale } from '@/lib/i18n/LocaleProvider'
import { LoadingDots } from '@/components/shared/LoadingDots'
import { vehicleDisplayName } from '@/lib/vehicleDisplayName'

interface Row {
  id: string; kind: string; status: string; site_address: string; scheduled_date: string | null
  advance_status: string; advance_amount_pkr: number; advance_pct: number; advance_method: string | null; advance_proof_url: string | null
  advance_announced_at: string | null; advance_rejected_reason: string | null; estimate_pkr: number | null
  customer_name: string; customer_mobile: string | null; owner_name: string; vehicle_type: string; model: string | null
}

function fmt(n: number) { return Number(n || 0).toLocaleString(undefined, { maximumFractionDigits: 0 }) }

const STATUS_COLOR: Record<string, string> = { confirmed: '#0f7a4d', released: '#0f7a4d', refunded: '#6b6560', rejected: '#b91c1c', refund_due: '#9a5714', announced: '#9a5714' }

export default function AdminEquipmentAdvancesPage() {
  const { t, isUrdu } = useLocale()
  const access = useSystemAccess()
  const supabase = createClient()
  const [rows, setRows] = useState<Row[]>([])
  const [loading, setLoading] = useState(true)
  const [signedUrls, setSignedUrls] = useState<Record<string, string>>({})
  const [busyId, setBusyId] = useState<string | null>(null)

  const load = () => supabase.rpc('admin_equipment_advances').then(({ data }) => apply((data ?? []) as Row[]))
  const apply = async (list: Row[]) => {
    setRows(list)
    setLoading(false)
    const urls: Record<string, string> = {}
    await Promise.all(list.filter((r) => r.advance_status === 'announced' && r.advance_proof_url).map(async (r) => {
      const { data: signed } = await supabase.storage.from('donation_receipts').createSignedUrl(r.advance_proof_url!, 300)
      if (signed) urls[r.id] = signed.signedUrl
    }))
    setSignedUrls(urls)
  }
  useEffect(() => { load() }, []) // eslint-disable-line react-hooks/exhaustive-deps

  const act = async (id: string, fn: 'confirm_equipment_advance' | 'reject_equipment_advance' | 'refund_equipment_advance', okKey: string) => {
    const args: Record<string, unknown> = { p_booking_id: id }
    if (fn === 'reject_equipment_advance') args.p_reason = prompt(t('sb.rejectReasonPrompt')) || null
    setBusyId(id)
    const { error } = await supabase.rpc(fn, args)
    setBusyId(null)
    if (error) { toast.error(friendlyError(error)); return }
    toast.success(t(okKey))
    load()
  }

  if (access.loading || loading) return <div className="text-center py-12 text-dp-on-surface-variant font-sans"><LoadingDots /></div>
  if (!access.canDonorsProjects) {
    return <div className="bg-white rounded-lg border border-dp-outline-variant p-8 text-center"><p className="font-sans text-[14px] text-dp-on-surface-variant">{t('sb.noAccessMessage')}</p></div>
  }

  const pending = rows.filter((r) => r.advance_status === 'announced')
  const refunds = rows.filter((r) => r.advance_status === 'refund_due')
  const history = rows.filter((r) => !['announced', 'refund_due'].includes(r.advance_status))

  const head = (r: Row) => (
    <>
      <p className="font-sans text-[15px] font-bold text-dp-on-surface">{r.customer_name} {r.customer_mobile ? <span className="text-dp-on-surface-variant font-normal">· {r.customer_mobile}</span> : null}</p>
      <p className="font-sans text-[12.5px] text-dp-on-surface-variant mt-0.5">{vehicleDisplayName(r.vehicle_type, r.model)} — {r.owner_name} · {t(`rq.kind.equipment.${r.kind}`)}</p>
      <p className="font-sans text-[12.5px] text-dp-on-surface-variant mt-0.5 flex items-center gap-1.5">
        <CalendarDays size={12} /> {r.scheduled_date ? new Date(r.scheduled_date).toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' }) : '—'}{r.advance_method ? ` · ${r.advance_method}` : ''}
      </p>
      <p className="font-sans text-[12.5px] text-dp-on-surface-variant mt-0.5 flex items-center gap-1.5"><MapPin size={12} /> {r.site_address}</p>
    </>
  )

  return (
    <div dir={isUrdu ? 'rtl' : 'ltr'} className="shop-ink-theme">
      <div className="mb-6">
        <h1 className="font-heading text-[32px] font-bold leading-[40px] text-dp-primary flex items-center gap-2"><Wrench size={26} /> {t('ea.pageTitle')}</h1>
        <p className="font-sans text-[13.5px] text-dp-on-surface-variant mt-1">{t('ea.pageSubtitle')}</p>
      </div>

      <p className="font-sans text-[12px] font-bold uppercase tracking-[0.05em] text-dp-on-surface-variant mb-3">{t('sb.awaitingConfirmationHeading')}</p>
      {pending.length === 0 ? (
        <div className="bg-white rounded-lg border border-dp-outline-variant p-8 text-center mb-8"><p className="font-sans text-[14px] text-dp-on-surface-variant">{t('sb.noPendingAdvances')}</p></div>
      ) : (
        <div className="space-y-4 mb-8">
          {pending.map((r) => (
            <div key={r.id} className="bg-white border border-dp-outline-variant rounded-lg p-5 flex flex-col md:flex-row gap-5">
              {signedUrls[r.id] && (
                <a href={signedUrls[r.id]} target="_blank" rel="noopener noreferrer" className="relative shrink-0 w-full md:w-40 h-40 block">
                  <NextImage src={signedUrls[r.id]} alt="Payment slip" fill sizes="160px" className="object-cover rounded-lg border border-dp-outline-variant" />
                </a>
              )}
              <div className="flex-1">
                <div className="flex items-start justify-between gap-3">
                  <div>{head(r)}</div>
                  <div className="text-end shrink-0">
                    <p className="font-heading text-[20px] font-bold text-dp-secondary ltr-num">{fmt(r.advance_amount_pkr)}</p>
                    <p className="font-sans text-[11px] text-dp-on-surface-variant ltr-num">{r.advance_pct}% · {fmt(r.estimate_pkr ?? 0)}</p>
                  </div>
                </div>
                <div className="flex gap-2 mt-3">
                  <button onClick={() => act(r.id, 'confirm_equipment_advance', 'sb.confirmedToast')} disabled={busyId === r.id} className="flex items-center gap-1.5 px-4 py-2 bg-dp-secondary text-white rounded-lg font-sans text-[13px] font-semibold cursor-pointer hover:bg-dp-primary transition-all disabled:opacity-50">
                    <CheckCircle size={14} /> {t('sb.confirmBtn')}
                  </button>
                  <button onClick={() => act(r.id, 'reject_equipment_advance', 'sb.rejectedToast')} disabled={busyId === r.id} className="flex items-center gap-1.5 px-4 py-2 border border-dp-outline-variant text-dp-on-surface-variant rounded-lg font-sans text-[13px] font-semibold cursor-pointer hover:bg-dp-surface-container transition-all disabled:opacity-50">
                    <XCircle size={14} /> {t('sb.rejectBtn')}
                  </button>
                </div>
              </div>
            </div>
          ))}
        </div>
      )}

      {refunds.length > 0 && (
        <>
          <p className="font-sans text-[12px] font-bold uppercase tracking-[0.05em] text-dp-on-surface-variant mb-3">{t('ea.refundsHeading')}</p>
          <div className="space-y-3 mb-8">
            {refunds.map((r) => (
              <div key={r.id} className="bg-white border border-[#f2c48d] rounded-lg p-4 flex items-start justify-between gap-3">
                <div>{head(r)}</div>
                <div className="text-end shrink-0 flex flex-col items-end gap-2">
                  <p className="font-heading text-[18px] font-bold text-dp-secondary ltr-num">{fmt(r.advance_amount_pkr)}</p>
                  <button onClick={() => act(r.id, 'refund_equipment_advance', 'ea.refundedToast')} disabled={busyId === r.id} className="flex items-center gap-1.5 px-3 py-1.5 bg-dp-secondary text-white rounded-lg font-sans text-[12.5px] font-semibold cursor-pointer disabled:opacity-50">
                    <RotateCcw size={13} /> {t('ea.refundBtn')}
                  </button>
                </div>
              </div>
            ))}
          </div>
        </>
      )}

      <p className="font-sans text-[12px] font-bold uppercase tracking-[0.05em] text-dp-on-surface-variant mb-3">{t('sb.historyHeading')}</p>
      {history.length === 0 ? (
        <p className="font-sans text-[13.5px] text-dp-on-surface-variant">{t('sb.noHistoryYet')}</p>
      ) : (
        <div className="space-y-2">
          {history.map((r) => (
            <div key={r.id} className="bg-white border border-dp-outline-variant rounded-lg p-3.5 flex items-center justify-between gap-3">
              <div className="min-w-0">
                <p className="font-sans text-[13.5px] font-semibold text-dp-on-surface truncate">{r.customer_name} — {vehicleDisplayName(r.vehicle_type, r.model)} ({r.owner_name})</p>
                <p className="font-sans text-[12px] text-dp-on-surface-variant mt-0.5 truncate">{r.site_address}</p>
              </div>
              <div className="text-end shrink-0">
                <p className="font-sans text-[10.5px] font-bold" style={{ color: STATUS_COLOR[r.advance_status] ?? '#6b6560' }}>{t(`ea.status.${r.advance_status}`)}</p>
                <p className="font-heading text-[14px] font-bold text-dp-secondary ltr-num">{fmt(r.advance_amount_pkr)}</p>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  )
}
