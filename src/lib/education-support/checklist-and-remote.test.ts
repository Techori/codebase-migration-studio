import { describe, expect, it } from "vitest";
import { checklistInputSchema, hasSensitiveDetail, missingChecklistItems } from "./checklist";
import { HOME_BACKEND_ID, HOME_ORIGIN, homeBaseFor } from "./remote";

const base = { lang: "en" as const, studentCategory: "school" as const, classOrCourse: "10", applicationType: "sponsorship" as const, state: "Madhya Pradesh", under18: true, infoReady: [], documentsReady: [], note: "" };

describe("student AI checklist accepts only non-sensitive details", () => {
  it("rejects a 12-digit Aadhaar-like number in the note", () => {
    expect(checklistInputSchema.safeParse({ ...base, note: "my aadhaar 2345 6789 0123" }).success).toBe(false);
  });
  it("rejects a 10-digit mobile number in the note", () => {
    expect(hasSensitiveDetail("call 9876543210")).toBe(true);
  });
  it("rejects an email address and an IFSC code", () => {
    expect(hasSensitiveDetail("student@example.com")).toBe(true);
    expect(hasSensitiveDetail("SBIN0001234")).toBe(true);
  });
  it("accepts ordinary notes with class numbers and years", () => {
    expect(checklistInputSchema.safeParse({ ...base, note: "Class 10, changed school in 2026" }).success).toBe(true);
  });
  it("skips guardian details for students 18 or older", () => {
    expect(missingChecklistItems({ infoReady: [], documentsReady: [], under18: false }).info.some(i => /guardian/i.test(i))).toBe(false);
    expect(missingChecklistItems({ infoReady: [], documentsReady: [], under18: true }).info.some(i => /guardian/i.test(i))).toBe(true);
  });
});

describe("scholarship form responses from every website address reach this project", () => {
  it("riloyd.in built with another backend sends to the published Lovable site", () => {
    expect(homeBaseFor("www.riloyd.in", "vkufohqqgzyjvcqmkodd")).toBe(HOME_ORIGIN);
    expect(homeBaseFor("riloyd.in", undefined)).toBe(HOME_ORIGIN);
  });
  it("this project's own builds and Lovable addresses save directly", () => {
    expect(homeBaseFor("www.riloyd.in", HOME_BACKEND_ID)).toBe("");
    expect(homeBaseFor("scholar-spark-sponsor-hub.lovable.app", "other")).toBe("");
  });
});
