// Saves Education Support registrations to the database and the Google Sheet backup.
// If the database is unavailable, the sheet still receives the registration with a backup acknowledgement number.
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "@/integrations/supabase/types";
import { applicationTypes, educationBasicSchema, educationCoreSchema, type ApplicationType, type EducationBasicValues, type EducationCoreValues, type EducationLookup, type EducationPrivateValues } from "./rules";
import { stateCodes } from "./numbering";
import { backupAckNumber, emptyRecord, formFieldKeys, istTimestamp, isBackupAck, UPDATE_PENDING, type FormFieldKey, type SheetRecord } from "./sheet";
import { applicationTypeChangeBlocker, editBlocker, paymentRequiredBlocker, type EditActor } from "./editing";
import { buildSheetRecord, dbRegistrationColumns, dbRowToSheetRecord, dbRowToValues, valuesToDbColumns, type DbRegistrationRow } from "./record-mapping";
import { appendSheetRecords, findSheetRecord, readAllSheetRecords, upsertSheetRecord, writeSheetRows } from "./sheets.server";

type Client = SupabaseClient<Database>;
type Row = DbRegistrationRow & { id: string };

/** An error whose message is meant for the visitor and must not trigger the backup path. */
export class VisitorError extends Error {}

/** The rate limit still applies, but a database problem in the limiter never blocks a response. */
async function safeLimit(key: string) {
  try { const { limitSubmission } = await import("../submissions.server"); await limitSubmission(key, { failOpen: true }); }
  catch (e) { if (e instanceof Error && /^Too many submissions/.test(e.message)) throw new VisitorError(e.message); console.error("Submission limiter unavailable", e); }
}
const dbNote = (now: Date) => `Database unavailable at ${istTimestamp(now)}; latest answers saved in this sheet`;

const NO_MATCH = "No registration matches these details. Please check your acknowledgement number or Registration ID, date of birth and state.";

async function admin() { return (await import("@/integrations/supabase/client.server")).supabaseAdmin; }
async function sha256Hex(value: string) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), b => b.toString(16).padStart(2, "0")).join("");
}
function kycSecret() {
  const secret = process.env["EDUCATION_KYC_ENCRYPTION_KEY"];
  if (!secret) throw new Error("Secure identity storage is unavailable. Please contact the Foundation team.");
  return secret;
}
async function encryptPrivate(p: EducationPrivateValues) {
  const { encryptDetails } = await import("./privacy.server");
  return encryptDetails({ bankHolder: p.bankHolder, bankName: p.bankName, bankAccount: p.bankAccount, bankIfsc: p.bankIfsc, aadhaarNumber: p.aadhaarNumber }, kycSecret());
}
async function bankLast4Of(ciphertext: string | null): Promise<string> {
  const secret = process.env["EDUCATION_KYC_ENCRYPTION_KEY"];
  if (!ciphertext || !secret) return "";
  try { const { decryptDetails } = await import("./privacy.server"); return (await decryptDetails(ciphertext, secret))["bankAccount"]?.slice(-4) ?? ""; } catch { return ""; }
}
async function coordinatorIdFor(client: Client, v: EducationCoreValues) {
  const code = v.withoutCoordinator ? "" : v.coordinatorCode.toUpperCase();
  if (!code) return null;
  const { data } = await client.from("coordinators").select("id").eq("referral_code", code).eq("active", true).maybeSingle();
  return data?.id ?? null;
}
const stateCodeOf = (state: string) => stateCodes.find(s => s.name.toLowerCase() === state.trim().toLowerCase())?.code ?? "00";
const random7 = () => crypto.getRandomValues(new Uint32Array(1))[0]! % 10_000_000;

