import { useState } from "react";
import { useServerFn } from "@tanstack/react-start";
import { ClipboardCheck, FileText, Info, Sparkles } from "lucide-react";
import { Button } from "@/components/ui/button";
import { getEducationChecklist } from "@/lib/education-checklist.functions";
import { viaHome } from "@/lib/education-support/remote";
import { applicationTypeKeys, applicationTypes, studentCategories, type ApplicationType, type StudentCategory } from "@/lib/education-support/rules";
import { indianStates } from "@/lib/education-support/catalog";
import { checklistDocuments, checklistInfoItems, checklistInputSchema, type ChecklistDocumentKey, type ChecklistInfoKey, type ChecklistResult } from "@/lib/education-support/checklist";
import type { EduLang } from "@/lib/education-support/labels";

const inputClass = "mt-1.5 w-full rounded-lg border border-edu-navy/20 bg-edu-paper px-3 py-2.5 text-sm text-edu-ink outline-none transition focus:border-edu-royal focus:ring-2 focus:ring-edu-royal/20";
const categoryLabels: Record<StudentCategory, [string, string]> = { school: ["School (Class 4–12)", "स्कूल (कक्षा 4–12)"], ug: ["Undergraduate (UG)", "स्नातक (UG)"], pg: ["Postgraduate (PG)", "स्नातकोत्तर (PG)"] };

