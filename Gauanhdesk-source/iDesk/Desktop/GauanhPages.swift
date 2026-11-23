import UIKit
import WebKit
import Security

// Gauanhdesk's own pages (windows on the desktop, like Settings): the virtual assistant (Google AI Studio / Gemini
// API), weather, and About. Each is a small HTML page; buttons reach Swift through PageBridge (DesktopPages.swift).

private func pageJSON(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return "null" }
    return String(decoding: data, as: UTF8.self)
}

/// The CSS the three pages share (the same dark look as Settings).
private let pageCSS = #"""
:root { color-scheme: dark; }
* { box-sizing: border-box; }
html, body { height: 100%; }
body { margin: 0; padding: 22px 26px; background: #161618; color: #eee; font: 15px -apple-system, sans-serif; }
h1 { font-size: 24px; margin: 0 0 4px; }
h2 { font-size: 13px; text-transform: uppercase; letter-spacing: .04em; color: #8e8e93; margin: 22px 0 8px; }
.note { color: #999; font-size: 13px; }
.card { background: #232326; border-radius: 12px; padding: 12px 16px; margin-bottom: 12px; }
button { background: #34343a; color: #eee; border: 0; border-radius: 8px; padding: 8px 13px; font: inherit; font-size: 14px; cursor: pointer; }
button:hover { background: #45454c; }
button.primary { background: #0a84ff; color: #fff; } button.primary:hover { background: #3797ff; }
button:disabled { opacity: .45; }
input, textarea { background: #2c2c30; color: #eee; border: 0; border-radius: 8px; padding: 9px 12px; font: inherit; font-size: 14px;
                  -webkit-user-select: text; user-select: text; outline: none; }
a { color: #8ab4ff; text-decoration: none; } a:hover { text-decoration: underline; }
"""#

// MARK: - Key storage

/// The AI Studio API key lives in the Keychain, never in the page or in UserDefaults.
enum GeminiKey {
    private static let service = "vn.gauanhdesk.gemini"
    private static let account = "apiKey"
    private static let modelKey = "gauanhdesk.geminiModel"
    static let defaultModel = "gemini-2.5-flash"

    static var value: String? {
        get {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
            var out: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                       kSecAttrAccount as String: account]
            SecItemDelete(base as CFDictionary)
            guard let newValue, !newValue.isEmpty, let data = newValue.data(using: .utf8) else { return }
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static var model: String {
        get { UserDefaults.standard.string(forKey: modelKey) ?? defaultModel }
        set {
            // Only what a model name is made of: it goes into the request address.
            var name = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.hasPrefix("models/") { name.removeFirst("models/".count) }
            let ok = !name.isEmpty && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-._".unicodeScalars.contains($0) }
            UserDefaults.standard.set(ok ? name : defaultModel, forKey: modelKey)
        }
    }
}

// MARK: - Assistant

enum AssistantPage {
    private static let system = "Bạn là trợ lý ảo trong Gauanhdesk, một desktop chạy trên iPhone và iPad. Trả lời ngắn gọn, rõ ràng, "
        + "bằng ngôn ngữ người dùng đang dùng (mặc định tiếng Việt)."

    static func handle(action: String, value: String, in webView: WKWebView?) {
        switch action {
        case "saveKey":
            // value: "<model>\u{1}<key>" (the key is kept as it is when left empty).
            let parts = value.components(separatedBy: "\u{1}")
            if let model = parts.first { GeminiKey.model = model }
            if parts.count > 1, !parts[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                GeminiKey.value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            run("ideskSaved(\(pageJSON(["hasKey": GeminiKey.value?.isEmpty == false, "model": GeminiKey.model])))", in: webView)
        case "removeKey":
            GeminiKey.value = nil
            run("ideskSaved(\(pageJSON(["hasKey": false, "model": GeminiKey.model])))", in: webView)
        case "getKey":
            DesktopModel.shared.openWindow("https://aistudio.google.com/apikey")
        case "ask":
            ask(value, in: webView)
        default: break
        }
    }

    private static func run(_ js: String, in webView: WKWebView?) {
        DispatchQueue.main.async { webView?.evaluateJavaScript(js) }
    }

    private static func ask(_ messagesJSON: String, in webView: WKWebView?) {
        func reply(_ ok: Bool, _ text: String) { run("ideskReply(\(pageJSON(["ok": ok, "text": text])))", in: webView) }
        guard let key = GeminiKey.value, !key.isEmpty else {
            reply(false, "Chưa có API key. Bấm ⚙ để dán khóa lấy từ Google AI Studio."); return
        }
        guard let data = messagesJSON.data(using: .utf8),
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: String]], !list.isEmpty else {
            reply(false, "Tin nhắn không hợp lệ."); return
        }
        let contents: [[String: Any]] = list.map {
            ["role": $0["role"] == "user" ? "user" : "model", "parts": [["text": $0["text"] ?? ""]]]
        }
        let body: [String: Any] = ["contents": contents, "systemInstruction": ["parts": [["text": system]]]]
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(GeminiKey.model):generateContent"),
              let payload = try? JSONSerialization.data(withJSONObject: body) else { reply(false, "Không tạo được yêu cầu."); return }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = payload
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error { reply(false, "Lỗi mạng: \(error.localizedDescription)"); return }
            guard let data, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                reply(false, "Không đọc được phản hồi."); return
            }
            if let err = obj["error"] as? [String: Any] {
                reply(false, (err["message"] as? String) ?? "Google trả về lỗi."); return
            }
            let parts = ((obj["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]
            let text = parts?.compactMap { $0["text"] as? String }.joined() ?? ""
            if text.isEmpty {
                let why = (obj["promptFeedback"] as? [String: Any])?["blockReason"] as? String
                reply(false, why.map { "Yêu cầu bị chặn (\($0))." } ?? "Trợ lý không trả lời.")
            } else {
                reply(true, text)
            }
        }.resume()
    }

    static func html() -> String {
        let state: [String: Any] = ["hasKey": GeminiKey.value?.isEmpty == false, "model": GeminiKey.model]
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <title>Trợ lý ảo</title><style>\(pageCSS)\(css)</style></head><body>
        <div class="top"><div><h1>✨ Trợ lý ảo</h1><div class="note" id="sub"></div></div><button id="gear" onclick="toggleSettings()">⚙</button></div>
        <div class="card" id="settings" style="display:none">
          <div class="note" style="margin-bottom:8px">Dùng API key của Google AI Studio (Gemini). Khóa được lưu trong Keychain của iPhone.</div>
          <div class="line"><input id="key" type="password" placeholder="Dán API key…" autocapitalize="off" autocorrect="off" style="flex:1"></div>
          <div class="line"><input id="model" placeholder="Tên model" autocapitalize="off" autocorrect="off" style="flex:1"></div>
          <div class="line"><button class="primary" onclick="saveKey()">Lưu</button><button onclick="send('getKey')">Lấy API key</button>
            <button onclick="send('removeKey')">Xóa khóa</button></div>
        </div>
        <div id="chat"></div>
        <div class="bar"><textarea id="box" rows="2" placeholder="Hỏi trợ lý…  (Enter để gửi, Shift+Enter xuống dòng)"
          onkeydown="if (event.key === 'Enter' && !event.shiftKey) { event.preventDefault(); sendMessage(); }"></textarea>
          <button class="primary" id="go" onclick="sendMessage()">Gửi</button><button onclick="clearChat()">Xóa</button></div>
        <script>
        let S = \(pageJSON(state)); const BRIDGE = '\(DesktopPages.messageName)';
        function send(a, v) { window.webkit.messageHandlers[BRIDGE].postMessage({ action: a, value: v === undefined ? '' : String(v) }); }
        function esc(s) { return String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); }
        const msgs = []; let busy = false;
        function md(t) {
          let h = esc(t);
          h = h.replace(/```[a-zA-Z0-9]*\\n?([\\s\\S]*?)```/g, (m, c) => '<pre>' + c + '</pre>');
          h = h.replace(/`([^`\\n]+)`/g, '<code>$1</code>').replace(/\\*\\*([^*\\n]+)\\*\\*/g, '<b>$1</b>');
          return h.replace(/\\n/g, '<br>');
        }
        function draw() {
          document.getElementById('sub').textContent = S.hasKey ? 'Model: ' + S.model : 'Chưa có API key — bấm ⚙ để cài đặt';
          const chat = document.getElementById('chat');
          chat.innerHTML = msgs.length ? msgs.map(m => `<div class="m ${m.role}">${md(m.text)}</div>`).join('')
            + (busy ? '<div class="m model note">Đang suy nghĩ…</div>' : '')
            : '<p class="note" style="padding:14px 4px">Xin chào! Mình là trợ lý ảo của Gauanhdesk. Hỏi mình bất cứ điều gì.</p>';
          document.getElementById('go').disabled = busy;
          chat.scrollTop = chat.scrollHeight;
        }
        function toggleSettings() {
          const s = document.getElementById('settings'); s.style.display = s.style.display === 'none' ? 'block' : 'none';
          document.getElementById('model').value = S.model;
        }
        function saveKey() {
          send('saveKey', document.getElementById('model').value + '\\u0001' + document.getElementById('key').value);
          document.getElementById('key').value = '';
        }
        function ideskSaved(s) { S = s; document.getElementById('settings').style.display = 'none'; draw(); }
        function sendMessage() {
          const box = document.getElementById('box'), text = box.value.trim();
          if (!text || busy) return;
          msgs.push({ role: 'user', text }); box.value = ''; busy = true; draw();
          send('ask', JSON.stringify(msgs));
        }
        function ideskReply(r) { busy = false; msgs.push({ role: r.ok ? 'model' : 'err', text: r.text }); draw(); }
        function clearChat() { msgs.length = 0; busy = false; draw(); }
        // An error line is shown but not sent back to the model.
        const _send = send; send = function (a, v) {
          if (a === 'ask') v = JSON.stringify(msgs.filter(m => m.role !== 'err'));
          _send(a, v);
        };
        draw(); if (!S.hasKey) toggleSettings();
        </script></body></html>
        """
    }

    private static let css = #"""
    body { display: flex; flex-direction: column; }
    .top { display: flex; justify-content: space-between; align-items: flex-start; }
    .line { display: flex; gap: 8px; margin-top: 8px; }
    #chat { flex: 1; overflow-y: auto; padding: 6px 0; -webkit-user-select: text; user-select: text; }
    .m { max-width: 88%; padding: 10px 14px; border-radius: 14px; margin: 8px 0; line-height: 1.45; word-wrap: break-word; }
    .m.user { background: #0a84ff; color: #fff; margin-left: auto; border-bottom-right-radius: 4px; }
    .m.model { background: #2c2c30; border-bottom-left-radius: 4px; }
    .m.err { background: #4a2326; color: #ff9d96; }
    pre { background: #111; padding: 10px; border-radius: 8px; overflow-x: auto; white-space: pre-wrap; margin: 6px 0; }
    code { background: #111; padding: 1px 5px; border-radius: 4px; }
    .bar { display: flex; gap: 8px; align-items: flex-end; padding-top: 10px; }
    .bar textarea { flex: 1; resize: none; }
    """#
}

// MARK: - Weather

enum WeatherPage {
    private static let key = "gauanhdesk.weatherCity"

    static func handle(action: String, value: String) {
        guard action == "city", let data = value.data(using: .utf8),
              let city = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = city["name"] as? String, city["lat"] is Double || city["lat"] is Int,
              city["lon"] is Double || city["lon"] is Int else { return }
        UserDefaults.standard.set(["name": name, "lat": city["lat"]!, "lon": city["lon"]!], forKey: key)
    }

    static func html() -> String {
        let saved = UserDefaults.standard.dictionary(forKey: key)
        let city: [String: Any] = saved ?? ["name": "Hà Nội", "lat": 21.0285, "lon": 105.8542]
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <title>Thời tiết</title><style>\(pageCSS)\(css)</style></head><body>
        <h1>🌤️ Thời tiết</h1>
        <div class="search"><input id="q" placeholder="Tìm thành phố…" style="flex:1" autocapitalize="off" autocorrect="off"
          onkeydown="if (event.key === 'Enter') search()"><button class="primary" onclick="search()">Tìm</button></div>
        <div id="results"></div>
        <div id="now"></div><div id="days"></div>
        <p class="note">Dữ liệu từ Open-Meteo.</p>
        <script>
        let CITY = \(pageJSON(city)); const BRIDGE = '\(DesktopPages.messageName)';
        function send(a, v) { window.webkit.messageHandlers[BRIDGE].postMessage({ action: a, value: v === undefined ? '' : String(v) }); }
        function esc(s) { return String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); }
        const W = { 0: ['Trời quang', '☀️'], 1: ['Gần như quang', '🌤️'], 2: ['Mây rải rác', '⛅'], 3: ['Nhiều mây', '☁️'],
          45: ['Sương mù', '🌫️'], 48: ['Sương mù đóng băng', '🌫️'], 51: ['Mưa phùn nhẹ', '🌦️'], 53: ['Mưa phùn', '🌦️'], 55: ['Mưa phùn dày', '🌦️'],
          56: ['Mưa phùn lạnh', '🌦️'], 57: ['Mưa phùn lạnh', '🌦️'], 61: ['Mưa nhỏ', '🌧️'], 63: ['Mưa vừa', '🌧️'], 65: ['Mưa to', '🌧️'],
          66: ['Mưa lạnh', '🌧️'], 67: ['Mưa lạnh to', '🌧️'], 71: ['Tuyết nhẹ', '🌨️'], 73: ['Tuyết', '🌨️'], 75: ['Tuyết dày', '❄️'],
          77: ['Hạt tuyết', '❄️'], 80: ['Mưa rào nhẹ', '🌦️'], 81: ['Mưa rào', '🌧️'], 82: ['Mưa rào lớn', '⛈️'], 85: ['Tuyết rào', '🌨️'],
          86: ['Tuyết rào lớn', '🌨️'], 95: ['Giông', '⛈️'], 96: ['Giông kèm mưa đá', '⛈️'], 99: ['Giông mưa đá lớn', '⛈️'] };
        const wx = c => W[c] || ['Không rõ', '🌡️'];
        const DAY = ['CN', 'T2', 'T3', 'T4', 'T5', 'T6', 'T7'];
        async function load() {
          const now = document.getElementById('now'), days = document.getElementById('days');
          now.innerHTML = '<div class="card note">Đang tải…</div>'; days.innerHTML = '';
          try {
            const u = 'https://api.open-meteo.com/v1/forecast?latitude=' + CITY.lat + '&longitude=' + CITY.lon
              + '&current=temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,precipitation,weather_code'
              + '&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max&timezone=auto&forecast_days=7';
            const r = await fetch(u); if (!r.ok) throw new Error(r.status);
            const d = await r.json(), c = d.current, [label, icon] = wx(c.weather_code);
            now.innerHTML = `<div class="card now"><div class="big">${icon}</div><div><div class="place">${esc(CITY.name)}</div>
              <div class="temp">${Math.round(c.temperature_2m)}°C</div><div>${esc(label)}</div></div>
              <div class="more">Cảm giác ${Math.round(c.apparent_temperature)}°C<br>Độ ẩm ${c.relative_humidity_2m}%<br>Gió ${Math.round(c.wind_speed_10m)} km/h<br>Mưa ${c.precipitation} mm</div></div>`;
            days.innerHTML = '<h2>7 ngày tới</h2><div class="card">' + d.daily.time.map((t, i) => {
              const dt = new Date(t + 'T12:00:00'), [l, ic] = wx(d.daily.weather_code[i]), p = d.daily.precipitation_probability_max[i];
              return `<div class="day"><span class="dn">${i === 0 ? 'Hôm nay' : DAY[dt.getDay()] + ' ' + dt.getDate() + '/' + (dt.getMonth() + 1)}</span>
                <span class="ic">${ic}</span><span class="lb">${esc(l)}</span><span class="rain">${p == null ? '' : '💧' + p + '%'}</span>
                <span class="tt">${Math.round(d.daily.temperature_2m_min[i])}° / <b>${Math.round(d.daily.temperature_2m_max[i])}°</b></span></div>`;
            }).join('') + '</div>';
          } catch (e) { now.innerHTML = '<div class="card" style="color:#ff9d96">Không tải được thời tiết. Kiểm tra mạng rồi thử lại.</div>'; }
        }
        async function search() {
          const q = document.getElementById('q').value.trim(), box = document.getElementById('results'); if (!q) return;
          try {
            const r = await fetch('https://geocoding-api.open-meteo.com/v1/search?count=6&language=vi&name=' + encodeURIComponent(q));
            const d = await r.json(), list = d.results || [];
            window.__found = list;
            box.innerHTML = list.length ? '<div class="card">' + list.map((x, i) =>
              `<div class="hit" onclick="pick(${i})">${esc(x.name)}<span class="note"> · ${esc([x.admin1, x.country].filter(Boolean).join(', '))}</span></div>`).join('') + '</div>'
              : '<div class="card note">Không tìm thấy thành phố.</div>';
          } catch (e) { box.innerHTML = '<div class="card note">Không tìm được. Kiểm tra mạng.</div>'; }
        }
        function pick(i) {
          const x = window.__found[i]; CITY = { name: x.name, lat: x.latitude, lon: x.longitude };
          send('city', JSON.stringify(CITY)); document.getElementById('results').innerHTML = ''; document.getElementById('q').value = ''; load();
        }
        load(); setInterval(load, 20 * 60 * 1000);
        </script></body></html>
        """
    }

    private static let css = #"""
    .search { display: flex; gap: 8px; margin: 12px 0; }
    .hit { padding: 9px 4px; border-top: 1px solid #2f2f33; cursor: pointer; } .hit:first-child { border-top: 0; } .hit:hover { color: #8ab4ff; }
    .now { display: flex; align-items: center; gap: 18px; padding: 18px 20px; }
    .now .big { font-size: 64px; } .now .place { font-size: 16px; color: #aaa; } .now .temp { font-size: 46px; font-weight: 600; line-height: 1.1; }
    .now .more { margin-left: auto; color: #bbb; font-size: 13px; line-height: 1.7; text-align: right; }
    .day { display: flex; align-items: center; gap: 10px; min-height: 44px; border-top: 1px solid #2f2f33; }
    .day:first-child { border-top: 0; } .dn { width: 76px; } .ic { font-size: 22px; width: 30px; } .lb { flex: 1; color: #ccc; }
    .rain { color: #6cb6ff; font-size: 13px; width: 56px; text-align: right; } .tt { width: 90px; text-align: right; font-variant-numeric: tabular-nums; color: #aaa; }
    .tt b { color: #eee; }
    """#
}

// MARK: - About

enum AboutPage {
    static let tiktokHandle = "haisoncubebyanhlq14"
    static let oldTiktokHandle = "Quanganhdaynek14"
    static let tiktokURL = "https://www.tiktok.com/@\(tiktokHandle)"

    static func handle(action: String) {
        if action == "tiktok" { DesktopModel.shared.openWindow(tiktokURL) }
    }

    static func html() -> String {
        let version = Bundle.iDesk.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <title>Giới thiệu</title><style>\(pageCSS)
        body { text-align: center; padding-top: 40px; } .logo { font-size: 64px; } .card { text-align: left; }
        </style></head><body>
        <div class="logo">🖥️</div><h1>Gauanhdesk</h1><div class="note">Phiên bản \(version)</div>
        <h2>Bản quyền</h2>
        <div class="card">© 2026 Anh. Bản quyền thuộc về Anh.<br>
          <span class="note">Dựa trên mã nguồn mở iDesk của HiếuK (giấy phép MIT).</span></div>
        <h2>Kênh TikTok</h2>
        <div class="card">TikTok: <b>@\(tiktokHandle)</b><br><span class="note">Tên cũ: \(oldTiktokHandle)</span>
          <div style="margin-top:10px"><button class="primary" onclick="window.webkit.messageHandlers.\(DesktopPages.messageName).postMessage({action:'tiktok',value:''})">Mở kênh TikTok</button></div></div>
        </body></html>
        """
    }
}
