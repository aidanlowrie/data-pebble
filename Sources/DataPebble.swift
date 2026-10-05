import AppKit
import SwiftUI
import ServiceManagement
import UserNotifications
import Darwin

struct Usage: Codable {
    var down: UInt64 = 0
    var up: UInt64 = 0
    var total: UInt64 { down + up }
    mutating func add(_ other: Usage) { down += other.down; up += other.up }
}
struct Day: Codable {
    var traffic = Usage()
    var apps: [String: Usage] = [:]
}
struct Ledger: Codable {
    var started = Date()
    var days: [String: Day] = [:]
}
func dayKey(_ date: Date) -> String {
    let f = DateFormatter(); f.calendar = .current; f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
}
func bytes(_ n: UInt64) -> String {
    if n < 1000 { return "\(n) B" }
    let units = ["kB", "MB", "GB", "TB"]
    var v = Double(n) / 1000; var i = 0
    while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
    return String(format: v < 10 ? "%.2f %@" : "%.1f %@", v, units[i])
}
// Read 64-bit kernel counters without starting a command-line process.
func interfaceUsage(_ interface: String) -> Usage? {
    var down: UInt64 = 0; var up: UInt64 = 0
    guard dp_interface_counters(interface, &down, &up) == 0 else { return nil }
    return Usage(down: down, up: up)
}
func delta(_ now: Usage, _ before: Usage) -> Usage {
    // An interface reset is a new baseline, never a huge negative/overflow count.
    Usage(down: now.down >= before.down ? now.down - before.down : 0,
          up: now.up >= before.up ? now.up - before.up : 0)
}
func appName(_ process: String) -> String {
    let name = process.replacingOccurrences(of: #"\.\d+$"#, with: "", options: .regularExpression)
    let low = name.lowercased()
    if low.contains("nsurlsession") || name == "Apple background transfers" { return "Apple transfers · earlier combined" }
    if low == "bird" || low.contains("cloudd") { return "iCloud services" }
    if low.contains("codex") || low == "node_repl" || low.hasPrefix("skycomputeruse") { return "Codex" }
    if low.contains("firefox") { return "Firefox" }
    if low.contains("chrome") { return "Google Chrome" }
    if low.contains("safari") || low.contains("webkit") { return "Safari / WebKit" }
    if low.contains("whatsapp") { return "WhatsApp" }
    if low.contains("dropbox") { return "Dropbox" }
    if low.contains("onedrive") { return "OneDrive" }
    if low == "dataaccessd" { return "Calendar & contacts sync" }
    if low.contains("gameoverlay") || low.contains("steam") { return "Steam" }
    if ["mdnsresponder", "apsd", "netbiosd", "networkservicep", "cloudtelemetrys", "syspolicyd", "trustd", "gamed"].contains(low) { return "macOS services" }
    return name
}

final class AppleTransferSources {
    private var cache: [Int32: (UInt64, String)] = [:]
    func name(for process: String) -> String {
        guard let pid = Int32(process.split(separator: ".").last ?? "") else { return "Apple transfers · unidentified" }
        var path = [CChar](repeating: 0, count: 4096)
        var uid: UInt32 = 0; var parent: Int32 = 0; var started: UInt64 = 0
        guard dp_process_identity(pid, &path, Int32(path.count), &uid, &parent, &started) == 0 else {
            return "Apple transfers · process \(pid)"
        }
        if let (previousStart, name) = cache[pid], previousStart == started { return name }
        var command = [CChar](repeating: 0, count: 8192)
        _ = dp_process_command(parent, &command, Int32(command.count))
        let name = Self.label(path: String(cString: path), uid: uid, parentCommand: String(cString: command), pid: pid)
        cache[pid] = (started, name)
        return name
    }
    static func label(path: String, uid: UInt32, parentCommand: String, pid: Int32) -> String {
        if path.contains("/CoreSimulator/") || parentCommand.contains("/Library/Developer/CoreSimulator/Devices/") {
            let prefix = "/Library/Developer/CoreSimulator/Devices/"
            if let argument = parentCommand.split(separator: "\n").first(where: { $0.contains(prefix) }),
               let range = argument.range(of: prefix), let device = argument[range.upperBound...].split(separator: "/").first,
               UUID(uuidString: String(device)) != nil {
                let root = String(argument[..<range.lowerBound])
                let plist = URL(fileURLWithPath: root + prefix + device + "/device.plist")
                if let data = try? Data(contentsOf: plist),
                   let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                   let name = dict["name"] as? String {
                    // The device UUID preserves attribution even if a simulator is renamed.
                    return "Apple transfers · \(name) simulator [\(device.prefix(4))]"
                }
                return "Apple transfers · simulator \(device.prefix(8))"
            }
            return "Apple transfers · simulator process \(pid)"
        }
        return uid == getuid() ? "Apple transfers · Mac" : "Apple transfers · macOS system"
    }
}

final class Meter: ObservableObject {
    @Published var ledger = Ledger()
    @Published var rate = Usage()
    @Published var activity = Usage()
    @Published var activityStart = Date()
    @Published var health = "Starting measurement…"
    @Published var appHealth = "Starting app breakdown…"
    @Published var period = 1
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var loginMessage: String?
    var changed: (() -> Void)?
    var backgroundTransferIncreased: ((String, Usage, Usage) -> Void)?
    private let transferSources = AppleTransferSources()
    var transferSourceName: ((String) -> String)?
    var testBackgroundAlert: (() -> Void)?
    @Published var alertHealth = "Alerts on · Mac background transfers only"
    let interface: String
    let location: URL
    private var baseline: Usage?
    private var lastSample: Date?
    private var timer: Timer?
    private let queue = DispatchQueue(label: "DataPebble.measurement", qos: .utility)
    private var process: Process?
    private var appReader: DispatchSourceRead?
    private var appGeneration = UUID()
    private var appRestart: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var sleeping = false
    private var panelVisible = false
    private var buffer = ""
    private var headerCount = 0
    private var lastSave = Date.distantPast
    private var stopping = false
    private var awaiting = false

    init(interface: String = "en0", storage: URL? = nil) {
        self.interface = interface
        let folder = storage ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DataPebble")
        location = folder.appendingPathComponent("usage.json")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: location) {
            if let saved = try? JSONDecoder().decode(Ledger.self, from: data) { ledger = saved }
            else {
                let backup = folder.appendingPathComponent("unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? data.write(to: backup)
                health = "Previous history could not be read; a backup was saved."
            }
        }
    }
    func start() {
        stopping = false
        // Show each existing source at zero until it records new traffic.
        var pids = [Int32](repeating: 0, count: 128)
        let count = dp_background_transfer_pids(&pids, 128)
        let key = dayKey(Date()); var day = ledger.days[key] ?? Day()
        for pid in pids.prefix(Int(count)) {
            let name = transferSources.name(for: "nsurlsessiond.\(pid)")
            if day.apps[name] == nil { day.apps[name] = Usage() }
        }
        ledger.days[key] = day
        sample(); startApps(); configureTimer()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.sleeping = true; self.timer?.invalidate(); self.stopApps(); self.save()
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.sleeping = false; self.baseline = nil; self.lastSample = nil
            self.sample(); self.startApps(); self.configureTimer()
        })
    }
    func configureTimer() {
        timer?.invalidate()
        guard !stopping, !sleeping else { return }
        // The closed menu needs only a cheap, coalescible background update.
        let interval: TimeInterval = panelVisible ? 2 : 15
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.sample() }
        timer?.tolerance = panelVisible ? 0.5 : 3
    }
    func setPanelVisible(_ visible: Bool) {
        panelVisible = visible; configureTimer()
        if visible { sample() }
    }
    func stop() {
        stopping = true; timer?.invalidate(); stopApps()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; observers.removeAll()
        save()
    }
    func sample() {
        guard !awaiting, !stopping, !sleeping else { return }; awaiting = true
        let interface = self.interface
        queue.async { [weak self] in
            let result = interfaceUsage(interface)
            DispatchQueue.main.async { self?.accept(result, at: Date()) }
        }
    }
    func accept(_ value: Usage?, at now: Date) {
        awaiting = false
        guard !stopping, !sleeping else { return }
        guard let value else { health = "Wi-Fi counters unavailable · retrying"; rate = Usage(); baseline = nil; changed?(); return }
        if let before = baseline, let time = lastSample {
            let use = delta(value, before); let seconds = max(1, now.timeIntervalSince(time))
            rate = Usage(down: UInt64(Double(use.down)/seconds), up: UInt64(Double(use.up)/seconds))
            // Split intervals crossing local midnight proportionally.
            let midnight = Calendar.current.startOfDay(for: now)
            if time < midnight && seconds < 60 {
                let fraction = min(1, max(0, midnight.timeIntervalSince(time)/seconds))
                let earlier = Usage(down: UInt64(Double(use.down)*fraction), up: UInt64(Double(use.up)*fraction))
                addTraffic(earlier, on: time)
                addTraffic(Usage(down: use.down-earlier.down, up: use.up-earlier.up), on: now)
            } else { addTraffic(use, on: now) }
            activity.add(use)
        }
        baseline = value; lastSample = now; health = "Measuring this Mac’s Wi-Fi"
        if now.timeIntervalSince(lastSave) >= 60 { save() }
        changed?()
    }
    func addTraffic(_ usage: Usage, on date: Date) {
        let key = dayKey(date); var day = ledger.days[key] ?? Day(); day.traffic.add(usage); ledger.days[key] = day
    }
    func stopApps() {
        appRestart?.cancel(); appRestart = nil
        appGeneration = UUID()
        appReader?.cancel(); appReader = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
    }
    func startApps() {
        guard !stopping, !sleeping, process == nil else { return }
        buffer = ""; headerCount = 0
        let generation = UUID(); appGeneration = generation
        let p = Process()
        // Keep stdin open: nettop spins on EOF when launched by a GUI app.
        // A terminal also flushes each sample, avoiding repeated process launches.
        var master: Int32 = -1; var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            appHealth = "App breakdown unavailable; Wi-Fi totals still work"; scheduleAppRetry(); return
        }
        var attributes = termios()
        if tcgetattr(slave, &attributes) == 0 { cfmakeraw(&attributes); tcsetattr(slave, TCSANOW, &attributes) }
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        let output = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        p.arguments = ["-n", "-c", "-d", "-P", "-L", "0", "-s", "30", "-J", "bytes_in,bytes_out", "-t", "wifi"]
        p.qualityOfService = .utility
        p.standardInput = output; p.standardOutput = output; p.standardError = FileHandle.nullDevice
        let descriptor = master
        let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        reader.setCancelHandler { Darwin.close(descriptor) }
        reader.setEventHandler { [weak self, weak reader] in
            var bytes = [UInt8](repeating: 0, count: 16384)
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 {
                let chunk = String(decoding: bytes.prefix(count), as: UTF8.self)
                DispatchQueue.main.async {
                    guard let self, self.appGeneration == generation else { return }
                    self.consume(chunk)
                }
            } else if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
                reader?.cancel()
            }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.appGeneration == generation else { return }
                self.appReader?.cancel(); self.appReader = nil; self.process = nil
                guard !self.stopping, !self.sleeping else { return }
                self.appHealth = "App breakdown interrupted · retrying"; self.scheduleAppRetry()
            }
        }
        do {
            try p.run(); try? output.close(); process = p; appReader = reader; reader.resume()
        } catch {
            try? output.close(); reader.cancel(); reader.resume()
            appHealth = "App breakdown unavailable; Wi-Fi totals still work"; scheduleAppRetry()
        }
    }
    func scheduleAppRetry() {
        appRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.startApps() }
        appRestart = work; DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }
    func consume(_ chunk: String) {
        buffer += chunk
        let key = dayKey(Date())
        var day = ledger.days[key] ?? Day()
        var updated = false
        var backgroundIncreases: [String: Usage] = [:]
        while let end = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<end]); buffer.removeSubrange(...end)
            if line.hasPrefix(",bytes_in,bytes_out") { headerCount += 1; continue }
            // First sample is cumulative history from before launch: deliberately discard it.
            guard headerCount >= 2 else { continue }
            let c = line.split(separator: ",", omittingEmptySubsequences: false)
            guard c.count >= 3, let d = UInt64(c[1]), let u = UInt64(c[2]) else { continue }
            appHealth = "Accumulated usage · updates every 30 seconds"
            guard d+u > 0 else { continue }
            let rawProcess = String(c[0])
            let isBackground = rawProcess.lowercased().hasPrefix("nsurlsessiond.")
            let name = isBackground ? (transferSourceName?(rawProcess) ?? transferSources.name(for: rawProcess)) : appName(rawProcess)
            var usage = day.apps[name] ?? Usage()
            usage.add(Usage(down: d, up: u)); day.apps[name] = usage; updated = true
            if isBackground { var increase = backgroundIncreases[name] ?? Usage(); increase.add(Usage(down: d, up: u)); backgroundIncreases[name] = increase }
        }
        // Publish once per chunk rather than re-rendering the panel for every app.
        if updated { ledger.days[key] = day }
        for (source, increase) in backgroundIncreases {
            backgroundTransferIncreased?(source, increase, day.apps[source] ?? Usage())
        }
    }
    var today: Usage { ledger.days[dayKey(Date())]?.traffic ?? Usage() }
    var days: [(String, Day)] {
        let cal = Calendar.current
        return (0..<period).reversed().map { offset in
            let key = dayKey(cal.date(byAdding: .day, value: -offset, to: Date())!)
            return (key, ledger.days[key] ?? Day())
        }
    }
    var total: Usage { days.reduce(Usage()) { var x=$0; x.add($1.1.traffic); return x } }
    var lifetime: Usage { ledger.days.values.reduce(Usage()) { var x=$0; x.add($1.traffic); return x } }
    var apps: [(String, Usage)] {
        var result: [String: Usage] = [:]
        for (_, day) in days { for (name, usage) in day.apps { let display = appName(name); var x=result[display] ?? Usage(); x.add(usage); result[display]=x } }
        return result.sorted { $0.value.total > $1.value.total }.map { ($0.key, $0.value) }
    }
    func resetActivity() { activity = Usage(); activityStart = Date() }
    func save() {
        do { try JSONEncoder().encode(ledger).write(to: location, options: .atomic); lastSave = Date() }
        catch { health = "Could not save history: \(error.localizedDescription)" }
    }
    func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval { loginMessage = "Allow Data Pebble in System Settings → General → Login Items." }
        } catch { loginMessage = error.localizedDescription }
    }
    func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "data-pebble-history.csv"; panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var text = "date,scope,download_bytes,upload_bytes\n"
        for (key, day) in ledger.days.sorted(by: {$0.key < $1.key}) {
            text += "\(key),Wi-Fi total,\(day.traffic.down),\(day.traffic.up)\n"
            for (name,u) in day.apps.sorted(by: {$0.key < $1.key}) { text += "\(key),\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\",\(u.down),\(u.up)\n" }
        }
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { loginMessage = "Export failed: \(error.localizedDescription)" }
    }
}