/** Coordinator details for a referral code: RILOYD staff (BDE/BDM or CRM employee) first, then registered coordinators. */
export async function referralCoordinator(db: Client, rawCode: string): Promise<{ code: string; name: string; mobile: string; email: string; type: string } | null> {
  const code = rawCode.trim().toUpperCase();
  if (!/^[A-Z0-9-]{2,40}$/.test(code)) return null;
  const staff = (await db.from("education_staff_access").select("user_id, referral_code").eq("active", true).ilike("referral_code", code)).data?.find(s => s.referral_code.toUpperCase() === code);
  const employee = staff ? null : (await db.from("crm_employee_profiles").select("user_id, employee_code").ilike("employee_code", code)).data?.find(e => e.employee_code.toUpperCase() === code);
  const userId = staff?.user_id ?? employee?.user_id;
  if (userId) {
    const { data: profile } = await db.from("crm_employee_profiles").select("full_name, phone").eq("user_id", userId).maybeSingle();
    const { data: user } = await db.auth.admin.getUserById(userId);
    return { code, name: profile?.full_name ?? "", mobile: profile?.phone ?? "", email: user?.user?.email ?? "", type: "RILOYD Employee" };
  }
  const { data: c } = await db.from("coordinators").select("full_name, phone, email").eq("active", true).eq("referral_code", code).maybeSingle();
  return c ? { code, name: c.full_name, mobile: c.phone, email: c.email, type: "Other" } : null;
}

/** Full form values with empty strings for everything not yet entered. */
function withBlanks(values: Partial<Record<string, unknown>>): Record<FormFieldKey, string | boolean> {
  const v = emptyRecord().values;
  for (const k of formFieldKeys) { const x = values[k]; if (typeof x === "string" || typeof x === "boolean") v[k] = x; }
  v.nationality = v.nationality || "Indian";
  return v;
}

/** Step 1: save basic details and issue a temporary Registration ID (database first, Google Sheet always); the acknowledgement number follows the payment ID. */
export async function startRegistration(basic: EducationBasicValues) {
  await safeLimit(basic.email);
  const now = new Date();
  const receiptHash = await sha256Hex(Array.from(crypto.getRandomValues(new Uint8Array(32)), b => b.toString(16)).join(""));
  const values = withBlanks(basic);
  let referral: Awaited<ReturnType<typeof referralCoordinator>> = null;
  let saved: { ack_number: string; created_at: string } | null = null;
  try {
    const db = await admin();
    if (basic.coordinatorCode) {
      referral = await referralCoordinator(db, basic.coordinatorCode).catch(() => null);
      if (referral) Object.assign(values, { withoutCoordinator: false, coordinatorCode: referral.code, coordinatorName: referral.name, coordinatorMobile: referral.mobile, coordinatorEmail: referral.email, coordinatorType: referral.type });
    }
    const columns = valuesToDbColumns(values as unknown as EducationCoreValues, now);
    const { data, error } = await db.from("education_support_registrations").insert({
      ...columns, declarations: {}, guardian_consent_at: null, form_status: "started",
      coordinator_id: referral ? await coordinatorIdFor(db, values as unknown as EducationCoreValues) : null,
      receipt_token_hash: receiptHash,
    }).select("ack_number, created_at").single();
    if (error || !data) throw error ?? new Error("No row returned");
    saved = data;
  } catch (e) {
    console.error("Education registration could not be saved in the database; using the Google Sheet backup.", e);
  }
  const ackNumber = saved?.ack_number ?? backupAckNumber(now, stateCodeOf(basic.state), random7());
  const fee = applicationTypes[basic.applicationType as ApplicationType].fee;
  const record = buildSheetRecord(values, {
    ackNumber, submittedAt: istTimestamp(saved ? new Date(saved.created_at) : now), savedInDatabase: saved ? "Yes" : "Backup only", formStatus: "Started",
    fee: String(fee), declarations: "No", receiptHash, dbNote: saved ? "" : dbNote(now),
  });
  try { await appendSheetRecords([record]); }
  catch (e) {
    console.error("Education registration could not be copied to the Google Sheet.", e);
    if (!saved) throw new Error("Your registration could not be saved. Please try again in a few minutes.");
  }
  return { ackNumber, createdAt: saved?.created_at ?? now.toISOString(), fee, applicationType: basic.applicationType as ApplicationType, values };
}

