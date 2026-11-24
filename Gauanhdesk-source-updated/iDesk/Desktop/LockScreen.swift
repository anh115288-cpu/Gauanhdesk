import SwiftUI
import LocalAuthentication
import CryptoKit

/// How the locked desktop is opened.
enum LockMethod: Int {
    /// Face ID / Touch ID, or the iPhone's own passcode.
    case device = 0
    /// A password chosen in Settings (kept in the Keychain). Touch ID / Face ID can still open it when turned on.
    case password = 1
}

/// Settings → Security: the desktop can lock (⌃⌘Q, when iDesk comes back after the iPhone was locked or another app
/// was used, and after the screen saver) and opens again with Face ID, Touch ID, the iPhone's passcode or a password
/// of its own. The screen saver (a big clock) starts after some minutes without input. The clock and the picture
/// behind it (lock screen and screen saver) can be customised.
enum LockSettings {
    private static let lockKey = "iDesk.lockWithFaceID", saverKey = "iDesk.screenSaverMinutes"
    private static let methodKey = "iDesk.lock.method", bioKey = "iDesk.lock.useBiometrics"
    private static let styleKey = "iDesk.lock.clockStyle", sizeKey = "iDesk.lock.clockSize", colorKey = "iDesk.lock.clockColor"
    private static let formatKey = "iDesk.lock.hourFormat", secondsKey = "iDesk.lock.seconds", dateKey = "iDesk.lock.date"
    private static let wallModeKey = "iDesk.lock.wallpaperMode", blurKey = "iDesk.lock.blur"

    private static func changed() { DispatchQueue.main.async { DesktopModel.shared.objectWillChange.send() } }

