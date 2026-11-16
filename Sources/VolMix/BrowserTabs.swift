import AppKit
import Darwin
import Foundation

/// Volume por aba nos navegadores baseados no Chromium (Chrome, Edge, Brave, Arc, Vivaldi…).
///
/// O navegador toca o áudio de todas as abas num único processo, então o process tap só enxerga
/// "o Chrome inteiro". Quem separa as abas é a extensão (pasta `Extension/`): ela manda a lista de
/// abas com som e aplica o volume e o mudo que escolhemos aqui.
///
/// Caminho: extensão -> native messaging -> `browser-host.sh` (nc) -> socket local -> este objeto.
@MainActor
final class BrowserTabs: ObservableObject {
    static let hostName = "com.wellingtonmota.deadnoise"
    /// ID fixo da extensão (vem da chave pública em `Extension/manifest.json`).
    static let extensionIDs = ["jlhckjdnagcebkaggaggldcaoodhlghd"]

    struct Tab: Identifiable, Equatable {
        let connection: Int
        let tabID: Int
        let title: String
        let host: String
        let favicon: NSImage?
        let audible: Bool
        let muted: Bool
        let gain: Float
        var id: String { "\(connection):\(tabID)" }

        static func == (a: Tab, b: Tab) -> Bool {
            a.id == b.id && a.title == b.title && a.host == b.host && a.audible == b.audible
                && a.muted == b.muted && a.gain == b.gain && (a.favicon == nil) == (b.favicon == nil)
        }
    }

    struct Browser: Identifiable, Equatable {
        let id: Int
        var name: String
        /// Bundle ID do navegador que abriu a conexão (para mostrar as abas embaixo dele).
        let bundleID: String?
        var tabs: [Tab]
    }

    @Published private(set) var browsers: [Browser] = []

    /// Navegadores Chromium conhecidos: bundle ID -> pasta de dados em ~/Library/Application Support.
    static let chromiumBrowsers: [String: String] = [
        "com.google.Chrome": "Google/Chrome",
        "com.google.Chrome.beta": "Google/Chrome Beta",
        "com.google.Chrome.dev": "Google/Chrome Dev",
        "com.google.Chrome.canary": "Google/Chrome Canary",
        "org.chromium.Chromium": "Chromium",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.brave.Browser": "BraveSoftware/Brave-Browser",
        "company.thebrowser.Browser": "Arc/User Data",
        "com.vivaldi.Vivaldi": "Vivaldi",
    ]

