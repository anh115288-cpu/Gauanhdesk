import SwiftUI
import WebKit
import AudioToolbox

/// A "Dynamic Island" at the top of the desktop. While a web page plays music or video, a small pill shows what is
/// playing; clicking it opens the controls (previous, back 10 s, play / pause, forward 10 s, next, and a progress
/// bar to click on). While the screen is being recorded the pill shows that instead (click to stop).
final class NowPlaying: ObservableObject {
    static let shared = NowPlaying()

    struct Info: Equatable {
        var title: String
        var artist: String
        var artwork: URL?
        var position: Double
        var duration: Double
        var playing: Bool
        var canSeek: Bool { duration.isFinite && duration > 0 }
    }

    @Published private(set) var info: Info?
    @Published var expanded = false

    private weak var target: WKWebView?
    private var timer: Timer?
    private var ticks = 0
    private var pausedSince: Date?
    private var polling = false

    static let enabledKey = "iDesk.island.enabled"
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey); if !newValue { shared.info = nil; shared.expanded = false }; DesktopModel.shared.objectWillChange.send() }
    }

    /// 0 = a floating island, 1 = a notch fixed to the top edge of the screen.
    static let styleKey = "iDesk.island.style"
    static var style: Int {
        get { UserDefaults.standard.integer(forKey: styleKey) }
        set { UserDefaults.standard.set(newValue == 1 ? 1 : 0, forKey: styleKey); DesktopModel.shared.objectWillChange.send() }
    }
    static var isNotch: Bool { style == 1 }
    static var top: CGFloat { isNotch ? 0 : 8 }

    /// The pill's outline: round all over (island) or flat on top and round below (notch).
    static func shape(height: CGFloat, expanded: Bool) -> UnevenRoundedRectangle {
        let r: CGFloat = expanded ? (isNotch ? 28 : 30) : (isNotch ? height * 0.5 : height / 2)
        return UnevenRoundedRectangle(topLeadingRadius: isNotch ? 0 : r, bottomLeadingRadius: r,
                                      bottomTrailingRadius: r, topTrailingRadius: isNotch ? 0 : r, style: .continuous)
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        ticks += 1
        guard Self.enabled else { return }
        // Every 2 seconds, every second while the controls are open.
        if expanded || ticks % 2 == 0 { poll() }
    }

    // MARK: Page side

    /// Added to every tab: remembers the page's media-session handlers (next / previous) and answers the island.
    static var pageScript: WKUserScript { WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true) }

    private static let source = """
    (() => {
      if (window.__ideskMedia) return;
      const handlers = {};
      try {
        const ms = navigator.mediaSession;
        if (ms && ms.setActionHandler) {
          const orig = ms.setActionHandler.bind(ms);
          ms.setActionHandler = function (a, h) { handlers[a] = h; return orig(a, h); };
        }
      } catch (e) {}
      const els = () => Array.from(document.querySelectorAll('audio, video')).filter(e => e.readyState > 0);
      const real = e => !e.muted && e.volume > 0 && (e.duration > 20 || !isFinite(e.duration));
      const pick = () => {
        const all = els().filter(real);
        return all.find(e => !e.paused && !e.ended) || all.find(e => e.currentTime > 0 && !e.ended) || null;
      };
      window.__ideskMedia = {
        status() {
          const e = pick(); if (!e) return null;
          let md = null; try { md = navigator.mediaSession && navigator.mediaSession.metadata; } catch (_) {}
          const art = md && md.artwork && md.artwork.length ? md.artwork[md.artwork.length - 1].src : '';
          return JSON.stringify({ playing: !e.paused && !e.ended, title: (md && md.title) || document.title || '',
            artist: (md && md.artist) || location.hostname, artwork: art, pos: e.currentTime || 0,
            dur: isFinite(e.duration) ? e.duration : 0 });
        },
        toggle() { const e = pick(); if (e) { e.paused ? e.play() : e.pause(); } },
        seek(d) { const e = pick(); if (e && isFinite(e.duration)) e.currentTime = Math.max(0, Math.min(e.duration, e.currentTime + d)); },
        seekTo(f) { const e = pick(); if (e && isFinite(e.duration)) e.currentTime = e.duration * Math.max(0, Math.min(1, f)); },
        next() {
          if (handlers.nexttrack) { try { handlers.nexttrack(); return; } catch (_) {} }
          const b = document.querySelector('.ytp-next-button, [aria-label="Next"], [data-testid="control-button-skip-forward"]');
          if (b) { b.click(); return; }
          const e = pick(); if (e && isFinite(e.duration)) e.currentTime = e.duration;
        },
        prev() {
          const e = pick();
          if (e && e.currentTime > 5) { e.currentTime = 0; return; }
          if (handlers.previoustrack) { try { handlers.previoustrack(); return; } catch (_) {} }
          const b = document.querySelector('.ytp-prev-button, [aria-label="Previous"], [data-testid="control-button-skip-back"]');
          if (b) { b.click(); return; }
          if (e) e.currentTime = 0;
        }
      };
    })();
    """

    // MARK: Polling

    private func poll() {
        let model = DesktopModel.shared
        guard model.isExternalConnected, !polling else { return }
        let views = Array(model.windows.flatMap { $0.tabs }.prefix(16))
        guard !views.isEmpty else { finish([]); return }
        polling = true
        var results: [(WKWebView, [String: Any])] = []
        let group = DispatchGroup()
        for web in views {
            group.enter()
            web.evaluateJavaScript("window.__ideskMedia ? window.__ideskMedia.status() : null") { value, _ in
                if let s = value as? String, let data = s.data(using: .utf8),
                   let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    results.append((web, d))
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in self?.polling = false; self?.finish(results) }
    }

    private func finish(_ results: [(WKWebView, [String: Any])]) {
        // The tab already controlled while it still plays, else the first one that plays, else the same tab paused.
        let playing = results.filter { ($0.1["playing"] as? Bool) == true }
        let chosen = playing.first { $0.0 === target } ?? playing.first ?? results.first { $0.0 === target }
        guard let (web, d) = chosen else {
            if info != nil, let since = pausedSince, Date().timeIntervalSince(since) > 60 || results.isEmpty { clear() }
            else if info != nil, pausedSince == nil { pausedSince = Date() }
            return
        }
        target = web
        let isPlaying = (d["playing"] as? Bool) == true
        if isPlaying { pausedSince = nil } else if pausedSince == nil { pausedSince = Date() }
        if !isPlaying, let since = pausedSince, Date().timeIntervalSince(since) > 60 { clear(); return }
        let new = Info(title: d["title"] as? String ?? "", artist: d["artist"] as? String ?? "",
                       artwork: (d["artwork"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) },
                       position: d["pos"] as? Double ?? 0, duration: d["dur"] as? Double ?? 0, playing: isPlaying)
        if new != info { info = new }
    }

    private func clear() { info = nil; expanded = false; target = nil; pausedSince = nil }

    // MARK: Controls

    private func run(_ js: String) {
        target?.evaluateJavaScript("window.__ideskMedia && window.__ideskMedia.\(js)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.poll() }
    }
    func toggle() { run("toggle()") }
    func seek(_ seconds: Double) { run("seek(\(seconds))") }
    func seek(toFraction f: Double) { run("seekTo(\(f))") }
    func next() { run("next()") }
    func previous() { run("prev()") }

    // MARK: Layout (shared by the view and the pointer)

    static func rect(screen: CGSize, expanded: Bool, recording: Bool) -> CGRect {
        let w: CGFloat = expanded ? 400 : (recording ? 190 : 210), h: CGFloat = expanded ? 156 : (isNotch ? 34 : 38)
        return CGRect(x: (screen.width - w) / 2, y: top, width: w, height: h)
    }
    static func buttonRect(_ i: Int, in r: CGRect) -> CGRect {      // 0 previous … 4 next
        CGRect(x: r.midX + CGFloat(i - 2) * 62 - 24, y: r.minY + 106, width: 48, height: 38)
    }
    static func barRect(in r: CGRect) -> CGRect { CGRect(x: r.minX + 22, y: r.minY + 80, width: r.width - 44, height: 16) }
}

extension DesktopModel {
    enum IslandKind { case music, recording }

    var islandKind: IslandKind? {
        guard NowPlaying.enabled, !showScreenSaver, !hasFullscreen else { return nil }
        if ScreenRecorder.shared.isRecording { return .recording }
        return NowPlaying.shared.info == nil ? nil : .music
    }

    var islandRect: CGRect? {
        guard let kind = islandKind else { return nil }
        return NowPlaying.rect(screen: screenSize, expanded: kind == .music && NowPlaying.shared.expanded, recording: kind == .recording)
    }

    func islandContains(_ p: CGPoint) -> Bool {
        (islandRect?.insetBy(dx: -4, dy: -4).contains(p) ?? false) || clockChipRects.contains { $0.rect.insetBy(dx: -4, dy: -4).contains(p) }
    }

    /// A click at `p`: true when the island used it.
    func islandClick(at p: CGPoint) -> Bool {
        if chipClick(at: p) { return true }
        guard let kind = islandKind, let r = islandRect else { return false }
        let np = NowPlaying.shared
        guard r.insetBy(dx: -4, dy: -4).contains(p) else {
            if np.expanded { np.expanded = false }
            return false
        }
        if kind == .recording { ScreenRecorder.shared.stop(); return true }
        guard np.expanded else { np.expanded = true; return true }
        if let i = (0..<5).first(where: { NowPlaying.buttonRect($0, in: r).contains(p) }) {
            switch i {
            case 0: np.previous()
            case 1: np.seek(-10)
            case 2: np.toggle()
            case 3: np.seek(10)
            default: np.next()
            }
        } else if NowPlaying.barRect(in: r).insetBy(dx: 0, dy: -8).contains(p) {
            np.seek(toFraction: Double((p.x - NowPlaying.barRect(in: r).minX) / NowPlaying.barRect(in: r).width))
        } else {
            np.expanded = false
        }
        return true
    }
}

struct IslandView: View {
    @ObservedObject var model: DesktopModel
    @ObservedObject private var np = NowPlaying.shared
    @ObservedObject private var recorder = ScreenRecorder.shared
    @ObservedObject private var cursor: CursorModel

    init(model: DesktopModel) {
        self.model = model
        self.cursor = model.cursor
    }

    var body: some View {
        ZStack {
            island
            ClockChipsView(model: model)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder private var island: some View {
        if let kind = model.islandKind, let r = model.islandRect {
            ZStack {
                NowPlaying.shape(height: r.height, expanded: kind == .music && np.expanded).fill(Color.black)
                    .shadow(color: .black.opacity(NowPlaying.isNotch ? 0 : 0.4), radius: 10, y: 4)
                if kind == .recording {
                    HStack(spacing: 8) {
                        Circle().fill(Color.red).frame(width: 10, height: 10)
                        Text("Recording").font(.system(size: 13, weight: .semibold))
                        Image(systemName: "stop.fill").font(.system(size: 11))
                    }.foregroundStyle(.white)
                } else if let info = np.info {
                    if np.expanded { expanded(info, r) } else { collapsed(info) }
                }
            }
            .frame(width: r.width, height: r.height)
            .position(x: r.midX, y: r.midY)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: np.expanded)
            .transition(.scale.combined(with: .opacity))
        }
    }

    private func art(_ info: NowPlaying.Info, size: CGFloat) -> some View {
        AsyncImage(url: info.artwork) { phase in
            if let image = phase.image { image.resizable().scaledToFill() }
            else { Color(white: 0.2).overlay(Image(systemName: "music.note").foregroundStyle(.white.opacity(0.7))) }
        }
        .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
    }

    private func collapsed(_ info: NowPlaying.Info) -> some View {
        HStack(spacing: 8) {
            art(info, size: 26)
            Text(verbatim: info.title).font(.system(size: 12, weight: .medium)).lineLimit(1).foregroundStyle(.white)
            Spacer(minLength: 0)
            TimelineView(.animation(minimumInterval: 0.12, paused: !info.playing)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                HStack(spacing: 2) {
                    ForEach(0..<4, id: \.self) { i in
                        Capsule().fill(Color.green).frame(width: 3, height: info.playing ? 5 + 11 * abs(CGFloat(sin(t * 5 + Double(i) * 1.7))) : 4)
                    }
                }.frame(height: 18)
            }
        }
        .padding(.horizontal, 12)
    }

    private func expanded(_ info: NowPlaying.Info, _ r: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 12) {
                art(info, size: 54)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: info.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(verbatim: info.artist).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 22).padding(.top, 16)

            let bar = NowPlaying.barRect(in: r)
            Capsule().fill(Color.white.opacity(0.2)).frame(width: bar.width, height: 5)
                .overlay(alignment: .leading) {
                    Capsule().fill(Color.white)
                        .frame(width: bar.width * CGFloat(info.canSeek ? min(1, info.position / info.duration) : 0), height: 5)
                }
                .offset(x: bar.minX - r.minX, y: bar.midY - r.minY - 2.5)

            let symbols = ["backward.fill", "gobackward.10", info.playing ? "pause.fill" : "play.fill", "goforward.10", "forward.fill"]
            ForEach(0..<5, id: \.self) { i in
                let b = NowPlaying.buttonRect(i, in: r)
                Image(systemName: symbols[i]).font(.system(size: i == 2 ? 22 : 18)).foregroundStyle(.white)
                    .frame(width: b.width, height: b.height)
                    .background(Circle().fill(Color.white.opacity(b.contains(cursor.position) ? 0.18 : 0)))
                    .offset(x: b.minX - r.minX, y: b.minY - r.minY)
            }
        }
    }
}


