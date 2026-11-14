import { createServerFn } from "@tanstack/react-start";
import { enquirySchema } from "./submission-schemas";

export const submitEnquiry = createServerFn({ method: "POST" })
  .inputValidator((data: unknown) => enquirySchema.parse(data))
  .handler(async ({ data }) => {
    const { limitSubmission } = await import("./submissions.server");
    await limitSubmission(data.email);
    const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
    const { data: saved, error } = await supabaseAdmin.from("contact_submissions").insert(data).select("ack_number").single();
    if (error || !saved) throw new Error("Your message could not be saved. Please try again.");
    return { ok: true, ackNumber: saved.ack_number };
  });