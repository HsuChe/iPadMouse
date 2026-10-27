// Menu bar only app (LSUIElement). Shows connection status, lets you pick the
// target display and flip scroll direction.

import AppKit
import ApplicationServices


final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let injector = Injector()
    private lazy var receiver = Receiver(injector: injector)
    private let statusMenuItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let naturalItem = NSMenuItem(title: "Natural Scrolling", action: #selector(toggleNatural), keyEquivalent: "")
    private let displayMenu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "ipad.landscape", accessibilityDescription: "iPad Mouse")

        let menu = NSMenu()
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        let displayItem = NSMenuItem(title: "Target Display", action: nil, keyEquivalent: "")
        displayItem.submenu = displayMenu
        menu.addItem(displayItem)
        naturalItem.target = self
        naturalItem.state = injector.naturalScrolling ? .on : .off
        menu.addItem(naturalItem)
        let axItem = NSMenuItem(title: "Open Accessibility Settings…", action: #selector(openAccessibility), keyEquivalent: "")
        axItem.target = self
        menu.addItem(axItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit iPad Mouse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        rebuildDisplayMenu()
        NotificationCenter.default.addObserver(self, selector: #selector(rebuildDisplayMenu),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

        receiver.onStatus = { [weak self] text in
            DispatchQueue.main.async { self?.statusMenuItem.title = text }
        }
        receiver.start()
        ensureAccessibility()
    }

    /// CGEvent posting is silently ignored until the user grants Accessibility access.
    private func ensureAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            statusMenuItem.title = "Grant Accessibility access, then relaunch"
        }
    }

    @objc private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleNatural() {
        injector.naturalScrolling.toggle()
        naturalItem.state = injector.naturalScrolling ? .on : .off
    }

    @objc private func rebuildDisplayMenu() {
        displayMenu.removeAllItems()
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = CGDirectDisplayID(number.uint32Value)
            let item = NSMenuItem(title: screen.localizedName, action: #selector(selectDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(id)
            item.state = id == injector.targetDisplay ? .on : .off
            displayMenu.addItem(item)
        }
    }

    @objc private func selectDisplay(_ sender: NSMenuItem) {
        injector.targetDisplay = CGDirectDisplayID(sender.tag)
        rebuildDisplayMenu()
        receiver.broadcastConfig()
    }
}