export async function savePaymentReference(data: { verify: EducationLookup; reference: string }) {
  await safeLimit(`pay:${data.verify.ackNumber}`);
  const found = await locate(data.verify);
  const bad = new VisitorError("This registration could not be updated. Please contact the Foundation team with your acknowledgement number.");
  const status = found.source === "database" ? found.row.payment_status : found.sheet.record.meta.paymentStatus;
  if (!["pending", "reference_submitted", ""].includes(status)) throw bad;
  if (found.source === "database") {
    try {
      const db = await admin();
      const { data: rows, error } = await db.from("education_support_registrations")
        .update({ payment_reference: data.reference, payment_reference_at: new Date().toISOString(), payment_status: "reference_submitted" })
        .eq("id", found.row.id).in("payment_status", ["pending", "reference_submitted"]).select(`id, ${dbRegistrationColumns}`);
      if (error?.code === "23505") throw new VisitorError("This transaction ID has already been used for another registration. Each payment ID can be used only once — please check your payment receipt.");
      if (error) throw error;
      const row = rows?.[0] as Row | undefined;
      if (!row) throw bad;
      if (row.form_status === "completed") {
        try { const { refreshEducationChecks } = await import("./checks.server"); await refreshEducationChecks(db, row.id, { ai: false }); }
        catch (e) { console.error("Education checks after payment ID failed", e); }
      }
      try { await syncRowToSheet(row); } catch (e) { console.error("Payment ID could not be copied to the Google Sheet.", e); }
      return { ok: true, ackNumber: row.ack_number as string | null };
    } catch (e) {
      if (e instanceof VisitorError) throw e;
      console.error("Payment ID could not be saved in the database; saving it in the Google Sheet.", e);
    }
  }
  await writeToSheet(found, new Date(), r => ({ ...r, meta: { ...r.meta, paymentReference: data.reference, paymentStatus: "reference_submitted" } }), "The payment ID could not be saved. Please try again.");
  // Saved only in the backup sheet: the acknowledgement number is issued once the database takes this payment ID.
  return { ok: true, ackNumber: null as string | null };
}

/**
 * Saves a change in the Google Sheet when the database could not take it. A row that is already in the database is
 * marked "Update pending" so the next reopen or admin sync copies it back; a missing sheet row is rebuilt from the database row.
 */
async function writeToSheet(found: Located, now: Date, change: (r: SheetRecord) => SheetRecord, failMessage: string) {
  try {
    const target = found.source === "sheet" ? found.sheet : await findSheetFor(found.row);
    const base = target?.record ?? dbRowToSheetRecord((found as { row: Row }).row, { bankLast4: await bankLast4Of((found as { row: Row }).row.private_details_ciphertext) });
    const inDatabase = found.source === "database" || base.meta.savedInDatabase !== "Backup only";
    const next = change(base);
    next.meta = { ...next.meta, savedInDatabase: inDatabase ? UPDATE_PENDING : "Backup only", dbNote: dbNote(now) };
    if (target) await writeSheetRows([{ ...target, record: next }]);
    else await appendSheetRecords([next]);
  } catch (e) {
    if (e instanceof VisitorError) throw e;
    console.error("Google Sheet backup write failed", e);
    throw new Error(failMessage);
  }
}

/** The sheet row for a database row: by acknowledgement number, or by the Registration ID it had before payment. */
async function findSheetFor(row: Row) {
  const found = await findSheetRecord(row.ack_number);
  if (found || !row.registration_id || row.registration_id === row.ack_number) return found;
  return findSheetRecord(row.registration_id);
}

async function syncRowToSheet(row: Row, edit?: { at: Date; by: string }) {
  const record = dbRowToSheetRecord(row, { bankLast4: await bankLast4Of(row.private_details_ciphertext), ...(edit ? { editedAt: edit.at, editedBy: edit.by } : {}) });
  if (!row.registration_id || row.registration_id === row.ack_number) return upsertSheetRecord(record);
  // Rewrites the pre-payment row in place so the new acknowledgement number never creates a second sheet row.
  const found = await findSheetFor(row);
  if (found) await writeSheetRows([{ ...found, record }]);
  else await appendSheetRecords([record]);
}