// MARK: - Stopwatch and timer

/// The stopwatch and the countdown timer of the Clock page. They keep running when the page's window is closed:
/// the island shows them as small pills beside it (click one to open the Clock page again).
final class ClockTools: ObservableObject {
    static let shared = ClockTools()

    // Stopwatch
    @Published private(set) var swStart: Date?
    @Published private(set) var swAccum: TimeInterval = 0
    // Timer
    @Published private(set) var tmEnd: Date?
    @Published private(set) var tmRemaining: TimeInterval = 0     // while not running
    @Published private(set) var tmTotal: TimeInterval = 0
    @Published private(set) var tmFinished = false
    private var finishedAt: Date?
    private var timer: Timer?

    var swRunning: Bool { swStart != nil }
    var swElapsed: TimeInterval { swAccum + (swStart.map { Date().timeIntervalSince($0) } ?? 0) }
    var swActive: Bool { swRunning || swAccum > 0 }
    var tmRunning: Bool { tmEnd != nil }
    var tmLeft: TimeInterval { tmEnd.map { max(0, $0.timeIntervalSinceNow) } ?? tmRemaining }
    var tmActive: Bool { tmRunning || tmRemaining > 0 || tmFinished }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        if let end = tmEnd, end <= Date() { finishTimer() }
        if tmFinished, let at = finishedAt, Date().timeIntervalSince(at) > 120 { dismissFinished() }
    }

    private func finishTimer() {
        tmEnd = nil; tmRemaining = 0; tmFinished = true; finishedAt = Date()
        DesktopModel.shared.showToast(String(localized: "Time is up!"))
        for i in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.8) { AudioServicesPlayAlertSound(SystemSoundID(1005)) }
        }
    }

    func dismissFinished() { tmFinished = false; finishedAt = nil; tmTotal = 0 }

    // Stopwatch
    func swToggle() {
        if let s = swStart { swAccum += Date().timeIntervalSince(s); swStart = nil } else { swStart = Date() }
    }
    func swReset() { swStart = nil; swAccum = 0 }

    // Timer
    func tmSet(seconds: TimeInterval) {
        tmFinished = false; tmEnd = nil
        tmTotal = max(0, seconds); tmRemaining = tmTotal
    }
    func tmToggle() {
        if tmFinished { dismissFinished(); return }
        if let end = tmEnd { tmRemaining = max(0, end.timeIntervalSinceNow); tmEnd = nil }
        else if tmRemaining > 0 { tmEnd = Date().addingTimeInterval(tmRemaining) }
    }
    func tmReset() { tmEnd = nil; tmFinished = false; tmRemaining = tmTotal }
    func tmClear() { tmEnd = nil; tmFinished = false; tmRemaining = 0; tmTotal = 0 }

    /// What the Clock page shows (it counts on its own between messages).
    var json: String {
        let d: [String: Any] = ["swRun": swRunning, "swMs": Int(swElapsed * 1000), "tmRun": tmRunning, "tmMs": Int(tmLeft * 1000),
                                "tmTotalMs": Int(tmTotal * 1000), "tmDone": tmFinished]
        return (try? JSONSerialization.data(withJSONObject: d)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    static func format(_ t: TimeInterval, tenths: Bool) -> String {
        let total = max(0, t)
        let h = Int(total) / 3600, m = Int(total) % 3600 / 60, s = Int(total) % 60
        let base = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
        return tenths ? base + String(format: ".%d", Int(total * 10) % 10) : base
    }
}

enum ClockChip { case timer, stopwatch }

extension DesktopModel {
    var clockChips: [ClockChip] {
        guard NowPlaying.enabled, !showScreenSaver, !hasFullscreen else { return [] }
        let c = ClockTools.shared
        return (c.tmActive ? [.timer] : []) + (c.swActive ? [.stopwatch] : [])
    }

    /// Pills of the timer and the stopwatch: right of the island, or in the middle when nothing else is shown.
    var clockChipRects: [(chip: ClockChip, rect: CGRect)] {
        let chips = clockChips
        guard !chips.isEmpty else { return [] }
        let w: CGFloat = 138, gap: CGFloat = 8
        var x: CGFloat
        if let main = islandRect { x = main.maxX + gap }
        else { x = (screenSize.width - (CGFloat(chips.count) * w + CGFloat(chips.count - 1) * gap)) / 2 }
        return chips.map { chip in
            defer { x += w + gap }
            return (chip, CGRect(x: x, y: NowPlaying.top, width: w, height: NowPlaying.isNotch ? 34 : 38))
        }
    }

    func chipClick(at p: CGPoint) -> Bool {
        guard let hit = clockChipRects.first(where: { $0.rect.insetBy(dx: -4, dy: -4).contains(p) }) else { return false }
        let c = ClockTools.shared
        if hit.chip == .timer && c.tmFinished { c.dismissFinished() } else { openPage(.clock) }
        return true
    }
}

struct ClockChipsView: View {
    @ObservedObject var model: DesktopModel
    @ObservedObject private var clock = ClockTools.shared

    var body: some View {
        ForEach(Array(model.clockChipRects.enumerated()), id: \.offset) { _, item in
            let r = item.rect
            TimelineView(.animation(minimumInterval: 0.1)) { _ in
                let timer = item.chip == .timer
                let done = timer && clock.tmFinished
                let running = timer ? clock.tmRunning : clock.swRunning
                HStack(spacing: 6) {
                    Image(systemName: timer ? "timer" : "stopwatch.fill").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(done ? Color.red : Color.orange)
                    Text(verbatim: done ? String(localized: "Time is up!") : ClockTools.format(timer ? clock.tmLeft : clock.swElapsed, tenths: !timer))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
                        .foregroundStyle(.white.opacity(running || done ? 1 : 0.6))
                }
                .frame(width: r.width, height: r.height)
                .background(NowPlaying.shape(height: r.height, expanded: false).fill(done ? Color.red.opacity(0.85) : Color.black)
                    .shadow(color: .black.opacity(NowPlaying.isNotch ? 0 : 0.4), radius: 8, y: 3))
            }
            .position(x: r.midX, y: r.midY)
        }
    }
}