    static var supportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DeadNoise", isDirectory: true)
    }
    static var socketURL: URL { supportDir.appendingPathComponent("browser.sock") }
    /// Cópia da extensão fora do app, para "Carregar sem compactação" no navegador.
    static var extensionDir: URL { supportDir.appendingPathComponent("Browser Extension", isDirectory: true) }

    private var server: LocalSocketServer?

    init() {
        installHostManifests()
        copyExtension()
        do {
            server = try LocalSocketServer(path: Self.socketURL.path) { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
        } catch {
            NSLog("DeadNoise: socket do navegador indisponível: \(error)")
        }
    }

    // MARK: API para a UI

    func tabs(forApp bundleID: String) -> [Tab] {
        browsers.filter { $0.bundleID == bundleID }.flatMap(\.tabs)
    }

    /// Navegadores conectados que não aparecem como app na lista (raro: o app some quando para de tocar).
    func orphanBrowsers(appIDs: Set<String>) -> [Browser] {
        browsers.filter { !$0.tabs.isEmpty && !appIDs.contains($0.bundleID ?? "") }
    }

    func isConnected(_ bundleID: String) -> Bool { browsers.contains { $0.bundleID == bundleID } }
    static func isChromium(_ bundleID: String) -> Bool { chromiumBrowsers[bundleID] != nil }

    func setGain(_ value: Float, for tab: Tab) {
        var g = min(max((value * 100).rounded() / 100, 0), 1)
        if g > 0.97 { g = 1 }
        update(tab) { Tab(connection: $0.connection, tabID: $0.tabID, title: $0.title, host: $0.host,
                          favicon: $0.favicon, audible: $0.audible, muted: $0.muted, gain: g) }
        send(["type": "gain", "tabId": tab.tabID, "gain": g], to: tab.connection)
    }

    func toggleMute(_ tab: Tab) {
        let muted = !tab.muted
        update(tab) { Tab(connection: $0.connection, tabID: $0.tabID, title: $0.title, host: $0.host,
                          favicon: $0.favicon, audible: $0.audible, muted: muted, gain: $0.gain) }
        send(["type": "mute", "tabId": tab.tabID, "muted": muted], to: tab.connection)
    }

    func focus(_ tab: Tab) {
        send(["type": "focus", "tabId": tab.tabID], to: tab.connection)
    }

    /// Prepara a instalação da extensão: mostra a pasta no Finder e abre a página de extensões.
    func openExtensionInstall(browser bundleID: String) {
        copyExtension()
        NSWorkspace.shared.activateFileViewerSelecting([Self.extensionDir])
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let page = bundleID == "com.microsoft.edgemac" ? "edge://extensions" : "chrome://extensions"
        guard let url = URL(string: page) else { return }
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config)
    }

    // MARK: Mensagens da extensão

    private func handle(_ event: LocalSocketServer.Event) {
        switch event {
        case .opened(let conn, let peerPID):
            let app = peerPID.flatMap(Self.ownerApp(of:))
            browsers.append(Browser(id: conn, name: app?.localizedName ?? String(localized: "Navegador"),
                                    bundleID: app?.bundleIdentifier, tabs: []))
        case .closed(let conn):
            browsers.removeAll { $0.id == conn }
        case .message(let conn, let data):
            guard let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let index = browsers.firstIndex(where: { $0.id == conn }) else { return }
            switch msg["type"] as? String {
            case "hello":
                if browsers[index].bundleID == nil, let name = msg["browser"] as? String { browsers[index].name = name }
            case "tabs":
                let list = (msg["tabs"] as? [[String: Any]] ?? []).compactMap { Self.parseTab($0, connection: conn) }
                if list != browsers[index].tabs { browsers[index].tabs = list }
            default:
                break
            }
        }
    }

    private static func parseTab(_ d: [String: Any], connection: Int) -> Tab? {
        guard let id = (d["id"] as? NSNumber)?.intValue else { return nil }
        var icon: NSImage?
        if let s = d["favicon"] as? String, let comma = s.firstIndex(of: ","),
           let data = Data(base64Encoded: String(s[s.index(after: comma)...])) {
            icon = NSImage(data: data)
        }
        return Tab(connection: connection, tabID: id,
                   title: d["title"] as? String ?? "",
                   host: d["host"] as? String ?? "",
                   favicon: icon,
                   audible: d["audible"] as? Bool ?? false,
                   muted: d["muted"] as? Bool ?? false,
                   gain: (d["gain"] as? NSNumber)?.floatValue ?? 1)
    }

    private func update(_ tab: Tab, _ change: (Tab) -> Tab) {
        guard let b = browsers.firstIndex(where: { $0.id == tab.connection }),
              let t = browsers[b].tabs.firstIndex(where: { $0.tabID == tab.tabID }) else { return }
        browsers[b].tabs[t] = change(browsers[b].tabs[t])
    }

    private func send(_ msg: [String: Any], to conn: Int) {
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        server?.send(data, to: conn)
    }

    /// O host (nc) é filho do navegador: sobe pelos pais até achar o app.
    private static func ownerApp(of pid: pid_t) -> NSRunningApplication? {
        var current: pid_t? = pid
        for _ in 0..<6 {
            guard let p = current else { break }
            if let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular { return app }
            current = CA.parentPID(of: p)
        }
        return nil
    }

    // MARK: Instalação

    /// Registra o host de native messaging em cada navegador Chromium instalado. Refeito a cada abertura
    /// porque o caminho do app pode mudar (ex.: movido para outra pasta).
    private func installHostManifests() {
        guard let host = Bundle.main.url(forResource: "browser-host", withExtension: "sh") else { return }
        let manifest: [String: Any] = [
            "name": Self.hostName,
            "description": "DeadNoise: volume por aba",
            "path": host.path,
            "type": "stdio",
            "allowed_origins": Self.extensionIDs.map { "chrome-extension://\($0)/" },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) else { return }
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        for folder in Set(Self.chromiumBrowsers.values) {
            let browserDir = support.appendingPathComponent(folder, isDirectory: true)
            guard FileManager.default.fileExists(atPath: browserDir.path) else { continue }
            let dir = browserDir.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
            let file = dir.appendingPathComponent("\(Self.hostName).json")
            if (try? Data(contentsOf: file)) == data { continue }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Mantém a cópia da extensão igual à que vem dentro do app (atualiza junto com o app).
    /// Troca só os arquivos que mudaram, sem apagar a pasta, para o navegador não perder a extensão.
    private func copyExtension() {
        guard let bundled = Bundle.main.url(forResource: "BrowserExtension", withExtension: nil) else { return }
        let fm = FileManager.default
        let dest = Self.extensionDir
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for name in (try? fm.contentsOfDirectory(atPath: bundled.path)) ?? [] {
            let source = bundled.appendingPathComponent(name)
            let target = dest.appendingPathComponent(name)
            if let a = try? Data(contentsOf: source), a == (try? Data(contentsOf: target)) { continue }
            try? fm.removeItem(at: target)
            try? fm.copyItem(at: source, to: target)
        }
    }
}

// MARK: Socket local

/// Servidor de socket Unix com o formato do native messaging: cada mensagem é um tamanho de 4 bytes
/// (ordem do Mac, little-endian) seguido de JSON em UTF-8.
final class LocalSocketServer: @unchecked Sendable {
    enum Event {
        case opened(Int, peerPID: pid_t?)
        case message(Int, Data)
        case closed(Int)
    }

    private final class Connection {
        let fd: Int32
        let source: DispatchSourceRead
        var buffer = Data()
        init(fd: Int32, source: DispatchSourceRead) { self.fd = fd; self.source = source }
    }

    private let queue = DispatchQueue(label: "deadnoise.browser.socket")
    private let listenFD: Int32
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int: Connection] = [:]
    private var nextID = 1
    private let onEvent: (Event) -> Void

    init(path: String, onEvent: @escaping (Event) -> Void) throws {
        self.onEvent = onEvent
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        unlink(path)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(listenFD)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, len) }
        }
        guard bound == 0, listen(listenFD, 8) == 0 else {
            let err = errno
            close(listenFD)
            throw POSIXError(.init(rawValue: err) ?? .EIO)
        }
        chmod(path, 0o600)
        _ = fcntl(listenFD, F_SETFL, O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll() }
        source.resume()
        acceptSource = source
    }

    func send(_ json: Data, to id: Int) {
        queue.async { [self] in
            guard let conn = connections[id] else { return }
            var length = UInt32(json.count).littleEndian
            var frame = Data(bytes: &length, count: 4)
            frame.append(json)
            let ok = frame.withUnsafeBytes { raw -> Bool in
                var offset = 0
                while offset < raw.count {
                    let n = write(conn.fd, raw.baseAddress! + offset, raw.count - offset)
                    if n > 0 { offset += n } else if n < 0 && errno == EINTR { continue } else { return false }
                }
                return true
            }
            if !ok { drop(id) }
        }
    }

    private func acceptAll() {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK) // escrita bloqueante (mensagens pequenas)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

            var pid: pid_t = 0
            var size = socklen_t(MemoryLayout<pid_t>.size)
            let peer: pid_t? = getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 && pid > 0 ? pid : nil

            let id = nextID
            nextID += 1
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            let conn = Connection(fd: fd, source: source)
            source.setEventHandler { [weak self] in self?.read(id) }
            source.setCancelHandler { close(fd) }
            connections[id] = conn
            onEvent(.opened(id, peerPID: peer))
            source.resume()
        }
    }

    private func read(_ id: Int) {
        guard let conn = connections[id] else { return }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let n = Darwin.read(conn.fd, &chunk, chunk.count)
        guard n > 0 else {
            if n < 0 && (errno == EAGAIN || errno == EINTR) { return }
            return drop(id)
        }
        conn.buffer.append(contentsOf: chunk[0..<n])
        while conn.buffer.count >= 4 {
            let length = conn.buffer.prefix(4).withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
            guard length <= 8 * 1024 * 1024 else { return drop(id) } // lixo: fecha a conexão
            guard conn.buffer.count >= 4 + length else { break }
            let body = conn.buffer.subdata(in: conn.buffer.startIndex + 4 ..< conn.buffer.startIndex + 4 + length)
            conn.buffer.removeFirst(4 + length)
            onEvent(.message(id, body))
        }
    }

    private func drop(_ id: Int) {
        guard let conn = connections.removeValue(forKey: id) else { return }
        conn.source.cancel()
        onEvent(.closed(id))
    }

    deinit {
        acceptSource?.cancel()
        close(listenFD)
        for (_, c) in connections { c.source.cancel() }
    }
}
