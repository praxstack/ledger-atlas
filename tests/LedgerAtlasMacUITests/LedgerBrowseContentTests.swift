import LedgerAtlasMacUI
import LedgerCore
import Testing

@Test func ledgerBrowseShowsEachOperationalState() {
  typealias Content = LedgerBrowseContent
  // Loading wins until the first index is built.
  #expect(
    Content.state(isLoading: true, entryCount: 0, matchCount: nil, filterActive: false, mode: .daily)
      == .loading)
  // A ledger with nothing in it says so, in every mode.
  for mode in LedgerBrowseMode.allCases {
    #expect(
      Content.state(isLoading: false, entryCount: 0, matchCount: 0, filterActive: false, mode: mode)
        == .emptyLedger)
  }
  // Filters that match nothing offer to clear them, even on an empty ledger.
  #expect(
    Content.state(isLoading: false, entryCount: 0, matchCount: 0, filterActive: true, mode: .daily)
      == .noMatches)
  #expect(
    Content.state(isLoading: false, entryCount: 5, matchCount: 0, filterActive: true, mode: .monthly)
      == .noMatches)
  // The Note view without notes explains where notes come from.
  #expect(
    Content.state(isLoading: false, entryCount: 5, matchCount: 0, filterActive: false, mode: .note)
      == .noNotes)
  // Otherwise the entries show.
  #expect(
    Content.state(isLoading: false, entryCount: 5, matchCount: 3, filterActive: true, mode: .daily)
      == .entries)
  #expect(
    Content.state(isLoading: false, entryCount: 5, matchCount: nil, filterActive: false, mode: .total)
      == .entries)
}
