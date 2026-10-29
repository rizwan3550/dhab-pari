'use client'

import { useEffect, useState } from 'react'
import Image from 'next/image'
import { createClient } from '@/lib/supabase/client'
import { motion } from 'motion/react'
import { Images, ChevronLeft, PlayCircle } from 'lucide-react'
import { useLocale } from '@/lib/i18n/LocaleProvider'
import { Lightbox } from '@/components/public/Lightbox'

interface Album {
  id: string
  title: string
  title_ur: string | null
  category: string | null
  cover_url: string | null
}

interface GalleryItem {
  id: string
  album_id: string
  url: string
  caption: string | null
  type: string
  display_order: number
}

const categoryColors: Record<string, string> = {
  projects: 'from-dp2-primary-dark to-amber-600',
  sports: 'from-emerald-600 to-emerald-800',
  kids: 'from-blue-500 to-blue-700',
  events: 'from-indigo-500 to-indigo-700',
  weddings: 'from-pink-500 to-pink-700',
  interviews: 'from-amber-500 to-amber-700',
}

export default function GalleryPage() {
  const { t, isUrdu } = useLocale()
  const [albums, setAlbums] = useState<Album[]>([])
  const [items, setItems] = useState<GalleryItem[]>([])
  const [selectedAlbum, setSelectedAlbum] = useState<string | null>(null)
  const [itemsLoading, setItemsLoading] = useState(false)
  const [lightboxIndex, setLightboxIndex] = useState(-1)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    const supabase = createClient()
    supabase
      .from('gallery_albums')
      .select('*')
      .order('display_order')
      .then(({ data }) => {
        setAlbums(data ?? [])
        setLoading(false)
      })
  }, [])

  const loadAlbumItems = async (albumId: string) => {
    setSelectedAlbum(albumId)
    setItemsLoading(true)
    window.scrollTo({ top: 0, behavior: 'smooth' })
    const supabase = createClient()
    const { data } = await supabase
      .from('gallery_items')
      .select('*')
      .eq('album_id', albumId)
      .order('display_order')
    setItems(data ?? [])
    setItemsLoading(false)
  }

  const closeAlbum = () => {
    setSelectedAlbum(null)
    setItems([])
    setLightboxIndex(-1)
  }

  const selectedAlbumData = albums.find((a) => a.id === selectedAlbum)
  const albumTitle = (a: Album) => (isUrdu && a.title_ur) || a.title

  return (
    <div className="max-w-[1200px] mx-auto px-4 sm:px-6 md:px-12 py-8 md:py-10 min-h-screen">
      {/* Header */}
      <div className="mb-6 md:mb-8">
        <h1 className="font-heading text-[20px] md:text-[23px] font-bold leading-snug text-dp2-primary section-title">
          {t('x.photoVideoGallery')}
        </h1>
        <p className="text-slate-500 font-sans text-[15px] leading-relaxed mt-1.5">
          {t('x.galleryIntro')}
        </p>
      </div>

      {/* Loading */}
      {loading && (
        <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-3 md:gap-4">
          {[1, 2, 3, 4].map((i) => (
            <div key={i} className="aspect-[4/5] bg-slate-200/70 rounded-2xl animate-pulse" />
          ))}
        </div>
      )}

      {/* Albums Grid (when no album selected) */}
      {!loading && !selectedAlbum && (
        <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-3 md:gap-4">
          {albums.map((album, i) => {
            const gradient = categoryColors[album.category ?? ''] ?? 'from-dp2-primary to-dp2-primary-dark'
            return (
              <motion.button
                key={album.id}
                initial={{ opacity: 0, y: 12 }}
                animate={{ opacity: 1, y: 0 }}
                transition={{ duration: 0.3, delay: Math.min(i * 0.04, 0.3) }}
                onClick={() => loadAlbumItems(album.id)}
                className="relative aspect-[4/5] rounded-2xl overflow-hidden group cursor-pointer text-start shadow-sm ring-1 ring-black/5 active:scale-[0.98] transition-transform"
              >
                {album.cover_url ? (
                  <Image
                    src={album.cover_url} alt={albumTitle(album)} fill
                    sizes="(min-width: 1024px) 25vw, (min-width: 768px) 33vw, 50vw"
                    priority={i < 4}
                    className="object-cover group-hover:scale-105 transition-transform duration-500"
                  />
                ) : (
                  <div className={`absolute inset-0 bg-gradient-to-br ${gradient} flex items-center justify-center`}>
                    <Images size={34} className="text-white/60" />
                  </div>
                )}
                <div className="absolute inset-0 bg-gradient-to-t from-black/80 via-black/15 to-transparent" />
                {album.category && (
                  <span className="absolute top-2.5 start-2.5 text-[10.5px] font-sans font-bold tracking-wide uppercase text-white bg-black/35 backdrop-blur-sm px-2 py-0.5 rounded-full">
                    {album.category}
                  </span>
                )}
                <div className="absolute inset-x-0 bottom-0 p-3">
                  <h3 className="font-heading text-[14px] md:text-[16px] font-bold text-white leading-snug line-clamp-2 drop-shadow">
                    {albumTitle(album)}
                  </h3>
                </div>
              </motion.button>
            )
          })}
          {albums.length === 0 && (
            <div className="col-span-full flex flex-col items-center text-center py-16 text-slate-500 font-sans gap-3">
              <Images size={36} className="text-slate-300" />
              {t('x.noAlbums')}
            </div>
          )}
        </div>
      )}

      {/* Album Items View */}
      {selectedAlbum && selectedAlbumData && (
        <div>
          <div className="sticky top-0 z-20 -mx-4 sm:-mx-6 md:mx-0 px-4 sm:px-6 md:px-0 py-3 mb-4 bg-dp2-surface/95 backdrop-blur flex items-center gap-3">
            <button
              onClick={closeAlbum}
              className="shrink-0 flex items-center gap-1 ps-2 pe-3 py-1.5 rounded-full bg-white border border-dp2-card-border text-dp2-primary-dark font-sans text-[13px] font-semibold hover:bg-dp2-primary-dark hover:text-white transition-colors cursor-pointer"
            >
              <ChevronLeft size={16} />
              {t('x.backToAlbums')}
            </button>
            <h2 className="min-w-0 font-heading text-[16px] md:text-[18px] font-bold leading-snug text-dp2-primary truncate">
              {albumTitle(selectedAlbumData)}
            </h2>
            {!itemsLoading && items.length > 0 && (
              <span className="ms-auto shrink-0 text-[12px] font-sans font-semibold text-slate-500 ltr-num" dir="ltr">{items.length}</span>
            )}
          </div>

          {/* Uniform square grid: optimized thumbnails at the size they are
              shown, rather than every original photo at full resolution. */}
          <div className="grid grid-cols-3 md:grid-cols-4 lg:grid-cols-5 gap-1 md:gap-2">
            {itemsLoading && Array.from({ length: 9 }).map((_, i) => (
              <div key={i} className="aspect-square bg-slate-200/70 rounded-md md:rounded-lg animate-pulse" />
            ))}
            {!itemsLoading && items.map((item, i) => (
              <button
                key={item.id}
                onClick={() => setLightboxIndex(i)}
                className="relative aspect-square rounded-md md:rounded-lg overflow-hidden bg-slate-200 cursor-pointer group"
                aria-label={item.caption ?? undefined}
              >
                {item.type === 'video' ? (
                  <>
                    <video src={`${item.url}#t=0.1`} className="absolute inset-0 w-full h-full object-cover" muted playsInline preload="metadata" />
                    <div className="absolute inset-0 flex items-center justify-center bg-black/25">
                      <PlayCircle size={32} className="text-white drop-shadow" />
                    </div>
                  </>
                ) : (
                  <Image
                    src={item.url} alt={item.caption ?? ''} fill
                    sizes="(min-width: 1024px) 20vw, (min-width: 768px) 25vw, 33vw"
                    priority={i < 6}
                    className="object-cover group-hover:scale-105 transition-transform duration-300"
                  />
                )}
              </button>
            ))}
          </div>

          {!itemsLoading && items.length === 0 && (
            <div className="text-center py-16 text-slate-500 font-sans">
              {t('x.noItemsAlbum')}
            </div>
          )}
        </div>
      )}

      <Lightbox
        images={items.map((it) => ({ url: it.url, caption: it.caption, type: it.type }))}
        index={lightboxIndex}
        onClose={() => setLightboxIndex(-1)}
        onNavigate={setLightboxIndex}
      />
    </div>
  )
}