const sameState = (a: string, b: string) => a.trim().toLowerCase() === b.trim().toLowerCase();
type Located = { source: "database"; row: Row } | { source: "sheet"; sheet: NonNullable<Awaited<ReturnType<typeof findSheetRecord>>> };

/** Find a registration by acknowledgement number, mobile and date of birth: database first, then the Google Sheet. */
async function locate(verify: EducationLookup, opts: { checkSheet?: boolean } = { checkSheet: true }): Promise<Located> {
  let dbReachable = false;
  try {
    const db = await admin();
    const { data, error } = await db.from("education_support_registrations").select(`id, ${dbRegistrationColumns}`).or(`ack_number.eq.${verify.ackNumber},registration_id.eq.${verify.ackNumber}`).maybeSingle();
    if (error) throw error;
    dbReachable = true;
    if (data) {
      const row = data as Row;
      if (String(row.date_of_birth).slice(0, 10) === verify.dateOfBirth && sameState(row.state, verify.state)) return opts.checkSheet ? await withPendingSheetUpdate(db, row) : { source: "database", row };
      throw new VisitorError(NO_MATCH);
    }
  } catch (e) {
    if (e instanceof VisitorError) throw e;
    console.error("Registration lookup in the database failed; trying the Google Sheet.", e);
  }
  let found: Awaited<ReturnType<typeof findSheetRecord>>;
  try { found = await findSheetRecord(verify.ackNumber); }
  catch { throw new Error(dbReachable ? NO_MATCH : "Registrations cannot be opened right now. Please try again in a few minutes."); }
  if (!found || found.record.values.dateOfBirth !== verify.dateOfBirth || !sameState(String(found.record.values.state), verify.state)) throw new VisitorError(NO_MATCH);
  return { source: "sheet", sheet: found };
}

/** If newer answers wait in the sheet (saved while the database was down), copy them into the database first; if that still fails, work from the sheet. */
async function withPendingSheetUpdate(db: Client, row: Row): Promise<Located> {
  let sheet: Awaited<ReturnType<typeof findSheetRecord>> = null;
  try { sheet = await findSheetFor(row); } catch { return { source: "database", row }; }
  if (!sheet || sheet.record.meta.savedInDatabase !== UPDATE_PENDING) return { source: "database", row };
  const applied = await applySheetToDatabase(db, row, sheet.record);
  return applied.ok ? { source: "database", row: applied.row } : { source: "sheet", sheet };
}

/** Copies a sheet row's answers, encrypted bank/Aadhaar and payment ID into the matching database row, then marks the sheet row "Yes". */
async function applySheetToDatabase(db: Client, row: Row, record: SheetRecord): Promise<{ ok: true; row: Row } | { ok: false; reason: string }> {
  const now = new Date();
  if (row.payment_status !== "paid") {
    const completed = /^completed$/i.test(record.meta.formStatus);
    const parsed = completed
      ? educationCoreSchema.safeParse({ ...record.values, confirmAccurate: true, agreeTerms: true, consentVerification: true, authorizeContact: true, understandFees: true })
      : educationBasicSchema.safeParse({ ...record.values, coordinatorCode: String(record.values.coordinatorCode ?? "") });
    if (!parsed.success) return { ok: false, reason: parsed.error.issues[0]?.message ?? "Invalid details in the sheet." };
    const values = (completed ? parsed.data : { ...withBlanks(record.values), ...parsed.data }) as unknown as EducationCoreValues;
    const { declarations, guardian_consent_at, ...columns } = valuesToDbColumns(values, now);
    const update = {
      ...columns, updated_at: now.toISOString(),
      ...(completed ? { declarations, guardian_consent_at, form_status: "completed", coordinator_id: await coordinatorIdFor(db, values), ...(row.form_status === "completed" ? {} : { completed_at: now.toISOString() }) } : { guardian_consent_at: row.guardian_consent_at }),
      ...(record.meta.privateCiphertext && record.meta.privateCiphertext !== row.private_details_ciphertext ? { private_details_ciphertext: record.meta.privateCiphertext, aadhaar_last_four: record.meta.aadhaarLast4 || null } : {}),
    };
    const payment = row.payment_status === "pending" && record.meta.paymentStatus === "reference_submitted" && record.meta.paymentReference
      ? { payment_reference: record.meta.paymentReference, payment_reference_at: now.toISOString(), payment_status: "reference_submitted" } : {};
    let { error } = await db.from("education_support_registrations").update({ ...update, ...payment }).eq("id", row.id).neq("payment_status", "paid");
    if (error?.code === "23505") ({ error } = await db.from("education_support_registrations").update(update).eq("id", row.id).neq("payment_status", "paid"));
    if (error) { console.error("Pending sheet answers could not be copied to the database", error); return { ok: false, reason: "The database refused this row." }; }
  }
  const { data, error } = await db.from("education_support_registrations").select(`id, ${dbRegistrationColumns}`).eq("id", row.id).single();
  if (error || !data) return { ok: false, reason: "The database row could not be read back." };
  const updated = data as Row;
  if (updated.form_status === "completed") { try { const { refreshEducationChecks } = await import("./checks.server"); await refreshEducationChecks(db, updated.id, { ai: false }); } catch (e) { console.error("Checks after sheet update failed", e); } }
  try { await syncRowToSheet(updated); } catch (e) { console.error("Sheet row could not be marked as saved", e); }
  return { ok: true, row: updated };
}

