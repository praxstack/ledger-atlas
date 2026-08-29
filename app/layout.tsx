import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Ledger Atlas",
  description: "A lightweight ledger for tracking transactions",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