    static var lockEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: lockKey) }
        set { UserDefaults.standard.set(newValue, forKey: lockKey) }
    }
    /// 0 = never.
    static var saverMinutes: Int {
        get { UserDefaults.standard.object(forKey: saverKey) as? Int ?? 10 }
        set { UserDefaults.standard.set(newValue, forKey: saverKey) }
    }

    // MARK: Unlocking

    static var method: LockMethod {
        get {
            let m = LockMethod(rawValue: UserDefaults.standard.integer(forKey: methodKey)) ?? .device
            return m == .password && !hasPassword ? .device : m      // a password method needs a password
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: methodKey); changed() }
    }
    /// With a password: also open with the fingerprint / face (when the iPhone has one set up).
    static var useBiometrics: Bool {
        get { UserDefaults.standard.object(forKey: bioKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: bioKey); changed() }
    }

    enum BiometryState: String { case ready, notEnrolled, none }

    /// What the iPhone can do: Touch ID (fingerprint), Face ID or Optic ID, and whether one is set up in iOS Settings.
    static var biometryState: BiometryState {
        let ctx = LAContext()
        var error: NSError?
        if ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) { return .ready }
        switch (error.map { LAError.Code(rawValue: $0.code) }) {
        case .biometryNotEnrolled?, .biometryLockout?: return .notEnrolled
        default: return .none
        }
    }
    static var biometryType: LABiometryType {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return ctx.biometryType
    }
    static var biometryName: String {
        switch biometryType {
        case .faceID: return "Face ID"
        case .touchID: return String(localized: "Touch ID (fingerprint)")
        case .opticID: return "Optic ID"
        default: return String(localized: "the passcode")
        }
    }
    /// The SF Symbol of the biometry the iPhone has (a fingerprint for Touch ID).
    static var biometrySymbol: String {
        switch biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        default: return "lock.open"
        }
    }
    static var biometryAvailable: Bool { biometryState == .ready }

    // MARK: Password (a salted SHA-256 of it, in the Keychain)

    private static let service = "iDesk.lockPassword"
    private static func digest(_ password: String, salt: Data) -> Data {
        Data(SHA256.hash(data: salt + Data(password.utf8)))
    }
    private static var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "lock"]
    }
    private static func stored() -> (salt: Data, hash: Data)? {
        var q = keychainQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data, data.count == 48 else { return nil }
        return (data.prefix(16), data.suffix(32))
    }
    static var hasPassword: Bool { stored() != nil }
    static let minPasswordLength = 4

    @discardableResult
    static func setPassword(_ password: String) -> Bool {
        guard password.count >= minPasswordLength else { return false }
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { return false }
        SecItemDelete(keychainQuery as CFDictionary)
        var add = keychainQuery
        add[kSecValueData as String] = salt + digest(password, salt: salt)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return false }
        method = .password
        return true
    }
    static func clearPassword() {
        SecItemDelete(keychainQuery as CFDictionary)
        method = .device
    }
    static func checkPassword(_ password: String) -> Bool {
        guard let s = stored() else { return false }
        return digest(password, salt: s.salt) == s.hash
    }

    // MARK: The clock

    /// Style of the digits: rounded, serif, thin, monospaced.
    static var clockStyle: Int {
        get { min(max(UserDefaults.standard.integer(forKey: styleKey), 0), 3) }
        set { UserDefaults.standard.set(newValue, forKey: styleKey); changed() }
    }
    /// 0 small, 1 medium, 2 large.
    static var clockSize: Int {
        get { UserDefaults.standard.object(forKey: sizeKey) as? Int ?? 1 }
        set { UserDefaults.standard.set(min(max(newValue, 0), 2), forKey: sizeKey); changed() }
    }
    static var clockScale: CGFloat { [0.7, 1.0, 1.35][clockSize] }
    static let clockColors: [Color] = [.white, Color(red: 1, green: 0.84, blue: 0.3), Color(red: 0.4, green: 0.85, blue: 1),
                                       Color(red: 1, green: 0.55, blue: 0.75), Color(red: 0.5, green: 0.95, blue: 0.55),
                                       Color(red: 1, green: 0.6, blue: 0.3)]
    static let clockCSSColors = ["#ffffff", "#ffd64d", "#66d9ff", "#ff8cbf", "#80f28c", "#ff994d"]
    static var clockColor: Int {
        get { min(max(UserDefaults.standard.integer(forKey: colorKey), 0), clockColors.count - 1) }
        set { UserDefaults.standard.set(newValue, forKey: colorKey); changed() }
    }
    /// 0 follows the iPhone's region, 1 is 12-hour, 2 is 24-hour.
    static var hourFormat: Int {
        get { UserDefaults.standard.integer(forKey: formatKey) }
        set { UserDefaults.standard.set(newValue, forKey: formatKey); changed() }
    }
    static var showSeconds: Bool {
        get { UserDefaults.standard.bool(forKey: secondsKey) }
        set { UserDefaults.standard.set(newValue, forKey: secondsKey); changed() }
    }
    static var showDate: Bool {
        get { UserDefaults.standard.object(forKey: dateKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: dateKey); changed() }
    }

    static func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        switch hourFormat {
        case 1: f.dateFormat = showSeconds ? "h:mm:ss a" : "h:mm a"
        case 2: f.dateFormat = showSeconds ? "HH:mm:ss" : "HH:mm"
        default: f.dateFormat = DateFormatter.dateFormat(fromTemplate: showSeconds ? "jmmss" : "jmm", options: 0, locale: .current)
        }
        return f.string(from: date)
    }
    static var refreshSeconds: TimeInterval { showSeconds ? 1 : 15 }

    // MARK: The picture behind the lock screen

    /// 0 = the desktop's wallpaper, 1 = a photo of its own.
    static var wallpaperMode: Int {
        get { hasOwnWallpaper ? UserDefaults.standard.integer(forKey: wallModeKey) : 0 }
        set { UserDefaults.standard.set(newValue, forKey: wallModeKey); changed() }
    }
    static var blurWallpaper: Bool {
        get { UserDefaults.standard.object(forKey: blurKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: blurKey); changed() }
    }
    private static var wallpaperFile: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("iDeskLockWallpaper.jpg")
    }
    private static var cachedWallpaper: UIImage?
    static var hasOwnWallpaper: Bool { ownWallpaper != nil }
    static var ownWallpaper: UIImage? {
        if cachedWallpaper == nil { cachedWallpaper = UIImage(contentsOfFile: wallpaperFile.path) }
        return cachedWallpaper
    }
    /// A photo for the lock screen: scaled to display size (less memory), then saved.
    static func setWallpaper(_ data: Data) {
        guard let image = UIImage(data: data) else { DesktopModel.shared.notice = String(localized: "Could not read this image."); return }
        let scale = min(1, 2560 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        try? resized.jpegData(compressionQuality: 0.85)?.write(to: wallpaperFile, options: .atomic)
        cachedWallpaper = resized
        wallpaperMode = 1
    }
    static func removeWallpaper() {
        try? FileManager.default.removeItem(at: wallpaperFile)
        cachedWallpaper = nil
        UserDefaults.standard.set(0, forKey: wallModeKey)
        changed()
    }
    /// A small copy for the Settings page.
    static func wallpaperThumbnail() -> String? {
        guard let image = ownWallpaper else { return nil }
        let size = CGSize(width: 192, height: 192 * image.size.height / max(1, image.size.width))
        let small = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return small.jpegData(compressionQuality: 0.7).map { "data:image/jpeg;base64," + $0.base64EncodedString() }
    }
}

