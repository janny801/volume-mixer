import AppKit
import SwiftUI

/// Owns presentation only. The same model and mixer view survive every open/close.
@MainActor final class MixerMenuBarController: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = MixerModel()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var localMonitor: Any?
    private var outsideMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            let image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Volume Mixer")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Volume Mixer"
            button.setAccessibilityLabel("Volume Mixer")
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: .leftMouseUp)
        }
        // Explicit dismissal prevents an outside-click close followed by the same
        // status-button click reopening the panel immediately.
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: MixerView(model: model))
    }

    @objc private func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem?.button else { return }
        // Measure before positioning: an initially zero-sized hosting view can
        // otherwise grow upward past the menu bar after the popover is shown.
        if let view = popover.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            popover.contentSize = view.fittingSize
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)
        popover.contentViewController?.view.window?.makeKey()
        startDismissalMonitors()
    }

    private func startDismissalMonitors() {
        stopDismissalMonitors()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { // Escape
                    self.popover.performClose(nil)
                    return nil
                }
                return event
            }
            // Let our button action handle its own click exactly once. Clicks
            // inside the panel still reach sliders, buttons, and the checkbox.
            if event.window === self.statusItem?.button?.window ||
                event.window === self.popover.contentViewController?.view.window {
                return event
            }
            self.popover.performClose(nil)
            return event
        }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.popover.performClose(nil)
        }
    }

    private func stopDismissalMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        localMonitor = nil
        outsideMonitor = nil
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem?.button?.highlight(false)
        stopDismissalMonitors()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopDismissalMonitors()
    }
}
