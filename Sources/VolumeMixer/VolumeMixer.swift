import AppKit
import SwiftUI
import ServiceManagement
import AudioBridge

struct MixerApp: Identifiable {
    let id: pid_t
    let name: String
    let icon: NSImage
    var percent: Double = 100
    var playing = false
    var status: String?
}

@MainActor final class MixerModel: ObservableObject {
    @Published var apps: [MixerApp] = []
    @Published var outputName = "System output"
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var loginError: String?
    private var routes: [pid_t: VMRoute] = [:]
    private var processes: [pid_t: [NSNumber]] = [:]
    private var timer: Timer?
    private var outputFingerprint = ""
    private var failures = Set<pid_t>()
    private var routeStarted: [pid_t: Date] = [:]

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resetAll() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resetAll() }
        }
    }

    func refresh() {
        let device = VMAudio.outputDevice()
        outputName = device["name"] as? String ?? "System output"
        let fingerprint = "\(device["id"] ?? 0)-\(device["rate"] ?? 0)"
        if fingerprint != outputFingerprint {
            for route in routes.values { route.stop() }
            routes.removeAll()
            failures.removeAll()
            outputFingerprint = fingerprint
        }
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != getpid()
        }
        let live = Set(running.map(\.processIdentifier))
        for pid in Array(routes.keys) where !live.contains(pid) {
            routes.removeValue(forKey: pid)?.stop()
            routeStarted.removeValue(forKey: pid)
        }
        failures.formIntersection(live)
        let previous = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        let audio = VMAudio.processes()
        processes = [:]
        var playing = Set<pid_t>()
        for entry in audio {
            guard let owner = entry["ownerPID"] as? NSNumber,
                  let object = entry["objectID"] as? NSNumber, live.contains(owner.int32Value) else { continue }
            processes[owner.int32Value, default: []].append(object)
            if entry["playing"] as? Bool == true { playing.insert(owner.int32Value) }
        }
        apps = running.map { app in
            var row = previous[app.processIdentifier] ?? MixerApp(
                id: app.processIdentifier, name: app.localizedName ?? "Application",
                icon: app.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!)
            row.playing = playing.contains(row.id)
            return row
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for app in apps where app.percent < 100 && !failures.contains(app.id) {
            reconcile(app.id)
        }
    }

    func setVolume(_ pid: pid_t, _ value: Double) {
        guard let index = apps.firstIndex(where: { $0.id == pid }) else { return }
        apps[index].percent = Double(VMClampGain(Float(value / 100))) * 100
        apps[index].status = nil
        failures.remove(pid)
        reconcile(pid)
    }

    private func reconcile(_ pid: pid_t) {
        guard let index = apps.firstIndex(where: { $0.id == pid }) else { return }
        let gain = Float(apps[index].percent / 100)
        // Unity is a true bypass: no tap, replay, changed output, or gain conversion.
        if gain >= 1 {
            routes.removeValue(forKey: pid)?.stop()
            routeStarted.removeValue(forKey: pid)
            apps[index].status = nil
            return
        }
        let ids = (processes[pid] ?? []).sorted { $0.uint32Value < $1.uint32Value }
        guard !ids.isEmpty else {
            routes.removeValue(forKey: pid)?.stop()
            apps[index].status = "Waiting for audio"
            return
        }
        if let route = routes[pid], route.processIDs == ids {
            if !route.healthy || (apps[index].playing && route.callbackCount == 0 &&
                Date().timeIntervalSince(routeStarted[pid] ?? Date()) > 4) {
                fail(pid, index: index, message: "Audio control unavailable. Original volume restored. Check audio capture permission, then retry.")
            } else {
                route.setGain(gain)
                apps[index].status = nil
            }
            return
        }
        routes.removeValue(forKey: pid)?.stop()
        do {
            routes[pid] = try VMRoute(processes: ids, gain: gain)
            routeStarted[pid] = Date()
            apps[index].status = nil
        } catch {
            fail(pid, index: index, message: error.localizedDescription)
        }
    }

    private func fail(_ pid: pid_t, index: Int, message: String) {
        routes.removeValue(forKey: pid)?.stop()
        routeStarted.removeValue(forKey: pid)
        failures.insert(pid)
        apps[index].percent = 100
        apps[index].status = message
    }

    func resetAll() {
        for route in routes.values { route.stop() }
        routes.removeAll()
        routeStarted.removeAll()
        failures.removeAll()
        for index in apps.indices { apps[index].percent = 100; apps[index].status = nil }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            loginError = SMAppService.mainApp.status == .requiresApproval ? "Allow Volume Mixer in System Settings → General → Login Items." : nil
        } catch { loginError = error.localizedDescription }
    }
}

struct MixerView: View {
    @ObservedObject var model: MixerModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Volume Mixer").font(.system(size: 18, weight: .semibold))
                    Label(model.outputName, systemImage: "speaker.wave.2")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Reset") { model.resetAll() }
                    .buttonStyle(.borderless).font(.caption)
                    .help("Return every app to its original volume")
            }.padding(18)
            Divider()
            if model.apps.isEmpty {
                Text("Open an app to adjust its volume.")
                    .foregroundStyle(.secondary).padding(30)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.apps) { app in
                            VStack(alignment: .leading, spacing: 7) {
                                HStack(spacing: 9) {
                                    Image(nsImage: app.icon).resizable().frame(width: 24, height: 24)
                                    Text(app.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    if app.playing {
                                        Image(systemName: "waveform").font(.caption2).foregroundStyle(.secondary)
                                            .accessibilityLabel("Playing audio")
                                    }
                                    Spacer(minLength: 4)
                                    Text("\(Int(app.percent.rounded()))%")
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .foregroundStyle(app.percent == 100 ? .secondary : .primary)
                                        .frame(width: 42, alignment: .trailing)
                                }
                                HStack(spacing: 10) {
                                    Button { model.setVolume(app.id, app.percent == 0 ? 100 : 0) } label: {
                                        Image(systemName: app.percent == 0 ? "speaker.slash.fill" : "speaker.wave.1.fill")
                                            .frame(width: 18)
                                    }.buttonStyle(.plain)
                                        .accessibilityLabel(app.percent == 0 ? "Restore \(app.name) to 100 percent" : "Mute \(app.name)")
                                    Slider(value: Binding(
                                        get: { model.apps.first(where: { $0.id == app.id })?.percent ?? 100 },
                                        set: { model.setVolume(app.id, $0) }), in: 0...100, step: 1)
                                        .accessibilityLabel("\(app.name) volume")
                                        .accessibilityValue("\(Int(app.percent)) percent")
                                }
                                if let status = app.status {
                                    Text(status).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }.padding(.horizontal, 18).padding(.vertical, 12)
                            if app.id != model.apps.last?.id { Divider().padding(.leading, 18) }
                        }
                    }
                }.frame(maxHeight: 430)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("100% = original volume · No boost")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
                        .toggleStyle(.checkbox).font(.caption)
                    Spacer()
                    Button("Quit") { model.resetAll(); NSApp.terminate(nil) }
                        .buttonStyle(.borderless).font(.caption)
                }
                if let error = model.loginError { Text(error).font(.caption2).foregroundStyle(.secondary) }
            }.padding(18)
        }.frame(width: 350)
    }
}

@main struct VolumeMixerApp: App {
    @StateObject private var model = MixerModel()
    var body: some Scene {
        MenuBarExtra("Volume Mixer", systemImage: "slider.horizontal.3") {
            MixerView(model: model)
        }.menuBarExtraStyle(.window)
    }
}
