// Copies queued website records to the "RILOYD Website Data" Google Sheet and uploaded documents to Google Drive (server only).
import { ID_HEADER, MIRROR_TABS, cellsToRow, columnLetter, isMirrorTable, mergeHeaders, placeRows, rowToCells, type MirrorTable } from "./google-mirror";

const SHEETS_URL = "https://connector-gateway.lovable.dev/google_sheets/v4";
const DRIVE_UPLOAD_URL = "https://connector-gateway.lovable.dev/google_drive/upload/drive/v3/files";
const ROW_BATCH = 300;
const FILE_BATCH = 8;

type QueueEntry = { id: number; source_table: string; row_id: string; kind: string; queued_at: string; attempts: number };
type Meta = { sheets?: { properties?: { sheetId?: number; title?: string; gridProperties?: { rowCount?: number; columnCount?: number } } }[] };

function env(name: string) {
  const v = process.env[name];
  if (!v) throw new Error(`${name} is not configured`);
  return v;
}

async function google<T>(url: string, connectionKey: string, init: { method?: string; body?: BodyInit; contentType?: string } = {}): Promise<T> {
  const res = await fetch(url, {
    method: init.method ?? "GET",
    headers: { Authorization: `Bearer ${env("LOVABLE_API_KEY")}`, "X-Connection-Api-Key": connectionKey, ...(init.body ? { "Content-Type": init.contentType ?? "application/json" } : {}) },
    ...(init.body ? { body: init.body } : {}),
  });
  if (!res.ok) {
    const text = await res.text();
    console.error(`Google request failed [${res.status}]: ${text}`);
    throw new Error(`Google request failed [${res.status}]: ${text.slice(0, 300)}`);
  }
  return res.json() as Promise<T>;
}

function sheets<T>(path: string, init: { method?: string; body?: unknown } = {}) {
  const url = `${SHEETS_URL}/spreadsheets/${env("EDUCATION_SHEET_ID")}${path}`;
  return google<T>(url, env("GOOGLE_SHEETS_API_KEY"), { method: init.method, ...(init.body === undefined ? {} : { body: JSON.stringify(init.body) }) });
}

const quoted = (tab: string) => `'${tab.replace(/'/g, "''")}'`;

async function admin() {
  const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
  return supabaseAdmin;
}

async function markFailed(ids: number[], entries: QueueEntry[], message: string) {
  if (!ids.length) return;
  const db = await admin();
  for (const e of entries.filter(x => ids.includes(x.id))) {
    await db.from("sheet_mirror_queue").update({ attempts: e.attempts + 1, last_error: message.slice(0, 500) }).eq("id", e.id).eq("queued_at", e.queued_at);
  }
}

async function finish(entries: QueueEntry[]) {
  const db = await admin();
  // Only remove entries that were not re-queued (changed again) while this run was working.
  for (const e of entries) await db.from("sheet_mirror_queue").delete().eq("id", e.id).eq("queued_at", e.queued_at);
}

