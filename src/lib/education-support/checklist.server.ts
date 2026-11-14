import { applicationTypes } from "./rules";
import { checklistDocuments, checklistInfoItems, checklistJsonSchema, checklistResultSchema, missingChecklistItems, type ChecklistInput, type ChecklistResult } from "./checklist";

const INSTRUCTIONS = `You help students prepare their RILOYD Foundation Education Support (scholarship & sponsorship) registration.
The online form has these steps: 1) basic details, which issue an acknowledgement number; 2) registration fee payment through Zoho and the payment ID (required before continuing); 3) education details; 4) personal details and address; 5) parent/guardian details and consent, only for students under 18; 6) coordinator details or registering without a coordinator; 7) bank and Aadhaar details; 8) declarations and final submission. The form does not upload documents; the Foundation team may ask for documents when verifying.
Using only the details given, return a short personalised checklist of information and documents the student still needs or should double-check before finishing the form, most important first (at most 12 items). Mark "must" for what the form itself requires and "recommended" for documents that are commonly asked for during verification. Explain each item in one plain sentence suited to the student's category and class/course.
Rules: never promise eligibility, selection, award amounts, deadlines or refunds; never invent RILOYD policies; say the Foundation team confirms specifics. Never ask the student to type Aadhaar, bank, phone or email details into this checklist. Answer entirely in the requested language (English or simple Hindi in Devanagari).`;

export async function generateEducationChecklist(input: ChecklistInput): Promise<{ result: ChecklistResult | null; error: string | null }> {
  const { streamResponse, GatewayError } = await import("@lovable.dev/ai-gateway");
  const type = applicationTypes[input.applicationType];
  const missing = missingChecklistItems(input);
  const details = {
    language: input.lang === "hi" ? "Hindi" : "English",
    studentCategory: input.studentCategory === "school" ? "School student" : input.studentCategory === "ug" ? "Undergraduate (UG)" : "Postgraduate (PG)",
    classOrCourse: input.classOrCourse || null, applyingFor: type.en, registrationFee: `₹${type.fee}`, state: input.state || null, under18: input.under18,
    informationReady: input.infoReady.map(k => checklistInfoItems[k][0]), informationNotYetReady: missing.info,
    documentsReady: input.documentsReady.map(k => checklistDocuments[k][0]), documentsNotYetReady: missing.documents,
    studentNote: input.note || null,
  };
  try {
    const stream = await streamResponse({
      model: "openai/gpt-6-astra",
      instructions: INSTRUCTIONS,
      input: JSON.stringify(details),
      reasoning: { effort: "low" },
      text: { format: { type: "json_schema", name: "education_checklist", strict: true, schema: checklistJsonSchema } },
    });
    let text = ""; let refused = false; let incomplete = false;
    for await (const event of stream) {
      if (event.type === "response.output_text.delta") text += event.delta;
      if (event.type === "response.refusal.delta" || event.type === "response.refusal.done") refused = true;
      if (event.type === "response.incomplete") incomplete = true;
    }
    if (refused) return { result: null, error: "The AI could not prepare a checklist for these details." };
    if (incomplete || !text) return { result: null, error: "The checklist was incomplete. Please try again." };
    const parsed = checklistResultSchema.safeParse(JSON.parse(text));
    if (!parsed.success) return { result: null, error: "The checklist could not be read. Please try again." };
    return { result: parsed.data, error: null };
  } catch (err) {
    if (err instanceof GatewayError) {
      console.error("Education checklist failed", err.code, err.httpStatus, err.ids);
      if (err.code === "rate_limited") return { result: null, error: "Too many requests right now. Please wait a minute and try again." };
      return { result: null, error: "The checklist helper is unavailable right now. You can still fill in the form." };
    }
    console.error("Education checklist failed", err);
    return { result: null, error: "The checklist helper is unavailable right now. You can still fill in the form." };
  }
}
