import { createFileRoute } from "@tanstack/react-router";
import { authenticateCronRequest } from "@/integrations/supabase/cron-auth";

/** Scheduled: copies new and changed form records to the Google Sheet and uploaded documents to Google Drive. */
export const Route = createFileRoute("/api/public/jobs/google-sheet-copy")({
  staticData: { sitemap: false },
  server: {
    handlers: {
      POST: async ({ request }) => {
        const authFailure = await authenticateCronRequest(request);
        if (authFailure) return authFailure;
        const { runGoogleMirror } = await import("@/lib/google-mirror.server");
        try {
          const result = await runGoogleMirror();
          if (result.rows || result.documents || result.failures.length) console.log("Google sheet copy", JSON.stringify(result));
          return Response.json({ ok: result.failures.length === 0, ...result }, { status: result.failures.length ? 503 : 200 });
        } catch (e) {
          console.error("Google sheet copy failed; will retry on the next run", e);
          return Response.json({ ok: false, error: e instanceof Error ? e.message : "Copy failed" }, { status: 503 });
        }
      },
    },
  },
});
