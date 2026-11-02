import LedgerCore

extension LedgerXLSXExchange.Content {
  /// Everything an XLSX export carries, read from a ledger snapshot. Deleted records are
  /// included and marked, so a workbook round-trips without losing them.
  public init(snapshot: LedgerStore.LedgerReadSnapshot) {
    self.init(
      accountGroups: snapshot.accountGroups, accounts: snapshot.accounts,
      categories: snapshot.categories, tags: snapshot.tags,
      transactions: snapshot.transactions.map { transaction in
        let revision = transaction.currentRevision
        return LedgerXLSXExchange.Transaction(
          id: transaction.id, draft: revision.draft, lifecycle: revision.lifecycle,
          tags: snapshot.revisionTags[revision.id] ?? .empty)
      })
  }
}

extension LedgerXLSXImportPlan.Existing {
  /// What the ledger already holds, for planning an import into it.
  public init(snapshot: LedgerStore.LedgerReadSnapshot) {
    let content = LedgerXLSXExchange.Content(snapshot: snapshot)
    self.init(
      accountGroups: content.accountGroups, accounts: content.accounts,
      categories: content.categories, tags: content.tags, transactions: content.transactions)
  }
}
