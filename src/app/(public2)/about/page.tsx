import type { Metadata } from 'next'
import Image from 'next/image'
import { createClient, createPublicClient } from '@/lib/supabase/server'
import { getPublicSiteContext } from '@/lib/publicSite'
import { getCookieTenantId } from '@/lib/tenant'

export async function generateMetadata(): Promise<Metadata> {
  const site = await getPublicSiteContext(await createClient(), await getCookieTenantId())
  return {
    title: 'About & Committee',
    description: `Meet the ${site.fullName} — village history, vision, mission, and team members.`,
  }
}

// Nothing on this page is per-visitor — committee roster, vision/mission,
// and village history all change rarely. Caching for 5 minutes turns every
// visit's full server render + DB round trip into one shared cached page.
export const revalidate = 300
import { Phone, Eye, Target } from 'lucide-react'
import { T, Bi, LocaleDir } from '@/components/i18n/T'
import { CommitteeAnnouncementsArchive } from '@/components/home/CommitteeAnnouncementsArchive'
import { messages } from '@/lib/i18n/messages'

const initialsColors = [
  'bg-dp2-primary-dark text-emerald-100',
  'bg-dp2-primary-dark text-white',
  'bg-amber-100 text-amber-800',
  'bg-amber-500 text-white',
  'bg-blue-600 text-white',
  'bg-rose-500 text-white',
]