const editableValues = (values: Record<FormFieldKey, string | boolean>) => ({ ...values, confirmAccurate: false, agreeTerms: false, consentVerification: false, authorizeContact: false, understandFees: false });

export async function lookupForEdit(verify: EducationLookup) {
  await safeLimit(`edit:${verify.ackNumber}`);
  const found = await locate(verify);
  const paymentStatus = found.source === "database" ? found.row.payment_status : found.sheet.record.meta.paymentStatus || "pending";
  const blocker = editBlocker(paymentStatus, "student");
  if (blocker) throw new VisitorError(blocker);
  const values = found.source === "database" ? dbRowToValues(found.row) : found.sheet.record.values;
  const formStatus = found.source === "database" ? found.row.form_status : /^completed$/i.test(found.sheet.record.meta.formStatus) ? "completed" : "started";
  const hasPrivateDetails = found.source === "database" ? Boolean(found.row.private_details_ciphertext) : Boolean(found.sheet.record.meta.privateCiphertext);
  return { ackNumber: verify.ackNumber, paymentStatus, formStatus, hasPrivateDetails, source: found.source, applicationType: String(values.applicationType) as ApplicationType, fee: applicationTypes[String(values.applicationType) as ApplicationType]?.fee ?? 0, values: editableValues(values) };
}

/** Saves what the student has entered so far (database; the Google Sheet takes it whenever the database fails). */
export async function saveProgress(verify: EducationLookup, raw: Record<string, unknown>) {
  const basic = educationBasicSchema.parse({ ...raw, coordinatorCode: typeof raw["coordinatorCode"] === "string" ? raw["coordinatorCode"] : "" });
  const values = { ...withBlanks(raw), ...basic };
  // Saved on every step, so skip the extra sheet read here; reopening and final submission pick up pending sheet answers.
  const found = await locate(verify, { checkSheet: false });
  const now = new Date();
  if (found.source === "database") {
    const row = found.row;
    const blocker = editBlocker(row.payment_status, "student") ?? applicationTypeChangeBlocker(row.application_type, basic.applicationType, row.payment_status, "student");
    if (blocker) throw new VisitorError(blocker);
    try {
      const db = await admin();
      const columns = valuesToDbColumns(values as unknown as EducationCoreValues, now);
      const { declarations: _d, ...rest } = columns;
      const { error } = await db.from("education_support_registrations").update({ ...rest, guardian_consent_at: row.guardian_consent_at, updated_at: now.toISOString() }).eq("id", row.id).neq("payment_status", "paid");
      if (error) throw error;
      return { ok: true, verify: { ackNumber: verify.ackNumber, dateOfBirth: basic.dateOfBirth, state: basic.state } };
    } catch (e) { console.error("Progress could not be saved in the database; saving it in the Google Sheet.", e); }
  } else {
    const paymentStatus = found.sheet.record.meta.paymentStatus || "pending";
    const blocker = editBlocker(paymentStatus, "student") ?? applicationTypeChangeBlocker(String(found.sheet.record.values.applicationType), basic.applicationType, paymentStatus, "student");
    if (blocker) throw new VisitorError(blocker);
  }
  await writeToSheet(found, now, r => buildSheetRecord(values, { ...r.meta, editedAt: istTimestamp(now), editedBy: "Student", fee: String(applicationTypes[basic.applicationType as ApplicationType].fee) }), "Your progress could not be saved. Please try again.");
  return { ok: true, verify: { ackNumber: verify.ackNumber, dateOfBirth: basic.dateOfBirth, state: basic.state } };
}