/** Student AI helper: non-sensitive answers → personalised list of missing information and documents. */
export function EducationChecklist({ lang }: { lang: EduLang }) {
  const en = lang === "en";
  const i = en ? 0 : 1;
  const ask = viaHome(useServerFn(getEducationChecklist), "checklist");
  const [category, setCategory] = useState<StudentCategory>("school");
  const [classOrCourse, setClassOrCourse] = useState("");
  const [applicationType, setApplicationType] = useState<ApplicationType>("sponsorship");
  const [state, setState] = useState("");
  const [under18, setUnder18] = useState(true);
  const [info, setInfo] = useState<ChecklistInfoKey[]>([]);
  const [docs, setDocs] = useState<ChecklistDocumentKey[]>([]);
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [result, setResult] = useState<ChecklistResult | null>(null);
  const toggle = <K extends string>(list: K[], key: K, set: (v: K[]) => void) => set(list.includes(key) ? list.filter(k => k !== key) : [...list, key]);

  async function run(e: React.FormEvent) {
    e.preventDefault(); setError(""); setResult(null);
    const input = { lang, studentCategory: category, classOrCourse, applicationType, state, under18, infoReady: info, documentsReady: docs, note };
    const parsed = checklistInputSchema.safeParse(input);
    if (!parsed.success) { setError(parsed.error.issues[0]?.message ?? "Please check your answers."); return; }
    setBusy(true);
    try {
      const r = await ask({ data: parsed.data });
      if (r.error || !r.result) setError(r.error ?? "Please try again.");
      else setResult(r.result);
    } catch (err) { setError(err instanceof Error ? err.message : "Please try again."); }
    finally { setBusy(false); }
  }

  return <div className="rounded-3xl border border-edu-navy/10 bg-edu-paper p-5 sm:p-8">
    <div className="flex items-start gap-3">
      <span className="grid h-11 w-11 shrink-0 place-items-center rounded-2xl bg-edu-sky text-edu-royal"><Sparkles className="h-5 w-5" aria-hidden="true" /></span>
      <div>
        <h2 className="text-xl font-black text-edu-navy sm:text-2xl">{en ? "What am I missing? — AI checklist" : "मुझसे क्या छूट रहा है? — AI चेकलिस्ट"}</h2>
        <p className="mt-1 text-sm text-edu-ink/70">{en ? "Tell us a few basics and tick what you already have. You will get a personal list of information and documents to keep ready." : "कुछ मूल बातें बताएँ और जो आपके पास है उस पर टिक करें। आपको तैयार रखने वाली जानकारी और दस्तावेज़ों की निजी सूची मिलेगी।"}</p>
        <p className="mt-2 inline-flex items-center gap-1.5 text-xs font-semibold text-edu-ink/60"><Info className="h-3.5 w-3.5" aria-hidden="true" />{en ? "No name, phone, Aadhaar or bank numbers needed." : "नाम, फ़ोन, आधार या बैंक नंबर की ज़रूरत नहीं।"}</p>
      </div>
    </div>

    <form onSubmit={e => void run(e)} className="mt-6 grid gap-5">
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <label className="text-sm font-semibold text-edu-ink">{en ? "Category" : "श्रेणी"}
          <select value={category} onChange={e => setCategory(e.target.value as StudentCategory)} className={inputClass}>{studentCategories.map(c => <option key={c} value={c}>{categoryLabels[c][i]}</option>)}</select></label>
        <label className="text-sm font-semibold text-edu-ink">{category === "school" ? (en ? "Class" : "कक्षा") : (en ? "Course" : "कोर्स")}
          <input value={classOrCourse} onChange={e => setClassOrCourse(e.target.value)} maxLength={80} placeholder={category === "school" ? "10" : "B.Sc."} className={inputClass} /></label>
        <label className="text-sm font-semibold text-edu-ink">{en ? "Applying for" : "आवेदन"}
          <select value={applicationType} onChange={e => setApplicationType(e.target.value as ApplicationType)} className={inputClass}>{applicationTypeKeys.map(k => <option key={k} value={k}>{applicationTypes[k][lang]} (₹{applicationTypes[k].fee})</option>)}</select></label>
        <label className="text-sm font-semibold text-edu-ink">{en ? "State" : "राज्य"}
          <select value={state} onChange={e => setState(e.target.value)} className={inputClass}><option value="">{en ? "Select" : "चुनें"}</option>{indianStates.map(s => <option key={s} value={s}>{s}</option>)}</select></label>
      </div>
      <label className="flex items-center gap-2 text-sm font-semibold text-edu-ink"><input type="checkbox" checked={under18} onChange={e => setUnder18(e.target.checked)} className="h-4 w-4 accent-edu-royal" />{en ? "The student is under 18" : "विद्यार्थी 18 वर्ष से कम है"}</label>

      <div className="grid gap-5 md:grid-cols-2">
        <fieldset className="rounded-2xl border border-edu-navy/10 p-4">
          <legend className="px-1 text-sm font-bold text-edu-navy">{en ? "Information I have ready" : "मेरे पास तैयार जानकारी"}</legend>
          <div className="mt-2 grid gap-2">{(Object.keys(checklistInfoItems) as ChecklistInfoKey[]).filter(k => k !== "guardian" || under18).map(k =>
            <label key={k} className="flex items-start gap-2 text-sm text-edu-ink/85"><input type="checkbox" checked={info.includes(k)} onChange={() => toggle(info, k, setInfo)} className="mt-0.5 h-4 w-4 accent-edu-royal" />{checklistInfoItems[k][i]}</label>)}</div>
        </fieldset>
        <fieldset className="rounded-2xl border border-edu-navy/10 p-4">
          <legend className="px-1 text-sm font-bold text-edu-navy">{en ? "Documents I have" : "मेरे पास दस्तावेज़"}</legend>
          <div className="mt-2 grid gap-2">{(Object.keys(checklistDocuments) as ChecklistDocumentKey[]).map(k =>
            <label key={k} className="flex items-start gap-2 text-sm text-edu-ink/85"><input type="checkbox" checked={docs.includes(k)} onChange={() => toggle(docs, k, setDocs)} className="mt-0.5 h-4 w-4 accent-edu-royal" />{checklistDocuments[k][i]}</label>)}</div>
        </fieldset>
      </div>

      <label className="text-sm font-semibold text-edu-ink">{en ? "Anything else? (optional)" : "कुछ और? (वैकल्पिक)"}
        <textarea value={note} onChange={e => setNote(e.target.value)} maxLength={400} rows={2} placeholder={en ? "e.g. I changed school this year" : "जैसे: इस साल स्कूल बदला है"} className={inputClass} /></label>

      {error && <p role="alert" className="text-sm font-semibold text-destructive">{error}</p>}
      <div><Button type="submit" disabled={busy} className="h-11 rounded-full bg-edu-royal px-7 text-edu-paper hover:bg-edu-royal/90"><ClipboardCheck className="h-4 w-4" aria-hidden="true" />{busy ? (en ? "Preparing your list…" : "सूची बन रही है…") : (en ? "Get my checklist" : "मेरी चेकलिस्ट बनाएँ")}</Button></div>
    </form>

    {result && <div className="mt-6 rounded-2xl bg-edu-sky/60 p-5" aria-live="polite">
      <p className="text-sm font-semibold text-edu-navy">{result.summary}</p>
      {result.items.length > 0 && <ul className="mt-4 grid gap-3">{result.items.map((item, n) =>
        <li key={n} className="flex gap-3 rounded-xl bg-edu-paper p-3">
          {item.kind === "document" ? <FileText className="mt-0.5 h-4 w-4 shrink-0 text-edu-royal" aria-hidden="true" /> : <Info className="mt-0.5 h-4 w-4 shrink-0 text-edu-royal" aria-hidden="true" />}
          <div className="text-sm">
            <p className="font-bold text-edu-ink">{item.title} <span className={`ml-1 rounded-full px-2 py-0.5 text-[11px] font-bold ${item.priority === "must" ? "bg-edu-royal text-edu-paper" : "bg-edu-sky text-edu-navy"}`}>{item.priority === "must" ? (en ? "Needed" : "ज़रूरी") : (en ? "Keep ready" : "तैयार रखें")}</span></p>
            <p className="mt-0.5 text-edu-ink/75">{item.why}</p>
          </div>
        </li>)}</ul>}
      <p className="mt-4 text-sm text-edu-ink/80"><strong>{en ? "Next step: " : "अगला कदम: "}</strong>{result.nextStep}</p>
      <p className="mt-3 text-xs text-edu-ink/60">{en ? "AI suggestions only. The Foundation team confirms the documents it needs; this list does not affect selection." : "यह केवल AI सुझाव है। ज़रूरी दस्तावेज़ फ़ाउंडेशन टीम पक्का करेगी; इस सूची से चयन पर असर नहीं पड़ता।"}</p>
    </div>}
  </div>;
}
