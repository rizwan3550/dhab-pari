'use client'

import { useEffect, useState } from 'react'
import { createClient } from '@/lib/supabase/client'
import Link from 'next/link'
import { Play, Eye, Clapperboard } from 'lucide-react'
import { youtubeThumbnailUrl } from '@/lib/videoEmbed'
import { useLocale } from '@/lib/i18n/LocaleProvider'

interface Video {
  id: string
  title: string
  title_ur: string | null
  description: string | null
  video_url: string
  thumbnail_url: string | null
  category: string | null
  duration_seconds: number | null
  is_featured: boolean
  views: number
}

const categoryTabs = [
  'All',
  'Interview',
  'Wedding',
  'Event',
  'Sports',
  'Documentary',
  'Project',
  'Freelancing',
]

const categoryTabKeys: Record<string, string> = {
  All: 'x.catAll',
  Interview: 'x.catInterview',
  Wedding: 'x.catWedding',
  Event: 'x.catEvent',
  Sports: 'x.catSports',
  Documentary: 'x.catDocumentary',
  Project: 'x.catProject',
  Freelancing: 'x.catFreelancing',
}

const categoryBadgeKeys: Record<string, string> = {
  interview: 'x.catInterview',
  wedding: 'x.catWedding',
  event: 'x.catEvent',
  sports: 'x.catSports',
  documentary: 'x.catDocumentary',
  project: 'x.catProject',
  news: 'x.catNews',
  freelancing: 'x.catFreelancing',
}

const categoryBadgeColors: Record<string, string> = {
  interview: 'bg-blue-600',
  wedding: 'bg-pink-600',
  event: 'bg-indigo-600',
  sports: 'bg-emerald-600',
  documentary: 'bg-amber-600',
  project: 'bg-dp2-primary-dark',
  news: 'bg-red-600',
  freelancing: 'bg-dp2-primary-dark',
}

function formatDuration(seconds: number | null) {
  if (!seconds) return '0:00'
  const m = Math.floor(seconds / 60)
  const s = seconds % 60
  return `${m}:${s.toString().padStart(2, '0')}`
}

export default function VideosPage() {
  const { t, isUrdu } = useLocale()
  const [videos, setVideos] = useState<Video[]>([])
  const [activeTab, setActiveTab] = useState('All')
  const [loading, setLoading] = useState(true)

  // Real bug, 2026-10-17: a transient fetch failure here used to look
  // identical to "genuinely no videos" — data ?? [] swallowed any error
  // silently, with no retry and nothing visible in the console. One
  // automatic retry covers the common transient case (a momentary auth
  // token refresh or network blip); a real, persisting error at least
  // now logs instead of vanishing.
  useEffect(() => {
    const supabase = createClient()
    let cancelled = false
    async function load(attempt = 1) {
      const { data, error } = await supabase
        .from('video_content')
        .select('*')
        .eq('is_published', true)
        .order('created_at', { ascending: false })
      if (cancelled) return
      if (error) {
        console.error('Failed to load videos', error)
        if (attempt < 2) { setTimeout(() => load(attempt + 1), 800); return }
      }
      setVideos(data ?? [])
      setLoading(false)
    }
    load()
    return () => { cancelled = true }
  }, [])

  const filtered =
    activeTab === 'All'
      ? videos
      : videos.filter(
          (v) => v.category?.toLowerCase() === activeTab.toLowerCase()
        )

  // Only offer the categories that actually have something in them — a
  // row of tabs that each lead to "no videos" reads as a broken page.
  const visibleTabs = loading
    ? categoryTabs
    : categoryTabs.filter((tab) => tab === 'All' || videos.some((v) => v.category?.toLowerCase() === tab.toLowerCase()))

  const featured = activeTab === 'All' ? videos.filter((v) => v.is_featured) : []
  const hero = featured[0] ?? null
  const rest = filtered.filter((v) => v.id !== hero?.id)

  return (
    <div className="max-w-[1200px] mx-auto px-4 sm:px-6 md:px-12 py-8 md:py-10 min-h-screen" dir={isUrdu ? 'rtl' : 'ltr'} style={isUrdu ? { fontFamily: 'var(--font-urdu-ui)' } : undefined}>
      {/* Header */}
      <div className="mb-5">
        <h1 className="font-heading text-[20px] md:text-[23px] font-bold leading-snug text-dp2-primary section-title">
          {t('x.videoLibrary')}
        </h1>
        <p className="text-slate-500 font-sans text-[15px] leading-relaxed mt-1.5">
          {t('x.videoLibrarySubtitle')}
        </p>
      </div>

      {/* Category chips — one swipeable row on a phone instead of three
          wrapped rows of oversized pills. */}
      <div className="-mx-4 sm:mx-0 px-4 sm:px-0 mb-6 flex gap-2 overflow-x-auto hide-scrollbar">
        {visibleTabs.map((tab) => (
          <button
            key={tab}
            onClick={() => setActiveTab(tab)}
            className={`shrink-0 px-3.5 py-1.5 rounded-full font-sans text-[13px] font-semibold transition-colors cursor-pointer ${
              activeTab === tab
                ? 'bg-dp2-primary text-white'
                : 'bg-white border border-dp2-card-border text-slate-600 hover:border-dp2-primary hover:text-dp2-primary'
            }`}
          >
            {t(categoryTabKeys[tab])}
          </button>
        ))}
      </div>

      {/* Loading */}
      {loading && (
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-x-4 gap-y-6">
          {[1, 2, 3, 4, 5, 6].map((i) => (
            <div key={i}>
              <div className="aspect-video bg-slate-200/70 rounded-xl animate-pulse" />
              <div className="h-3.5 bg-slate-200/70 rounded mt-3 w-4/5 animate-pulse" />
              <div className="h-3 bg-slate-200/70 rounded mt-2 w-1/3 animate-pulse" />
            </div>
          ))}
        </div>
      )}

      {!loading && filtered.length === 0 && (
        <div className="flex flex-col items-center text-center py-16 text-slate-500 font-sans text-[15px] gap-3">
          <Clapperboard size={36} className="text-slate-300" />
          {t('x.noVideosCategory')}
        </div>
      )}

      {!loading && filtered.length > 0 && (
        <div className="space-y-8">
          {hero && <HeroVideo video={hero} />}

          {rest.length > 0 && (
            <section>
              {hero && (
                <h2 className="font-heading text-[17px] font-bold leading-snug text-dp2-primary mb-4">
                  {t('x.allVideos')}
                </h2>
              )}
              <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-x-4 gap-y-6">
                {rest.map((video) => (
                  <VideoCard key={video.id} video={video} />
                ))}
              </div>
            </section>
          )}
        </div>
      )}
    </div>
  )
}

