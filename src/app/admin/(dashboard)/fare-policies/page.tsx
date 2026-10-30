'use client'

// The committee's fare policy per service (migration 776) — free travel
// radius, travel rate per km, maximum distance, advance %, the hourly
// overtime rule and full-day hours. What's saved here is exactly what
// the server charges by and what every rider booking window and driver
// screen shows as "Fare rules".

import { useEffect, useState } from 'react'
import { toast } from 'sonner'
import { Receipt, Save, Loader2 } from 'lucide-react'
import { createClient } from '@/lib/supabase/client'
import { friendlyError } from '@/lib/errors'
import { useSystemAccess } from '@/hooks/useSystemAccess'
import { useLocale } from '@/lib/i18n/LocaleProvider'
import { LoadingDots } from '@/components/shared/LoadingDots'
import { loadFarePolicies, type FarePolicy, type FareService } from '@/lib/farePolicy'

type Draft = Record<string, string>

const FIELDS: { key: keyof FarePolicy; services: FareService[] | 'all'; suffix?: string }[] = [
  { key: 'free_radius_km', services: ['machinery', 'tractor', 'loader', 'shadi'], suffix: 'km' },
  { key: 'travel_rate_per_km_pkr', services: ['machinery', 'tractor', 'loader', 'shadi'], suffix: '₨' },
  { key: 'max_distance_km', services: 'all', suffix: 'km' },
  { key: 'advance_pct', services: ['machinery', 'tractor', 'loader', 'shadi'], suffix: '%' },
  { key: 'overtime_grace_minutes', services: ['hourly'], suffix: 'min' },
  { key: 'overtime_block_minutes', services: ['hourly'], suffix: 'min' },
  { key: 'overtime_rate_pct', services: ['hourly'], suffix: '%' },
  { key: 'full_day_hours', services: ['shadi'], suffix: 'h' },
]

function toDraft(p: FarePolicy): Draft {
  const d: Draft = {}
  for (const [k, v] of Object.entries(p)) d[k] = v == null ? '' : String(v)
  return d
}
const num = (s: string) => (s.trim() === '' ? null : Number(s))

export default function AdminFarePoliciesPage() {
  const { t, isUrdu } = useLocale()
  const access = useSystemAccess()
  const [drafts, setDrafts] = useState<Record<string, Draft>>({})
  const [order, setOrder] = useState<FareService[]>([])
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState<string | null>(null)

  useEffect(() => {
    loadFarePolicies(true).then((all) => {
      setDrafts(Object.fromEntries(all.map((p) => [p.service_key, toDraft(p)])))
      setOrder(all.map((p) => p.service_key))
      setLoading(false)
    })
  }, [])

  const set = (svc: string, key: string, value: string) => setDrafts((d) => ({ ...d, [svc]: { ...d[svc], [key]: value } }))

  const save = async (svc: FareService) => {
    const d = drafts[svc]
    setSaving(svc)
    const { error } = await createClient().rpc('set_service_fare_policy', {
      p_service: svc,
      p_free_radius_km: num(d.free_radius_km ?? ''), p_travel_rate_per_km_pkr: num(d.travel_rate_per_km_pkr ?? ''),
      p_max_distance_km: num(d.max_distance_km ?? ''), p_advance_pct: num(d.advance_pct ?? ''),
      p_overtime_grace_minutes: num(d.overtime_grace_minutes ?? ''), p_overtime_block_minutes: num(d.overtime_block_minutes ?? ''),
      p_overtime_rate_pct: num(d.overtime_rate_pct ?? ''), p_full_day_hours: num(d.full_day_hours ?? ''),
      p_notes_en: d.notes_en ?? '', p_notes_ur: d.notes_ur ?? '',
    })
    setSaving(null)
    if (error) { toast.error(friendlyError(error)); return }
    loadFarePolicies(true)
    toast.success(t('fpa.savedToast'))
  }

  if (access.loading || loading) return <div className="text-center py-12 text-dp-on-surface-variant font-sans"><LoadingDots /></div>
  if (!access.canDonorsProjects) {
    return <div className="bg-white rounded-lg border border-dp-outline-variant p-8 text-center"><p className="font-sans text-[14px] text-dp-on-surface-variant">{t('sb.noAccessMessage')}</p></div>
  }

  return (
    <div dir={isUrdu ? 'rtl' : 'ltr'} className="shop-ink-theme">
      <div className="mb-6">
        <h1 className="font-heading text-[32px] font-bold leading-[40px] text-dp-primary flex items-center gap-2"><Receipt size={26} /> {t('fpa.pageTitle')}</h1>
        <p className="font-sans text-[13.5px] text-dp-on-surface-variant mt-1">{t('fpa.pageSubtitle')}</p>
      </div>
      <div className="grid gap-4 md:grid-cols-2">
        {order.map((svc) => {
          const d = drafts[svc] ?? {}
          return (
            <div key={svc} className="bg-white border border-dp-outline-variant rounded-lg p-5">
              <p className="font-sans text-[16px] font-bold text-dp-on-surface mb-3">{t(`fpa.service.${svc}`)}</p>
              <div className="grid grid-cols-2 gap-3">
                {FIELDS.filter((f) => f.services === 'all' || f.services.includes(svc)).map((f) => (
                  <label key={f.key} className="flex flex-col gap-1">
                    <span className="font-sans text-[12px] font-semibold text-dp-on-surface-variant">{t(`fpa.field.${f.key}`)} {f.suffix ? <span className="font-normal">({f.suffix})</span> : null}</span>
                    <input type="number" inputMode="decimal" min={0} value={d[f.key] ?? ''} onChange={(e) => set(svc, f.key, e.target.value)}
                      placeholder={f.key === 'max_distance_km' ? t('fpa.noLimit') : ''} className="dp2-input text-[14px] ltr-num" />
                  </label>
                ))}
              </div>
              <label className="flex flex-col gap-1 mt-3">
                <span className="font-sans text-[12px] font-semibold text-dp-on-surface-variant">{t('fpa.field.notes_en')}</span>
                <textarea value={d.notes_en ?? ''} onChange={(e) => set(svc, 'notes_en', e.target.value)} rows={2} className="dp2-input text-[13.5px]" />
              </label>
              <label className="flex flex-col gap-1 mt-2">
                <span className="font-sans text-[12px] font-semibold text-dp-on-surface-variant">{t('fpa.field.notes_ur')}</span>
                <textarea dir="rtl" value={d.notes_ur ?? ''} onChange={(e) => set(svc, 'notes_ur', e.target.value)} rows={2} className="dp2-input text-[13.5px]" />
              </label>
              <button onClick={() => save(svc)} disabled={saving === svc} className="mt-3 flex items-center gap-1.5 px-4 py-2 bg-dp-secondary text-white rounded-lg font-sans text-[13px] font-semibold cursor-pointer hover:bg-dp-primary disabled:opacity-50">
                {saving === svc ? <Loader2 size={14} className="animate-spin" /> : <Save size={14} />} {t('fpa.saveBtn')}
              </button>
            </div>
          )
        })}
      </div>
    </div>
  )
}