extension DesktopModel {
    /// Locks the desktop (when locking is turned on, or asked for by ⌃⌘Q).
    func lockDesktop(force: Bool = false) {
        guard force || LockSettings.lockEnabled, isExternalConnected, !isLocked else { return }
        closePanels()
        isLocked = true
    }

    /// Asks for Face ID / Touch ID / the passcode on the iPhone and unlocks. With a password of its own, only the
    /// fingerprint / face is asked for here (the iPhone's passcode is not a way in then).
    func unlockDesktop() {
        let passwordOnly = LockSettings.method == .password
        if passwordOnly && !(LockSettings.useBiometrics && LockSettings.biometryAvailable) { return }
        let ctx = LAContext()
        ctx.localizedCancelTitle = String(localized: "Cancel")
        if passwordOnly { ctx.localizedFallbackTitle = "" }          // no “Enter passcode” button
        let policy: LAPolicy = passwordOnly ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication
        ctx.evaluatePolicy(policy, localizedReason: String(localized: "Unlock the desktop")) { ok, _ in
            DispatchQueue.main.async { if ok { self.finishUnlock() } }
        }
    }

    /// The password typed on the iPhone. Returns whether it was right (and the desktop opened).
    @discardableResult
    func unlockDesktop(password: String) -> Bool {
        guard LockSettings.checkPassword(password) else { return false }
        finishUnlock()
        return true
    }

    private func finishUnlock() { isLocked = false; lastInput = Date() }

    /// Any input: the screen saver ends (and the clock for the next one restarts).
    func noteInput() {
        lastInput = Date()
        if showScreenSaver {
            withAnimation(.easeOut(duration: 0.3)) { showScreenSaver = false }
            lockDesktop()
        }
    }

    /// Every few seconds: starts the screen saver after the chosen idle time (not while a video plays fullscreen).
    func checkIdle() {
        let minutes = LockSettings.saverMinutes
        guard minutes > 0, isExternalConnected, !showScreenSaver, !hasFullscreen, presentation == nil,
              !ScreenRecorder.shared.isRecording,
              Date().timeIntervalSince(lastInput) > Double(minutes * 60) else { return }
        closePanels()
        withAnimation(.easeIn(duration: 0.8)) { showScreenSaver = true }
    }
}

/// The time and date, in the style chosen in Settings (lock screen and screen saver).
struct LockClock: View {
    let date: Date
    /// The size of the digits at "medium".
    let baseSize: CGFloat
    var weight: Font.Weight? = nil