let blue = Color(red: 0.15, green: 0.39, blue: 0.89)
let orange = Color(red: 0.82, green: 0.42, blue: 0.09)
struct Panel: View {
    @ObservedObject var meter: Meter
    @State private var info = false
    var body: some View {
        let appUsages = meter.apps
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "circle.lefthalf.filled").foregroundStyle(blue).font(.title2)
                Text("Data Pebble").font(.system(size: 17, weight: .semibold, design: .rounded))
                Spacer()
                Button { info.toggle() } label: { Image(systemName: "info.circle").font(.system(size: 16)) }.buttonStyle(.plain).help("What is measured")
                Menu {
                    Button(meter.loginEnabled ? "✓ Open at login" : "Open at login") { meter.toggleLogin() }
                    Button("Export history…") { meter.export() }
                    Button("Test background transfer alert") { meter.testBackgroundAlert?() }
                    Divider()
                    Button("Quit Data Pebble") { NSApplication.shared.terminate(nil) }
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 16)) }.menuStyle(.borderlessButton).fixedSize()
            }
            Picker("Time period", selection: $meter.period) {
                Text("Today").tag(1); Text("7 days").tag(7); Text("30 days").tag(30)
            }.pickerStyle(.segmented).labelsHidden()
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(bytes(meter.total.total)).font(.system(size: 36, weight: .medium, design: .rounded)).monospacedDigit()
                    Spacer()
                    Text(meter.period == 1 ? "TODAY" : "LAST \(meter.period) DAYS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
                splitBar(meter.total, height: 7)
                HStack {
                    Label(bytes(meter.total.down), systemImage: "arrow.down").foregroundStyle(blue)
                    Spacer()
                    Label(bytes(meter.total.up), systemImage: "arrow.up").foregroundStyle(orange)
                }.font(.system(size: 13, weight: .medium)).monospacedDigit()
            }
            if meter.period > 1 { history }
            HStack(spacing: 7) {
                Circle().fill(meter.health.hasPrefix("Measuring") ? Color.green : Color.orange).frame(width: 6, height: 6)
                Text("Now").foregroundStyle(.secondary)
                Text("↓ \(bytes(meter.rate.down))/s").foregroundStyle(blue)
                Text("↑ \(bytes(meter.rate.up))/s").foregroundStyle(orange)
                Spacer()
            }.font(.system(size: 11)).monospacedDigit().help(meter.health)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Since reset").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(bytes(meter.activity.total)).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
                    Button("Reset") { meter.resetActivity() }.buttonStyle(.borderless).font(.system(size: 11)).help("Start a new activity measurement; daily history is kept")
                }
                Text("Reset, try something, then see how much data it used.").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("All app activity since \(meter.activityStart.formatted(date: .omitted, time: .shortened)) · ↓ \(bytes(meter.activity.down))  ↑ \(bytes(meter.activity.up))")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(12).background(blue.opacity(0.065), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text("By app").font(.system(size: 13, weight: .semibold)); Spacer(); Text("ESTIMATES").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary) }
                if appUsages.isEmpty {
                    Text("App usage will appear as data is transferred.").font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(appUsages, id: \.0) { name, usage in
                                VStack(spacing: 4) {
                                    HStack { Text(name).lineLimit(1); Spacer(); Text(bytes(usage.total)).monospacedDigit() }.font(.system(size: 12))
                                    GeometryReader { g in
                                        let maxValue = max(1, appUsages.first?.1.total ?? 1)
                                        splitBar(usage, height: 4).frame(width: max(3, g.size.width * Double(usage.total)/Double(maxValue)))
                                    }.frame(height: 4)
                                }.help("\(name) · Downloaded \(bytes(usage.down)) · Uploaded \(bytes(usage.up))")
                            }
                        }.padding(.vertical, 2).padding(.trailing, 4)
                    }.frame(height: min(meter.period == 1 ? 170 : 100, CGFloat(appUsages.count)*40))
                }
                Text(meter.appHealth).font(.system(size: 10)).foregroundStyle(.secondary)
                Text(meter.alertHealth).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("This Mac · Wi-Fi across all networks").font(.system(size: 11, weight: .medium))
                Text("Tracking since \(meter.ledger.started.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 10)).foregroundStyle(.secondary)
                Text("\(bytes(meter.lifetime.total)) recorded in total · decimal MB / GB").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if !meter.health.hasPrefix("Measuring") { Text(meter.health).font(.caption).foregroundStyle(orange) }
            if let message = meter.loginMessage { Text(message).font(.caption).foregroundStyle(orange) }
        }
        .padding(22).frame(width: 376, height: 690, alignment: .topLeading).background(Color(nsColor: .windowBackgroundColor))
        .popover(isPresented: $info) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Know what counts").font(.headline)
                Text("Totals measure bytes sent and received by this Mac’s Wi-Fi while Data Pebble is running. Downloads and uploads both count. Local-network traffic is included; Ethernet, other devices and earlier usage are not.")
                Text("Your mobile provider’s bill may differ. App figures are estimates and may not add up to the Wi-Fi total: short-lived connections, network overhead and shared Apple services affect attribution.")
                Text("Apple transfers are split into your Mac, macOS system, and named iPhone simulators. These identify the transfer service, not necessarily the app requesting a transfer. Earlier combined history cannot be separated retroactively.")
                Text("Since reset measures all traffic during the activity, including background apps. It cannot prove which action caused it.")
                Text("Viewing a downloaded photo, video or document can use no internet data. Streaming, syncing and uploading do use data.")
                Text("History stays on this Mac. No analytics, cloud service or speed tests. Keep the app open to record usage; use Open at login in the menu for future sessions.")
            }.font(.system(size: 12)).padding(20).frame(width: 330)
        }
    }
    func splitBar(_ use: Usage, height: CGFloat) -> some View {
        GeometryReader { g in
            HStack(spacing: 0) {
                blue.frame(width: use.total > 0 ? g.size.width*Double(use.down)/Double(use.total) : 0)
                orange
            }.opacity(use.total == 0 ? 0 : 1)
        }.frame(height: height).background(Color.secondary.opacity(0.12)).clipShape(Capsule())
    }
    var history: some View {
        VStack(spacing: 5) {
            HStack(alignment: .bottom, spacing: meter.period == 7 ? 9 : 3) {
                ForEach(meter.days, id: \.0) { key, day in
                    let largest = max(1, meter.days.map { $0.1.traffic.total }.max() ?? 1)
                    let height = max(2, 48*Double(day.traffic.total)/Double(largest))
                    VStack(spacing: 0) {
                        orange.frame(height: day.traffic.total > 0 ? height*Double(day.traffic.up)/Double(day.traffic.total) : 0)
                        blue.frame(height: day.traffic.total > 0 ? height*Double(day.traffic.down)/Double(day.traffic.total) : 2)
                    }.opacity(day.traffic.total == 0 ? 0.12 : 1).clipShape(RoundedRectangle(cornerRadius: 3))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .help("\(key): ↓ \(bytes(day.traffic.down)) · ↑ \(bytes(day.traffic.up))")
                }
            }.frame(height: 48)
            HStack { Text(String(meter.days.first?.0.suffix(5) ?? "")); Spacer(); Text("Today") }.font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, UNUserNotificationCenterDelegate {
    var status: NSStatusItem!
    var popover = NSPopover()
    var meter: Meter!
    private var terminationSignal: DispatchSourceSignal?
    private var notificationsAllowed = false
    static let alertThreshold: UInt64 = 1_000_000
    private var pendingAlerts: [String: Usage] = [:]
    private var alertTotals: [String: Usage] = [:]
    private var alertWork: DispatchWorkItem?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Only one recorder may own the history at once.
        let duplicates = NSRunningApplication.runningApplications(withBundleIdentifier: "local.aidan.DataPebble")
        if duplicates.count > 1 { NSApp.terminate(nil); return }
        meter = Meter()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] allowed, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.notificationsAllowed = allowed
                self.meter.alertHealth = allowed ? "Alerts on · Mac background transfers only" : "Enable Data Pebble notifications in System Settings"
                if let error { NSLog("Data Pebble notification authorization: %@", error.localizedDescription) }
                if allowed, CommandLine.arguments.contains("--test-background-alert") { self.showBackgroundAlert(Usage(down: 1_000_000), total: Usage(down: 1_000_000), source: "Apple transfers · Mac", test: true) }
            }
        }
        meter.backgroundTransferIncreased = { [weak self] source, increase, total in
            guard source == "Apple transfers · Mac" else { return }
            self?.queueBackgroundAlert(increase, total: total, source: source)
        }
        meter.testBackgroundAlert = { [weak self] in self?.showBackgroundAlert(Usage(down: 1_000_000), total: Usage(down: 1_000_000), source: "Apple transfers · Mac", test: true) }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.target = self; status.button?.action = #selector(toggle)
        status.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 376, height: 690)
        popover.delegate = self
        signal(SIGTERM, SIG_IGN)
        terminationSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminationSignal?.setEventHandler { NSApp.terminate(nil) }; terminationSignal?.resume()
        meter.changed = { [weak self] in self?.updateTitle() }
        meter.start(); updateTitle()
        if CommandLine.arguments.contains("--show") { DispatchQueue.main.asyncAfter(deadline: .now()+1) { self.toggle() } }
    }
    func updateTitle() {
        let title = "↕ \(bytes(meter.today.total))"
        if status.button?.title != title { status.button?.title = title }
        status.button?.toolTip = "Data Pebble · Today: ↓ \(bytes(meter.today.down)) / ↑ \(bytes(meter.today.up))"
    }
    func queueBackgroundAlert(_ increase: Usage, total: Usage, source: String) {
        // Coalesce fragmented output within each source, never across sources.
        var pending = pendingAlerts[source] ?? Usage(); pending.add(increase)
        pendingAlerts[source] = pending; alertTotals[source] = total
        alertWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Small increases keep accumulating until they reach the alert threshold.
            for (source, increase) in self.pendingAlerts where increase.total >= AppDelegate.alertThreshold {
                self.pendingAlerts[source] = nil
                self.showBackgroundAlert(increase, total: self.alertTotals[source] ?? Usage(), source: source)
            }
        }
        alertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
    func showBackgroundAlert(_ increase: Usage, total: Usage, source: String, test: Bool = false) {
        // Re-read permission so changes in System Settings take effect immediately.
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                self.notificationsAllowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
                guard self.notificationsAllowed else {
                    NSSound.beep()
                    self.meter.alertHealth = "Background transfers increased · enable notifications in System Settings"
                    return
                }
                self.meter.alertHealth = "Alerts on · Mac background transfers only"
                self.sendBackgroundAlert(increase, total: total, source: source, test: test)
            }
        }
    }
    private func sendBackgroundAlert(_ increase: Usage, total: Usage, source: String, test: Bool) {
        let content = UNMutableNotificationContent()
        content.title = test ? "Data Pebble test alert" : "Apple background transfers increased"
        content.subtitle = source
        content.body = test ? "Alerts are working. No transfer was made." : "+\(bytes(increase.total)) · ↓ \(bytes(increase.down)) · ↑ \(bytes(increase.up)). Today: \(bytes(total.total))."
        content.sound = .default
        // Replace the previous alert rather than filling Notification Center.
        let request = UNNotificationRequest(identifier: "apple-background-transfers." + source, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                NSLog("Data Pebble notification failed: %@", error.localizedDescription)
                DispatchQueue.main.async { self?.meter.alertHealth = "Background alert failed · check notification settings"; NSSound.beep() }
            }
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
    @objc func toggle() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = status.button {
            meter.setPanelVisible(true)
            popover.contentViewController = NSHostingController(rootView: Panel(meter: meter))
            NSApp.activate(ignoringOtherApps: true); popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
    func popoverDidClose(_ notification: Notification) {
        // No hidden SwiftUI view tree to recompute while recording in the menu bar.
        popover.contentViewController = nil; meter.setPanelVisible(false)
    }
    func applicationWillTerminate(_ notification: Notification) { meter?.stop() }
}

@main struct Entry {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            precondition(interfaceUsage("not_an_interface") == nil)
            precondition(delta(Usage(down: 110, up: 230), Usage(down: 100, up: 200)).total == 40)
            precondition(delta(Usage(down: 1, up: 3), Usage(down: 100, up: 200)).total == 0)
            precondition(appName("Codex (Service).123") == "Codex")
            precondition(appName("nsurlsessiond.622") == "Apple transfers · earlier combined")
            precondition(appName("Apple background transfers") == "Apple transfers · earlier combined")
            precondition(AppleTransferSources.label(path: "/usr/libexec/nsurlsessiond", uid: getuid(), parentCommand: "", pid: 622) == "Apple transfers · Mac")
            precondition(AppleTransferSources.label(path: "/usr/libexec/nsurlsessiond", uid: getuid() + 1, parentCommand: "", pid: 415) == "Apple transfers · macOS system")
            precondition(AppleTransferSources.label(path: "/Library/Developer/CoreSimulator/Runtime/nsurlsessiond", uid: getuid(), parentCommand: "", pid: 77) == "Apple transfers · simulator process 77")
            let testFolder = FileManager.default.temporaryDirectory.appendingPathComponent("DataPebble-tests-"+UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: testFolder) }
            let meter = Meter(interface: "test", storage: testFolder)
            var increases: [Usage] = []
            var alertSources: [String] = []
            meter.transferSourceName = { $0 == "nsurlsessiond.415" ? "Apple transfers · macOS system" : "Apple transfers · Mac" }
            meter.backgroundTransferIncreased = { source, increase, _ in alertSources.append(source); increases.append(increase) }
            meter.consume(",bytes_in,bytes_out,\nfirefox.1,99999,99999,\n,bytes_in,bytes_out,\nfirefox.1,20,30,\n")
            precondition(meter.apps.first(where: {$0.0 == "Firefox"})?.1.total == 50)
            meter.consume(",bytes_in,bytes_out,\nfirefox.1,7,")
            meter.consume("8,\ncloudd.2,3,4,\n")
            precondition(meter.apps.first(where: {$0.0 == "Firefox"})?.1.total == 65)
            precondition(meter.apps.first(where: {$0.0 == "iCloud services"})?.1.total == 7)
            let anchor = Calendar.current.startOfDay(for: Date()).addingTimeInterval(100)
            meter.accept(Usage(down: 100, up: 100), at: anchor)
            meter.accept(Usage(down: 200, up: 150), at: anchor.addingTimeInterval(15))
            precondition(meter.today.total == 150)
            meter.save()
            let restored = Meter(interface: "test", storage: testFolder)
            precondition(restored.today.total == 150 && restored.apps.count == 2)
            meter.consume(",bytes_in,bytes_out,\nnsurlsessiond.622,10,0,\nnsurlsessiond.415,0,5,\n")
            precondition(increases.count == 2 && increases.reduce(UInt64(0)) { $0 + $1.total } == 15)
            precondition(Set(alertSources) == Set(["Apple transfers · Mac", "Apple transfers · macOS system"]))
            precondition(meter.apps.first(where: {$0.0 == "Apple transfers · Mac"})?.1.total == 10)
            precondition(meter.apps.first(where: {$0.0 == "Apple transfers · macOS system"})?.1.total == 5)
            meter.consume(",bytes_in,bytes_out,\nnsurlsessiond.622,0,0,\nfirefox.1,200,100,\n")
            precondition(increases.count == 2)
            meter.save()
            let splitRestored = Meter(interface: "test", storage: testFolder)
            precondition(splitRestored.apps.first(where: {$0.0 == "Apple transfers · Mac"})?.1.total == 10)
            precondition(splitRestored.apps.first(where: {$0.0 == "Apple transfers · macOS system"})?.1.total == 5)
            let baselineMeter = Meter(interface: "test", storage: testFolder)
            baselineMeter.transferSourceName = meter.transferSourceName
            baselineMeter.backgroundTransferIncreased = { _, _, _ in preconditionFailure("Historical baseline must not trigger an alert") }
            baselineMeter.consume(",bytes_in,bytes_out,\nnsurlsessiond.622,999999,999999,\n")
            baselineMeter.backgroundTransferIncreased = { _, increase, _ in increases.append(increase) }
            baselineMeter.consume(",bytes_in,bytes_out,\nnsurlsessiond.622,0,")
            baselineMeter.consume("1,\n")
            precondition(increases.count == 3 && increases[2].total == 1)
            print("PASS: counters, baselines, fragmented samples, source separation, history, background alerts for downloads/uploads and quiet samples")
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--transfer-source"), CommandLine.arguments.count > index + 1 {
            print(AppleTransferSources().name(for: CommandLine.arguments[index + 1])); return
        }
        if CommandLine.arguments.contains("--read-counters") {
            if let value = interfaceUsage("en0"), let data = try? JSONEncoder().encode(value) { print(String(decoding: data, as: UTF8.self)) }
            else { exit(1) }
            return
        }
        if CommandLine.arguments.contains("--probe") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DataPebble-probe-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let meter = Meter(storage: folder)
            meter.start(); RunLoop.current.run(until: Date().addingTimeInterval(35)); meter.stop()
            print("Wi-Fi bytes: \(meter.today.total); app bytes: \(meter.apps.reduce(UInt64(0)) { $0 + $1.1.total }); \(meter.appHealth)")
            return
        }
        let app = NSApplication.shared; let delegate = AppDelegate(); app.delegate = delegate; app.run()
    }
}
