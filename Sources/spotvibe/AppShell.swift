// SpotVibe — a Spotlight replacement for macOS 26.
// Copyright (C) 2026 Nicolò Santamaria
//
// This program is free software: you can redistribute it and/or modify it under
// the terms of the GNU General Public License version 3, as published by the Free
// Software Foundation. It comes with ABSOLUTELY NO WARRANTY; see LICENSE.

import AppKit
import SpotVibeCore
import Carbon.HIToolbox
import SwiftUI

// MARK: - Floating panel

final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Global hotkey (⌥Space)
// ponytail: Carbon RegisterEventHotKey is still the only system-wide hotkey API that
// needs no Accessibility permission. An NSEvent global monitor would prompt the user.

private var hotKeyRef: EventHotKeyRef?
private var onHotKey: (() -> Void)?
private var handlerInstalled = false

/// Installs the Carbon handler once, then binds the chord. Re-registering is just
/// unregistering the old reference and taking a new one — the handler stays put.
@discardableResult
private func installHotKey(code: UInt32, modifiers: UInt32, _ action: @escaping () -> Void) -> Bool {
    onHotKey = action
    if !handlerInstalled {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        guard InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            onHotKey?()
            return noErr
        }, 1, &spec, nil, nil) == noErr else { return false }
        handlerInstalled = true
    }
    if let existing = hotKeyRef { UnregisterEventHotKey(existing); hotKeyRef = nil }
    // Fails with eventHotKeyExistsErr when Alfred, Raycast or an input-source switcher
    // already owns the chord. Report it, or the app looks simply broken.
    return RegisterEventHotKey(code, modifiers,
                               EventHotKeyID(signature: 0x5356_4245, id: 1),
                               GetApplicationEventTarget(), 0, &hotKeyRef) == noErr
}

/// Hands the chord back to the system. A registered hotkey never reaches the app at all,
/// so while the settings are listening for a new one this has to be let go of — otherwise
/// pressing the current chord to keep it would toggle the panel shut instead of being
/// recorded as the choice it is.
private func releaseHotKey() {
    guard let existing = hotKeyRef else { return }
    UnregisterEventHotKey(existing)
    hotKeyRef = nil
}

// MARK: - Controller

