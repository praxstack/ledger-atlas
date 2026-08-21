import LedgerAtlasMacUI
import Testing

@Test func reducedMotionDisablesEveryShellNavigationAnimation() {
  for source in AppDestination.allCases {
    for destination in AppDestination.allCases {
      #expect(
        MotionPolicy.navigationAnimation(
          from: source,
          to: destination,
          reduceMotion: true
        ) == nil
      )
    }
  }
}

@Test func ordinaryMotionRetainsAConsistentShellNavigationAnimation() {
  #expect(
    MotionPolicy.navigationAnimation(
      from: .ledger,
      to: .insights,
      reduceMotion: false
    ) != nil
  )
}
