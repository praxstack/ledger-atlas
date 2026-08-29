import { describe, expect, it } from "vitest";
import {
  calculateBalance,
  createTransaction,
  type Transaction,
} from "./ledger";

describe("ledger", () => {
  it("calculates balance from transactions", () => {
    const transactions: Transaction[] = [
      {
        id: "1",
        description: "Opening balance",
        amount: 100,
        createdAt: "2026-01-01T00:00:00.000Z",
      },
      {
        id: "2",
        description: "Coffee",
        amount: -4.5,
        createdAt: "2026-01-02T00:00:00.000Z",
      },
    ];

    expect(calculateBalance(transactions)).toBe(95.5);
  });

  it("rejects empty descriptions", () => {
    expect(() => createTransaction("   ", 10)).toThrow(
      "Description is required",
    );
  });

  it("rejects zero amounts", () => {
    expect(() => createTransaction("Rent", 0)).toThrow(
      "Amount must be a non-zero number",
    );
  });
});