function thumbnailOf(video: Video) {
  return video.thumbnail_url || youtubeThumbnailUrl(video.video_url)
}

function CategoryBadge({ video }: { video: Video }) {
  const { t } = useLocale()
  if (!video.category) return null
  return (
    <span className={`text-[10.5px] font-bold uppercase tracking-wider font-sans text-white px-2 py-0.5 rounded ${categoryBadgeColors[video.category] ?? 'bg-dp2-primary'}`}>
      {t(categoryBadgeKeys[video.category.toLowerCase()] ?? '', video.category)}
    </span>
  )
}

function Thumb({ video, large }: { video: Video; large?: boolean }) {
  const src = thumbnailOf(video)
  return (
    <div className="relative aspect-video rounded-xl overflow-hidden bg-slate-900">
      {src ? (
        // eslint-disable-next-line @next/next/no-img-element
        <img src={src} alt="" loading={large ? 'eager' : 'lazy'} decoding="async" className="absolute inset-0 w-full h-full object-cover group-hover:scale-[1.03] transition-transform duration-500" />
      ) : (
        <div className="absolute inset-0 bg-gradient-to-br from-dp2-primary to-dp2-primary-dark" />
      )}
      <div className="absolute inset-0 bg-black/10 group-hover:bg-black/25 transition-colors" />
      <div className="absolute inset-0 flex items-center justify-center">
        <div className={`${large ? 'w-16 h-16' : 'w-12 h-12'} bg-black/45 backdrop-blur-sm rounded-full flex items-center justify-center ring-1 ring-white/30 group-hover:scale-110 group-hover:bg-red-600 transition-all`}>
          <Play size={large ? 26 : 20} className="text-white ms-0.5" fill="white" />
        </div>
      </div>
      {video.duration_seconds ? (
        <div dir="ltr" className="absolute bottom-2 end-2 bg-black/75 text-white text-[11.5px] font-semibold px-1.5 py-0.5 rounded font-sans">
          {formatDuration(video.duration_seconds)}
        </div>
      ) : null}
    </div>
  )
}

function VideoTitle({ video, className }: { video: Video; className: string }) {
  const { isUrdu } = useLocale()
  // title is always English (no _ur column for it); title_ur is optional.
  // Show the visitor's own language first — dir pinned per string so a
  // clamp never cuts an English title from the wrong end under Urdu.
  if (isUrdu && video.title_ur) {
    return <h3 dir="rtl" className={`${className} text-start`} style={{ fontFamily: 'var(--font-urdu-ui)' }}>{video.title_ur}</h3>
  }
  return <h3 dir="ltr" className={`${className} text-start`}>{video.title}</h3>
}

function HeroVideo({ video }: { video: Video }) {
  const { t } = useLocale()
  return (
    <Link href={`/videos/${video.id}`} className="group block">
      <div className="relative">
        <Thumb video={video} large />
        <div className="absolute top-3 start-3 flex items-center gap-1.5">
          <span className="text-[10.5px] font-bold uppercase tracking-wider font-sans text-dp2-primary-dark bg-dp2-amber px-2 py-0.5 rounded">{t('x.featured')}</span>
          <CategoryBadge video={video} />
        </div>
      </div>
      <div className="mt-3">
        <VideoTitle video={video} className="font-sans font-bold text-[17px] md:text-[19px] leading-snug text-slate-900 line-clamp-2 group-hover:text-dp2-primary transition-colors" />
        {video.description && (
          <p dir="auto" className="text-slate-500 text-[14px] font-sans leading-relaxed mt-1 line-clamp-2 text-start">{video.description}</p>
        )}
        <div className="flex items-center gap-1.5 mt-1.5 text-slate-500 text-[12.5px] font-sans">
          <Eye size={13} />
          <span>{video.views.toLocaleString()} {t('x.views')}</span>
        </div>
      </div>
    </Link>
  )
}

function VideoCard({ video }: { video: Video }) {
  const { t } = useLocale()
  return (
    <Link href={`/videos/${video.id}`} className="group block">
      <Thumb video={video} />
      <div className="mt-2.5 flex gap-2.5">
        <div className="min-w-0 flex-1">
          <VideoTitle video={video} className="font-sans font-semibold text-[15px] leading-snug text-slate-900 line-clamp-2 group-hover:text-dp2-primary transition-colors" />
          <div className="flex items-center flex-wrap gap-x-2 gap-y-1 mt-1.5 text-slate-500 text-[12.5px] font-sans">
            <CategoryBadge video={video} />
            <span className="inline-flex items-center gap-1"><Eye size={12} /> {video.views.toLocaleString()} {t('x.views')}</span>
          </div>
        </div>
      </div>
    </Link>
  )
}
