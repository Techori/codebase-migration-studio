import { applicationTypes, paymentStatusLabels, type ApplicationType } from "./rules";

// Builds the acknowledgement PDF in the browser; jsPDF loads only when requested.
export type AckData = { ackNumber: string; studentName: string; createdAt: string; category: string; classOrCourse: string; sector: string; applicationType: ApplicationType; paymentStatus: keyof typeof paymentStatusLabels; coordinatorName: string; registrationId?: string | null };

/** Registration columns the CRM needs to rebuild the acknowledgement PDF (no contact or bank details). */
export type AckSourceRow = { ack_number: string; registration_id: string | null; created_at: string; student_name: string; student_category: string; current_class: string | null; course_name: string | null; education_sector: string | null; application_type: string; payment_status: string; without_coordinator: boolean; coordinator: unknown };
export const ackSourceColumns = "ack_number, registration_id, created_at, student_name, student_category, current_class, course_name, education_sector, application_type, payment_status, without_coordinator, coordinator";

/** Same PDF details the student downloads, built from a saved registration row. */
export function ackDataFromRow(r: AckSourceRow): AckData {
  const school = r.student_category === "school";
  const c = (r.coordinator && typeof r.coordinator === "object" ? r.coordinator : {}) as Record<string, unknown>;
  const pay = (r.payment_status in paymentStatusLabels ? r.payment_status : "pending") as AckData["paymentStatus"];
  return {
    ackNumber: r.ack_number, registrationId: r.registration_id, studentName: r.student_name, createdAt: r.created_at,
    category: school ? "School student" : r.student_category === "ug" ? "Undergraduate (UG)" : "Postgraduate (PG)",
    classOrCourse: school ? (r.current_class ? `Class ${r.current_class}` : "") : (r.course_name ?? ""),
    sector: r.education_sector ?? "", applicationType: (r.application_type in applicationTypes ? r.application_type : "scholarship") as ApplicationType,
    paymentStatus: pay, coordinatorName: r.without_coordinator ? "" : String(c["name"] ?? ""),
  };
}

export async function buildAcknowledgementPdf(d: AckData): Promise<Blob> {
  const { jsPDF } = await import("jspdf");
  const doc = new jsPDF({ unit: "pt", format: "a4" });
  const app = applicationTypes[d.applicationType];
  doc.setFillColor(11, 31, 75); doc.rect(0, 0, 595, 110, "F");
  doc.setTextColor(255, 255, 255); doc.setFont("helvetica", "bold"); doc.setFontSize(20);
  doc.text("RILOYD Foundation", 40, 50);
  doc.setFontSize(12); doc.setFont("helvetica", "normal");
  doc.text("Education Support – Student Scholarship & Sponsorship Registration", 40, 75);
  doc.setTextColor(15, 23, 42); doc.setFont("helvetica", "bold"); doc.setFontSize(14);
  doc.text("Registration Acknowledgement", 40, 150);
  doc.setFontSize(22); doc.setTextColor(29, 78, 216); doc.text(d.ackNumber, 40, 182);
  const rows: [string, string][] = [
    ...(d.registrationId ? [["Registration ID", d.registrationId] as [string, string]] : []),
    ["Student name", d.studentName], ["Registration date", new Date(d.createdAt).toLocaleString("en-IN")], ["Student category", d.category],
    ["Class / course", d.classOrCourse || "—"], ["Education sector", d.sector || "—"], ["Applied for", app.en],
    ["Registration fee", `Rs. ${app.fee}`], ["Payment status", paymentStatusLabels[d.paymentStatus]], ["Coordinator", d.coordinatorName || "Registered without a coordinator"],
  ];
  doc.setFontSize(11); let y = 220;
  for (const [k, v] of rows) { doc.setTextColor(100, 116, 139); doc.setFont("helvetica", "normal"); doc.text(k, 40, y); doc.setTextColor(15, 23, 42); doc.setFont("helvetica", "bold"); doc.text(doc.splitTextToSize(v, 330), 220, y); y += 28; }
  doc.setFont("helvetica", "normal"); doc.setFontSize(9); doc.setTextColor(71, 85, 105);
  doc.text(doc.splitTextToSize("Scholarship amounts are maximum potential awards, not guaranteed payments. The registration fee is separate from selection; final eligibility and award amounts depend on verification and the official decision. Keep this acknowledgement number for all communication.", 515), 40, y + 20);
  const QRCode = await import('qrcode');
  const qr = await QRCode.toDataURL(`RILOYD Education Support\nAcknowledgement: ${d.ackNumber}${d.registrationId ? `\nRegistration ID: ${d.registrationId}` : ""}`, { width: 240, margin: 2, errorCorrectionLevel: 'M' });
  doc.addImage(qr, 'PNG', 40, y + 90, 90, 90);
  doc.text('Registration reference QR — not proof of payment or approval.', 145, y + 135);
  return doc.output("blob");
}
