// Public scholarship-form API used by copies of the site hosted elsewhere (riloyd.in). Same validation, rate limits
// and Google Sheet fallback as the server functions.
import { ZodError } from "zod";
import { educationBasicSchema, educationLookupSchema, educationProgressSchema, educationSubmitSchema, parseEducationEdit, paymentReferenceSchema, referralCodeSchema } from "./rules";
import { checklistInputSchema } from "./checklist";
import type { EducationAction } from "./remote";

const ALLOWED_ORIGINS = new Set(["https://riloyd.in", "https://www.riloyd.in"]);

export function educationCors(origin: string | null): Record<string, string> {
  if (!origin || !ALLOWED_ORIGINS.has(origin)) return { Vary: "Origin" };
  return { "Access-Control-Allow-Origin": origin, "Access-Control-Allow-Methods": "POST, OPTIONS", "Access-Control-Allow-Headers": "content-type", "Access-Control-Max-Age": "86400", Vary: "Origin" };
}

async function run(action: EducationAction, input: unknown): Promise<unknown> {
  const store = await import("./registration-store.server");
  switch (action) {
    case "start": return store.startRegistration(educationBasicSchema.parse(input));
    case "payment": return store.savePaymentReference(paymentReferenceSchema.parse(input));
    case "lookup": return store.lookupForEdit(educationLookupSchema.parse(input));
    case "progress": { const d = educationProgressSchema.parse(input); return store.saveProgress(d.verify, d.values); }
    case "submit": { const d = educationSubmitSchema.parse(input); const { core, priv } = parseEducationEdit(d); return store.saveFullRegistration(d.verify, core, priv); }
    case "referral": {
      const d = referralCodeSchema.parse(input);
      const { limitSubmission } = await import("../submissions.server");
      await limitSubmission(`ref:${d.code.toUpperCase()}`, { failOpen: true });
      try { const { supabaseAdmin } = await import("@/integrations/supabase/client.server"); return await store.referralCoordinator(supabaseAdmin, d.code); }
      catch (e) { console.error("Referral lookup failed", e); return null; }
    }
    case "checklist": {
      const d = checklistInputSchema.parse(input);
      const { limitSubmission } = await import("../submissions.server");
      await limitSubmission("edu-checklist", { failOpen: true, ipOnly: true });
      const { generateEducationChecklist } = await import("./checklist.server");
      return generateEducationChecklist(d);
    }
  }
}

const actions = new Set<string>(["start", "payment", "lookup", "progress", "submit", "referral", "checklist"]);

export async function handleEducationRequest(request: Request, action: string): Promise<Response> {
  const headers = educationCors(request.headers.get("origin"));
  const reply = (status: number, body: unknown) => Response.json(body, { status, headers });
  if (!actions.has(action)) return reply(404, { error: "Not found." });
  let input: unknown;
  try { input = await request.json(); } catch { return reply(400, { error: "Invalid request." }); }
  try {
    const result = await run(action as EducationAction, input);
    return reply(200, { result: result ?? null });
  } catch (e) {
    if (e instanceof ZodError) return reply(400, { error: e.issues[0]?.message ?? "Please check your details." });
    console.error(`Education ${action} request failed`, e);
    return reply(400, { error: e instanceof Error ? e.message : "Please try again in a few minutes." });
  }
}
