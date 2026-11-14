// Which website tables are copied to which tab of the "RILOYD Website Data" Google Sheet, and how a row becomes sheet cells.
// Browser-safe and pure, so it can be tested; the server job lives in google-mirror.server.ts.

export type MirrorTable =
  | "contact_submissions" | "registration_applications" | "programme_applications" | "foundation_submissions"
  | "young_innovators_registrations" | "prototype_submissions" | "crm_leads" | "programme_payments";

export const MIRROR_TABS: Record<MirrorTable, { tab: string; select: string }> = {
  contact_submissions: { tab: "Enquiries", select: "*" },
  registration_applications: { tab: "Registrations", select: "*" },
  programme_applications: { tab: "Programme applications", select: "*" },
  foundation_submissions: { tab: "Foundation", select: "*" },
  young_innovators_registrations: { tab: "Young Innovators", select: "*" },
  prototype_submissions: { tab: "Prototype checks", select: "*" },
  crm_leads: { tab: "CRM leads", select: "*, customer:crm_customers(customer_code, full_name, email, phone, company)" },
  programme_payments: { tab: "Payments", select: "*" },
};

export const ID_HEADER = "Record ID";

/** Internal columns that mean nothing in a sheet or must stay private. */
const HIDDEN = new Set(["id", "document_path", "receipt_token_hash", "private_details_ciphertext", "code_hash", "coordinator_id", "owner_id", "source_id", "customer_id", "application_id"]);

export function isMirrorTable(value: string): value is MirrorTable {
  return Object.prototype.hasOwnProperty.call(MIRROR_TABS, value);
}

export function headerFor(key: string, parent?: string): string {
  const label = key.replace(/_/g, " ").replace(/([a-z])([A-Z])/g, "$1 $2").trim();
  const nice = label.charAt(0).toUpperCase() + label.slice(1);
  return parent ? `${headerFor(parent)} – ${nice}` : nice;
}

function cell(value: unknown): string {
  if (value === null || value === undefined) return "";
  if (Array.isArray(value)) return value.map(v => (typeof v === "object" && v !== null ? JSON.stringify(v) : String(v))).join(", ");
  if (typeof value === "object") return JSON.stringify(value);
  if (typeof value === "boolean") return value ? "Yes" : "No";
  return String(value);
}

/** One database row → { header: text }, with the record ID first and JSON details spread over their own columns. */
export function rowToCells(row: Record<string, unknown>): Record<string, string> {
  const out: Record<string, string> = { [ID_HEADER]: String(row["id"] ?? "") };
  for (const [key, value] of Object.entries(row)) {
    if (HIDDEN.has(key)) continue;
    if (value && typeof value === "object" && !Array.isArray(value)) {
      for (const [sub, inner] of Object.entries(value as Record<string, unknown>)) out[headerFor(sub, key)] = cell(inner);
    } else out[headerFor(key)] = cell(value);
  }
  return out;
}

/** Existing header row plus any new headers appended at the end (existing order is never changed). */
export function mergeHeaders(existing: string[], rows: Record<string, string>[]): string[] {
  const header = existing.length ? [...existing] : [ID_HEADER];
  if (header[0] !== ID_HEADER && !header.includes(ID_HEADER)) header.unshift(ID_HEADER);
  const have = new Set(header);
  for (const r of rows) for (const h of Object.keys(r)) if (!have.has(h)) { have.add(h); header.push(h); }
  return header;
}

export function cellsToRow(cells: Record<string, string>, header: string[]): string[] {
  return header.map(h => cells[h] ?? "");
}

/** Decide which sheet row each record goes to: its existing row when the ID is already listed, else the next free rows. */
export function placeRows(idColumn: string[], ids: string[]): Map<string, number> {
  const at = new Map<string, number>();
  idColumn.forEach((v, i) => { if (i > 0 && v) at.set(v.trim(), i + 1); });
  let next = Math.max(idColumn.length, 1) + 1;
  const placed = new Map<string, number>();
  for (const id of ids) {
    if (placed.has(id)) continue;
    const existing = at.get(id);
    placed.set(id, existing ?? next++);
  }
  return placed;
}

export function columnLetter(n: number): string {
  let s = "";
  for (let x = n; x > 0; x = Math.floor((x - 1) / 26)) s = String.fromCharCode(65 + ((x - 1) % 26)) + s;
  return s;
}
