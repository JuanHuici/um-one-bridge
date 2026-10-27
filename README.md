# UM-ONE Bridge

Driver en espacio de usuario para Roland UM-ONE **originales** (USB 0582:012A) en macOS 15+.
App de barra de menú sin dependencias: IOUSBHost + CoreMIDI (UMP, protocolo MIDI 1.0).

## Instalación

1. Descargá el `.dmg` de la última versión en Releases.
2. Arrastrá **UM-ONE Bridge** a Aplicaciones y abrila: aparece un ícono de teclado en la barra de menú.
3. Conectá tus UM-ONE: aparecen como "UM-ONE 1", "UM-ONE 2"… en Configuración de Audio MIDI y en tu DAW.

## Estructura

- `UMONEBridge.xcodeproj`: app "UM-ONE Bridge" (LSUIElement, sin sandbox).
- `UMONEBridge/`: UI (MenuBarExtra), modelo, login item (SMAppService).
- `Packages/UMOneCore/`: todo lo demás, sin UI.
  - `USBMIDICodec.swift`: USB-MIDI ↔ UMP (tablas de CIN, SysEx, System Common, Real-Time).
  - `UMOneConnection.swift`: interfaz 0, lecturas bulk 0x81 asíncronas continuas, cola de escritura 0x02.
  - `DeviceManager.swift`: notificaciones IOKit (llegada/salida), SET_CONFIGURATION 1 con reintentos.
  - `MIDIPort.swift`: fuente + destino virtual "UM-ONE n", IDs estables, offline al desconectar.
  - `BridgeService.swift`: une todo; slot por locationID persistido en UserDefaults.
  - `umone-diag`: herramienta de diagnóstico.

## Compilar

La configuración Release firma con el Developer ID del autor. Para compilar sin ese certificado,
firmá en forma local:

```bash
xcodebuild -project UMONEBridge.xcodeproj -scheme UMONEBridge -configuration Release -derivedDataPath build/DerivedData \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM= build
cp -R "build/DerivedData/Build/Products/Release/UM-ONE Bridge.app" /Applications/
```

Para "Iniciar al abrir sesión", conviene que la app esté en /Applications.

## Publicar una versión

`scripts/release.sh` compila, verifica la firma Developer ID y el Hardened Runtime, arma
`dist/UM-ONE-Bridge-<versión>.dmg`, lo firma, lo notariza y le engrapa el ticket. Una sola vez antes:

```bash
xcrun notarytool store-credentials umone-notary --apple-id <apple-id> --team-id U3T5TG2HFV
```

La primera vez, macOS pide permiso para que `codesign` use la clave del llavero: elegí "Permitir siempre".
`scripts/release.sh --skip-notarize` genera el DMG firmado sin notarizar, para pruebas.

## Diagnóstico

```bash
cd Packages/UMOneCore && swift build && swift test
.build/debug/umone-diag --descriptors        # abre, muestra descriptores, configura, abre pipes, cierra
.build/debug/umone-diag --dump               # paquetes USB-MIDI crudos (cerrar antes la app)
.build/debug/umone-diag --send-note          # Do central por canal 1 en cada UM-ONE
.build/debug/umone-diag --reset --location 0x10321000   # re-enumera: simula desconectar/conectar
.build/debug/umone-diag --headless --verbose # el bridge completo sin UI
```

Modo verbose (menú o `--verbose`): los paquetes crudos van a os_log, categoría `raw`:

```bash
/usr/bin/log stream --level info --predicate 'subsystem == "com.juanhuici.umone-bridge"'
```

## Notas

- Los nombres siguen al **puerto USB** (`locationID`), no a la unidad: el UM-ONE no tiene número de serie.
- `--dump`, `--send-note` y `--headless` necesitan la interfaz en exclusiva: cerrá la app antes.

## Agradecimientos

[giulioz/um-one-macos](https://github.com/giulioz/um-one-macos) mostró que el UM-ONE original
funciona en macOS moderno desde espacio de usuario y documentó los endpoints que usa (interfaz 0,
bulk 0x02/0x81). UM-ONE Bridge es una implementación independiente y no contiene código de ese proyecto.

## Licencia

MIT, ver [LICENSE](LICENSE).

Roland y UM-ONE son marcas de Roland Corporation. Este proyecto es independiente: no está afiliado,
respaldado ni soportado por Roland. Se distribuye tal cual, sin garantía.
