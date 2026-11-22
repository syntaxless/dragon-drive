import WidgetKit
import SwiftUI
import ActivityKit
import AppIntents

// Draws the drive's Live Activity (DriveActivity.swift, shared with the app): lock screen, Dynamic Island, StandBy.

@main
struct DriveWidgetBundle: WidgetBundle {
    var body: some Widget {
        DriveLiveActivity()
    }
}

private let orange = Color(red: 1.0, green: 0.42, blue: 0.1)

struct DriveLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DriveActivityAttributes.self) { ctx in
            LockScreenView(ctx: ctx)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Recording", systemImage: "record.circle").foregroundColor(orange).font(.caption)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(ctx.state.distance).font(.headline).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(timerInterval: ctx.attributes.start...Date.distantFuture, countsDown: false)
                        .font(.title2).monospacedDigit().multilineTextAlignment(.center)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    FinishButton(show: ctx.state.canFinish)
                }
            } compactLeading: {
                Image(systemName: "record.circle").foregroundColor(orange)
            } compactTrailing: {
                Text(timerInterval: ctx.attributes.start...Date.distantFuture, countsDown: false)
                    .monospacedDigit().frame(maxWidth: 52)
            } minimal: {
                Image(systemName: "record.circle").foregroundColor(orange)
            }
        }
    }
}

struct LockScreenView: View {
    let ctx: ActivityViewContext<DriveActivityAttributes>
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Dragon Drive").font(.caption).foregroundColor(orange)
                Text(timerInterval: ctx.attributes.start...Date.distantFuture, countsDown: false)
                    .font(.system(size: 34, weight: .semibold)).monospacedDigit().foregroundColor(.white)
                Text(ctx.state.distance.isEmpty ? ctx.state.source : ctx.state.distance + " · " + ctx.state.source)
                    .font(.subheadline).foregroundColor(.white.opacity(0.75))
            }
            Spacer()
            FinishButton(show: ctx.state.canFinish)
        }
        .padding(16)
    }
}

struct FinishButton: View {
    let show: Bool
    var body: some View {
        if show {
            if #available(iOS 17.0, *) {
                Button(intent: FinishFromLockScreenIntent()) {
                    Text("Finish").font(.headline).padding(.horizontal, 6)
                }
                .tint(orange)
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