    private var digits: Font {
        let size = baseSize * LockSettings.clockScale
        switch LockSettings.clockStyle {
        case 1: return .system(size: size, weight: weight ?? .medium, design: .serif).monospacedDigit()
        case 2: return .system(size: size, weight: .ultraLight, design: .default).monospacedDigit()
        case 3: return .system(size: size * 0.9, weight: weight ?? .regular, design: .monospaced)
        default: return .system(size: size, weight: weight ?? .semibold, design: .rounded).monospacedDigit()
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(verbatim: LockSettings.timeString(date))
                .font(digits)
                .minimumScaleFactor(0.4).lineLimit(1)
                .foregroundStyle(LockSettings.clockColors[LockSettings.clockColor])
            if LockSettings.showDate {
                Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.system(size: max(16, baseSize * LockSettings.clockScale * 0.2), weight: .light))
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
    }
}

/// The big clock of the screen saver, drifting slowly so nothing burns into the display.
struct ScreenSaverView: View {
    let size: CGSize
    var body: some View {
        TimelineView(.periodic(from: .now, by: LockSettings.refreshSeconds)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let k = LockSettings.clockScale
            // Within the screen: the clock is about 600 × 220 points at medium size.
            let dx = CGFloat(sin(t / 37)) * max(0, size.width / 2 - 340 * k), dy = CGFloat(cos(t / 53)) * max(0, size.height / 2 - 160 * k)
            ZStack {
                Color.black
                LockClock(date: ctx.date, baseSize: 150, weight: LockSettings.clockStyle == 0 ? .thin : nil)
                    .opacity(0.85)
                    .offset(x: dx, y: dy)
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}

/// The locked desktop: the wallpaper (blurred, or not), the time, and how to open it.
struct LockScreenView: View {
    @ObservedObject var model: DesktopModel
    let size: CGSize
    var body: some View {
        TimelineView(.periodic(from: .now, by: LockSettings.refreshSeconds)) { ctx in
            let own = LockSettings.wallpaperMode == 1
            let blur = LockSettings.blurWallpaper
            ZStack {
                Color.black          // nothing of the desktop shows through the blur's edges
                WallpaperView(index: own ? -1 : model.wallpaper, image: own ? LockSettings.ownWallpaper : model.customWallpaper, watermark: false)
                    .blur(radius: blur ? 40 : 0, opaque: true)
                    .overlay(Color.black.opacity(blur ? 0.35 : 0.2))
                VStack(spacing: 10) {
                    Image(systemName: "lock.fill").font(.system(size: 34))
                    LockClock(date: ctx.date, baseSize: 110)
                    Text(verbatim: Device.words(unlockHint))
                        .font(.system(size: 18, weight: .medium))
                        .padding(.horizontal, 20).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 30)
                }
                .foregroundStyle(.white)
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private var unlockHint: String {
        if LockSettings.method == .password {
            return LockSettings.useBiometrics && LockSettings.biometryAvailable
                ? String(localized: "Unlock on the iPhone with the password or \(LockSettings.biometryName)")
                : String(localized: "Unlock on the iPhone with the password")
        }
        return String(localized: "Unlock on the iPhone with \(LockSettings.biometryName)")
    }
}

/// On the iPhone while the desktop is locked.
struct LockedRemote: View {
    @ObservedObject var model: DesktopModel
    @State private var password = ""
    @State private var wrong = false
    @FocusState private var focused: Bool

    private var usesPassword: Bool { LockSettings.method == .password }
    private var biometricsOffered: Bool { !usesPassword || (LockSettings.useBiometrics && LockSettings.biometryAvailable) }

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "lock.display").font(.system(size: 64)).foregroundStyle(.tint)
            Text("The desktop is locked").font(.title2.bold())
            if usesPassword {
                VStack(spacing: 10) {
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focused)
                        .submitLabel(.go)
                        .onSubmit(submit)
                        .padding(.horizontal, 14).frame(maxWidth: 360, minHeight: 50)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.16)))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(wrong ? Color.red : .clear, lineWidth: 1.5))
                    if wrong { Text("Wrong password").font(.footnote).foregroundStyle(.red) }
                    Button(action: submit) {
                        Text("Unlock").font(.headline).frame(maxWidth: 360, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty)
                }
            }
            if biometricsOffered {
                Button { model.unlockDesktop() } label: {
                    Label(String(localized: "Unlock with \(LockSettings.biometryName)"), systemImage: LockSettings.biometrySymbol)
                        .font(.headline).frame(maxWidth: 360, minHeight: 54)
                }
                .buttonStyle(usesPassword ? .bordered : .borderedProminent)
            }
            Spacer()
        }
        .padding(24)
        .onAppear {
            password = ""
            wrong = false
            if biometricsOffered { model.unlockDesktop() }
            if usesPassword { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focused = true } }
        }
    }

    private func submit() {
        guard !password.isEmpty else { return }
        if model.unlockDesktop(password: password) { password = ""; return }
        wrong = true
        password = ""
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
