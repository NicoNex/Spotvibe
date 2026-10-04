// SpotVibe — a Spotlight replacement for macOS 26.
// Copyright (C) 2026 Nicolò Santamaria
//
// This program is free software: you can redistribute it and/or modify it under
// the terms of the GNU General Public License version 3, as published by the Free
// Software Foundation. It comes with ABSOLUTELY NO WARRANTY; see LICENSE.

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
    /// Whether a chord is being waited for lives on the preferences, not here: the
    /// controller watches it to let go of the global hotkey while we listen, so the chord
    /// that is already bound can be pressed to confirm itself.
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var settings: Preferences?

    func toggle(_ settings: Preferences) { monitor == nil ? start(settings) : stop() }

    func start(_ settings: Preferences) {
        guard monitor == nil else { return }
        self.settings = settings
        settings.recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            let carbon = Self.carbonModifiers(event.modifierFlags)
            // A hotkey with no modifier would swallow that key everywhere, system-wide.
            guard carbon != 0 else { return nil }
            settings.setHotKey(code: UInt32(event.keyCode), modifiers: carbon, label: Self.label(for: event))
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .drawCompleted)
            stop()
            return nil // swallowed, or the chord also reaches the search field
        }
    }

    func stop() {
        guard monitor != nil else { return } // or the hotkey is re-bound on every redraw
        NSEvent.removeMonitor(monitor!)
        monitor = nil
        settings?.recording = false
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title
            // Two columns, because the slab is 798 wide: one column of eight-word rows
            // across that much glass is mostly empty space with a control stranded at the
            // far right, and the eye has to travel the whole width to pair label to value.
            HStack(alignment: .top, spacing: Self.columnGap) {
                VStack(alignment: .leading, spacing: Self.groupGap) {
                    group(loc("Appearance")) {
                        row("circle.lefthalf.filled", loc("Window opacity")) {
                            // Live: the panel behind these settings changes as the thumb moves.
                            Slider(value: opacity, in: 0 ... 1)
                                .labelsHidden()
                                .frame(width: 176)
                                // The notch the slider snaps to: the default, in the middle.
                                .overlay(alignment: .bottom) {
                                    Capsule().fill(.secondary.opacity(0.6)).frame(width: 1.5, height: 5)
                                        .offset(y: 6)
                                }
                        }
                    }
                    group(loc("Search")) {
                        row("folder", loc("Look in")) {
                            Picker("", selection: bound.scope) {
                                Text(loc("Home folder")).tag(Preferences.Scope.home)
                                Text(loc("Whole Mac")).tag(Preferences.Scope.everywhere)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 176)
                        }
                        Divider().opacity(0.5).padding(.leading, 42)
                        row("clock.arrow.circlepath", loc("Show recents")) {
                            Toggle("", isOn: bound.showRecents)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }
                    }
                }
                VStack(alignment: .leading, spacing: Self.groupGap) {
                    group(loc("Shortcut")) {
                        row("keyboard", loc("Open SpotVibe")) { recorderButton }
                    }
                    group(loc("Web")) {
                        row("magnifyingglass", loc("Search engine")) {
                            Picker("", selection: bound.engine) {
                                ForEach(Preferences.Engine.allCases) { Text($0.label).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 150)
                        }
                    }
                    Spacer(minLength: 0)
                    hint
                }
            }
            .padding(.horizontal, Self.margin)
            Spacer(minLength: 0)
        }
        .onDisappear { recorder.stop() }
    }

    private static let margin: CGFloat = 28
    private static let columnGap: CGFloat = 22
    private static let groupGap: CGFloat = 16

    private var title: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(loc("Settings"))
                .font(.system(size: 22, weight: .semibold, design: .rounded))
            Spacer(minLength: 0)
            Button(role: .close) { onClose() }
                .buttonStyle(.glass)
        }
        .padding(.horizontal, Self.margin)
        .padding(.top, 20)
        .padding(.bottom, 18)
    }

    /// Fills the space the shorter column leaves rather than padding it out, and answers the
    /// one question the recorder raises the moment anyone looks at it.
    private var hint: some View {
        Text(Self.recorderHint)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .padding(.bottom, 2)
    }

    private static let recorderHint = loc("Click, then press the keys you want. Esc cancels.")

    // Plain bindings, no haptic. They used to fire one on every change, which is where the
    // double click came from: AppKit already performs feedback for a segmented control and
    // a switch, and the trackpad clicks on release regardless.
    private var bound: Bindable<Preferences> { Bindable(settings) }

    /// Snaps to the default, and says so with a tap — a slider drag has no click of its own,
    /// which is the case the haptic is kept for.
    private var opacity: Binding<Double> {
        Binding(get: { settings.opacity }, set: { value in
            let snapped = Preferences.snapped(value)
            if snapped == Preferences.defaultOpacity, settings.opacity != snapped {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .drawCompleted)
            }
            settings.opacity = snapped
        })
    }

    /// Haptic only where a value changes without a click: recording a shortcut, which is
    /// committed by the keyboard (see HotKeyRecorder). Everywhere else the trackpad is
    /// already clicking — once going down and once coming back up — and a tap of our own on
    /// top of the release click is the doubled click you feel.
    private var recorderButton: some View {
        Button { recorder.toggle(settings) } label: {
            Text(settings.recording ? loc("Press a shortcut…") : settings.hotKeyLabel)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .frame(width: 150)
        }
        .buttonStyle(.glass)
        .help(Self.recorderHint)
    }

    // MARK: Chrome

    /// A caption over a card of rows, which is how every settings window on this Mac is
    /// laid out — the grouping is the thing being read, and a hairline across the whole
    /// panel does not group, it only divides.
    private func group(_ name: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(name.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            // ponytail: a plain translucent fill, NOT a second glass layer. Glass cannot
            // sample glass, and the slab under this one already is some.
            VStack(spacing: 0, content: rows)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.primary.opacity(0.055)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.primary.opacity(0.07), lineWidth: 0.5))
        }
    }

    private func row(_ icon: String, _ label: String, @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 10) {
            // The symbol is what makes a row findable at a glance; the label is what makes
            // it unambiguous. Fixed width so every label starts on the same line.
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(label).font(.system(size: 13)).lineLimit(1).fixedSize()
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
    }
}
