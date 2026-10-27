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
            Text("No hay ningún UM-ONE conectado")
        }
        ForEach(model.ports) { port in
            Text("\(port.name) — \(port.state.label)")
            Text(String(format: "    USB 0x%08X · in %llu · out %llu", port.locationID, port.messagesIn, port.messagesOut))
            if case .error(let message) = port.state {
                Text("    \(message)")
            }
        }
        Divider()
        Toggle("Modo verbose (paquetes USB al log)", isOn: $model.verbose)
        Toggle("Iniciar al abrir sesión", isOn: Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }))
        if model.loginItemNeedsApproval {
            Button("Aprobar en Configuración del Sistema…") { LoginItem.openSettings() }
        }
        Button("Abrir Configuración de Audio MIDI") {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
        }
        Divider()
        Button("Salir") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

extension MIDIPort.State {
    var label: String {
        switch self {
        case .waiting: "desconectado"
        case .configuring: "configurando…"
        case .connected: "conectado"
        case .error: "error"
        }
    }
}
