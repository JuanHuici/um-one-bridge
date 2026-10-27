import AppKit
import SwiftUI
import UMOneCore

@main
struct UMONEBridgeApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.anyConnected ? "pianokeys" : "pianokeys.inverse")
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuContent: View {
    @Bindable var model: AppModel

    var body: some View {
        Text("UM-ONE Bridge")
        if let error = model.startupError {
            Text("Error: \(error)")
        }
        if model.ports.isEmpty {
            Text("No UM-ONE connected")
        }
        ForEach(model.ports) { port in
            Text("\(port.name) — \(port.state.label)")
            Text(String(format: "    USB 0x%08X · in %llu · out %llu", port.locationID, port.messagesIn, port.messagesOut))
            if case .error(let message) = port.state {
                Text("    \(message)")
            }
        }
        Divider()
        Toggle("Verbose Mode (Log Raw USB Packets)", isOn: $model.verbose)
        Toggle("Launch at Login", isOn: Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }))
        if model.loginItemNeedsApproval {
            Button("Approve in System Settings…") { LoginItem.openSettings() }
        }
        Button("Open Audio MIDI Setup") {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
        }
        Divider()
        Button("Quit UM-ONE Bridge") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

extension MIDIPort.State {
    var label: String {
        switch self {
        case .waiting: "disconnected"
        case .configuring: "configuring…"
        case .connected: "connected"
        case .error: "error"
        }
    }
}
