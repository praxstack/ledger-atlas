import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";

let sandbox: string;
let file: string;
let ledger: typeof import("./ledger");

beforeEach(async () => {
  sandbox = await mkdtemp(path.join(tmpdir(), "ledger-persistence-"));
  file = path.join(sandbox, "data", "transactions.json");
  // Resolve the existing public store against a disposable working directory.
  vi.spyOn(process, "cwd").mockReturnValue(sandbox);
  vi.resetModules();
  ledger = await import("./ledger");
});

afterEach(async () => {
  vi.restoreAllMocks();
  await rm(sandbox, { recursive: true, force: true });
});

describe("public ledger persistence", () => {
  it("starts empty, imports a snapshot and retains a subsequent addition", async () => {
    expect(await ledger.readLedger()).toEqual({ transactions: [] });
    const imported = ledger.createTransaction("Opening", 100);
    await ledger.writeLedger({ transactions: [imported] });
    const added = await ledger.addTransaction("Coffee", -4.5);
    expect(await ledger.readLedger()).toEqual({ transactions: [added, imported] });
    expect(ledger.calculateBalance((await ledger.readLedger()).transactions)).toBe(95.5);
  });

  it("rejects corrupted history without overwriting even one byte", async () => {
    await mkdir(path.dirname(file));
    const damaged = '{"transactions":[{"id":"synthetic-history"}';
    await writeFile(file, damaged);
    await expect(ledger.addTransaction("New", 1)).rejects.toThrow();
    expect(await readFile(file, "utf8")).toBe(damaged);
  });

  it("rejects malformed persisted rows and invalid snapshot imports", async () => {
    await mkdir(path.dirname(file));
    for (const value of [null, {}, { transactions: [{ amount: "10" }] },
      { transactions: [{ ...ledger.createTransaction("Valid", 1), createdAt: "invalid" }] }]) {
      const bytes = JSON.stringify(value);
      await writeFile(file, bytes);
      await expect(ledger.readLedger()).rejects.toThrow();
      await expect(ledger.addTransaction("New", 1)).rejects.toThrow();
      expect(await readFile(file, "utf8")).toBe(bytes);
    }
    const valid = { transactions: [ledger.createTransaction("Kept", 1)] };
    // Begin a separate valid-store scenario without using the public import API to erase corruption.
    await rm(file);
    await ledger.writeLedger(valid);
    const bytes = await readFile(file, "utf8");
    await expect(ledger.writeLedger({ transactions: [{ amount: "10" }] } as never)).rejects.toThrow();
    expect(await readFile(file, "utf8")).toBe(bytes);
  });

  it("preserves all acknowledged concurrent entries and recovers after a rejected add", async () => {
    await ledger.writeLedger({ transactions: [] });
    const results = await Promise.allSettled(Array.from({ length: 20 }, (_, i) =>
      ledger.addTransaction(`Entry ${i}`, i === 7 ? 0 : 1)));
    const accepted = results.flatMap(result => result.status === "fulfilled" ? [result.value] : []);
    expect(accepted).toHaveLength(19);
    const rows = (await ledger.readLedger()).transactions;
    expect(rows).toHaveLength(19);
    expect(new Set(rows.map(row => row.id))).toEqual(new Set(accepted.map(row => row.id)));
    await ledger.addTransaction("After failure", 2);
    expect((await ledger.readLedger()).transactions).toHaveLength(20);
  });

  it("uses exact cent totals and rejects amounts that cannot be stored safely", async () => {
    const rows = [0.1, 0.2, -0.3].map(amount => ledger.createTransaction("Decimal", amount));
    expect(ledger.calculateBalance(rows)).toBe(0);
    expect(ledger.createTransaction("Cent", 0.29).amount).toBe(0.29);
    for (const amount of [1e308, Number.NaN, Number.POSITIVE_INFINITY, 0.001]) {
      expect(() => ledger.createTransaction("Invalid", amount)).toThrow();
    }
    expect(() => ledger.calculateBalance([
      ledger.createTransaction("Large", 50_000_000_000_000),
      ledger.createTransaction("Large", 50_000_000_000_000),
    ])).toThrow();
  });

  it("never writes an invalid new entry or overwrites on filesystem read failure", async () => {
    await expect(ledger.addTransaction("", 1)).rejects.toThrow();
    await expect(readFile(file)).rejects.toMatchObject({ code: "ENOENT" });
    await mkdir(file, { recursive: true });
    await expect(ledger.addTransaction("Cannot read directory", 1)).rejects.toThrow();
  });

  it("rejects snapshot replacement over malformed history and preserves its bytes", async () => {
    await mkdir(path.dirname(file));
    for (const damaged of ['{"transactions":[', '{"transactions":[{"amount":"10"}]}']) {
      await writeFile(file, damaged);
      await expect(ledger.writeLedger({ transactions: [] })).rejects.toThrow();
      expect(await readFile(file, "utf8")).toBe(damaged);
    }
  });

  it("rejects a cent total that the public dollar-number cannot represent exactly", async () => {
    const large = ledger.createTransaction("Large exact amount", 70_368_744_177_664);
    const small = ledger.createTransaction("One cent", 0.01);
    expect(() => ledger.calculateBalance([large, small])).toThrow();
    await ledger.writeLedger({ transactions: [large] });
    const bytes = await readFile(file, "utf8");
    await expect(ledger.addTransaction("One cent", 0.01)).rejects.toThrow();
    expect(await readFile(file, "utf8")).toBe(bytes);
  });

  it("does not invent a cent while converting an accepted large decimal amount", async () => {
    await ledger.addTransaction("Opening", 90_071_992_547_409.9);
    await ledger.addTransaction("Offset", -90_071_992_547_409);
    const rows = (await ledger.readLedger()).transactions;
    expect(ledger.calculateBalance(rows)).toBe(0.9);
    await ledger.writeLedger({ transactions: rows });
    expect(ledger.calculateBalance((await ledger.readLedger()).transactions)).toBe(0.9);
  });
});
