import type { Metadata } from 'next'
import { GraduationCap, HeartHandshake, MessageSquarePlus, ArrowRight } from 'lucide-react'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getPublicSiteContext } from '@/lib/publicSite'
import { getCookieTenantId } from '@/lib/tenant'
import { T, Bi } from '@/components/i18n/T'

export async function generateMetadata(): Promise<Metadata> {
  const site = await getPublicSiteContext(await createClient(), await getCookieTenantId())
  return {
    title: 'Education Corner',
    description: `Education support programs in ${site.name}.`,
  }
}

// Real gap, 2026-10-06: this page used to show three fabricated "Scholarship
// Info Cards" with invented numbers (e.g. "25 students supported") and a
// list of five named students with fabricated achievements, none of it
// backed by any table. Harmless as placeholder copy for one village's own
// site, but it would show the exact same fake Dhab Pari-specific names on
// any other village's site, word for word. Replaced with links to the
// education-support systems this app actually has and actually tracks
// (Kafalat/Wazifa/Zakat, under the real welfare hub) rather than inventing
// a second, unbacked "scholarship" concept next to them.
export default async function EducationPage() {
  const site = await getPublicSiteContext(await createClient(), await getCookieTenantId())
  return (
    <div className="max-w-[1200px] mx-auto px-6 md:px-12 py-10 min-h-screen">
      <div className="text-center mb-12 max-w-3xl mx-auto">
        <div className="inline-flex items-center justify-center p-3 bg-blue-100 rounded-full text-blue-600 mb-4">
          <GraduationCap size={32} />
        </div>
        <h1 className="font-heading text-[20px] md:text-[23px] font-bold leading-[28px] text-dp2-primary mb-2">
          <T k="x.educationCorner" />
        </h1>
        <p className="text-slate-500 font-sans text-[15px] leading-relaxed">
          <Bi
            en={`Supporting the next generation of ${site.name} through sponsorship, stipends, and community support.`}
            ur={`کفالت، وظائف اور برادری کے تعاون سے ${site.nameUrdu || site.name} کی اگلی نسل کی مدد۔`}
          />
        </p>
      </div>

      <section className="mb-10">
        <div className="bg-white border border-dp2-card-border rounded-2xl p-6 md:p-8 flex flex-col md:flex-row items-start md:items-center gap-5">
          <div className="w-14 h-14 shrink-0 rounded-xl bg-emerald-100 text-emerald-700 flex items-center justify-center">
            <HeartHandshake size={28} />
          </div>
          <div className="flex-1">
            <h2 className="font-heading text-[20px] md:text-[23px] font-bold leading-snug text-dp2-primary mb-1.5">
              <Bi en="Kafalat, Wazifa & Zakat" ur="کفالت، وظیفہ اور زکوٰۃ" />
            </h2>
            <p className="text-slate-500 font-sans text-[15px] leading-relaxed">
              <Bi
                en="Sponsor an orphan or student directly (Kafalat), support ongoing education stipends (Taleemi Wazifa), or contribute to the pooled Zakat & Ushr fund. Every program here is run and tracked by the committee — real sponsors, real recipients."
                ur="کسی یتیم یا طالب علم کی براہِ راست کفالت کریں، جاری تعلیمی وظائف میں حصہ ڈالیں، یا زکوٰۃ و عشر کے مشترکہ فنڈ میں عطیہ دیں۔ ہر پروگرام کمیٹی چلاتی اور اس کا ریکارڈ رکھتی ہے — حقیقی کفیل، حقیقی مستحقین۔"
              />
            </p>
          </div>
          <Link href="/welfare" className="shrink-0 inline-flex items-center gap-1.5 bg-dp2-primary text-white px-5 py-2.5 rounded-xl font-sans text-[15px] font-semibold hover:brightness-110 transition-all">
            <Bi en="Explore Welfare Programs" ur="فلاحی پروگرام دیکھیں" /> <ArrowRight size={15} />
          </Link>
        </div>
      </section>

      <div className="bg-blue-50 border border-blue-200 rounded-xl p-8 text-center">
        <div className="inline-flex items-center justify-center p-2.5 bg-white rounded-full text-blue-600 mb-3">
          <MessageSquarePlus size={22} />
        </div>
        <h3 className="font-heading text-[20px] md:text-[23px] font-bold leading-snug text-blue-900 mb-2">
          <Bi en={`Have an idea for education in ${site.name}?`} ur={`${site.nameUrdu || site.name} میں تعلیم کے لیے کوئی خیال ہے؟`} />
        </h3>
        <p className="text-blue-700 font-sans text-[15px] leading-relaxed mb-6 max-w-xl mx-auto">
          <Bi en="A tuition center, a book drive, a tutoring program — suggest it directly to the committee." ur="ٹیوشن سینٹر، کتابوں کی مہم، پڑھائی میں مدد کا پروگرام — براہِ راست کمیٹی کو تجویز دیں۔" />
        </p>
        <Link
          href="/suggestions"
          className="inline-block bg-blue-600 text-white px-8 py-3 rounded-xl font-sans font-semibold hover:bg-blue-700 transition-all"
        >
          <Bi en="Submit a Suggestion" ur="تجویز دیں" />
        </Link>
      </div>
    </div>
  )
}