final class Controller: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let preferences = Preferences()
    private lazy var search = Search(settings: preferences)
    private var panel: Panel!
    private var status: NSStatusItem!

    func applicationDidFinishLaunching(_: Notification) {
        // FIRST, before anything touches `search`. That property is lazy, and reading it
        // walks three application directories asking LaunchServices for a localized name
        // per bundle — several hundred milliseconds during which ⌥Space did nothing at all.
        // The handler cannot fire while we are still inside this method, so registering
        // here costs nothing and makes the chord live as early as it can be.
        status = makeStatusItem(hotKeyOK: bindHotKey())
        preferences.onHotKeyChanged = { [weak self] in self?.syncHotKey() }
        preferences.onRecordingChanged = { [weak self] _ in self?.syncHotKey() }

        panel = Panel(contentRect: NSRect(origin: .zero, size: RootView.panelSize),
                      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                      backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .screenSaver // above full-screen apps, like Spotlight
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // No window shadow. On a borderless transparent panel AppKit derives it from the
        // alpha channel and draws a hard dark contour around the glass instead of a soft
        // drop shadow. A SwiftUI .shadow() is not an option either: it rasterises the
        // glass and kills the edge refraction. The slabs carry their own rim.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        // Explicit layer backing: AppKit hosts SwiftUI and the glass backdrop on
        // CoreAnimation layers, which composite on the GPU through Metal.
        panel.contentView?.wantsLayer = true
        panel.delegate = self

        let host = NSHostingController(rootView: RootView(search: search, onClose: { [weak self] in self?.hide() }))
        // No self-sizing: the window keeps one size for its whole life and the content
        // moves inside it. See RootView.panelSize.
        host.view.setValue(NSColor.clear, forKey: "backgroundColor")
        panel.contentViewController = host

        preferences.onScopeChanged = { [weak self] in self?.search.rescope() }
        preferences.onRecentsChanged = { [weak self] in self?.search.refresh() }

        if let demo = ProcessInfo.processInfo.environment["SPOTVIBE_DEMO"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.show()
                // `SPOTVIBE_DEMO=settings` opens straight onto the settings screen; any
                // other value is typed into the field.
                if demo == "settings" { self?.search.showingSettings = true }
                else if demo != "1" { self?.search.text = demo }
            }
        }
    }

    /// The single authority on who holds the chord and what the menu says about it.
    /// Both the hotkey change and the recording change route here, so "do not hold the
    /// chord while the settings are listening for one" is stated once, in the place that
    /// holds it — rather than as a rebind skipped in one callback and a label rewritten in
    /// both, which is what it was.
    private func syncHotKey() {
        if preferences.recording { releaseHotKey(); return }
        status.menu?.items.first?.title = Self.hotKeyMenuTitle(ok: bindHotKey(),
                                                               label: preferences.hotKeyLabel)
    }

    private func bindHotKey() -> Bool {
        installHotKey(code: preferences.hotKeyCode,
                      modifiers: preferences.hotKeyModifiers) { [weak self] in self?.toggle() }
    }

    /// The chord is shown inline because a status-item menu cannot display a key equivalent
    /// for a Carbon-registered global hotkey.
    private static func hotKeyMenuTitle(ok: Bool, label: String) -> String {
        ok ? String(format: loc("Open SpotVibe  %@"), label)
           : String(format: loc("Open SpotVibe  (%@ unavailable)"), label)
    }

    private func makeStatusItem(hotKeyOK: Bool) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: "SpotVibe")
        let menu = NSMenu()
        menu.addItem(withTitle: Self.hotKeyMenuTitle(ok: hotKeyOK, label: preferences.hotKeyLabel),
                     action: #selector(showFromMenu), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: loc("Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        return item
    }

    @objc private func showFromMenu() { show() }

    /// `search.visible` and not `panel.isVisible`: the panel stays on screen through the
    /// close fade, and without this a hotkey during those 120 ms hit `hide()`'s guard and
    /// did nothing at all.
    func toggle() { search.visible ? hide() : show() }

    func show() {
        // The hotkey fires while another app is frontmost, so NSScreen.main is that app's
        // screen, not the one being looked at. The pointer is the better guess.
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens.first
        // frame, not visibleFrame: the window has to reach the physical top of the display,
        // where the notch is, and the panel's level is above the menu bar anyway.
        guard let full = screen?.frame else { return }

        search.opened = false
        reposition(on: full)
        panel.alphaValue = 0
        // Order in and take key WHILE THE CONTENT IS STILL SMALL. Making a window key runs
        // AppKit's key-view search over the hosting view, and with the results grid already
        // built that search pins the main thread inside -[NSWindow makeKeyAndOrderFront:]
        // and never returns. activate() must come first for the same reason.
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        search.expanded = true
        search.visible = true

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        // After a frame, not `async`: main-queue blocks drain before SwiftUI's commit
        // observer runs, so an `async` here lands in the SAME update as `expanded` above.
        // The slabs would then lay out at full size on their only pass and the entrance
        // would silently never animate. A real delay guarantees a first pass at 0.94.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { self.search.opened = true }
    }

    /// Pinned to the top edge of the screen the pointer is on, so the window itself never
    /// has to move: the panel is laid out at a fixed inset inside it.
    ///
    /// Takes the frame rather than looking one up. Deriving it from `panel.screen` undid
    /// the work `show` does to pick the right display: the panel is offscreen before the
    /// first show, so `panel.screen` is nil and the fallback is `NSScreen.main` — which,
    /// while another app is frontmost, is that app's display. On two screens the panel got
    /// one display's centre and the other's top edge.
    private func reposition(on full: NSRect) {
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: full.midX - size.width / 2, y: full.maxY - size.height))
    }

    func hide() {
        guard panel.isVisible, search.visible else { return }
        search.visible = false

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: {
            // A show that came in mid-fade owns the panel now; leave it alone.
            guard !self.search.visible else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            self.search.reset()
        }
    }

    func windowDidResignKey(_: Notification) { hide() }
}
