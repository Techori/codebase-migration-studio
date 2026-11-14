import { createServerFn } from "@tanstack/react-start";
import { checklistInputSchema } from "./education-support/checklist";

/** Student AI checklist (public, rate-limited per visitor; no contact, bank or Aadhaar details accepted). */
export const getEducationChecklist = createServerFn({ method: "POST" })
  .inputValidator((input: unknown) => checklistInputSchema.parse(input))
  .handler(async ({ data }) => {
    const { limitSubmission } = await import("./submissions.server");
    await limitSubmission("edu-checklist", { failOpen: true, ipOnly: true });
    const { generateEducationChecklist } = await import("./education-support/checklist.server");
    return generateEducationChecklist(data);
  });
