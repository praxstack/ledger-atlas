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
  var windows: [NSWindow] = []

  func makeGuard() -> LedgerQuitGuard {
    LedgerQuitGuard(
      confirm: { [self] in
        asks += 1
        endDuringQuestion?.end()
        return answer
      },
      replyToTerminate: { [self] in replies.append($0) },
      windows: { [self] in windows })
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

// Closing the only window quits the app, and a window opened again would get its own lock and
// session while the write still holds the ledger, so the window can't close during a write.
@MainActor
@Test func theWindowCantBeClosedWhileALedgerIsBeingWritten() {
  let recorder = QuitRecorder()
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
    styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
    defer: true)
  window.isReleasedWhenClosed = false
  let panel = NSPanel(
    contentRect: NSRect(x: 0, y: 0, width: 100, height: 50), styleMask: [.titled, .closable],
    backing: .buffered, defer: true)
  recorder.windows = [window, panel]
  let quitGuard = recorder.makeGuard()

  let importing = quitGuard.begin("synthetic import")
  #expect(!window.styleMask.contains(.closable))
  #expect(window.styleMask.contains(.miniaturizable))
  #expect(panel.styleMask.contains(.closable))
  let opening = quitGuard.begin("synthetic open")
  importing.end()
  #expect(!window.styleMask.contains(.closable))
  opening.end()
  #expect(window.styleMask.contains(.closable))
}
