import { mkdir, readFile, writeFile } from "node:fs/promises";
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

export async function readLedger(): Promise<LedgerSnapshot> {
  try {
    const raw = await readFile(DATA_FILE, "utf8");
    const parsed = JSON.parse(raw) as LedgerSnapshot;
    if (!Array.isArray(parsed.transactions)) {
      return { transactions: [] };
    }
    return parsed;
  } catch {
    return { transactions: [] };
  }
}

export async function writeLedger(snapshot: LedgerSnapshot): Promise<void> {
  await mkdir(DATA_DIR, { recursive: true });
  await writeFile(DATA_FILE, JSON.stringify(snapshot, null, 2));
}

export function calculateBalance(transactions: Transaction[]): number {
  return transactions.reduce((total, tx) => total + tx.amount, 0);
}

export function createTransaction(
  description: string,
  amount: number,
): Transaction {
  const trimmed = description.trim();
  if (!trimmed) {
    throw new Error("Description is required");
  }
  if (!Number.isFinite(amount) || amount === 0) {
    throw new Error("Amount must be a non-zero number");
  }

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
  const ledger = await readLedger();
  const transaction = createTransaction(description, amount);
  ledger.transactions.unshift(transaction);
  await writeLedger(ledger);
  return transaction;
}