export default async function AboutPage() {
  const supabase = await createClient()
  const site = await getPublicSiteContext(supabase, await getCookieTenantId())

  // All three queries in parallel rather than one after another — each
  // was a full database round trip before this page could start rendering.
  const publicSupabase = await createPublicClient()
  const [{ data: members }, { data: notesRaw }, { data: settings }] = await Promise.all([
    supabase
      .from('committee_members')
      .select('*')
      .eq('is_active', true)
      .order('display_order'),
    // Ordered by when it was actually posted, not release_date — same
    // reasoning as the homepage card's identical query: keeps this archive's
    // top entry in agreement with whichever note the homepage is featuring,
    // rather than the two disagreeing whenever a release_date gets set to an
    // earlier day than a genuinely newer post. Public client: same reason as
    // the homepage (anon-only policy until migration 773).
    publicSupabase
      .from('committee_notes')
      .select('id, body_en, body_ur, release_date, linked_project_id, link_url, link_label_en, link_label_ur, projects(title, title_ur)')
      .eq('is_published', true)
      .order('created_at', { ascending: false }),
    supabase
      .from('site_settings')
      .select('key, value')
      .in('key', ['about_text', 'about_text_ur', 'vision', 'vision_ur', 'mission', 'mission_ur', 'display_language']),
  ])

  const allMembers = members ?? []

  const committeeNotes = ((notesRaw ?? []) as unknown as {
    id: string; body_en: string; body_ur: string; release_date: string; linked_project_id: string | null
    link_url: string | null; link_label_en: string | null; link_label_ur: string | null
    projects: { title: string; title_ur: string | null } | { title: string; title_ur: string | null }[] | null
  }[]).map((n) => {
    const proj = Array.isArray(n.projects) ? n.projects[0] : n.projects
    return {
      id: n.id, body_en: n.body_en, body_ur: n.body_ur, release_date: n.release_date,
      project_id: n.linked_project_id, project_title: proj?.title ?? null, project_title_ur: proj?.title_ur ?? null,
      link_url: n.link_url, link_label_en: n.link_label_en, link_label_ur: n.link_label_ur,
    }
  })

  const settingsMap: Record<string, string> = {}
  settings?.forEach((s) => { settingsMap[s.key] = s.value ?? '' })

  // Both languages are rendered here and the visitor's own toggle picks one
  // in the browser (<Bi>/<LocaleDir>), same as every other public page now —
  // this page used to follow only the site-wide display_language setting,
  // so an Urdu reader saw it entirely in English under an Urdu header.
  const history = (lang: 'en' | 'ur') => {
    const m = messages[lang]
    return {
      p1: m['x.villageHistoryP1']
        .replaceAll('{name}', lang === 'ur' ? site.nameUrdu : site.name)
        .replaceAll('{district}', site.district)
        .replaceAll('{province}', site.province),
      p2: m['x.villageHistoryP2'].replaceAll('{established}', site.established),
      heading: m['x.aboutHeading'].replaceAll('{name}', lang === 'ur' ? site.nameUrdu : site.name),
    }
  }
  const historyEn = history('en')
  const historyUr = history('ur')

  // Migration 508 added the _ur counterparts these three never had. <Bi>
  // falls back to the English value when the Urdu setting is blank (never
  // to a hardcoded literal — an admin who edits about_text should see that
  // change reflected even before they've filled in the Urdu version).
  const aboutTextEn = settingsMap.about_text || `Dedicated to the prosperity and welfare of ${site.name} village through transparent management and community support.`
  const visionEn = settingsMap.vision || `A self-sustaining village with modern infrastructure for every household.`
  const missionEn = settingsMap.mission || 'To provide transparent governance, efficient water management, and community-driven development through collective effort.'

  return (
    <div className="max-w-[1200px] mx-auto px-6 md:px-12 py-10 min-h-screen">
      {/* Header */}
      <div className="mb-12 text-center max-w-3xl mx-auto">
        <h1 className="font-heading text-[20px] md:text-[32px] font-bold leading-snug text-dp2-primary mb-3">
          <Bi en={historyEn.heading} ur={historyUr.heading} />
        </h1>
        {site.committeeUrdu && (
          <p
            className="text-slate-500 text-[17px] mb-2"
            style={{ fontFamily: 'var(--font-urdu-ui)', lineHeight: '1.6' }}
          >
            {site.committeeUrdu}
          </p>
        )}
      </div>

      {/* Village History */}
      <section className="mb-16">
        <LocaleDir className="bg-white border border-dp2-card-border rounded-2xl p-6 md:p-12">
          <h2 className="font-heading text-[15px] font-bold leading-[24px] text-dp2-primary mb-6">
            <T k="x.villageHistory" />
          </h2>
          <div className="prose max-w-none">
            <p className="font-sans text-[15px] leading-relaxed text-slate-500 mb-4">
              <Bi en={historyEn.p1} ur={historyUr.p1} />
            </p>
            <p className="font-sans text-[15px] leading-relaxed text-slate-500 mb-4">
              <Bi en={historyEn.p2} ur={historyUr.p2} />
            </p>
            <p className="font-sans text-[15px] leading-relaxed text-slate-500">
              <Bi en={aboutTextEn} ur={settingsMap.about_text_ur} />
            </p>
          </div>
        </LocaleDir>
      </section>

      {/* Vision + Mission.
          dir added here (was missing entirely before -- this section never
          flipped, unlike Village History above it), and each body paragraph
          gets its own dir="ltr" guard for the same reason as about_text:
          only when it's actually showing the English fallback, so a filled-
          in Urdu translation still reads correctly RTL. */}
      <LocaleDir className="mb-16 grid grid-cols-1 md:grid-cols-2 gap-4 md:gap-6">
        <div className="bg-dp2-primary text-white rounded-xl p-8 relative overflow-hidden">
          <div className="relative z-10">
            <div className="flex items-center gap-3 mb-4">
              <Eye size={24} className="text-emerald-200" />
              <h2 className="font-heading text-[15px] font-bold leading-[24px]">
                <T k="x.ourVision" />
              </h2>
            </div>
            <p className="font-sans text-[15px] leading-relaxed opacity-90">
              <Bi en={visionEn} ur={settingsMap.vision_ur} />
            </p>
          </div>
          <div className="absolute -bottom-8 -right-8 w-32 h-32 bg-white/5 rounded-full blur-2xl" />
        </div>

        <div className="bg-white border border-dp2-card-border rounded-2xl p-8 relative overflow-hidden">
          <div className="relative z-10">
            <div className="flex items-center gap-3 mb-4">
              <Target size={24} className="text-dp2-primary-dark" />
              <h2 className="font-heading text-[15px] font-bold leading-[24px] text-dp2-primary section-title">
                <T k="x.ourMission" />
              </h2>
            </div>
            <p className="font-sans text-[15px] leading-relaxed text-slate-500">
              <Bi en={missionEn} ur={settingsMap.mission_ur} />
            </p>
          </div>
        </div>
      </LocaleDir>

      {/* Committee Members */}
      <section>
        <div className="text-center mb-10">
          <h2 className="font-heading text-[20px] md:text-[23px] font-bold leading-[28px] text-dp2-primary mb-2">
            <T k="x.committeeMembers" />
          </h2>
          <p className="text-slate-500 font-sans text-[15px]">
            <T k="x.peopleDrivingChange" />
          </p>
        </div>

        <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-3 md:gap-5">
          {allMembers.map((member, i) => {
            const initials = member.name
              .split(' ')
              .map((w: string) => w[0])
              .join('')
              .slice(0, 2)
              .toUpperCase()
            const color = initialsColors[i % initialsColors.length]
            return (
              <div
                key={member.id}
                className="bg-white border border-dp2-card-border rounded-2xl p-4 md:p-6 text-center hover:border-dp2-primary-dark transition-colors"
              >
                {member.photo_url ? (
                  // Eager, and priority for the first rows: the grid is
                  // short, and lazy-loading made photos pop in one by one
                  // as the page scrolled. The tinted circle behind each
                  // one holds its space while it downloads.
                  <Image
                    src={member.photo_url} alt={member.name} width={80} height={80} sizes="80px"
                    priority={i < 6} loading={i < 6 ? undefined : 'eager'}
                    className="w-20 h-20 rounded-full object-cover mx-auto mb-3 bg-slate-100 ring-2 ring-dp2-primary/10"
                  />
                ) : (
                  <div className={`w-20 h-20 rounded-full ${color} flex items-center justify-center font-bold font-sans text-[20px] mx-auto mb-3`}>
                    {initials}
                  </div>
                )}
                <h3 className="font-sans text-[15px] font-bold text-slate-800 leading-snug">
                  {member.name}
                </h3>
                {member.name_ur && (
                  <p
                    className="text-slate-500 text-[15px] mt-1"
                    style={{ fontFamily: 'var(--font-urdu-ui)', lineHeight: '2' }}
                  >
                    {member.name_ur}
                  </p>
                )}
                <p className="text-dp2-primary-dark font-sans text-[13px] font-semibold mt-1.5">
                  <Bi en={member.position} ur={member.position_ur} />
                </p>
                {member.phone && (
                  <a
                    href={`tel:${member.phone.replace(/-/g, '')}`}
                    dir="ltr" className="inline-flex items-center gap-1 mt-2 text-slate-500 text-[13px] font-sans hover:text-dp2-primary transition-colors"
                  >
                    <Phone size={14} />
                    {member.phone}
                  </a>
                )}
                {(member.bio || member.bio_ur) && (
                  <p className="text-slate-500 text-[13.5px] font-sans mt-2 line-clamp-2">
                    <Bi en={member.bio || member.bio_ur} ur={member.bio_ur} />
                  </p>
                )}
              </div>
            )
          })}
        </div>

        {allMembers.length === 0 && (
          <div className="text-center py-16 text-slate-500 font-sans">
            <T k="x.noCommitteeMembers" />
          </div>
        )}
      </section>

      {/* Committee Announcements — every note ever posted, date-wise, not
          just the latest one the homepage card carries. */}
      <section className="mt-16">
        <CommitteeAnnouncementsArchive notes={committeeNotes} />
      </section>
    </div>
  )
}
