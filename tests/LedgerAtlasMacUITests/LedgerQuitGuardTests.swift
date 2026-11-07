import AppKit
import Testing

@testable import LedgerAtlasMacUI

// Quit during an import or upgrade would leave a half-written ledger (#178), so Quit asks and
// then waits for the write to end.

@MainActor
private final class QuitRecorder {
  var asks = 0
  var answer = true
  var replies: [Bool] = []
  var endDuringQuestion: LedgerQuitGuard.Work?

  func makeGuard() -> LedgerQuitGuard {
    LedgerQuitGuard(
      confirm: { [self] in
        asks += 1
        endDuringQuestion?.end()
        return answer
      },
      replyToTerminate: { [self] in replies.append($0) })
  }
}

@MainActor
@Test func quitIsImmediateWhenNothingIsBeingWritten() {
  let recorder = QuitRecorder()
  let quitGuard = recorder.makeGuard()
  #expect(quitGuard.terminateReply() == .terminateNow)
  quitGuard.begin("synthetic").end()
  #expect(quitGuard.terminateReply() == .terminateNow)
  #expect(recorder.asks == 0)
}

@MainActor
@Test func keepWorkingCancelsTheQuitAndTheWriteContinues() {
  let recorder = QuitRecorder()
  recorder.answer = false
  let quitGuard = recorder.makeGuard()
  let work = quitGuard.begin("synthetic import")
  #expect(quitGuard.terminateReply() == .terminateCancel)
  #expect(!quitGuard.quitsWhenIdle)
  work.end()
  #expect(recorder.replies.isEmpty)
}

@MainActor
@Test func quitWhenFinishedQuitsOnceTheLastWriteEnds() {
  let recorder = QuitRecorder()
  let quitGuard = recorder.makeGuard()
  let importing = quitGuard.begin("synthetic import")
  let opening = quitGuard.begin("synthetic open")
  #expect(quitGuard.terminateReply() == .terminateLater)
  // A second Cmd-Q while waiting doesn't ask again.
  #expect(quitGuard.terminateReply() == .terminateLater)
  #expect(recorder.asks == 1)
  importing.end()
  importing.end()
  #expect(recorder.replies.isEmpty)
  opening.end()
  #expect(recorder.replies == [true])
  #expect(quitGuard.runningWork == 0 && !quitGuard.quitsWhenIdle)
}

@MainActor
@Test func aWriteThatEndsWhileTheQuestionIsShowingQuitsNow() {
  let recorder = QuitRecorder()
  let quitGuard = recorder.makeGuard()
  recorder.endDuringQuestion = quitGuard.begin("synthetic import")
  #expect(quitGuard.terminateReply() == .terminateNow)
  #expect(recorder.replies.isEmpty)
}
