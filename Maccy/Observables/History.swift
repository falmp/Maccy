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
        Task { @MainActor in
          self.updateItems(self.search.search(string: self.searchQuery, within: self.all).map(\.object))

          if self.searchQuery.isEmpty {
            AppState.shared.navigator.select(item: self.unpinnedItems.first)
          } else {
            AppState.shared.navigator.highlightFirst()
          }

          AppState.shared.popup.needsResize = true
        }
      }
    }
  }

  @MainActor
  var all: [HistoryItemDecorator] {
    let sortDescriptor: SortDescriptor<HistoryItem> = Defaults[.sortBy].sortDescriptor
    let fetchDescriptor = FetchDescriptor<HistoryItem>(
      sortBy: [sortDescriptor]
    )
    let historyItems = (try? Storage.shared.context.fetch(fetchDescriptor)) ?? []
    return historyItems.map({ HistoryItemDecorator($0) })
  }

  var firstVisibleItem: HistoryItemDecorator? {
    items.first
  }

  var lastVisibleItem: HistoryItemDecorator? {
    items.last
  }

  private let search = Search()
  private let sorter = Sorter()
  private let throttler = Throttler(minimumDelay: 0.2)

  init() {
    Task { @MainActor in
      self.updateItems(self.all)
    }
  }

  @MainActor
  func load() async throws {
    updateItems(all)
  }

  @MainActor
  func insertIntoStorage(_ item: HistoryItem) throws {
    Storage.shared.context.insert(item)
    try Storage.shared.context.save()
  }

  @MainActor
  func add(_ item: HistoryItem) {
    if isIgnored(item) {
      return
    }

    if let existingHistoryItem = findSimilarItem(item) {
      if isModified(item) == nil {
        item.contents = existingHistoryItem.contents
      }
      Storage.shared.context.delete(existingHistoryItem)
    }

    Storage.shared.context.insert(item)

    if all.count > Defaults[.size] {
      if let lastItem = all.last {
        Storage.shared.context.delete(lastItem.item)
      }
    }

    try? Storage.shared.context.save()
    updateItems(all)
  }

  @MainActor
  func removeAll() {
    items.forEach({ $0.item.contents.forEach({ Storage.shared.context.delete($0) }) })
    try? Storage.shared.context.delete(model: HistoryItem.self)
    try? Storage.shared.context.save()
    updateItems(all)
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

    let nextToSelect = AppState.shared.navigator.selection.items.count > 1 ?
      itemAfter(AppState.shared.navigator.selection.items.last) :
      itemAfter(item)

    AppState.shared.navigator.selection.items.forEach { decorator in
      decorator.item.contents.forEach { Storage.shared.context.delete($0) }
      Storage.shared.context.delete(decorator.item)
    }

    try? Storage.shared.context.save()
    updateItems(all)

    if let nextToSelect {
      AppState.shared.navigator.select(item: nextToSelect)
    }

    searchQuery = ""
  }

  func updateItems(_ newItems: [HistoryItemDecorator]) {
    items = newItems
  }

  @MainActor
  func select(_ item: HistoryItemDecorator?) {
    guard let item else {
      return
    }

    let modifierFlags = currentModifierFlags()

    if modifierFlags.isEmpty {
      AppState.shared.popup.close()
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
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
      case .paste:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
        Clipboard.shared.paste()
      case .pasteWithoutFormatting:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item, removeFormatting: true)
        Clipboard.shared.paste()
      case .pasteWithTransformation:
        AppState.shared.popup.close()
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

    searchQuery = ""
  }

  @MainActor
  func startPasteStack(selection: inout Selection<HistoryItemDecorator>) {
    guard AppState.shared.multiSelectionEnabled else { return }
    guard let item = selection.first else { return }
    PasteStack.initializeIfNeeded()

    let modifierFlags = currentModifierFlags()

    let stack = PasteStack(items: selection.items, modifierFlags: modifierFlags)
    pasteStack = stack

    logger.info("Initialising PasteStack with \(stack.items.count) items")
    logger.info("Copying \(item.item.title) from PasteStack")

    if modifierFlags.isEmpty {
      AppState.shared.popup.close()
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
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
      case .paste:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
        Clipboard.shared.paste()
      case .pasteWithoutFormatting:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item, removeFormatting: true)
        Clipboard.shared.paste()
      case .pasteWithTransformation:
        AppState.shared.popup.close()
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

    searchQuery = ""
  }

  func handlePasteStack() {
    guard let stack = pasteStack else {
      return
    }

    guard let pasted = stack.items.first else {
      pasteStack = nil
      logger.info("PasteStack is empty")
      return
    }

    logger.info("PasteStack pasted \(pasted.item.title)")

    stack.items.removeFirst()

    guard let item = stack.items.first else {
      pasteStack = nil
      logger.info("PasteStack is empty")
      return
    }

    logger.info("Copying \(item.item.title) from PasteStack. \(stack.items.count) items remaining in stack.")

    Task { @MainActor in
      if stack.modifierFlags.isEmpty {
        if Defaults[.applyTransformationByDefault],
           let activeID = Defaults[.activeTransformationID],
           let transformation = Defaults[.transformations].first(where: { $0.id == activeID }) {
          Clipboard.shared.copy(item.item, transform: transformation.apply)
        } else {
          Clipboard.shared.copy(item.item, removeFormatting: Defaults[.removeFormattingByDefault])
        }
      } else {
        switch HistoryItemAction(stack.modifierFlags) {
        case .copy:
          Clipboard.shared.copy(item.item)
        case .paste:
          Clipboard.shared.copy(item.item)
        case .pasteWithoutFormatting:
          Clipboard.shared.copy(item.item, removeFormatting: true)
        case .pasteWithTransformation:
          if let activeID = Defaults[.activeTransformationID],
             let transformation = Defaults[.transformations].first(where: { $0.id == activeID }) {
            Clipboard.shared.copy(item.item, transform: transformation.apply)
          } else {
            Clipboard.shared.copy(item.item)
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
    logger.info("Interrupting PasteStack")
    pasteStack = nil
  }

  @MainActor
  func togglePin(_ item: HistoryItemDecorator?) {
    guard let item else { return }

    item.togglePin()

    _ = sorter.sort(all.map(\.item))
    try? Storage.shared.context.save()
    updateItems(all)

    searchQuery = ""
  }

  func itemAfter(_ item: HistoryItemDecorator?) -> HistoryItemDecorator? {
    guard let item else {
      return nil
    }

    if let index = items.firstIndex(of: item), index < items.count - 1 {
      return items[index + 1]
    }

    return nil
  }

  @MainActor
  func findSimilarItem(_ item: HistoryItem) -> HistoryItem? {
    return all.first(where: { $0.item.supersedes(item) })?.item
  }

  @MainActor
  var pressedShortcutItem: HistoryItemDecorator? {
    if let event = NSApp.currentEvent, event.type == .keyDown {
      return item(for: event)
    }
    return AppState.shared.navigator.selection.first ?? items.first
  }

  private func item(for event: NSEvent) -> HistoryItemDecorator? {
    let key = Sauce.shared.key(for: Int(event.keyCode))
    return items.first { $0.shortcuts.contains(where: { $0.key == key }) }
  }

  private func isIgnored(_ item: HistoryItem) -> Bool {
    if item.contents.isEmpty {
      return true
    }

    return false
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
