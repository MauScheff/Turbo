import ActivityKit
import SwiftUI
import WidgetKit

@main
struct BeepBeepLiveActivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        BeepBeepLiveActivityWidget()
    }
}

struct BeepBeepLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BeepBeepLiveActivityAttributes.self) { context in
            BeepBeepLiveActivityLockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.contactName)
                            .font(.headline)
                        Text(context.state.phase.statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.canEnd {
                        Link(destination: endURL(for: context)) {
                            Label("End", systemImage: "phone.down.fill")
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let speakerName = context.state.speakerName {
                        Text("\(speakerName) \(context.state.phase == .speaking ? "is speaking" : "is live")")
                            .font(.caption)
                            .lineLimit(1)
                    } else {
                        Link("Open BeepBeep", destination: openURL(for: context))
                            .font(.caption)
                    }
                }
            } compactLeading: {
                Image(systemName: iconName(for: context.state.phase))
            } compactTrailing: {
                Text(shortStatus(for: context.state.phase))
            } minimal: {
                Image(systemName: "waveform")
            }
            .widgetURL(openURL(for: context))
        }
    }
}

private struct BeepBeepLiveActivityLockScreenView: View {
    let context: ActivityViewContext<BeepBeepLiveActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName(for: context.state.phase))
                .font(.title2)
                .frame(width: 34, height: 34)
                .foregroundStyle(.white)
                .background(Circle().fill(Color.accentColor))

            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.contactName)
                    .font(.headline)
                    .lineLimit(1)
                Text(statusLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if context.state.canEnd {
                Link(destination: endURL(for: context)) {
                    Text("End")
                        .font(.headline)
                        .foregroundStyle(.red)
                }
            }

            Link(destination: openURL(for: context)) {
                Text("Open")
                    .font(.headline)
            }
        }
        .padding(.vertical, 8)
        .activityBackgroundTint(Color(.systemBackground))
        .activitySystemActionForegroundColor(.accentColor)
    }

    private var statusLine: String {
        if let speakerName = context.state.speakerName {
            return "\(context.state.phase.statusText) - \(speakerName)"
        }
        return context.state.phase.statusText
    }
}

private func openURL(for context: ActivityViewContext<BeepBeepLiveActivityAttributes>) -> URL {
    conversationURL(for: context, action: "open")
}

private func endURL(for context: ActivityViewContext<BeepBeepLiveActivityAttributes>) -> URL {
    conversationURL(for: context, action: "end")
}

private func conversationURL(
    for context: ActivityViewContext<BeepBeepLiveActivityAttributes>,
    action: String
) -> URL {
    var components = URLComponents()
    components.scheme = "beepbeep"
    components.host = "conversation"
    components.queryItems = [
        URLQueryItem(name: "handle", value: context.attributes.contactHandle),
        URLQueryItem(name: "action", value: action),
    ]
    return components.url ?? URL(string: "beepbeep://conversation")!
}

private func iconName(for phase: BeepBeepLiveActivityPhase) -> String {
    switch phase {
    case .connecting, .reconnecting:
        return "antenna.radiowaves.left.and.right"
    case .connected:
        return "checkmark.circle.fill"
    case .speaking:
        return "waveform.circle.fill"
    case .listening:
        return "ear"
    }
}

private func shortStatus(for phase: BeepBeepLiveActivityPhase) -> String {
    switch phase {
    case .connecting:
        return "..."
    case .connected:
        return "On"
    case .speaking:
        return "Talk"
    case .listening:
        return "Live"
    case .reconnecting:
        return "..."
    }
}
