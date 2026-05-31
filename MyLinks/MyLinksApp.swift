//
//  MyLinkBarApp.swift
//  MyLinkBar
//
//  Created by 임현성 on 5/26/26.
//

import AppKit
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let popoverWidth: CGFloat = 392
    private static let defaultPopoverHeight: CGFloat = 560

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("MyLinkBar: applicationDidFinishLaunching")
        NSApplication.shared.setActivationPolicy(.accessory)
        registerLaunchAtLogin()

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusItem = statusItem

        if let button = statusItem.button {
            let image = Self.menuBarIcon()

            button.image = image
            button.imagePosition = .imageOnly
            button.title = ""
            button.target = self
            button.action = #selector(togglePopover)
            button.toolTip = "MyLinks"
            NSLog("MyLinkBar: status item button configured")
        } else {
            NSLog("MyLinkBar: failed to create status item button")
        }

        popover.behavior = .transient
        popover.delegate = self
        popover.animates = false
        popover.contentSize = NSSize(width: Self.popoverWidth, height: Self.savedPopoverHeight)
        popover.contentViewController = NSHostingController(
            rootView: ContentView { [weak self] height in
                self?.popover.contentSize = NSSize(width: Self.popoverWidth, height: height)
            }
        )
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else {
            return
        }

        if popover.isShown {
            closePopover()
        } else {
            DispatchQueue.main.async { [weak self, weak button] in
                guard let self, let button, !self.popover.isShown else {
                    return
                }

                NSLog("MyLinkBar: showing popover")
                self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                self.startOutsideClickMonitor()
            }
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        stopOutsideClickMonitor()
    }

    private func startOutsideClickMonitor() {
        stopOutsideClickMonitor()

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.closePopover()
            }
        }
    }

    private func stopOutsideClickMonitor() {
        guard let outsideClickMonitor else {
            return
        }

        NSEvent.removeMonitor(outsideClickMonitor)
        self.outsideClickMonitor = nil
    }

    private static func menuBarIcon() -> NSImage? {
        if let image = NSImage(named: "WoowacourseIcon") {
            image.size = NSSize(width: 22, height: 22)
            image.isTemplate = true
            return image
        }

        let image = NSImage(systemSymbolName: "link.circle.fill", accessibilityDescription: "MyLinks")
        image?.size = NSSize(width: 22, height: 22)
        image?.isTemplate = true
        return image
    }

    private static var savedPopoverHeight: CGFloat {
        let savedHeight = UserDefaults.standard.double(forKey: "popoverHeight")
        return savedHeight == 0 ? defaultPopoverHeight : savedHeight
    }

    private func registerLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("MyLinks: failed to register launch at login: \(error.localizedDescription)")
        }
    }
}

extension AppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        stopOutsideClickMonitor()
    }
}

@main
struct MyLinkBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
