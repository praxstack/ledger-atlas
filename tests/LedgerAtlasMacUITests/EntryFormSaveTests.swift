import Foundation
import LedgerCore
import LedgerStore
import Testing

@testable import LedgerAtlasMacUI

/// #169: the entry form stays open after Save. A save that fails must keep everything typed and
/// say why; only a save that wrote the entry starts the next one. Synthetic data only.

private func typedEntry() throws -> NativeEntryFields {
  var entry = NativeEntryFields()
  entry.amount = "12,5,0"
  entry.note = "Chai at office"
  entry.categoryID = "category-food"
  entry.selectedTags = ["tag-work"]
  entry.accountChosen = true
  entry.categoryChosen = true
  entry.suggestion = LedgerEntrySuggestion(
    accountID: "account-cash", categoryID: "category-food",
    fromDay: try SourceLocalDate(year: 2026, month: 10, day: 12), sourceTransactionID: "earlier")
  entry.savedCount = 2
  return entry
}

@Test func aFailedSaveKeepsTheEntryAndTheSameSubmission() throws {
  let typed = try typedEntry()
  var entry = typed
  entry.finishSave(.notSaved(LedgerJourney.entryAmountNotANumberMessage))
  #expect(entry.saveError == LedgerJourney.entryAmountNotANumberMessage)
  // Everything else is exactly as typed, including the submission ID, so Save again is the
  // same submission and cannot write the entry twice.
  var withoutError = entry
  withoutError.saveError = nil
  #expect(withoutError == typed)
}

@Test func aSuccessfulSaveStartsAFreshEntryWithANewSubmission() throws {
  var entry = try typedEntry()
  entry.finishSave(.notSaved(LedgerJourney.entryNotSavedMessage))
  let failedSubmission = entry.submissionID
  // Saved on the retry: the error goes, the fields clear, and the next entry is a new submission.
  entry.finishSave(.saved)
  #expect(entry.saveError == nil)
  #expect(entry.savedCount == 3)
  #expect(entry.submissionID != failedSubmission)
  #expect(entry.amount.isEmpty && entry.note.isEmpty)
  #expect(entry.categoryID == nil && entry.selectedTags.isEmpty && entry.suggestion == nil)
  #expect(!entry.accountChosen && !entry.categoryChosen)
}

@Test func aSaveAnEarlierTryHadRecordedSaysSoOnTheFreshEntry() throws {
  var entry = try typedEntry()
  entry.finishSave(.notSaved(LedgerJourney.entryNotSavedMessage))
  let failedSubmission = entry.submissionID
  entry.amount = "130"
  // The first try had been written after all, with the amount as first typed.
  entry.finishSave(.savedEarlier(LedgerJourney.entrySavedEarlierMessage))
  #expect(entry.saveError == nil)
  #expect(entry.saveNotice == LedgerJourney.entrySavedEarlierMessage)
  #expect(entry.savedCount == 3)
  #expect(entry.submissionID != failedSubmission && entry.amount.isEmpty)
  // The next entry that saves drops the notice.
  entry.finishSave(.saved)
  #expect(entry.saveNotice == nil)
}
