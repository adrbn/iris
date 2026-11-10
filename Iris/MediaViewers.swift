import AVFoundation
import SwiftUI
import UIKit

/// Photo with pinch-to-zoom and double-tap (UIScrollView: the real Photos feel, momentum and bounce).
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.maximumZoomScale = 5
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFit
        view.isUserInteractionEnabled = true
        view.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(view)
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            view.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            view.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            view.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            view.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
        ])
        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(double)
        context.coordinator.view = view
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.view?.image = image
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var view: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { view }

        @objc func doubleTap(_ tap: UITapGestureRecognizer) {
            guard let scroll = tap.view as? UIScrollView, let view else { return }
            if scroll.zoomScale > 1 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = tap.location(in: view)
                let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
            }
        }
    }
}

/// Video without the stock iOS chrome: tap to show/hide, big play button, scrubber, speed, sound.
struct IrisVideoPlayer: View {
    let url: URL
    let shown: Bool
    @State private var player: AVPlayer?
    @State private var playing = false
    @State private var time: Double = 0
    @State private var duration: Double = 0
    @State private var scrubbing = false
    @State private var controls = true
    @State private var muted = false
    @State private var speed: Float = 1
    @State private var observer: Any?
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black
            if let player { PlayerLayer(player: player) }
            Color.clear.contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { controls.toggle() }; scheduleHide() }
            if controls { overlay.transition(.opacity) }
        }
        .onAppear(perform: setUp)
        .onChange(of: shown) { if !shown { pause() } }
        .onDisappear { pause() }
    }

    private var overlay: some View {
        ZStack {
            VStack {
                Spacer()
                VStack(spacing: 8) {
                    Slider(value: $time, in: 0...max(duration, 0.1)) { editing in
                        scrubbing = editing
                        if editing { hideTask?.cancel() } else { seek(time); scheduleHide() }
                    }
                    .tint(Theme.accent)
                    .onChange(of: time) { if scrubbing { seek(time) } }
                    ZStack {
                        HStack {
                            Text(format(time)).monospacedDigit()
                            Spacer()
                            Text("-" + format(max(duration - time, 0))).monospacedDigit()
                        }
                        HStack(spacing: 18) {
                            Button { cycleSpeed() } label: {
                                Text(speed == 1 ? "1×" : speed == 1.5 ? "1,5×" : "2×").font(.footnote.weight(.bold))
                                    .frame(width: 44, height: 40).contentShape(Rectangle())
                            }
                            .accessibilityLabel("Vitesse")
                            Button(action: toggle) {
                                Image(systemName: playing ? "pause.fill" : "play.fill").font(.title2.weight(.bold))
                                    .frame(width: 52, height: 44).contentShape(Rectangle())
                                    .contentTransition(.symbolEffect(.replace))
                            }
                            .accessibilityLabel(playing ? "Pause" : "Lecture")
                            Button { muted.toggle(); player?.isMuted = muted } label: {
                                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                    .frame(width: 44, height: 40).contentShape(Rectangle())
                            }
                            .accessibilityLabel(muted ? "Remettre le son" : "Couper le son")
                        }
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.white)
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .onTapGesture { scheduleHide() }   // a tap on the bar itself must not hide it
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
    }

    private func setUp() {
        guard player == nil else { return }
        let p = AVPlayer(url: url)
        p.actionAtItemEnd = .pause
        player = p
        observer = p.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { t in
            MainActor.assumeIsolated {
                if !scrubbing { time = t.seconds }
                if let d = p.currentItem?.duration.seconds, d.isFinite { duration = d }
                playing = p.rate > 0
            }
        }
    }

    private func toggle() {
        guard let player else { return }
        if playing { pause(); return }
        if duration > 0, time >= duration - 0.1 { seek(0) }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        player.playImmediately(atRate: speed)
        playing = true
        scheduleHide()
    }

    private func pause() { player?.pause(); playing = false; hideTask?.cancel(); controls = true }

    private func seek(_ s: Double) {
        player?.seek(to: CMTime(seconds: s, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func cycleSpeed() {
        speed = speed == 1 ? 1.5 : speed == 1.5 ? 2 : 1
        if playing { player?.rate = speed }
        scheduleHide()
    }

    /// Controls fade out 2.5 s after the last touch while playing.
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, playing, !scrubbing else { return }
            withAnimation(.easeInOut(duration: 0.3)) { controls = false }
        }
    }

    private func format(_ s: Double) -> String {
        guard s.isFinite else { return "0:00" }
        let t = Int(s.rounded(.down))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Bare AVPlayerLayer, no system controls.
private struct PlayerLayer: UIViewRepresentable {
    let player: AVPlayer

    final class View: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> View {
        let v = View()
        v.playerLayer.videoGravity = .resizeAspect
        v.playerLayer.player = player
        return v
    }

    func updateUIView(_ v: View, context: Context) { v.playerLayer.player = player }
}
