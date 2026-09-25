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
    /// The top edge of the screen, notch included — the window is pinned to it.
    private var screenTop: CGFloat = 0

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
                // Scaled too: leaving these unscaled while the animations stretch makes an
                // open collide with the close before it, and the recording is unreadable.
                DispatchQueue.main.asyncAfter(deadline: .now() + at * Self.tempo, execute: step)
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
        // frame, not visibleFrame: the window has to reach the physical top of the display,
        // where the notch is, and the panel's level is above the menu bar anyway.
        guard let full = screen?.frame else { return }
        screenTop = full.maxY
        // The notch is what is left when the two menu-bar areas beside it are taken out.
        let aux = (screen?.auxiliaryTopLeftArea?.width ?? 0) + (screen?.auxiliaryTopRightArea?.width ?? 0)
        search.notchWidth = aux > 0 ? max(0, full.width - aux) : 0

        // Start as one drop, with nothing in it.
        search.dripped = false
        search.separated = false
        search.shaped = false
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
        // 2. it lets go of the notch and falls, rounding out as it lands
        after(0.02) { self.search.dripped = true }
        // 3. it divides: a small droplet above, a large one below, the bridge between them
        //    thinning until it snaps
        after(0.34) { self.search.separated = true }
        // 4. each droplet stretches into what it was going to be — the bar and the panel
        after(0.72) { self.search.shaped = true }
        // 5. and only then do the contents arrive
        after(0.98) { self.search.contentVisible = true }
    }

    /// Stretches every beat of the entrance, for watching it back frame by frame.
    /// `SPOTVIBE_TEMPO=4` runs it at a quarter speed.
    static let tempo = Double(ProcessInfo.processInfo.environment["SPOTVIBE_TEMPO"] ?? "") ?? 1

    /// Runs `work` on the main queue after `delay`, scaled by the tempo.
    private func after(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay * Self.tempo, execute: work)
    }

    /// Pinned to the top edge of the screen. The content falls from the notch to its
    /// resting place inside the window, so the window itself never has to move.
    private func reposition() {
        guard let full = panel.screen?.frame ?? NSScreen.main?.frame else { return }
        let size = panel.frame.size
        let top = screenTop == 0 ? full.maxY : screenTop
        panel.setFrameOrigin(NSPoint(x: full.midX - size.width / 2, y: top - size.height))
    }

    func windowDidResize(_: Notification) { reposition() }

    func hide() {
        guard panel.isVisible, search.visible else { return }
        search.visible = false

        // The reverse order: the contents go first, then the two bodies flow back into one,
        // and only then does the drop fade. `expanded` deliberately stays true — clearing
        // it would empty the hierarchy mid-animation.
        search.contentVisible = false
        // The bar and the panel round back into droplets, the droplets flow into one drop
        // at the centre, and that drop swells and bursts.
        after(0.04) { self.search.shaped = false }
        after(0.20) { self.search.separated = false }
        after(0.30) { self.search.dripped = false }
        after(0.48) { self.search.popping = true }

        // The rejoin needs its own beat. Fading immediately outran the spring and the panel
        // vanished mid-merge, so the closing never read as liquid.
        // Cut, not a fade. A soap bubble is there and then it is not, so 0.07s reads as
        // gone rather than as something that faded quickly.
        after(0.60) {
            guard !self.search.visible, self.panel.isVisible else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.07 * Self.tempo
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
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
