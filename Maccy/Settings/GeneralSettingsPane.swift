import SwiftUI
import Defaults
import KeyboardShortcuts
import LaunchAtLogin
import Settings
import Foundation

struct GeneralSettingsPane: View {
  private let notificationsURL = URL(
    string: "x-apple.systempreferences:com.apple.preference.notifications?id=\(Bundle.main.bundleIdentifier ?? "")"
  )

  @Default(.searchMode) private var searchMode
  @Default(.transformations) private var transformations
  @Default(.activeTransformationID) private var activeTransformationID
  @Default(.applyTransformationByDefault) private var applyTransformationByDefault

  @State private var copyModifier = ""
  @State private var pasteModifier = ""
  @State private var pasteWithoutFormatting = ""
  @State private var pasteWithTransformation = ""

  @State private var updater = SoftwareUpdater()

  var body: some View {
    Settings.Container(contentWidth: 450) {
      Settings.Section(title: "", bottomDivider: true) {
        LaunchAtLogin.Toggle {
          Text("LaunchAtLogin", tableName: "GeneralSettings")
        }
        Toggle(isOn: $updater.automaticallyChecksForUpdates) {
          Text("CheckForUpdates", tableName: "GeneralSettings")
        }
        Button(
          action: { updater.checkForUpdates() },
          label: { Text("CheckNow", tableName: "GeneralSettings") }
        )
      }

      Settings.Section(label: { Text("Open", tableName: "GeneralSettings") }) {
        KeyboardShortcuts.Recorder(for: .popup, onChange: { newShortcut in
          if newShortcut == nil {
            AppState.shared.popup.deinitEventsMonitor()
          } else {
            AppState.shared.popup.initEventsMonitor()
          }
        })
          .help(Text("OpenTooltip", tableName: "GeneralSettings"))
      }

      Settings.Section(label: { Text("Pin", tableName: "GeneralSettings") }) {
        KeyboardShortcuts.Recorder(for: .pin)
          .help(Text("PinTooltip", tableName: "GeneralSettings"))
      }
      Settings.Section(label: { Text("Delete", tableName: "GeneralSettings") }
      ) {
        KeyboardShortcuts.Recorder(for: .delete)
          .help(Text("DeleteTooltip", tableName: "GeneralSettings"))
      }
      Settings.Section(
        bottomDivider: true,
        label: { Text("ShowPreview", tableName: "GeneralSettings") }
      ) {
        KeyboardShortcuts.Recorder(for: .togglePreview)
          .help(Text("ShowPreviewTooltip", tableName: "GeneralSettings"))
      }

      Settings.Section(
        label: { Text("Search", tableName: "GeneralSettings") }
      ) {
        Picker("", selection: $searchMode) {
          ForEach(Search.Mode.allCases) { mode in
            Text(mode.description)
          }
        }
        .labelsHidden()
        .frame(width: 180, alignment: .leading)
      }

      Settings.Section(
        bottomDivider: true,
        label: { Text("Transformation", tableName: "GeneralSettings") }
      ) {
        Picker("", selection: $activeTransformationID) {
          Text("None", tableName: "GeneralSettings").tag(UUID?.none)
          ForEach(transformations) { transformation in
            Text(transformation.name).tag(UUID?.some(transformation.id))
          }
        }
        .onChange(of: activeTransformationID) { refreshModifiers() }
        .labelsHidden()
        .frame(width: 180, alignment: .leading)
      }

      Settings.Section(
        bottomDivider: true,
        label: { Text("Behavior", tableName: "GeneralSettings") }
      ) {
        Defaults.Toggle(key: .pasteByDefault) {
          Text("PasteAutomatically", tableName: "GeneralSettings")
        }
        .onChange(of: Defaults[.pasteByDefault]) { refreshModifiers() }
        .fixedSize()

        Defaults.Toggle(key: .removeFormattingByDefault) {
          Text("PasteWithoutFormatting", tableName: "GeneralSettings")
        }
        .onChange(of: Defaults[.removeFormattingByDefault]) { refreshModifiers() }
        .fixedSize()

        Defaults.Toggle(key: .applyTransformationByDefault) {
          Text("PasteWithTransformation", tableName: "GeneralSettings")
        }
        .onChange(of: applyTransformationByDefault) { refreshModifiers() }

        Text(String(
          format: NSLocalizedString("Modifiers", tableName: "GeneralSettings", comment: ""),
          copyModifier, pasteModifier, pasteWithoutFormatting, pasteWithTransformation
        ))
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.gray)
        .controlSize(.small)
      }

      Settings.Section(title: "") {
        if let notificationsURL = notificationsURL {
          Link(destination: notificationsURL, label: {
            Text("NotificationsAndSounds", tableName: "GeneralSettings")
          })
        }
      }
    }
    .onAppear(perform: refreshModifiers)
  }

  private func refreshModifiers() {
    copyModifier = modifierDescription(HistoryItemAction.copy)
    pasteModifier = modifierDescription(HistoryItemAction.paste)
    pasteWithoutFormatting = modifierDescription(HistoryItemAction.pasteWithoutFormatting)
    pasteWithTransformation = modifierDescription(HistoryItemAction.pasteWithTransformation)
    
    Clipboard.shared.reapplyCurrentTransformation()
  }

  private func modifierDescription(_ action: HistoryItemAction) -> String {
    let description = action.modifierFlags.description
    if description.isEmpty {
      return "⏎"
    } else {
      return description
    }
  }
}

#Preview {
  GeneralSettingsPane()
    .environment(\.locale, .init(identifier: "en"))
}
