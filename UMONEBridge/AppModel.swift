import Foundation
import Observation
import os
import UMOneCore

@MainActor @Observable
final class AppModel {
    private(set) var ports: [BridgeService.PortStatus] = []
    private(set) var startupError: String?
    private(set) var launchAtLogin = LoginItem.isEnabled
    private(set) var loginItemNeedsApproval = LoginItem.needsApproval

    var verbose: Bool {
        didSet {
            service?.options.verbose.store(verbose, ordering: .relaxed)
            UserDefaults.standard.set(verbose, forKey: "Verbose")
        }
    }

    var anyConnected: Bool { ports.contains { $0.state == .connected } }

    private let service: BridgeService?
    private let log = Logger(subsystem: Log.subsystem, category: "app")

    init() {
        let verbose = UserDefaults.standard.bool(forKey: "Verbose")
        self.verbose = verbose
        var startupError: String?
        do {
            service = try BridgeService()
        } catch {
            service = nil
            startupError = String(describing: error)
        }
        self.startupError = startupError
        if let startupError {
            log.error("bridge failed to start: \(startupError, privacy: .public)")
        }
        if let service {
            service.options.verbose.store(verbose, ordering: .relaxed)
            service.onChange = { [weak self] in
                Task { @MainActor in self?.refresh() }
            }
            service.start()
        }
        // Counters are atomics read by polling; state changes also arrive through onChange.
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.refresh()
            }
        }
    }

    func refresh() {
        guard let service else { return }
        let now = service.snapshot()
        if now != ports { ports = now }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        LoginItem.set(enabled)
        launchAtLogin = LoginItem.isEnabled
        loginItemNeedsApproval = LoginItem.needsApproval
    }
}
