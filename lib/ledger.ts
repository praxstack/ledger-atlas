import { mkdir, open, readFile, rename, rm } from "node:fs/promises";
import path from "node:path";

export type Transaction = {
  id: string;
  description: string;
  amount: number;
  createdAt: string;
};

export type LedgerSnapshot = {
  transactions: Transaction[];
};

const DATA_DIR = path.join(process.cwd(), "data");
const DATA_FILE = path.join(DATA_DIR, "transactions.json");

// ponytail: serializes one process; multiple server instances need a shared store.
let writeLock: Promise<void> = Promise.resolve();
function withWriteLock<T>(write: () => Promise<T>): Promise<T> {
  const run = writeLock.then(write);
  writeLock = run.then(() => undefined, () => undefined);
  return run;
}

function cents(amount: number): number {
  if (typeof amount !== "number" || !Number.isFinite(amount) || amount === 0) {
    throw new Error("Amount must be a non-zero number");
  }
  const [whole, fraction = ""] = String(amount).split(".");
  const value = Number(whole + fraction.padEnd(2, "0"));
  if (!/^-?\d+$/.test(whole) || fraction.length > 2 || !Number.isSafeInteger(value)) {
    throw new Error("Amount must be an exact, safely representable number of cents");
  }
  return value;
}

function validateSnapshot(snapshot: LedgerSnapshot): void {
  if (!snapshot || !Array.isArray(snapshot.transactions)) {
    throw new Error("Invalid ledger snapshot");
  }
  const ids = new Set<string>();
  for (const transaction of snapshot.transactions) {
    if (!transaction || typeof transaction.id !== "string" || !transaction.id ||
        ids.has(transaction.id) || typeof transaction.description !== "string" ||
        !transaction.description.trim() || typeof transaction.createdAt !== "string" ||
        !Number.isFinite(Date.parse(transaction.createdAt))) {
      throw new Error("Invalid persisted transaction");
    }
    ids.add(transaction.id);
  }
  calculateBalance(snapshot.transactions);
}

export async function readLedger(): Promise<LedgerSnapshot> {
  try {
    const raw = await readFile(DATA_FILE, "utf8");
    const parsed = JSON.parse(raw) as LedgerSnapshot;
    validateSnapshot(parsed);
    return parsed;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return { transactions: [] };
    throw error;
  }
}

export async function writeLedger(snapshot: LedgerSnapshot): Promise<void> {
  return withWriteLock(async () => {
    await readLedger();
    await persistLedger(snapshot);
  });
}

async function persistLedger(snapshot: LedgerSnapshot): Promise<void> {
  validateSnapshot(snapshot);
  const serialized = JSON.stringify(snapshot, null, 2);
  await mkdir(DATA_DIR, { recursive: true });
  const temporary = path.join(DATA_DIR, `.transactions-${crypto.randomUUID()}.tmp`);
  const handle = await open(temporary, "wx", 0o600);
  try {
    await handle.writeFile(serialized, "utf8");
    await handle.sync();
    await handle.close();
    await rename(temporary, DATA_FILE);
  } finally {
    await handle.close().catch(() => undefined);
    await rm(temporary, { force: true }).catch(() => undefined);
  }
}

export function calculateBalance(transactions: Transaction[]): number {
  const total = transactions.reduce((sum, tx) => {
    const next = sum + cents(tx.amount);
    if (!Number.isSafeInteger(next)) throw new Error("Balance exceeds safe cent range");
    return next;
  }, 0);
  const balance = total / 100;
  if (balance !== 0 && cents(balance) !== total) throw new Error("Balance cannot preserve exact cents");
  return balance;
}

export function createTransaction(
  description: string,
  amount: number,
): Transaction {
  const trimmed = typeof description === "string" ? description.trim() : "";
  if (!trimmed) {
    throw new Error("Description is required");
  }
  cents(amount);

  return {
    id: crypto.randomUUID(),
    description: trimmed,
    amount,
    createdAt: new Date().toISOString(),
  };
}

export async function addTransaction(
  description: string,
  amount: number,
): Promise<Transaction> {
  const transaction = createTransaction(description, amount);
  return withWriteLock(async () => {
    const ledger = await readLedger();
    ledger.transactions.unshift(transaction);
    await persistLedger(ledger);
    return transaction;
  });
}
