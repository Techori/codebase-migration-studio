import { createFileRoute } from "@tanstack/react-router";
import { authenticateCronRequest } from "@/integrations/supabase/cron-auth";

/** Scheduled: copies scholarship answers that only reached the Google Sheet into the database once it is available. */
export const Route = createFileRoute("/api/public/jobs/education-sheet-sync")({
  staticData: { sitemap: false },
  server: {
    handlers: {
      POST: async ({ request }) => {
        const authFailure = await authenticateCronRequest(request);
        if (authFailure) return authFailure;
        const { syncWithSheet } = await import("@/lib/education-support/registration-store.server");
        try {
          const result = await syncWithSheet();
          if (result.imported || result.updated || result.appended || result.skipped.length) console.log("Education sheet sync", JSON.stringify(result));
          return Response.json({ ok: true, ...result });
        } catch (e) {
          console.error("Education sheet sync failed; will retry on the next run", e);
          return Response.json({ ok: false, error: e instanceof Error ? e.message : "Sync failed" }, { status: 503 });
        }
      },
    },
  },
});