/** Final submission (also used to save later edits): all steps must be complete. */
export async function saveFullRegistration(verify: EducationLookup, core: EducationCoreValues, priv: EducationPrivateValues | null) {
  await safeLimit(`edit:${verify.ackNumber}`);
  const found = await locate(verify);
  const actor: EditActor = "student";
  const now = new Date();
  const paymentStatus = found.source === "database" ? found.row.payment_status : found.sheet.record.meta.paymentStatus || "pending";
  const oldType = found.source === "database" ? found.row.application_type : String(found.sheet.record.values.applicationType);
  const hasPrivate = found.source === "database" ? Boolean(found.row.private_details_ciphertext) : Boolean(found.sheet.record.meta.privateCiphertext);
  const blocker = paymentRequiredBlocker(paymentStatus, actor) ?? editBlocker(paymentStatus, actor) ?? applicationTypeChangeBlocker(oldType, core.applicationType, paymentStatus, actor);
  if (blocker) throw new VisitorError(blocker);
  if (!priv && !hasPrivate) throw new VisitorError("Please enter your bank and Aadhaar details.");
  if (found.source === "database") {
    try { const db = await admin(); return await updateDatabaseRow(db, db, found.row, core, priv, actor, now); }
    catch (e) {
      if (e instanceof VisitorError) throw e;
      console.error("Final submission could not be saved in the database; saving it in the Google Sheet.", e);
    }
  }
  const encrypted = priv ? await encryptPrivate(priv) : null;
  await writeToSheet(found, now, r => {
    const next = buildSheetRecord(core as unknown as Record<FormFieldKey, string | boolean>, { ...r.meta, formStatus: "Completed", declarations: "Yes", editedAt: istTimestamp(now), editedBy: "Student", fee: String(applicationTypes[core.applicationType as ApplicationType].fee) });
    if (priv && encrypted) { next.meta.privateCiphertext = encrypted; next.meta.bankLast4 = priv.bankAccount.slice(-4); next.meta.aadhaarLast4 = priv.aadhaarNumber.slice(-4); }
    return next;
  }, "Your registration could not be saved. Please try again in a few minutes.");
  const createdAt = found.source === "database" ? found.row.created_at : found.sheet.record.meta.submittedAt;
  return { ackNumber: verify.ackNumber, paymentStatus, fee: applicationTypes[core.applicationType as ApplicationType].fee, applicationType: core.applicationType as ApplicationType, createdAt };
}

