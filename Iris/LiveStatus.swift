import ActivityKit
import Combine
import UIKit
import WidgetKit

/// Keeps the widgets and the Dynamic Island in step with the glasses, also in the background
/// (bluetooth-central keeps the BLE link, and its battery frames, alive).
///
/// ponytail: iOS only lets an app START a Live Activity in the foreground (push-to-start needs an
/// APNs server). So it starts when Iris is open with the glasses connected, then only updates;
/// plugging the charger in updates it with an alert, which pops the Dynamic Island open.
/// iOS ends an activity after 8 h: the next time Iris opens, it starts again.
@MainActor final class LiveStatus {
    private var bag: Set<AnyCancellable> = []
    private var last: GlassesSnapshot?
    private var ready = false

    init(glasses: Glasses) {
        // An activity started by a previous install outlives it, but its views belonged to the old
        // extension: the Dynamic Island shows a black pill (09/11). End leftovers, then start fresh.
        Task { [weak self] in
            for activity in Activity<GlassesActivity>.activities { await activity.end(nil, dismissalPolicy: .immediate) }
            self?.ready = true
            if let s = self?.last { self?.start(s) }
        }
        glasses.$battery.combineLatest(glasses.$charging, glasses.$state, glasses.$name)
            .sink { [weak self] battery, charging, state, name in
                self?.update(GlassesSnapshot(name: name, battery: battery, charging: charging, connected: state == .ready))
            }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in if let s = self?.last { self?.start(s) } }
            .store(in: &bag)
    }

    private func update(_ s: GlassesSnapshot) {
        var same = s; same.date = last?.date ?? s.date
        guard same != last else { return }
        let pluggedIn = s.charging && last?.charging == false
        last = s
        s.save()
        WidgetCenter.shared.reloadAllTimelines()
        start(s)
        guard let battery = s.battery else { return }
        let content = ActivityContent(state: GlassesActivity.ContentState(battery: battery, charging: s.charging, connected: s.connected), staleDate: nil)
        for activity in Activity<GlassesActivity>.activities {
            Task {
                if pluggedIn {
                    await activity.update(content, alertConfiguration: AlertConfiguration(
                        title: "Lunettes en charge", body: "\(battery) %", sound: .default))
                } else {
                    await activity.update(content)
                }
            }
        }
    }

    private func start(_ s: GlassesSnapshot) {
        guard ready, Activity<GlassesActivity>.activities.isEmpty, s.connected, let battery = s.battery,
              ActivityAuthorizationInfo().areActivitiesEnabled,
              UIApplication.shared.applicationState == .active else { return }
        do {
            _ = try Activity.request(
                attributes: GlassesActivity(name: s.name.isEmpty ? "Lunettes" : s.name),
                content: ActivityContent(state: GlassesActivity.ContentState(battery: battery, charging: s.charging, connected: true), staleDate: nil))
            Log.line("activité en direct lancée")
        } catch {
            Log.line("activité en direct refusée : \(error.localizedDescription)")
        }
    }
}
