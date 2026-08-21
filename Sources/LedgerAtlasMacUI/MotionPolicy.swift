import SwiftUI

public enum MotionPolicy {
  public static func navigationAnimation(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .easeOut(duration: 0.16)
  }

  public static func navigationAnimation(
    from _: AppDestination,
    to _: AppDestination,
    reduceMotion: Bool
  ) -> Animation? {
    navigationAnimation(reduceMotion: reduceMotion)
  }
}
