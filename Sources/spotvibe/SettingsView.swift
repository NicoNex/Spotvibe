import AppKit
import Carbon.HIToolbox
import Observation
import SpotVibeCore
import SwiftUI

// MARK: - Hot-key recording

/// Captures the next chord the user presses. A local monitor rather than `onKeyPress`,
/// because Carbon needs the raw key CODE and SwiftUI only hands over the character — which
/// is the wrong thing on any layout where the character moves.
@Observable
final class HotKeyRecorder {
    var active = false
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored var onCapture: ((UInt32, UInt32, String) -> Void)?

    func toggle() { active ? stop() : start() }

    func start() {
        guard monitor == nil else { return }
        active = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            let carbon = Self.carbonModifiers(event.modifierFlags)
            // A hotkey with no modifier would swallow that key everywhere, system-wide.
            guard carbon != 0 else { return nil }
            onCapture?(UInt32(event.keyCode), carbon, Self.label(for: event))
            stop()
            return nil // swallowed, or the chord also reaches the search field
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        active = false
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        return mask
    }

    /// In the order the system writes them, so it reads like every other shortcut on the Mac.
    private static func label(for event: NSEvent) -> String {
        var out = ""
        if event.modifierFlags.contains(.control) { out += "⌃" }
        if event.modifierFlags.contains(.option) { out += "⌥" }
        if event.modifierFlags.contains(.shift) { out += "⇧" }
        if event.modifierFlags.contains(.command) { out += "⌘" }
        return out + keyName(event)
    }

    private static func keyName(_ event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default:
            let typed = event.charactersIgnoringModifiers ?? ""
            return typed.isEmpty ? "Key \(event.keyCode)" : typed.uppercased()
        }
    }
}

// MARK: - Settings screen

struct SettingsView: View {
    let settings: Preferences
    var onClose: () -> Void

    // ponytail: hand-expanded @State — the SwiftUIMacros plugin ships with Xcode only and
    // this target builds against the Command Line Tools. See RootView for the same dance.
    private var _recorder = State(initialValue: HotKeyRecorder())
    private var recorder: HotKeyRecorder { _recorder.wrappedValue }

    /// A Force Touch trackpad is the only thing that renders these, so they are a bonus for
    /// the hardware that has one rather than the feedback the change depends on.
    private func haptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    section(loc("Appearance")) {
                        row(loc("Glass thickness")) {
                            Picker("", selection: thicknessBinding) {
                                Text(loc("Thin")).tag(Preferences.Thickness.thin)
                                Text(loc("Medium")).tag(Preferences.Thickness.medium)
                                Text(loc("Thick")).tag(Preferences.Thickness.thick)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 260)
                        }
                    }
                    separator
                    section(loc("Shortcut")) {
                        row(loc("Open SpotVibe")) { recorderButton }
                    }
                    separator
                    section(loc("Search")) {
                        row(loc("Look in")) {
                            Picker("", selection: scopeBinding) {
                                Text(loc("Home folder")).tag(Preferences.Scope.home)
                                Text(loc("Whole Mac")).tag(Preferences.Scope.everywhere)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 260)
                        }
                        row(loc("Show recents")) {
                            Toggle("", isOn: recentsBinding)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }
                    }
                    separator
                    section(loc("Web")) {
                        row(loc("Search engine")) {
                            Picker("", selection: engineBinding) {
                                ForEach(Preferences.Engine.allCases) { Text($0.label).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 200)
                        }
                    }
                }
                .padding(.bottom, 14)
            }
            .scrollIndicators(.never)
        }
        .onDisappear { recorder.stop() }
    }

    private var title: some View {
        HStack {
            Text(loc("Settings"))
                .font(.system(size: 17, weight: .semibold))
            Spacer(minLength: 0)
            Button(role: .close) { onClose() }
                .buttonStyle(.glass)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    /// Bindings rather than direct writes, so the haptic fires exactly when the value
    /// actually changes and not on every redraw.
    private var thicknessBinding: Binding<Preferences.Thickness> {
        Binding(get: { settings.thickness }, set: { settings.thickness = $0; haptic() })
    }
    private var scopeBinding: Binding<Preferences.Scope> {
        Binding(get: { settings.scope }, set: { settings.scope = $0; haptic() })
    }
    private var engineBinding: Binding<Preferences.Engine> {
        Binding(get: { settings.engine }, set: { settings.engine = $0; haptic() })
    }
    private var recentsBinding: Binding<Bool> {
        Binding(get: { settings.showRecents }, set: { settings.showRecents = $0; haptic() })
    }

    private var recorderButton: some View {
        Button {
            recorder.onCapture = { code, modifiers, label in
                settings.setHotKey(code: code, modifiers: modifiers, label: label)
                haptic()
            }
            recorder.toggle()
        } label: {
            Text(recorder.active ? loc("Press a shortcut…") : settings.hotKeyLabel)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .frame(width: 170)
        }
        .buttonStyle(.glass)
        .help(loc("Click, then press the keys you want. Esc cancels."))
    }

    // MARK: Chrome

    private var separator: some View {
        Divider()
            .opacity(0.6)
            .padding(.horizontal, 22)
            .padding(.vertical, 6)
    }

    private func section(_ name: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 22)
                .padding(.top, 8)
            content()
        }
    }

    private func row(_ label: String, @ViewBuilder control: () -> some View) -> some View {
        HStack {
            Text(label).font(.system(size: 13))
            Spacer(minLength: 16)
            control()
        }
        .padding(.horizontal, 22)
        .frame(height: 38)
    }
}
