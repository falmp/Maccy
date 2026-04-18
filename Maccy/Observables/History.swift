// swiftlint:disable file_length
import AppKit.NSRunningApplication
import Defaults
import Foundation
import Logging
import Observation
import Sauce
import Settings
import SwiftData

@Observable
class History: ItemsContainer { // swiftlint:disable:this type_body_length
  static let shared = History()
  let logger = Logger(label: "org.p0deje.Maccy")

  var items: [HistoryItemDecorator] = []
  var pasteStack: PasteStack?

  var pinnedItems: [HistoryItemDecorator] { items.filter(\.isPinned) }
  var unpinnedItems: [HistoryItemDecorator] { items.filter(\.isUnpinned) }

  var searchQuery: String = "" {
    didSet {
      throttler.throttle { [self] in
        updateItems(search.search(string: searchQuery, within: all).map(\.object))

        if searchQuery.isEmpty {
          AppState.shared.navigator.select(item: unpinnedItems.first)
        } else {
          AppState.shared.navigator.highlightFirst()
        }

        AppState.shared.popup.needsResize = true
      }
    }
  }

  @ObservationIgnored
  var all: [HistoryItemDecorator] = []

  var firstVisibleItem: HistoryItemDecorator? {
    items.first
  }

  var lastVisibleItem: HistoryItemDecorator? {
    items.last
  }

  private let search = Search()
  private let sorter = Sorter()
  private let throttler = Throttler(minimumDelay: 0.2)

  @ObservationIgnored
  private var sessionLog: [Int: HistoryItem] = [:]

  init() {
    Task { @MainActor in
      try? await self.load()
    }
  }

  @MainActor
  func load() async throws {
    let fetchDescriptor = FetchDescriptor<HistoryItem>()
    let historyItems = (try? Storage.shared.context.fetch(fetchDescriptor)) ?? []
    all = sorter.sort(historyItems).map({ HistoryItemDecorator($0) })
    items = all
    
    updateShortcuts()
    
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  func insertIntoStorage(_ item: HistoryItem) throws {
    Storage.shared.context.insert(item)
    try Storage.shared.context.save()
  }

  @discardableResult
  @MainActor
  func add(_ item: HistoryItem) -> HistoryItemDecorator {
    if #available(macOS 15.0, *) {
      try? History.shared.insertIntoStorage(item)
    }

    var removedItemIndex: Int?
    if let existingHistoryItem = findSimilarItem(item) {
      if isModified(item) == nil {
        item.contents = existingHistoryItem.contents
      }
      item.firstCopiedAt = existingHistoryItem.firstCopiedAt
      item.numberOfCopies += existingHistoryItem.numberOfCopies
      item.pin = existingHistoryItem.pin
      item.title = existingHistoryItem.title
      
      Storage.shared.context.delete(existingHistoryItem)
      removedItemIndex = all.firstIndex(where: { $0.item == existingHistoryItem })
      if let index = removedItemIndex {
        all.remove(at: index)
      }
    }

    let itemDecorator = HistoryItemDecorator(item)
    
    let sortedItems = sorter.sort(all.map(\.item) + [item])
    if let index = sortedItems.firstIndex(of: item) {
      all.insert(itemDecorator, at: index)
    }

    items = all
    updateUnpinnedShortcuts()
    
    sessionLog[Clipboard.shared.changeCount] = item
    
    AppState.shared.popup.needsResize = true
    
    return itemDecorator
  }

  @MainActor
  func removeAll() {
    items.forEach({ $0.item.contents.forEach({ Storage.shared.context.delete($0) }) })
    try? Storage.shared.context.delete(model: HistoryItem.self)
    try? Storage.shared.context.save()
    all = []
    items = []
  }