async function mirrorRows(entries: QueueEntry[]) {
  if (!entries.length) return 0;
  const db = await admin();
  const byTable = new Map<MirrorTable, QueueEntry[]>();
  for (const e of entries) if (isMirrorTable(e.source_table)) byTable.set(e.source_table, [...(byTable.get(e.source_table) ?? []), e]);

  const records = new Map<MirrorTable, Record<string, string>[]>();
  for (const [table, list] of byTable) {
    const { data, error } = await db.from(table).select(MIRROR_TABS[table].select).in("id", list.map(e => e.row_id));
    if (error) throw new Error(`Could not read ${table}: ${error.message}`);
    records.set(table, ((data ?? []) as unknown as Record<string, unknown>[]).map(rowToCells));
  }

  // Make sure every tab exists, then read each tab's header row and ID column in one request.
  const meta = await sheets<Meta>("?fields=sheets.properties");
  const tabs = new Map((meta.sheets ?? []).map(s => [s.properties?.title ?? "", s.properties]));
  const missing = [...byTable.keys()].map(t => MIRROR_TABS[t].tab).filter(t => !tabs.has(t));
  if (missing.length) {
    const added = await sheets<{ replies?: { addSheet?: { properties?: { sheetId?: number; title?: string; gridProperties?: { rowCount?: number; columnCount?: number } } } }[] }>(":batchUpdate", { method: "POST", body: { requests: missing.map(title => ({ addSheet: { properties: { title } } })) } });
    for (const r of added.replies ?? []) if (r.addSheet?.properties?.title) tabs.set(r.addSheet.properties.title, r.addSheet.properties);
  }
  const order = [...byTable.keys()];
  const ranges = order.flatMap(t => [`${quoted(MIRROR_TABS[t].tab)}!1:1`, `${quoted(MIRROR_TABS[t].tab)}!A:A`]);
  const got = await sheets<{ valueRanges?: { values?: string[][] }[] }>(`/values:batchGet?${ranges.map(r => `ranges=${encodeURIComponent(r)}`).join("&")}`);

  const writes: { range: string; values: string[][] }[] = [];
  const grow: unknown[] = [];
  order.forEach((table, i) => {
    const tab = MIRROR_TABS[table].tab;
    const existingHeader = got.valueRanges?.[i * 2]?.values?.[0] ?? [];
    const idColumn = (got.valueRanges?.[i * 2 + 1]?.values ?? []).map(r => r[0] ?? "");
    const rows = records.get(table) ?? [];
    const header = mergeHeaders(existingHeader, rows);
    if (header[0] !== ID_HEADER) throw new Error(`The first column of the "${tab}" tab must stay "${ID_HEADER}".`);
    const placed = placeRows(idColumn.length ? idColumn : [ID_HEADER], rows.map(r => r[ID_HEADER] ?? ""));
    if (header.length !== existingHeader.length) writes.push({ range: `${quoted(tab)}!A1:${columnLetter(header.length)}1`, values: [header] });
    for (const r of rows) {
      const at = placed.get(r[ID_HEADER] ?? "");
      if (at) writes.push({ range: `${quoted(tab)}!A${at}:${columnLetter(header.length)}${at}`, values: [cellsToRow(r, header)] });
    }
    // Google rejects writes outside the grid, so grow it first when needed.
    const props = tabs.get(tab);
    const lastRow = Math.max(0, ...placed.values());
    if (props?.sheetId !== undefined) {
      const rowsHave = props.gridProperties?.rowCount ?? 0;
      const colsHave = props.gridProperties?.columnCount ?? 0;
      if (lastRow > rowsHave) grow.push({ appendDimension: { sheetId: props.sheetId, dimension: "ROWS", length: lastRow - rowsHave + 200 } });
      if (header.length > colsHave) grow.push({ appendDimension: { sheetId: props.sheetId, dimension: "COLUMNS", length: header.length - colsHave } });
    }
  });
  if (grow.length) await sheets(":batchUpdate", { method: "POST", body: { requests: grow } });
  if (writes.length) await sheets("/values:batchUpdate", { method: "POST", body: { valueInputOption: "RAW", data: writes } });
  return [...records.values()].reduce((n, r) => n + r.length, 0);
}

async function copyDocument(entry: QueueEntry) {
  const db = await admin();
  const { data: app, error } = await db.from("registration_applications").select("id, application_code, full_name, document_path, document_name").eq("id", entry.row_id).maybeSingle();
  if (error) throw new Error(error.message);
  if (!app?.document_path) return;
  const { data: file, error: dlError } = await db.storage.from("registration-documents").download(app.document_path);
  if (dlError || !file) throw new Error(`Document could not be read: ${dlError?.message ?? "missing"}`);
  const boundary = `riloyd-${crypto.randomUUID()}`;
  const name = `${app.application_code} - ${app.full_name} - ${app.document_name ?? app.document_path.split("/").pop()}`;
  const metadata = JSON.stringify({ name, parents: [env("RILOYD_DRIVE_FOLDER_ID")] });
  const body = new Blob([
    `--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${metadata}\r\n--${boundary}\r\nContent-Type: ${file.type || "application/octet-stream"}\r\n\r\n`,
    await file.arrayBuffer(),
    `\r\n--${boundary}--`,
  ]);
  const uploaded = await google<{ id: string; webViewLink?: string }>(`${DRIVE_UPLOAD_URL}?uploadType=multipart&fields=id,webViewLink`, env("GOOGLE_DRIVE_API_KEY"), {
    method: "POST", body, contentType: `multipart/related; boundary=${boundary}`,
  });
  // Saving the link re-queues the row, so the sheet shows it on the next run.
  await db.from("registration_applications").update({ drive_file_url: uploaded.webViewLink ?? `https://drive.google.com/file/d/${uploaded.id}/view` }).eq("id", app.id);
}

/** One run: copy waiting documents to Drive, then waiting rows to the sheet. Failures stay queued for the next run. */
export async function runGoogleMirror() {
  const db = await admin();
  const { data, error } = await db.from("sheet_mirror_queue").select("id, source_table, row_id, kind, queued_at, attempts").order("queued_at").limit(ROW_BATCH + FILE_BATCH);
  if (error) throw new Error(`Queue could not be read: ${error.message}`);
  const queue = (data ?? []) as QueueEntry[];
  const files = queue.filter(e => e.kind === "file").slice(0, FILE_BATCH);
  const rows = queue.filter(e => e.kind === "row").slice(0, ROW_BATCH);

  let documents = 0;
  const failures: string[] = [];
  for (const f of files) {
    try { await copyDocument(f); await finish([f]); documents++; }
    catch (e) { const m = e instanceof Error ? e.message : String(e); failures.push(m); await markFailed([f.id], [f], m); }
  }
  let copied = 0;
  try { copied = await mirrorRows(rows); await finish(rows); }
  catch (e) { const m = e instanceof Error ? e.message : String(e); failures.push(m); await markFailed(rows.map(r => r.id), rows, m); }
  return { rows: copied, documents, failures };
}