/** `client` performs the update (admin session or service role); `lookup` resolves coordinator codes. */
async function updateDatabaseRow(client: Client, lookup: Client, row: Row, core: EducationCoreValues, priv: EducationPrivateValues | null, actor: EditActor, now: Date) {
  const blocker = editBlocker(row.payment_status, actor) ?? applicationTypeChangeBlocker(row.application_type, core.applicationType, row.payment_status, actor);
  if (blocker) throw new VisitorError(blocker);
  const update = {
    ...valuesToDbColumns(core, now), coordinator_id: await coordinatorIdFor(lookup, core), updated_at: now.toISOString(),
    form_status: "completed", ...(row.form_status === "completed" ? {} : { completed_at: now.toISOString() }),
    ...(priv ? { private_details_ciphertext: await encryptPrivate(priv), aadhaar_last_four: priv.aadhaarNumber.slice(-4) } : {}),
  };
  let q = client.from("education_support_registrations").update(update).eq("id", row.id);
  if (actor === "student") q = q.neq("payment_status", "paid");
  const { data, error } = await q.select(`id, ${dbRegistrationColumns}`);
  if (error || !data?.length) { console.error("Education registration update failed", error); throw new Error("Your changes could not be saved. Please try again."); }
  const updated = data[0] as Row;
  try { const { refreshEducationChecks } = await import("./checks.server"); await refreshEducationChecks(client, row.id, { ai: false }); }
  catch (e) { console.error("Education checks after edit failed", e); }
  try { await syncRowToSheet(updated, { at: now, by: actor === "admin" ? "Admin" : "Student" }); }
  catch (e) { console.error("Edited registration could not be copied to the Google Sheet.", e); }
  return { ackNumber: updated.ack_number, paymentStatus: updated.payment_status, fee: updated.registration_fee, applicationType: updated.application_type as ApplicationType, createdAt: updated.created_at };
}

export async function getForAdmin(client: Client, id: string) {
  const { data, error } = await client.from("education_support_registrations").select(`id, ${dbRegistrationColumns}`).eq("id", id).single();
  if (error || !data) throw new Error("Registration not found.");
  const row = data as Row;
  return { ackNumber: row.ack_number, paymentStatus: row.payment_status, values: { ...dbRowToValues(row), confirmAccurate: true, agreeTerms: true, consentVerification: true, authorizeContact: true, understandFees: true } };
}

export async function updateFromAdmin(client: Client, id: string, core: EducationCoreValues, priv: EducationPrivateValues | null) {
  const { data, error } = await client.from("education_support_registrations").select(`id, ${dbRegistrationColumns}`).eq("id", id).single();
  if (error || !data) throw new Error("Registration not found.");
  return updateDatabaseRow(client, await admin(), data as Row, core, priv, "admin", new Date());
}

