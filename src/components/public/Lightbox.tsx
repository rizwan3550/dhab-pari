'use client'

import { useEffect, useRef } from 'react'
import Image, { getImageProps } from 'next/image'
import { X, ChevronLeft, ChevronRight } from 'lucide-react'

interface LightboxImage { url: string; caption?: string | null; type?: string }

/**
 * A minimal full-screen photo viewer — click a thumbnail, see it large,
 * step through the rest of the gallery without leaving the page. No
 * external library: a small self-contained component is less to carry
 * than a dependency for it. Used by the project gallery and /gallery.
 *
 * Phone-first: swipe left/right to step, arrow keys and Esc on desktop,
 * the page behind it doesn't scroll, and the neighbouring photos are
 * fetched in the background so the next swipe is instant rather than a
 * blank frame while it downloads.
 */
export function Lightbox({
  images, index, onClose, onNavigate,
}: {
  images: LightboxImage[]
  index: number
  onClose: () => void
  onNavigate: (index: number) => void
}) {
  const touchStartX = useRef<number | null>(null)
  const open = index >= 0 && index < images.length
  const count = images.length
  const prev = () => onNavigate((index - 1 + count) % count)
  const next = () => onNavigate((index + 1) % count)

  useEffect(() => {
    if (!open) return
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose()
      else if (e.key === 'ArrowLeft' && count > 1) onNavigate((index - 1 + count) % count)
      else if (e.key === 'ArrowRight' && count > 1) onNavigate((index + 1) % count)
    }
    const previousOverflow = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    window.addEventListener('keydown', onKey)
    return () => {
      document.body.style.overflow = previousOverflow
      window.removeEventListener('keydown', onKey)
    }
  }, [open, index, count, onClose, onNavigate])

  // Warm the browser cache for the photos a swipe will show next, using
  // the exact optimized srcset the <Image> below will request.
  useEffect(() => {
    if (!open || count < 2) return
    for (const n of [images[(index + 1) % count], images[(index - 1 + count) % count]]) {
      if (n.type === 'video') continue
      const { props } = getImageProps({ src: n.url, alt: '', fill: true, sizes: '92vw' })
      const pre = new window.Image()
      pre.sizes = '92vw'
      if (props.srcSet) pre.srcset = props.srcSet
      pre.src = props.src
    }
  }, [open, index, count, images])

  if (!open) return null
  const img = images[index]

  const onTouchStart = (e: React.TouchEvent) => { touchStartX.current = e.touches[0].clientX }
  const onTouchEnd = (e: React.TouchEvent) => {
    if (touchStartX.current === null || count < 2) return
    const dx = e.changedTouches[0].clientX - touchStartX.current
    touchStartX.current = null
    if (Math.abs(dx) < 50) return
    if (dx < 0) next()
    else prev()
  }

  return (
    <div
      className="fixed inset-0 bg-black/95 z-[200] flex items-center justify-center p-4 select-none"
      onClick={onClose}
      onTouchStart={onTouchStart}
      onTouchEnd={onTouchEnd}
      role="dialog"
      aria-modal="true"
    >
      <button onClick={onClose} className="absolute top-3 end-3 text-white/90 hover:text-white bg-white/10 hover:bg-white/20 rounded-full p-2 cursor-pointer z-10 transition-colors" aria-label="Close">
        <X size={22} />
      </button>

      {count > 1 && (
        <p className="absolute top-5 start-4 font-sans text-[12.5px] font-semibold text-white/70 ltr-num z-10" dir="ltr">{index + 1} / {count}</p>
      )}

      {count > 1 && (
        <button
          onClick={(e) => { e.stopPropagation(); prev() }}
          className="hidden sm:flex absolute start-4 text-white/90 hover:text-white bg-white/10 hover:bg-white/20 rounded-full p-2 cursor-pointer z-10 transition-colors"
          aria-label="Previous"
        >
          <ChevronLeft size={26} />
        </button>
      )}

      <div className="relative max-w-[92vw] max-h-[80vh] w-full h-full flex items-center justify-center" onClick={(e) => e.stopPropagation()}>
        {img.type === 'video' ? (
          <video key={img.url} src={img.url} controls autoPlay playsInline className="max-w-full max-h-full rounded-lg" />
        ) : (
          <Image key={img.url} src={img.url} alt={img.caption ?? ''} fill sizes="92vw" priority className="object-contain" />
        )}
      </div>

      {count > 1 && (
        <button
          onClick={(e) => { e.stopPropagation(); next() }}
          className="hidden sm:flex absolute end-4 text-white/90 hover:text-white bg-white/10 hover:bg-white/20 rounded-full p-2 cursor-pointer z-10 transition-colors"
          aria-label="Next"
        >
          <ChevronRight size={26} />
        </button>
      )}

      {img.caption && (
        <div className="absolute bottom-0 inset-x-0 px-5 pt-10 pb-6 bg-gradient-to-t from-black/80 to-transparent pointer-events-none">
          <p dir="auto" className="font-sans text-[14px] text-white/95 text-center leading-relaxed max-w-2xl mx-auto">{img.caption}</p>
        </div>
      )}
    </div>
  )
}
