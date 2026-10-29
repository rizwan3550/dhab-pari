import Image from 'next/image'

// Phase 1 of the card-based redesign, 2026-10-12. The new design's own
// `image-slot` placeholder, backed by a real image two ways: `src`
// (an existing real column -- project.before_image_url, a classified's
// photo_url, a video's thumbnail_url) or `slotImages[slotKey]` (the new
// site_card_images table, for the committee logo and the decorative
// welfare/mentor thumbnails with no natural column of their own). Either
// way this renders at exactly the size/shape its wrapping element gives
// it (absolute inset-0, matching every card slot in the design), never
// its own intrinsic size -- card dimensions stay identical whether a
// tenant has uploaded a photo yet or not.
// next/image only for hosts next.config.ts allows (every hosted Supabase
// project is *.supabase.co, plus same-origin paths) — anything else falls
// back to a plain lazy <img> rather than throwing.
function isOptimizable(src: string) {
  if (src.startsWith('/')) return true
  try { return new URL(src).hostname.endsWith('.supabase.co') } catch { return false }
}

export function ImageSlot2({
  src, shape = 'rect', placeholder, className = '', sizes = '(min-width: 1024px) 50vw, 100vw', priority = false,
}: {
  src?: string | null
  shape?: 'rect' | 'circle'
  placeholder?: string
  className?: string
  // How wide the slot renders, so a 160px card thumbnail downloads a
  // ~320px image instead of the full-resolution original upload.
  sizes?: string
  priority?: boolean
}) {
  if (src) {
    if (isOptimizable(src)) {
      return <Image src={src} alt="" fill sizes={sizes} priority={priority} className={`object-cover ${className}`} />
    }
    // eslint-disable-next-line @next/next/no-img-element
    return <img src={src} alt="" loading={priority ? 'eager' : 'lazy'} decoding="async" className={`absolute inset-0 w-full h-full object-cover ${className}`} />
  }
  return (
    <div
      className={`absolute inset-0 w-full h-full flex items-center justify-center bg-dp2-card-border/40 text-[10px] font-medium text-dp-on-surface-variant text-center px-2 ${shape === 'circle' ? 'rounded-full' : ''} ${className}`}
    >
      {placeholder}
    </div>
  )
}
