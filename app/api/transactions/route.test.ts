import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";

let sandbox: string;
let route: typeof import("./route");
beforeEach(async () => {
  sandbox = await mkdtemp(path.join(tmpdir(), "ledger-route-"));
  vi.spyOn(process, "cwd").mockReturnValue(sandbox);
  vi.resetModules();
  route = await import("./route");
});
afterEach(async () => {
  vi.restoreAllMocks();
  await rm(sandbox, { recursive: true, force: true });
});
function post(value: unknown) {
  return route.POST(new Request("http://localhost/api/transactions", {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(value),
  }));
}

it("returns an empty ledger then persists every acknowledged concurrent POST", async () => {
  expect(await (await route.GET()).json()).toEqual({ transactions: [], balance: 0 });
  const responses = await Promise.all(Array.from({ length: 10 }, (_, i) => post({ description: `API ${i}`, amount: 0.1 })));
  expect(responses.every(response => response.status === 201)).toBe(true);
  const data = await (await route.GET()).json();
  expect(data.transactions).toHaveLength(10);
  expect(data.balance).toBe(1);
});

it("rejects invalid requests without writing a ledger", async () => {
  for (const value of [null, {}, { description: "Zero", amount: 0 },
    { description: "Boolean", amount: true }, { description: "Array", amount: [1] },
    { description: "Fraction", amount: 0.001 }, { description: {}, amount: 1 }]) {
    expect((await post(value)).status).toBe(400);
  }
  await expect(readFile(path.join(sandbox, "data", "transactions.json"))).rejects.toMatchObject({ code: "ENOENT" });
});

it("does not acknowledge a POST over corrupted history or erase that history", async () => {
  const file = path.join(sandbox, "data", "transactions.json");
  await mkdir(path.dirname(file));
  const bytes = '{"transactions":[';
  await writeFile(file, bytes);
  expect((await post({ description: "New", amount: 1 })).status).not.toBe(201);
  expect(await readFile(file, "utf8")).toBe(bytes);
});