  @MainActor
  func clear() {
    if Defaults[.suppressClearAlert] {
      removeAll()
    } else {
      let alert = NSAlert()
      alert.messageText = NSLocalizedString("ClearHistoryTitle", comment: "")
      alert.informativeText = NSLocalizedString("ClearHistoryMessage", comment: "")
      alert.addButton(withTitle: NSLocalizedString("ClearHistoryConfirm", comment: ""))
      alert.addButton(withTitle: NSLocalizedString("ClearHistoryCancel", comment: ""))
      alert.showsSuppressionButton = true

      let response = alert.runModal()
      if response == .alertFirstButtonReturn {
        if alert.suppressionButton?.state == .on {
          Defaults[.suppressClearAlert] = true
        }

        removeAll()
      }
    }
  }

  @MainActor
  func clearAll() {
    removeAll()
  }

  @MainActor
  func delete(_ item: HistoryItemDecorator?) {
    guard let item else {
      return
    }

    Storage.shared.context.delete(item.item)
    try? Storage.shared.context.save()
    
    all.removeAll { $0 == item }
    items.removeAll { $0 == item }

    updateUnpinnedShortcuts()
    AppState.shared.popup.needsResize = true
  }

  @MainActor
  func select(_ item: HistoryItemDecorator?) {
    guard let item else {
      return
    }

    let modifierFlags = currentModifierFlags()

    // Explicitly hide the app first to return focus to the target application.
    // This is critical in the new SwiftUI architecture to ensure Cmd+V is received.
    NSApp.hide(nil)
    AppState.shared.popup.close()

    if modifierFlags.isEmpty {
      if Defaults[.applyTransformationByDefault],
         let activeID = Defaults[.activeTransformationID],
         let transformation = Defaults[.transformations].first(where: { $0.id == activeID }) {
        Clipboard.shared.copy(item.item, transform: transformation.apply)
      } else {
        Clipboard.shared.copy(item.item, removeFormatting: Defaults[.removeFormattingByDefault])
      }

      if Defaults[.pasteByDefault] {
        Clipboard.shared.paste()
      }
    } else {
      switch HistoryItemAction(modifierFlags) {
      case .copy:
        Clipboard.shared.copy(item.item)
      case .paste:
        Clipboard.shared.copy(item.item)
        Clipboard.shared.paste()
      case .pasteWithoutFormatting:
        Clipboard.shared.copy(item.item, removeFormatting: true)
        Clipboard.shared.paste()
      case .pasteWithTransformation:
        if let activeID = Defaults[.activeTransformationID],
           let transformation = Defaults[.transformations].first(where: { $0.id == activeID }) {
          Clipboard.shared.copy(item.item, transform: transformation.apply)
        } else {
          Clipboard.shared.copy(item.item)
        }
        Clipboard.shared.paste()
      case .unknown:
        return
      }
    }

    Task {
      searchQuery = ""
    }
  }

  @MainActor
  func startPasteStack(selection: inout Selection<HistoryItemDecorator>) {
    guard AppState.shared.multiSelectionEnabled else { return }
    guard let item = selection.first else { return }
    PasteStack.initializeIfNeeded()

    let modifierFlags = currentModifierFlags()

    let stack = PasteStack(items: selection.items, modifierFlags: modifierFlags)
    pasteStack = stack

    // Explicitly hide the app first.
    NSApp.hide(nil)
    AppState.shared.popup.close()

    if modifierFlags.isEmpty {
      if Defaults[.applyTransformationByDefault],
         let activeID = Defaults[.activeTransformationID],
         let transformation = Defaults[.transformations].first(where: { $0.id == activeID }) {
        Clipboard.shared.copy(item.item, transform: transformation.apply)
      } else {
        Clipboard.shared.copy(item.item, removeFormatting: Defaults[.removeFormattingByDefault])
      }
    } else {
      switch HistoryItemAction(modifierFlags) {
      case .copy:
        Clipboard.shared.copy(item.item)
      case .paste:
        Clipboard.shared.copy(item.item)
        Clipboard.shared.paste()
      case .pasteWithoutFormatting:
        Clipboard.shared.copy(item.item, removeFormatting: true)
        Clipboard.shared.paste()
      case .pasteWithTransformation:
        if let activeID = Defaults[.activeTransformationID],
           let transformation = Defaults[.transformations].first(where: { $0.id == activeID }) {
          Clipboard.shared.copy(item.item, transform: transformation.apply)
        } else {
          Clipboard.shared.copy(item.item)
        }
        Clipboard.shared.paste()
      case .unknown:
        return
      }
    }

    Task {
      searchQuery = ""
    }
  }

