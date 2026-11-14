import { z } from "zod";
import { applicationTypeKeys, studentCategories, type ApplicationType } from "./rules";
import { indianStates } from "./catalog";

// Browser-safe rules for the student AI checklist: only non-sensitive application details are accepted.

export const checklistInfoItems = {
  institution: ["School / college name and address", "स्कूल / कॉलेज का नाम और पता"],
  enrollment: ["Enrollment / roll number", "नामांकन / रोल नंबर"],
  session: ["Academic session (e.g. 2026-27)", "शैक्षणिक सत्र (जैसे 2026-27)"],
  parents: ["Father's and mother's names", "पिता और माता का नाम"],
  address: ["Permanent and current address with PIN code", "स्थायी और वर्तमान पता, पिन कोड सहित"],
  guardian: ["Parent / guardian name, mobile and consent", "माता-पिता / अभिभावक का नाम, मोबाइल और सहमति"],
  coordinator: ["Coordinator name and mobile, or referral code", "समन्वयक का नाम और मोबाइल, या रेफ़रल कोड"],
  bank: ["Bank account details with IFSC", "IFSC सहित बैंक खाते का विवरण"],
  payment: ["Registration fee paid and payment ID saved", "पंजीकरण शुल्क भरा और पेमेंट आईडी सहेजी"],
} as const;
export const checklistDocuments = {
  aadhaar: ["Aadhaar card", "आधार कार्ड"],
  photo: ["Recent passport-size photo", "हाल की पासपोर्ट साइज़ फ़ोटो"],
  marksheet: ["Last exam marksheet", "पिछली परीक्षा की मार्कशीट"],
  idCard: ["School / college ID card", "स्कूल / कॉलेज पहचान पत्र"],
  feeReceipt: ["Current fee receipt or admission slip", "वर्तमान फ़ीस रसीद या प्रवेश पर्ची"],
  bonafide: ["Bonafide / study certificate", "बोनाफ़ाइड / अध्ययन प्रमाण पत्र"],
  bankPassbook: ["Bank passbook first page or cancelled cheque", "बैंक पासबुक का पहला पेज या रद्द चेक"],
  income: ["Family income certificate", "परिवार आय प्रमाण पत्र"],
  caste: ["Caste certificate (if applicable)", "जाति प्रमाण पत्र (यदि लागू हो)"],
  domicile: ["Domicile / residence certificate", "निवास प्रमाण पत्र"],
} as const;
export type ChecklistInfoKey = keyof typeof checklistInfoItems;
export type ChecklistDocumentKey = keyof typeof checklistDocuments;
const infoKeys = Object.keys(checklistInfoItems) as [ChecklistInfoKey, ...ChecklistInfoKey[]];
const documentKeys = Object.keys(checklistDocuments) as [ChecklistDocumentKey, ...ChecklistDocumentKey[]];

/** True when text looks like a phone, Aadhaar or bank number (8+ digits), an email address or an IFSC code. */
export function hasSensitiveDetail(text: string): boolean {
  return /\d(?:[\s-]?\d){7,}/.test(text) || /[^\s@]+@[^\s@]+\.[^\s@]+/.test(text) || /\b[A-Z]{4}0[A-Z0-9]{6}\b/i.test(text);
}
const SENSITIVE = "Please remove phone, Aadhaar or bank numbers and email addresses — they are not needed for this checklist.";
const safeText = (max: number) => z.string().trim().max(max).refine(v => !hasSensitiveDetail(v), SENSITIVE);

export const checklistInputSchema = z.object({
  lang: z.enum(["en", "hi"]),
  studentCategory: z.enum(studentCategories),
  classOrCourse: safeText(80),
  applicationType: z.enum(applicationTypeKeys as [ApplicationType, ...ApplicationType[]]),
  state: z.string().refine(v => v === "" || (indianStates as readonly string[]).includes(v), "Select a valid state."),
  under18: z.boolean(),
  infoReady: z.array(z.enum(infoKeys)).max(infoKeys.length),
  documentsReady: z.array(z.enum(documentKeys)).max(documentKeys.length),
  note: safeText(400),
});
export type ChecklistInput = z.infer<typeof checklistInputSchema>;

export const checklistResultSchema = z.object({
  summary: z.string(),
  items: z.array(z.object({ kind: z.enum(["information", "document"]), priority: z.enum(["must", "recommended"]), title: z.string(), why: z.string() })).max(20),
  nextStep: z.string(),
});
export type ChecklistResult = z.infer<typeof checklistResultSchema>;

export const checklistJsonSchema = {
  type: "object", additionalProperties: false, required: ["summary", "items", "nextStep"],
  properties: {
    summary: { type: "string" },
    items: { type: "array", items: { type: "object", additionalProperties: false, required: ["kind", "priority", "title", "why"], properties: {
      kind: { type: "string", enum: ["information", "document"] },
      priority: { type: "string", enum: ["must", "recommended"] },
      title: { type: "string" }, why: { type: "string" },
    } } },
    nextStep: { type: "string" },
  },
} as const;

/** Items the student has not ticked — sent to the model with English labels. */
export function missingChecklistItems(input: Pick<ChecklistInput, "infoReady" | "documentsReady" | "under18">) {
  const info = infoKeys.filter(k => !input.infoReady.includes(k) && (k !== "guardian" || input.under18)).map(k => checklistInfoItems[k][0]);
  const documents = documentKeys.filter(k => !input.documentsReady.includes(k)).map(k => checklistDocuments[k][0]);
  return { info, documents };
}