/** Two-way catch-up: backup-only sheet rows go into the database, and database rows missing from the sheet are added to it. */
export async function syncWithSheet() {
  const db = await admin();
  const sheetRows = await readAllSheetRecords();
  const dbAcks = new Set<string>();
  const renamed = new Map<string, string>(); // pre-payment Registration ID -> acknowledgement number
  for (let from = 0; ; from += 1000) {
    const { data, error } = await db.from("education_support_registrations").select("ack_number, registration_id").order("created_at").range(from, from + 999);
    if (error) throw new Error("The database could not be read. Please try again.");
    for (const r of data ?? []) { dbAcks.add(r.ack_number); if (r.registration_id && r.registration_id !== r.ack_number) renamed.set(r.registration_id, r.ack_number); }
    if (!data || data.length < 1000) break;
  }
  const marked: typeof sheetRows = [];
  const skipped: { ackNumber: string; reason: string }[] = [];
  let imported = 0;
  let updated = 0;
  const seen = new Set<string>();
  for (const raw of sheetRows) {
    const newAck = renamed.get(raw.record.meta.ackNumber);
    // A row still under its pre-payment Registration ID takes the acknowledgement number issued since.
    const s = newAck ? { ...raw, record: { ...raw.record, meta: { ...raw.record.meta, ackNumber: newAck } } } : raw;
    if (newAck && !seen.has(newAck)) marked.push(s);
    const ack = s.record.meta.ackNumber;
    if (seen.has(ack)) continue;
    seen.add(ack);
    if (dbAcks.has(ack) && s.record.meta.savedInDatabase === UPDATE_PENDING) {
      const { data: row } = await db.from("education_support_registrations").select(`id, ${dbRegistrationColumns}`).eq("ack_number", ack).single();
      const applied = row ? await applySheetToDatabase(db, row as Row, s.record) : { ok: false as const, reason: "The database row could not be read." };
      if (applied.ok) { updated++; const i = marked.indexOf(s); if (i >= 0) marked.splice(i, 1); } else skipped.push({ ackNumber: ack, reason: applied.reason });
      continue;
    }
    if (dbAcks.has(ack)) {
      if (s.record.meta.savedInDatabase !== "Yes") { const i = marked.indexOf(s); if (i >= 0) marked.splice(i, 1); marked.push({ ...s, record: { ...s.record, meta: { ...s.record.meta, savedInDatabase: "Yes" } } }); }
      continue;
    }
    if (!isBackupAck(ack)) { skipped.push({ ackNumber: ack, reason: "Not a backup number and not found in the database." }); continue; }
    const completed = /^completed$/i.test(s.record.meta.formStatus);
    const parsed = completed
      ? educationCoreSchema.safeParse({ ...s.record.values, confirmAccurate: true, agreeTerms: true, consentVerification: true, authorizeContact: true, understandFees: true })
      : educationBasicSchema.safeParse({ ...s.record.values, coordinatorCode: String(s.record.values.coordinatorCode ?? "") });
    if (!parsed.success) { skipped.push({ ackNumber: ack, reason: parsed.error.issues[0]?.message ?? "Invalid details in the sheet." }); continue; }
    if (!s.record.meta.receiptHash || !/^[a-f0-9]{64}$/.test(s.record.meta.receiptHash)) { skipped.push({ ackNumber: ack, reason: "Receipt check column is missing or was changed." }); continue; }
    const createdAt = new Date(s.record.meta.submittedAt);
    const created = Number.isNaN(createdAt.getTime()) ? new Date() : createdAt;
    const pay = ["pending", "reference_submitted"].includes(s.record.meta.paymentStatus) ? s.record.meta.paymentStatus : "pending";
    const values = completed ? parsed.data as EducationCoreValues : withBlanks(s.record.values) as unknown as EducationCoreValues;
    const columns = valuesToDbColumns(values, created);
    const { data: inserted, error } = await db.from("education_support_registrations").insert({
      ...columns, ...(completed ? { completed_at: created.toISOString() } : { declarations: {}, guardian_consent_at: null }),
      form_status: completed ? "completed" : "started", ack_number: ack, created_at: created.toISOString(),
      coordinator_id: await coordinatorIdFor(db, values), receipt_token_hash: s.record.meta.receiptHash,
      private_details_ciphertext: s.record.meta.privateCiphertext || null, aadhaar_last_four: s.record.meta.aadhaarLast4 || null,
      payment_status: pay, payment_reference: pay === "reference_submitted" ? s.record.meta.paymentReference || null : null,
    }).select("id, ack_number").single();
    if (error || !inserted) { skipped.push({ ackNumber: ack, reason: error?.code === "23505" ? "Payment ID already used by another registration." : "The database refused this row." }); continue; }
    imported++;
    if (completed) try { const { refreshEducationChecks } = await import("./checks.server"); await refreshEducationChecks(db, inserted.id, { ai: false }); } catch (e) { console.error("Checks after sheet import failed", e); }
    // A backup row with a payment ID gets its real acknowledgement number on import.
    seen.add(inserted.ack_number);
    marked.push({ ...s, record: { ...s.record, meta: { ...s.record.meta, ackNumber: inserted.ack_number, savedInDatabase: "Yes", dbNote: "" } } });
  }
  await writeSheetRows(marked);

  const missing = [...dbAcks].filter(a => !seen.has(a));
  let appended = 0;
  for (let i = 0; i < missing.length; i += 100) {
    const { data } = await db.from("education_support_registrations").select(`id, ${dbRegistrationColumns}`).in("ack_number", missing.slice(i, i + 100)).order("created_at");
    const records = await Promise.all(((data ?? []) as Row[]).map(async r => dbRowToSheetRecord(r, { bankLast4: await bankLast4Of(r.private_details_ciphertext) })));
    await appendSheetRecords(records);
    appended += records.length;
  }
  return { imported, updated, appended, skipped };
}
