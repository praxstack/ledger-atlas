import { NextResponse } from "next/server";
import { addTransaction, calculateBalance, readLedger } from "@/lib/ledger";

export async function GET() {
  const ledger = await readLedger();
  return NextResponse.json({
    transactions: ledger.transactions,
    balance: calculateBalance(ledger.transactions),
  });
}

export async function POST(request: Request) {
  try {
    const body = (await request.json()) as {
      description?: string;
      amount?: number;
    };

    if (!body || typeof body.description !== "string" || typeof body.amount !== "number") {
      throw new Error("Description and numeric amount are required");
    }
    const transaction = await addTransaction(body.description, body.amount);

    const ledger = await readLedger();
    return NextResponse.json(
      {
        transaction,
        balance: calculateBalance(ledger.transactions),
      },
      { status: 201 },
    );
  } catch (error) {
    const message =
      error instanceof Error ? error.message : "Unable to create transaction";
    return NextResponse.json({ error: message }, { status: 400 });
  }
}
