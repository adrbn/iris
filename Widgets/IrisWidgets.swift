import ActivityKit
import SwiftUI
import WidgetKit

@main
struct IrisWidgets: WidgetBundle {
    var body: some Widget {
        GlassesWidget()
        GlassesLiveActivity()
    }
}

// MARK: - Home and Lock Screen widget

struct GlassesEntry: TimelineEntry {
    let date: Date
    let snapshot: GlassesSnapshot?
}

struct GlassesProvider: TimelineProvider {
    func placeholder(in context: Context) -> GlassesEntry {
        GlassesEntry(date: .now, snapshot: GlassesSnapshot(name: "L801", battery: 72, charging: false, connected: true))
    }
    func getSnapshot(in context: Context, completion: @escaping (GlassesEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : GlassesEntry(date: .now, snapshot: GlassesSnapshot.load()))
    }
    /// The app reloads the timelines when the state changes; nothing to schedule here.
    func getTimeline(in context: Context, completion: @escaping (Timeline<GlassesEntry>) -> Void) {
        completion(Timeline(entries: [GlassesEntry(date: .now, snapshot: GlassesSnapshot.load())], policy: .never))
    }
}

struct GlassesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "IrisGlasses", provider: GlassesProvider()) { entry in
            GlassesWidgetView(snapshot: entry.snapshot)
                .containerBackground(Theme.surface, for: .widget)
        }
        .configurationDisplayName("Lunettes")
        .description("Batterie et connexion de tes lunettes.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private func stateText(_ s: GlassesSnapshot?) -> String {
    guard let s else { return "Ouvre Iris" }
    if s.charging { return "En charge" }
    return s.connected ? "Connectées" : "Hors de portée"
}

struct GlassesWidgetView: View {
    let snapshot: GlassesSnapshot?
    @Environment(\.widgetFamily) private var family

    private var battery: Int? { snapshot?.battery }
    private var level: Double { Double(battery ?? 0) / 100 }

    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: level) {
                Image(systemName: "eyeglasses")
            } currentValueLabel: {
                Text(battery.map(String.init) ?? "–").font(.system(.title3, design: .monospaced, weight: .medium))
            }
            .gaugeStyle(.accessoryCircularCapacity)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label(stateText(snapshot), systemImage: snapshot?.charging == true ? "bolt.fill" : "eyeglasses").font(.caption)
                Text(battery.map { "\($0) %" } ?? "–").font(.system(.title2, design: .monospaced, weight: .medium))
                Gauge(value: level) { EmptyView() }.gaugeStyle(.accessoryLinearCapacity)
            }
        case .accessoryInline:
            Label(battery.map { "Lunettes \($0) %" } ?? "Lunettes", systemImage: snapshot?.charging == true ? "bolt.fill" : "eyeglasses")
        case .systemMedium:
            HStack(spacing: 16) {
                big
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 6) {
                    Image(systemName: "eyeglasses").font(.system(size: 40, weight: .light)).foregroundStyle(Theme.ink)
                    Text(stateText(snapshot)).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                    if let date = snapshot?.date { Text(date, style: .relative).font(.caption2).foregroundStyle(Theme.muted) }
                }
            }
        default:
            big
        }
    }

    private var big: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Meta(snapshot?.name.isEmpty == false ? snapshot!.name : "Lunettes")
                Spacer()
                if snapshot?.charging == true { Image(systemName: "bolt.fill").foregroundStyle(Theme.accent) }
            }
            Spacer(minLength: 4)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(battery.map(String.init) ?? "–")
                    .font(.system(size: 48, weight: .medium, design: .monospaced)).tracking(-3)
                    .foregroundStyle(Theme.ink).minimumScaleFactor(0.6).lineLimit(1)
                Text("%").font(.system(size: 16, design: .monospaced)).foregroundStyle(Theme.muted)
            }
            BatteryBar(level: level).padding(.vertical, 6)
            Text(stateText(snapshot)).font(.caption.weight(.medium)).foregroundStyle(Theme.muted)
        }
    }
}

struct BatteryBar: View {
    let level: Double
    var height: CGFloat = 6
    var track = Theme.track
    var fill = Theme.accent

    var body: some View {
        GeometryReader { geo in
            Capsule().fill(track)
                .overlay(alignment: .leading) { Capsule().fill(fill).frame(width: geo.size.width * level) }
        }
        .frame(height: height)
    }
}

// MARK: - Live Activity (Lock Screen + Dynamic Island)

/// Plain RGB on purpose: SpringBoard renders an archived copy of these views, and Theme's
/// light/dark UIColors (closure-based) don't survive it: the island stayed a black pill (09/11).
private let islandOrange = Color(red: 1, green: 0x5B / 255, blue: 0x1F / 255)

struct GlassesLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GlassesActivity.self) { context in
            LockScreenActivity(name: context.attributes.name, state: context.state)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "eyeglasses").font(.title2).foregroundStyle(islandOrange)
                        .frame(width: 44, height: 44).background(Color.white.opacity(0.08), in: Circle())
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\(s.battery)").font(.system(size: 34, weight: .medium, design: .monospaced)).tracking(-2)
                        Text("%").font(.system(size: 13, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                    }
                    .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.name).font(.system(.caption, design: .monospaced)).tracking(1.1)
                        .foregroundStyle(.white.opacity(0.6))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        BatteryBar(level: Double(s.battery) / 100, track: .white.opacity(0.18), fill: islandOrange)
                        Label(s.charging ? "En charge" : s.connected ? "Connectées" : "Hors de portée",
                              systemImage: s.charging ? "bolt.fill" : "checkmark")
                            .font(.footnote.weight(.semibold)).foregroundStyle(s.charging ? islandOrange : .white)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: s.charging ? "bolt.fill" : "eyeglasses").foregroundStyle(islandOrange)
            } compactTrailing: {
                Text("\(s.battery)%").font(.system(.footnote, design: .monospaced, weight: .semibold)).foregroundStyle(.white)
            } minimal: {
                Gauge(value: Double(s.battery) / 100) { Image(systemName: "eyeglasses") }
                    .gaugeStyle(.accessoryCircularCapacity).tint(islandOrange)
            }
            .keylineTint(islandOrange)
        }
    }
}

struct LockScreenActivity: View {
    let name: String
    let state: GlassesActivity.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: state.charging ? "bolt.fill" : "eyeglasses").font(.title3).foregroundStyle(.black)
                    .frame(width: 44, height: 44).background(islandOrange, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(.caption, design: .monospaced)).tracking(1.1).foregroundStyle(.white.opacity(0.6))
                    Text(state.charging ? "En charge" : state.connected ? "Connectées" : "Hors de portée")
                        .font(.headline).foregroundStyle(.white)
                }
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(state.battery)").font(.system(size: 40, weight: .medium, design: .monospaced)).tracking(-2)
                    Text("%").font(.system(size: 15, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                }
                .foregroundStyle(.white)
            }
            BatteryBar(level: Double(state.battery) / 100, track: .white.opacity(0.18), fill: islandOrange)
        }
        .padding(18)
    }
}
