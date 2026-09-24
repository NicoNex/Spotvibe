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

@discardableResult
private func installHotKey(_ action: @escaping () -> Void) -> Bool {
    onHotKey = action
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    guard InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        onHotKey?()
        return noErr
    }, 1, &spec, nil, nil) == noErr else { return false }
    // Fails with eventHotKeyExistsErr when Alfred, Raycast or an input-source switcher
    // already owns ⌥Space. Report it, or the app looks simply broken.
    return RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey),
                               EventHotKeyID(signature: 0x5356_4245, id: 1),
                               GetApplicationEventTarget(), 0, &hotKeyRef) == noErr
}

func trace(_ message: String) {
    guard let path = ProcessInfo.processInfo.environment["SPOTVIBE_TRACE"] else { return }
    let line = message + "\n"
    if path == "1" {
        FileHandle.standardError.write(line.data(using: .utf8)!)
        return
    }
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        try? handle.close()
    }
}

// MARK: - Controller

final class Controller: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let search = Search()
    private var panel: Panel!
    private var status: NSStatusItem!
    private var topY: CGFloat = 0

    func applicationDidFinishLaunching(_: Notification) {
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

        let hotKeyOK = installHotKey { [weak self] in self?.toggle() }
        status = makeStatusItem(hotKeyOK: hotKeyOK)

        // ponytail: a scripted open/close so the transitions can be recorded and watched
        // back frame by frame. Animations cannot be checked from a still.
        if ProcessInfo.processInfo.environment["SPOTVIBE_CYCLE"] != nil {
            let steps: [(TimeInterval, () -> Void)] = [
                (0.8, { [weak self] in self?.show() }),
                (3.0, { [weak self] in self?.hide() }),
                (5.0, { [weak self] in self?.show(); self?.search.text = "cal" }),
                (7.4, { [weak self] in self?.hide() }),
                (9.2, { NSApp.terminate(nil) }),
            ]
            for (at, step) in steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + at, execute: step)
            }
            return
        }

        if let demo = ProcessInfo.processInfo.environment["SPOTVIBE_DEMO"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.show()
                if demo != "1" { self?.search.text = demo }
            }
        }
    }

    private func makeStatusItem(hotKeyOK: Bool) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: "SpotVibe")
        let menu = NSMenu()
        menu.addItem(withTitle: hotKeyOK ? "Apri SpotVibe  ⌥Space" : "Apri SpotVibe  (⌥Space occupata)",
                     action: #selector(showFromMenu), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Esci", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        return item
    }

    @objc private func showFromMenu() { show() }

    func toggle() { panel.isVisible ? hide() : show() }

    func show() {
        // The hotkey fires while another app is frontmost, so NSScreen.main is that app's
        // screen, not the one being looked at. The pointer is the better guess.
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        topY = visible.maxY - visible.height * 0.10

        // Start as one drop, with nothing in it.
        search.separated = false
        search.contentVisible = false
        reposition()
        panel.alphaValue = 0
        // Order in and take key WHILE THE CONTENT IS STILL SMALL. Making a window key runs
        // AppKit's key-view search over the hosting view, and with the results grid already
        // built that search pins the main thread inside -[NSWindow makeKeyAndOrderFront:]
        // and never returns. activate() must come first for the same reason.
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        search.expanded = true

        // 1. the drop fades in whole
        after(0.05) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.panel.animator().alphaValue = 1
            }
            self.search.focusToken += 1
            self.search.visible = true
        }
        // 2. it pulls apart: the bridge between the two shapes thins, snaps, and rebounds
        after(0.20) { self.search.separated = true }
        // 3. once they have settled, the contents arrive
        after(0.62) { self.search.contentVisible = true }
    }

    /// Runs `work` on the main queue after `delay`, dropped if the panel changed state.
    private func after(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The panel grows downwards as results arrive, so anchor it by its top edge.
    private func reposition() {
        guard let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                     y: max(visible.minY, min(topY - size.height, visible.maxY - size.height))))
    }

    func windowDidResize(_: Notification) { reposition() }

    func hide() {
        guard panel.isVisible, search.visible else { return }
        search.visible = false

        // The reverse order: the contents go first, then the two bodies flow back into one,
        // and only then does the drop fade. `expanded` deliberately stays true — clearing
        // it would empty the hierarchy mid-animation.
        search.contentVisible = false
        after(0.10) { self.search.separated = false }

        // The rejoin needs its own beat. Fading immediately outran the spring and the panel
        // vanished mid-merge, so the closing never read as liquid.
        after(0.46) {
            guard !self.search.visible, self.panel.isVisible else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.panel.animator().alphaValue = 0
            } completionHandler: {
                guard !self.search.visible else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
                self.search.reset()
            }
        }
    }

    func windowDidResignKey(_: Notification) { hide() }
}
