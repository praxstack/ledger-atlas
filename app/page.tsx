"use client";

import { FormEvent, useEffect, useState } from "react";

type Transaction = {
  id: string;
  description: string;
  amount: number;
  createdAt: string;
};

type LedgerResponse = {
  transactions: Transaction[];
  balance: number;
};

const currency = new Intl.NumberFormat("en-US", {
  style: "currency",
  currency: "USD",
});

export default function HomePage() {
  const [ledger, setLedger] = useState<LedgerResponse>({
    transactions: [],
    balance: 0,
  });
  const [description, setDescription] = useState("");
  const [amount, setAmount] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  async function loadLedger() {
    const response = await fetch("/api/transactions");
    const data = (await response.json()) as LedgerResponse;
    setLedger(data);
    setLoading(false);
  }

  useEffect(() => {
    void loadLedger();
  }, []);

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);

    const response = await fetch("/api/transactions", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        description,
        amount: Number(amount),
      }),
    });

    const data = await response.json();
    if (!response.ok) {
      setError(data.error ?? "Failed to add transaction");
      return;
    }

    setDescription("");
    setAmount("");
    await loadLedger();
  }

  return (
    <main className="page">
      <header className="hero">
        <p className="eyebrow">Ledger Atlas</p>
        <h1>Track credits and debits in one place.</h1>
        <p className="balance">
          Current balance:{" "}
          <strong>{loading ? "..." : currency.format(ledger.balance)}</strong>
        </p>
      </header>

      <section className="panel">
        <h2>Add transaction</h2>
        <form className="form" onSubmit={handleSubmit}>
          <label>
            Description
            <input
              value={description}
              onChange={(event) => setDescription(event.target.value)}
              placeholder="Office supplies"
              required
            />
          </label>
          <label>
            Amount
            <input
              type="number"
              step="0.01"
              value={amount}
              onChange={(event) => setAmount(event.target.value)}
              placeholder="-24.99"
              required
            />
          </label>
          <button type="submit">Add entry</button>
        </form>
        {error ? <p className="error">{error}</p> : null}
      </section>

      <section className="panel">
        <h2>Recent transactions</h2>
        {loading ? (
          <p>Loading ledger...</p>
        ) : ledger.transactions.length === 0 ? (
          <p>No transactions yet. Add your first entry above.</p>
        ) : (
          <ul className="transactions">
            {ledger.transactions.map((transaction) => (
              <li key={transaction.id}>
                <div>
                  <strong>{transaction.description}</strong>
                  <span>{new Date(transaction.createdAt).toLocaleString()}</span>
                </div>
                <span
                  className={
                    transaction.amount >= 0 ? "amount credit" : "amount debit"
                  }
                >
                  {currency.format(transaction.amount)}
                </span>
              </li>
            ))}
          </ul>
        )}
      </section>
    </main>
  );
}
