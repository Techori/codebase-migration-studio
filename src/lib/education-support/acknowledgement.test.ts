import { describe, expect, it } from "vitest";
import { ackDataFromRow, ackSourceColumns } from "./acknowledgement";

const row = { ack_number: "261114130100001", registration_id: "R261114130953463", created_at: "2026-11-14T07:26:55Z", student_name: "Asha Kumari", student_category: "school", current_class: "9", course_name: null, education_sector: "Science", application_type: "scholarship_25k", payment_status: "reference_submitted", without_coordinator: false, coordinator: { name: "Ravi", mobile: "9999999999" } };

describe("CRM acknowledgement PDF data", () => {
  it("keeps both the acknowledgement number and the Registration ID", () => {
    const d = ackDataFromRow(row);
    expect(d.ackNumber).toBe("261114130100001");
    expect(d.registrationId).toBe("R261114130953463");
    expect(d.classOrCourse).toBe("Class 9");
    expect(d.coordinatorName).toBe("Ravi");
  });
  it("never reads contact, bank or Aadhaar columns", () => {
    for (const col of ["mobile", "email", "aadhaar", "private_details", "payment_reference"]) expect(ackSourceColumns).not.toContain(col);
  });
});
