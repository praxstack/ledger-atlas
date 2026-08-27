import SwiftUI
import WidgetKit

@main
struct LedgerAtlasWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "com.praxstack.ledgeratlas.widget", provider: ProjectionProvider()) {
      ProjectionWidgetView(projection: $0.projection)
    }
    .configurationDisplayName("Ledger Atlas")
    .description("A private Ledger Atlas status summary.")
    .supportedFamilies([.systemSmall])
  }
}

private struct ProjectionEntry: TimelineEntry {
  let date: Date
  let projection: RedactedWidgetProjection
}

private struct ProjectionProvider: TimelineProvider {
  func placeholder(in context: Context) -> ProjectionEntry {
    ProjectionEntry(date: .now, projection: .empty)
  }

  func getSnapshot(in context: Context, completion: @escaping (ProjectionEntry) -> Void) {
    completion(ProjectionEntry(date: .now, projection: projection))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<ProjectionEntry>) -> Void) {
    let entry = ProjectionEntry(date: .now, projection: projection)
    completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(900))))
  }

  private var projection: RedactedWidgetProjection {
    guard let containerURL = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: RedactedWidgetProjectionStore.appGroupIdentifier)
    else { return .reopenRequired }
    return RedactedWidgetProjectionStore(containerURL: containerURL).read()
  }
}

private struct ProjectionWidgetView: View {
  let projection: RedactedWidgetProjection

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Ledger Atlas", systemImage: "lock.shield")
        .font(.headline)
      Text(projection.message)
        .font(.subheadline)
    }
    .containerBackground(.fill.tertiary, for: .widget)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Ledger Atlas. \(projection.message)")
  }
}
