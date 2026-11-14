import { createFileRoute } from "@tanstack/react-router";

export const Route = createFileRoute("/api/public/education/$action")({
  staticData: { sitemap: false },
  server: {
    handlers: {
      OPTIONS: async ({ request }) => {
        const { educationCors } = await import("@/lib/education-support/public-api.server");
        return new Response(null, { status: 204, headers: educationCors(request.headers.get("origin")) });
      },
      POST: async ({ request, params }) => {
        const { handleEducationRequest } = await import("@/lib/education-support/public-api.server");
        return handleEducationRequest(request, params.action);
      },
    },
  },
});
