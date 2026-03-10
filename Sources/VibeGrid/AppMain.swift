#if os(macOS)
import AppKit
import Foundation

private let sharedDelegate = VibeGridAppDelegate()

@main
struct VibeGridEntry {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = sharedDelegate
        app.run()
    }
}

final class VibeGridAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var appState: AppState?
    private var statusItem: NSStatusItem?
    private var requestAccessibilityMenuItem: NSMenuItem?
    private var separatorBeforeAccessibilityMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        appState = AppState()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAccessibilityStatusDidUpdate(_:)),
            name: .vibeGridAccessibilityStatusDidUpdate,
            object: nil
        )
        setupStatusMenu()

        appState?.openControlCenter()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }

            _ = self.appState?.requestAccessibilityOnStartup(prompt: true)
            self.updateAccessibilityMenuVisibility()
            self.appState?.refresh()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        appState?.openControlCenter()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc
    private func openControlCenter() {
        appState?.openControlCenter()
    }

    @objc
    private func openSettings() {
        appState?.openSettings()
    }

    @objc
    private func openYamlFile() {
        appState?.openConfigFile()
    }

    @objc
    private func requestAccessibilityPermission() {
        _ = appState?.requestAccessibility(prompt: true, resetPermissionState: true)
        appState?.refresh()
        updateAccessibilityMenuVisibility()
    }

    @objc
    private func handleAccessibilityStatusDidUpdate(_ notification: Notification) {
        updateAccessibilityMenuVisibility()
    }

    @objc
    private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func setupStatusMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        if let button = item.button {
            button.image = nil
            button.title = "VibeGrid"
            button.toolTip = "VibeGrid Window Manager"
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Control Center", action: #selector(openControlCenter), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open YAML File", action: #selector(openYamlFile), keyEquivalent: ""))

        let settingsMenuItem = NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: "")
        settingsMenuItem.image = nil
        menu.addItem(settingsMenuItem)

        let separatorBeforeAccessibility = NSMenuItem.separator()
        menu.addItem(separatorBeforeAccessibility)
        separatorBeforeAccessibilityMenuItem = separatorBeforeAccessibility

        let requestAccessibilityMenuItem = NSMenuItem(
            title: "Request Accessibility Permission",
            action: #selector(requestAccessibilityPermission),
            keyEquivalent: ""
        )
        menu.addItem(requestAccessibilityMenuItem)
        self.requestAccessibilityMenuItem = requestAccessibilityMenuItem

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit VibeGrid", action: #selector(quit), keyEquivalent: "q"))

        for menuItem in menu.items {
            menuItem.target = self
        }
        menu.delegate = self

        item.menu = menu
        updateAccessibilityMenuVisibility()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateAccessibilityMenuVisibility()
    }

    private func updateAccessibilityMenuVisibility() {
        let accessibilityGranted = appState?.accessibilityGranted() ?? false
        requestAccessibilityMenuItem?.isHidden = accessibilityGranted
        separatorBeforeAccessibilityMenuItem?.isHidden = accessibilityGranted
    }
}

#endif
