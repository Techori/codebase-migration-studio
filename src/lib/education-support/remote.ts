// Browser-safe: copies of this site built elsewhere (riloyd.in is currently served by another host with another
// database) send scholarship form actions to the published Lovable site, so every response reaches this
// project's database and Google Sheet.

/** Published Lovable address of this project. Update if the Lovable URL name changes. */
export const HOME_ORIGIN = "https://scholar-spark-sponsor-hub.lovable.app";
/** Backend this project's own builds use. */
export const HOME_BACKEND_ID = "bsccjowqfsngafbiirxg";

export type EducationAction = "start" | "payment" | "lookup" | "progress" | "submit" | "referral" | "checklist";

const lovableHost = (host: string) => host === "localhost" || host === "127.0.0.1" || host.endsWith(".lovable.app") || host.endsWith(".lovableproject.com") || host.endsWith(".lovable.dev");

/** "" when this build talks to this project's own backend; otherwise the published Lovable address. */
export function homeBaseFor(host: string, backendId: string | undefined): string {
  if (lovableHost(host) || backendId === HOME_BACKEND_ID) return "";
  return HOME_ORIGIN;
}
export function educationHomeBase(): string {
  if (typeof window === "undefined") return "";
  return homeBaseFor(window.location.hostname, import.meta.env["VITE_SUPABASE_PROJECT_ID"] as string | undefined);
}

export async function callEducationHome<R>(base: string, action: EducationAction, data: unknown): Promise<R> {
  let res: Response;
  try { res = await fetch(`${base}/api/public/education/${action}`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(data) }); }
  catch { throw new Error("Could not connect. Please check your internet and try again."); }
  const body = (await res.json().catch(() => null)) as { result?: R; error?: string } | null;
  if (!res.ok || !body || !("result" in body)) throw new Error(body?.error || "Please try again in a few minutes.");
  return body.result as R;
}

/** Wraps a server function so builds outside this project send the same call to the published Lovable site. */
export function viaHome<A, R>(fn: (opts: { data: A }) => Promise<R>, action: EducationAction): (opts: { data: A }) => Promise<R> {
  return opts => {
    const base = educationHomeBase();
    return base ? callEducationHome<R>(base, action, opts.data) : fn(opts);
  };
}
