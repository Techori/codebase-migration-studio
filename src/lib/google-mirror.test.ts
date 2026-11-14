import { describe, expect, it } from "vitest";
import { ID_HEADER, MIRROR_TABS, cellsToRow, mergeHeaders, placeRows, rowToCells } from "./google-mirror";

describe("Google Sheet copy", () => {
  it("sends every website form to its own tab", () => {
    expect(Object.values(MIRROR_TABS).map(t => t.tab)).toEqual([
      "Enquiries", "Registrations", "Programme applications", "Foundation", "Young Innovators", "Prototype checks", "CRM leads", "Payments",
    ]);
  });

  it("puts the record ID first and never copies private check values", () => {
    const cells = rowToCells({ id: "abc", full_name: "Asha", receipt_token_hash: "secret", private_details_ciphertext: "x", document_path: "abc/doc.pdf", details: { city: "Patna" } });
    expect(Object.keys(cells)[0]).toBe(ID_HEADER);
    expect(cells[ID_HEADER]).toBe("abc");
    expect(cells["Full name"]).toBe("Asha");
    expect(cells["Details – City"]).toBe("Patna");
    expect(Object.values(cells)).not.toContain("secret");
    expect(Object.values(cells)).not.toContain("x");
    expect(Object.values(cells)).not.toContain("abc/doc.pdf");
  });

  it("adds new columns at the end without moving existing ones", () => {
    const header = mergeHeaders([ID_HEADER, "Status"], [{ [ID_HEADER]: "1", "Full name": "A", Status: "new" }]);
    expect(header).toEqual([ID_HEADER, "Status", "Full name"]);
    expect(cellsToRow({ [ID_HEADER]: "1", "Full name": "A", Status: "new" }, header)).toEqual(["1", "new", "A"]);
  });

  it("updates a record's existing row and appends new ones after the last row", () => {
    const placed = placeRows([ID_HEADER, "a", "b"], ["b", "c", "d"]);
    expect(placed.get("b")).toBe(3);
    expect(placed.get("c")).toBe(4);
    expect(placed.get("d")).toBe(5);
  });
});
