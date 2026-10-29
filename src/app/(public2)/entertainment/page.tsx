import type { Metadata } from 'next'
import { Trophy, Sparkles, MessageSquarePlus, ArrowRight } from 'lucide-react'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getPublicSiteContext } from '@/lib/publicSite'
import { getCookieTenantId } from '@/lib/tenant'
import { T, Bi } from '@/components/i18n/T'

export async function generateMetadata(): Promise<Metadata> {
  const site = await getPublicSiteContext(await createClient(), await getCookieTenantId())
  return {
    title: 'Community Corner',
    description: `Sports and community talent from ${site.name} village.`,
  }
}

// Real gap, 2026-10-06: this page used to show fabricated Urdu poems (with
// invented named authors), fabricated sports results, and a fabricated
// "Kids Corner" — none of it read from any table. Same problem as
// /education: harmless on one village's own site, but it would show the
// exact same fake poems and scores on every other village's site, word
// for word. Replaced with links to the real, data-backed systems this app
// already has for exactly this content (village_events filtered to
// category=sports, and the Talent Showcase) instead of inventing a
// second, unbacked version of either.
export default function EntertainmentPage() {
  return (
    <div className="max-w-[1200px] mx-auto px-6 md:px-12 py-10 min-h-screen">
      <div className="text-center mb-12 max-w-3xl mx-auto">
        <h1 className="font-heading text-[20px] md:text-[23px] font-bold leading-[28px] text-dp2-primary mb-2">
          <T k="x.communityCorner" />
        </h1>
        <p className="text-slate-500 font-sans text-[15px] leading-relaxed">
          <Bi en="Sports, talent, and community life from the village." ur="گاؤں کے کھیل، ہنر اور اجتماعی زندگی۔" />
        </p>
      </div>

      <section className="mb-6">
        <div className="bg-white border border-dp2-card-border rounded-2xl p-6 md:p-8 flex flex-col md:flex-row items-start md:items-center gap-5">
          <div className="w-14 h-14 shrink-0 rounded-xl bg-amber-100 text-amber-700 flex items-center justify-center">
            <Trophy size={28} />
          </div>
          <div className="flex-1">
            <h2 className="font-heading text-[20px] md:text-[23px] font-bold leading-snug text-dp2-primary mb-1.5">
              <T k="x.sportsUpdates" />
            </h2>
            <p className="text-slate-500 font-sans text-[15px] leading-relaxed">
              <Bi en="Tournaments, matches, and athletics days — the same village events calendar the committee keeps up to date, filtered to sports." ur="ٹورنامنٹ، میچ اور کھیلوں کے دن — کمیٹی کا وہی تقریبات کا کیلنڈر، صرف کھیلوں کے لیے۔" />
            </p>
          </div>
          <Link href="/sports" className="shrink-0 inline-flex items-center gap-1.5 bg-dp2-primary text-white px-5 py-2.5 rounded-xl font-sans text-[15px] font-semibold hover:brightness-110 transition-all">
            <Bi en="View Sports Calendar" ur="کھیلوں کا کیلنڈر دیکھیں" /> <ArrowRight size={15} />
          </Link>
        </div>
      </section>

      <section className="mb-10">
        <div className="bg-white border border-dp2-card-border rounded-2xl p-6 md:p-8 flex flex-col md:flex-row items-start md:items-center gap-5">
          <div className="w-14 h-14 shrink-0 rounded-xl bg-pink-100 text-pink-600 flex items-center justify-center">
            <Sparkles size={28} />
          </div>
          <div className="flex-1">
            <h2 className="font-heading text-[20px] md:text-[23px] font-bold leading-snug text-dp2-primary mb-1.5"><Bi en="Talent Showcase" ur="ٹیلنٹ شو کیس" /></h2>
            <p className="text-slate-500 font-sans text-[15px] leading-relaxed">
              <Bi en="Poetry, art, Quran recitation, and other talent submitted by villagers themselves — admin-reviewed before it goes up." ur="شاعری، فن، تلاوتِ قرآن اور دیگر ہنر جو گاؤں والے خود بھیجتے ہیں — شائع ہونے سے پہلے انتظامیہ جائزہ لیتی ہے۔" />
            </p>
          </div>
          <Link href="/talent" className="shrink-0 inline-flex items-center gap-1.5 bg-dp2-primary text-white px-5 py-2.5 rounded-xl font-sans text-[15px] font-semibold hover:brightness-110 transition-all">
            <Bi en="View Talent Showcase" ur="ٹیلنٹ شو کیس دیکھیں" /> <ArrowRight size={15} />
          </Link>
        </div>
      </section>

      <div className="bg-dp2-primary-dark text-white rounded-xl p-8 text-center">
        <div className="inline-flex items-center justify-center p-2.5 bg-white/15 rounded-full mb-3">
          <MessageSquarePlus size={22} />
        </div>
        <h3 className="font-heading text-[20px] md:text-[23px] font-bold leading-snug mb-2">
          <T k="x.talentToShare" />
        </h3>
        <p className="opacity-90 font-sans text-[15px] leading-relaxed mb-6 max-w-xl mx-auto">
          <Bi en="Have an idea for a community event or activity? Suggest it to the committee." ur="کسی اجتماعی تقریب یا سرگرمی کا خیال ہے؟ کمیٹی کو تجویز دیں۔" />
        </p>
        <Link
          href="/suggestions"
          className="inline-block bg-emerald-200 text-emerald-800 px-8 py-3 rounded-xl font-sans font-semibold hover:scale-105 transition-transform"
        >
          <T k="x.submitContent" />
        </Link>
      </div>
    </div>
  )
}