  func handlePasteStack() {
    guard let stack = pasteStack else {
      return
    }

    guard let item = stack.items.first else {
      pasteStack = nil
      return
    }

    stack.items.removeFirst()

    guard let nextItem = stack.items.first else {
      pasteStack = nil
      return
    }

    Task { @MainActor in
      if stack.modifierFlags.isEmpty {
        if Defaults[.applyTransformationByDefault],
           let activeID = Defaults[.activeTransformationID],
           let transformation = Defaults[.transformations].first(where: { $0.id == activeID }) {
          Clipboard.shared.copy(nextItem.item, transform: transformation.apply)
        } else {
          Clipboard.shared.copy(nextItem.item, removeFormatting: Defaults[.removeFormattingByDefault])
        }
      } else {
        switch HistoryItemAction(stack.modifierFlags) {
        case .copy:
          Clipboard.shared.copy(nextItem.item)
        case .paste:
          Clipboard.shared.copy(nextItem.item)
        case .pasteWithoutFormatting:
          Clipboard.shared.copy(nextItem.item, removeFormatting: true)
        case .pasteWithTransformation:
          if let activeID = Defaults[.activeTransformationID],
             let transformation = Defaults[.transformations].first(where: { $0.id == activeID }) {
            Clipboard.shared.copy(nextItem.item, transform: transformation.apply)
          } else {
            Clipboard.shared.copy(nextItem.item)
          }
        case .unknown:
          return
        }
      }
    }
  }

  func interruptPasteStack() {
    guard pasteStack != nil else {
      return
    }
    pasteStack = nil
  }

  @MainActor
  func togglePin(_ item: HistoryItemDecorator?) {
    guard let item else { return }

    item.togglePin()

    let sortedItems = sorter.sort(all.map(\.item))
    if let currentIndex = all.firstIndex(of: item),
       let newIndex = sortedItems.firstIndex(of: item.item) {
      all.remove(at: currentIndex)
      all.insert(item, at: newIndex)
    }

    items = all

    searchQuery = ""
    updateUnpinnedShortcuts()
  }

  @MainActor
  func findSimilarItem(_ item: HistoryItem) -> HistoryItem? {
    return all.first(where: { $0.item.supersedes(item) })?.item
  }

  @MainActor
  var pressedShortcutItem: HistoryItemDecorator? {
    if let event = NSApp.currentEvent, event.type == .keyDown {
      let key = Sauce.shared.key(for: Int(event.keyCode))
      return items.first { $0.shortcuts.contains(where: { $0.key == key }) }
    }
    return AppState.shared.navigator.selection.first ?? items.first
  }

  private func updateItems(_ newItems: [HistoryItemDecorator]) {
    items = newItems
    updateUnpinnedShortcuts()
  }

  private func updateShortcuts() {
    for item in pinnedItems {
      if let pin = item.item.pin {
        item.shortcuts = KeyShortcut.create(character: pin)
      }
    }

    updateUnpinnedShortcuts()
  }

  private func updateUnpinnedShortcuts() {
    let visibleUnpinnedItems = unpinnedItems.filter(\.isVisible)
    for item in visibleUnpinnedItems {
      item.shortcuts = []
    }

    var index = 1
    for item in visibleUnpinnedItems.prefix(9) {
      item.shortcuts = KeyShortcut.create(character: String(index))
      index += 1
    }
  }

  private func isModified(_ item: HistoryItem) -> String? {
    return item.pin
  }

  private func currentModifierFlags() -> NSEvent.ModifierFlags {
    return NSApp.currentEvent?.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting([.capsLock, .numericPad, .function]) ?? []
  }
}
