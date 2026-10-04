// SpotVibe — a Spotlight replacement for macOS 26.
// Copyright (C) 2026 Nicolò Santamaria
//
// This program is free software: you can redistribute it and/or modify it under
// the terms of the GNU General Public License version 3, as published by the Free
// Software Foundation. It comes with ABSOLUTELY NO WARRANTY; see LICENSE.

import AppKit
import SpotVibeCore
import SwiftUI

// MARK: - View

struct RootView: View {
    let search: Search
    var onClose: () -> Void

    // ponytail: hand-written expansions of `@FocusState` and `@Namespace`. The
    // SwiftUIMacros plugin ships with Xcode only and this target builds against the
    // Command Line Tools. Collapse both back to attributes once Xcode is installed.
    private var _focused = FocusState<Bool>()
    private var _ns = Namespace()
    private var ns: Namespace.ID { _ns.wrappedValue }

    /// Derived, not a second 7: the recents shelf is exactly one row of this grid, and two
    /// constants that must match would only drift apart.
    private static let columns = Search.recentLimit
    private static let cellWidth: CGFloat = 114
    private static let cellHeight: CGFloat = 132
    private static let cellGap: CGFloat = 8
    private static let rowHeight: CGFloat = 48
    private static let panelWidth = cellWidth * CGFloat(columns)
    private static let outerPadding: CGFloat = 34
    /// The window is a FIXED size and the content is laid out inside it. A window resize is
    /// a single AppKit step that cannot agree with a SwiftUI interpolation, so a self-sizing
    /// window would jolt the panel.
    static let panelSize = CGSize(width: panelWidth + outerPadding * 2, height: 850)
    /// Where the panel sits, measured from the top of the screen.
    private static let topInset: CGFloat = 188
    private static let gap: CGFloat = 26
    private static let fieldHeight: CGFloat = 56
    /// The gear is a circle the same height as the field, on the same row, so the two read
    /// as one control strip. The field gives up exactly that much width plus the gap.
    private static let gearGap: CGFloat = 12
    private static let fieldWidth = panelWidth - fieldHeight - gearGap
    /// The settings take the results' place under the field row, and are as tall as they
    /// need to be. Fixed, because settings do not grow or shrink with a search.
    private static let settingsHeight: CGFloat = 306
    /// 40, not 26. Lensing happens at the rim, and on a slab this size the rim is a
    /// hairline around a large frosted field — a wider curve puts more of the edge at an
    /// angle where it actually bends what is behind it.
    private static let slabRadius: CGFloat = 40
    /// The container's merge distance. Under the 12 between field and gear and the 26 down
    /// to the lower slab, so all three stay separate drops of glass at rest.
    private static let mergeDistance: CGFloat = 8

    /// The one animation of the settings change: the lower slab changes height and its
    /// content changes with it. Nothing else moves, so there is nothing to keep in step.
    private var settle: Animation? { search.reduceMotion ? nil : .smooth(duration: 0.32) }

    /// The glass takes its time; the writing on it does not. Out fast, in after a beat, and
    /// the two screens are never legible on the slab together.
    private static let contentFade = AnyTransition.asymmetric(
        insertion: .opacity.animation(.easeIn(duration: 0.16).delay(0.12)),
        removal: .opacity.animation(.easeOut(duration: 0.10)))

    /// The live system accent. Color.accentColor resolves to the asset-catalog accent and
    /// only falls back to the system one, so it is not the same guarantee.
    private var accent: Color {
        _ = search.appearanceToken // re-resolve when System Settings changes the accent
        return Color(nsColor: .controlAccentColor)
    }

    private var settings: Preferences { search.settings }

    /// The accent tints the glass, scaled by the system glass-tint slider. Reduce
    /// Transparency swaps the glass out for a solid window background.
    private var glass: Glass {
        guard !search.reduceTransparency else { return .identity }
        // The tint follows System Settings > Appearance, and nothing else: NSGlassTintAmount
        // is the only key the system exposes for that slider. At 0 the glass takes no
        // pigment at all, which is also when the rim reads most three-dimensional — pigment
        // fills in the specular highlight. Turning that slider down IS the control for it.
        //
        // interactive() stays: it is the single addition macOS 27 made to the material
        // (AppKit spells it NSGlassEffectView.effectIsInteractive) and gives the glass a
        // live specular response rather than a static sheen.
        let tint = accent.opacity(0.16 * search.glassTint)
        // The system has no thickness knob — `.clear` and `.regular` are the whole family —
        // so "thin" is the clear material and the other two are the regular one, separated
        // by the scrim below. `.clear` does take a tint, despite what one might assume.
        return (settings.usesClearGlass ? Glass.clear : .regular).tint(tint).interactive()
    }

    /// Sits ON TOP of the material (the background modifier is applied before `.glassEffect`,
    /// so the glass goes behind it). `.clear` on its own is too thin for a panel this dense
    /// with small text — over a busy backdrop the labels collide with what is behind them —
    /// so the scrim is there from the first notch of the slider and grows with it.
    private var scrim: CGFloat { settings.scrim }

    private var solidFallback: AnyShapeStyle {
        if search.reduceTransparency { return AnyShapeStyle(.windowBackground) }
        guard scrim > 0 else { return AnyShapeStyle(.clear) }
        return AnyShapeStyle(Color(nsColor: .windowBackgroundColor).opacity(scrim))
    }

    private func showSettings(_ open: Bool) { search.showingSettings = open }

    /// A hairline just inside the rim. The glass draws its own edge, but over a busy or
    /// low-contrast backdrop that edge washes out and the slab loses its outline. `.primary`
    /// so it inverts with the appearance, and `strokeBorder` so the line sits inside the
    /// shape instead of straddling it. An overlay composites above the glass — it does not
    /// filter the subtree, so the backdrop sampling underneath is untouched.
    ///
    /// Over it, the specular edge: brightest along the top where the light is, fading down
    /// the sides and catching again at the bottom lip. That line is most of what makes a
    /// slab read as a thick piece of glass rather than a frosted card.
    private func rim(_ shape: some InsettableShape) -> some View {
        shape.strokeBorder(.primary.opacity(0.10), lineWidth: 0.5)
            .overlay {
                shape.strokeBorder(Self.specular, lineWidth: 1)
                    .opacity(search.reduceTransparency ? 0 : 1)
            }
    }

    private static let specular = LinearGradient(
        stops: [.init(color: .white.opacity(0.60), location: 0),
                .init(color: .white.opacity(0.08), location: 0.35),
                .init(color: .white.opacity(0.06), location: 0.8),
                .init(color: .white.opacity(0.28), location: 1)],
        startPoint: .top, endPoint: .bottom)

    /// The one way a slab is dressed, in the one order that works: clipped BEFORE the glass
    /// (after it, the clip would rasterise the glass layer offscreen and cost the backdrop
    /// sampling), the scrim under the material, the rim over it.
    private func slab(_ content: some View, in shape: some InsettableShape) -> some View {
        content
            .clipShape(shape)
            .background(solidFallback, in: shape)
            .glassEffect(glass, in: shape)
            .overlay { rim(shape) }
    }

    /// Three glass slabs in one container: they sample the same backdrop and lens into each
    /// other across the gap, which is where the Liquid Glass distortion actually comes from.
    var body: some View {
        ZStack(alignment: .top) {
            // Clicking the margin dismisses, the way clicking outside the panel does. The
            // window is deliberately larger than the glass, so without this the transparent
            // area around it would swallow those clicks.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)

            GlassEffectContainer(spacing: Self.mergeDistance) {
                VStack(spacing: Self.gap) {
                    HStack(spacing: Self.gearGap) {
                        slab(field
                            // Opacity on the CONTENT, inside the glass — never on the
                            // element, which would rasterise the glass layer.
                            .opacity(search.showingSettings ? 0.4 : 1)
                            .disabled(search.showingSettings)
                            .frame(width: Self.fieldWidth, height: Self.fieldHeight),
                             in: Capsule())
                        slab(gear.frame(width: Self.fieldHeight, height: Self.fieldHeight),
                             in: Capsule())
                    }
                    // Clipped to the slab: a selected cell scrolled past the rounded edge
                    // was drawing outside the panel.
                    if search.showingSettings || (search.rowCount > 0 && search.expanded) {
                        slab(lower.frame(width: Self.panelWidth, height: lowerHeight,
                                         alignment: .top),
                             in: RoundedRectangle(cornerRadius: Self.slabRadius, style: .continuous))
                            // A glass element that is added or removed mid-animation comes
                            // back un-hit-testable, so this one only ever appears or goes
                            // at once; what animates is its height and its content.
                            .transition(.identity)
                    }
                }
                .animation(settle, value: search.showingSettings)
                .padding(.horizontal, Self.outerPadding)
                .padding(.top, Self.topInset)
            }
        }
        .frame(width: Self.panelSize.width, height: Self.panelSize.height, alignment: .top)
        // Nothing here wraps the glass container in opacity, blur, scale or shadow. Every
        // one of those forces the subtree offscreen, and a glass layer that renders
        // offscreen stops sampling the live backdrop — it degrades to a flat blur with no
        // rim refraction. Present and dismiss are animated on the NSPanel, in AppShell.
        .onAppear { _focused.wrappedValue = true }
        // The hosting view outlives every hide, so re-show has to re-assert focus itself.
        // `visible` goes false on every hide, so each show is a change even mid-fade.
        .onChange(of: search.visible) { _, shown in if shown { _focused.wrappedValue = true } }
        // Esc backs out of settings first, and only closes the panel from the search screen.
        .onExitCommand {
            if search.showingSettings { showSettings(false) } else { onClose() }
        }
        .task(id: search.text) {
            // Not while hidden: `reset()` clears the text after the fade, and that would
            // otherwise wake a task for a panel nobody can see.
            guard search.visible else { return }
            // `try?` here would swallow the cancellation and run the search anyway,
            // firing once per keystroke — the exact thrash this debounce exists to stop.
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            search.run(search.text)
        }
    }

    private var lowerHeight: CGFloat {
        search.showingSettings ? Self.settingsHeight : resultsHeight
    }

    /// Results or settings, whichever the gear chose. Plain views, not glass, so swapping
    /// them carries none of the glass constraints.
    @ViewBuilder
    private var lower: some View {
        if search.showingSettings {
            SettingsView(settings: settings) { showSettings(false) }
                .frame(width: Self.panelWidth, height: Self.settingsHeight)
                .transition(Self.contentFade)
        } else {
            results.transition(Self.contentFade)
        }
    }

    /// A Button rather than an `onTapGesture`, so it is reachable from the keyboard too.
    /// It toggles: the same circle opens the settings and closes them again.
    private var gear: some View {
        Button {
            // No haptic here: the click that got us here already produced one going down
            // and produces another coming up, and a third tap between them is the doubled
            // click. Haptics are kept for what has no click at all — see SettingsView.
            showSettings(!search.showingSettings)
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle()) // the whole circle, not just the glyph
        }
        .buttonStyle(.plain)
        .help(loc("Settings"))
    }

    private var field: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(loc("Search apps and files"), text: Bindable(search).text)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.primary)
                .focused(_focused.projectedValue)
                .onSubmit(activate)
                .onKeyPress(.leftArrow) { move(-1) }
                .onKeyPress(.rightArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-step(down: false)) }
                .onKeyPress(.downArrow) { move(step(down: true)) }
        }
        .padding(.horizontal, 24)
        .frame(height: Self.fieldHeight)
    }

    // MARK: Rows

    /// A path, not a URL. `URL(fileURLWithPath:)` stats the path to decide directory-ness,
    /// and the only consumer turned it straight back into a string — so building one per
    /// hit per body evaluation was a file-system probe per app, dozens of times a second
    /// while an arrow key repeats.
    private enum RowIcon { case file(String), symbol(String) }

    private struct RowModel: Identifiable {
        let id: Int
        let icon: RowIcon
        let title: String
        /// Only the web row carries one. A path is prettified in `row(model:)` instead,
        /// for the five rows actually drawn — building one for every hit meant several
        /// hundred throwaway strings per body evaluation that no grid cell ever reads.
        let subtitle: String?

        /// The path behind the row, for the ones that have one.
        var path: String? {
            if case let .file(path) = icon { return path }
            return nil
        }
    }

    /// One list built in one pass, so row identities can never collide between renders
    /// and the web row can never disagree with `rowCount` about whether it exists.
    private var rows: [RowModel] {
        var out = search.hits.enumerated().map { index, hit in
            RowModel(id: index, icon: .file(hit.id), title: hit.name, subtitle: nil)
        }
        if search.showsWebRow {
            out.append(RowModel(id: search.hits.count, icon: .symbol("globe"),
                                title: String(format: loc("Search the web for “%@”"), search.text),
                                subtitle: loc("Opens your default browser")))
        }
        return out
    }

    /// Moving inside the grid steps by a whole row; moving in the list steps by one.
    ///
    /// Going DOWN out of the last grid row is clamped to the first list row. A full row's
    /// worth would otherwise vault over the first few utilities or files, leaving rows that
    /// could only be reached by arrowing back up.
    private func step(down: Bool) -> Int {
        guard search.selection < search.appCount else { return 1 }
        // The shelf is its own grid, `recentCount` cells wide — usually fewer than seven.
        // So the cell under recents[i] is at recentCount + i, and stepping by the GRID's
        // width across that boundary jumped columns going down and, coming up out of the
        // first app row, overshot the shelf entirely and wrapped to the bottom of the list.
        let shelf = search.recentCount
        if shelf > 0 {
            if search.selection < shelf { return shelf }
            if !down, search.selection < shelf + Self.columns { return shelf }
        }
        guard down else { return Self.columns }
        return min(Self.columns, search.appCount - search.selection)
    }

    /// Section sizes, read straight off the counts rather than off `rows`. Building the row
    /// models is O(hits) with a `prettyPath` per row, and `body` can run many times per
    /// frame during the entrance — so nothing that only needs a COUNT is allowed to build
    /// them. `results` materialises the models exactly once and slices that one array.
    private var appGridCount: Int { search.appCount - search.recentCount }
    private var listCount: Int { search.rowCount - search.appCount }

    private static let gridColumns = Array(repeating: GridItem(.fixed(cellWidth), spacing: 0),
                                           count: columns)

    private func grid(_ models: ArraySlice<RowModel>) -> some View {
        LazyVGrid(columns: Self.gridColumns, spacing: Self.cellGap) {
            ForEach(models) { cell(model: $0) }
        }
    }

    private var results: some View {
        // Built once here, then sliced. Going through the `rows` getter per section would
        // rebuild the whole array for every access, several times per body evaluation.
        let all = rows
        let recentRows = all.prefix(search.recentCount)
        let appRows = all.dropFirst(search.recentCount).prefix(appGridCount)
        let listRows = all.dropFirst(search.appCount)

        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // No visible titles over the two grids: a shelf of three over a wall of
                    // apps says what each is, and the luminous rule between them does the
                    // dividing. The names stay for VoiceOver.
                    if !recentRows.isEmpty {
                        grid(recentRows)
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel(loc("Recent"))
                    }
                    if !appRows.isEmpty {
                        if !recentRows.isEmpty { separator }
                        grid(appRows)
                            .padding(.bottom, 10)
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel(loc("Applications"))
                    }
                    if !listRows.isEmpty {
                        if !recentRows.isEmpty || !appRows.isEmpty { separator }
                        // One name for the catch-all in both modes, the way Spotlight has a
                        // single "Altro": below this line are the utilities while browsing,
                        // and the file hits once a term is typed.
                        header(loc("Other"))
                        LazyVStack(spacing: 2) {
                            ForEach(listRows) { row(model: $0) }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    }
                }
                .padding(.top, Self.topPad)
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .animation(.spring(response: 0.26, dampingFraction: 0.78), value: search.selection)
            .onChange(of: search.selection) { _, new in
                proxy.scrollTo(new)
            }
        }
    }

    /// Snapped to whole rows and whole grid lines, so neither section ends half-drawn.
    private var resultsHeight: CGFloat {
        var height = Self.topPad
        // Every section but the first is preceded by a separator, so this tracks whether
        // one has already been drawn.
        var following = false
        if search.recentCount > 0 {
            height += Self.cellHeight - Self.cellGap // always one row
            following = true
        }
        if appGridCount > 0 {
            if following { height += Self.separatorBlock }
            let lines = (appGridCount + Self.columns - 1) / Self.columns
            height += CGFloat(min(lines, 4)) * Self.cellHeight + 10 - Self.cellGap
            following = true
        }
        if listCount > 0 {
            if following { height += Self.separatorBlock }
            height += Self.headerHeight + CGFloat(min(listCount, 5)) * Self.rowHeight + 8
        }
        // The window is a fixed size now, so the slab cannot grow past what fits in it.
        return min(height, 452)
    }

    private static let headerHeight: CGFloat = 26
    private static let topPad: CGFloat = 12
    /// The rule plus the padding around it, which `resultsHeight` has to account for.
    private static let separatorBlock: CGFloat = 13

    /// A hairline between sections, not a hard rule: the panel is one surface. Faded at
    /// both ends, so it reads as light caught inside the glass rather than a line on it.
    private var separator: some View {
        Rectangle()
            .fill(LinearGradient(colors: [.clear, .primary.opacity(0.22), .clear],
                                 startPoint: .leading, endPoint: .trailing))
            .frame(height: 1)
            .padding(.horizontal, 28)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }

    private func header(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .frame(height: Self.headerHeight, alignment: .leading)
    }

    private var launching: Bool { search.launching != nil }

    /// Everything that was not chosen steps back while the app comes up, so the one that
    /// was reads as picked rather than as merely still there.
    private func dimmed(_ selected: Bool) -> Double {
        launching && !selected ? 0.3 : 1
    }

    /// The selection is a lens: a lighter, brighter pane of the same glass, lifted a
    /// little off the slab, with the writing on it left as it was. A block of accent colour
    /// sat ON the glass like a sticker. Reduce Transparency keeps the solid accent — with
    /// the glass gone there is nothing for a lens to be made of.
    private var lens: Bool { !search.reduceTransparency }

    /// One highlight shared through the namespace, so moving the selection slides it.
    @ViewBuilder
    private func highlight(_ selected: Bool, cornerRadius: CGFloat) -> some View {
        if selected {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            Group {
                if lens {
                    shape.fill(.white.opacity(0.22))
                        .overlay { shape.strokeBorder(Self.specular, lineWidth: 1) }
                        .shadow(color: .black.opacity(0.14), radius: 10, y: 5)
                } else {
                    shape.fill(accent)
                }
            }
            .matchedGeometryEffect(id: "selection", in: ns)
        }
    }

    /// White on the accent block; on the lens the writing keeps its own colour.
    private func onHighlight(_ selected: Bool) -> Bool { selected && !lens }

    @ViewBuilder
    private func icon(_ icon: RowIcon, size: CGFloat, selected: Bool) -> some View {
        switch icon {
        case let .file(path):
            Image(nsImage: Icons.icon(forPath: path))
                .resizable().frame(width: size, height: size)
        case let .symbol(name):
            Image(systemName: name)
                .font(.system(size: size * 0.66))
                .frame(width: size, height: size)
                .foregroundStyle(onHighlight(selected) ? AnyShapeStyle(.white) : AnyShapeStyle(accent))
        }
    }

    // ponytail: the selection lens is a translucent fill, NOT glass. Glass cannot
    // sample glass, so nesting a second glass layer inside the slab renders wrong.
    private func cell(model: RowModel) -> some View {
        let selected = model.id == search.selection
        let content = VStack(spacing: 7) {
            // 72, not 57: a macOS app icon carries about 20% transparent margin inside its
            // canvas, so the glyph you actually see is ~0.8 of the frame. Spotlight shows a
            // 57pt glyph, which is this frame.
            icon(model.icon, size: 72, selected: selected)
                // Scales one icon, well inside the slab. Scaling anything that *contains*
                // the glass would rasterise it and cost the edge refraction.
                //
                // Launching is the same gesture, further: the chosen icon springs once
                // while everything around it steps back. The previous version grew the
                // highlight into a slab-sized rectangle of accent colour, which covered
                // half the grid on its way out and read as a rendering fault.
                .scaleEffect(selected ? (launching ? 1.24 : 1.06) : 1)
                .animation(.spring(response: 0.28, dampingFraction: 0.62), value: selected)
                .animation(.spring(response: 0.24, dampingFraction: 0.55), value: search.launching)
            Text(model.title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .lineLimit(2).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: Self.cellWidth - 10, height: Self.cellHeight - Self.cellGap)
        return selectable(content, model, selected: selected, cornerRadius: 26)
    }

    /// What a grid cell and a list row have in common once laid out: the colour that
    /// flips on the highlight, the highlight itself, the dimming during a launch, and a
    /// hit area and scroll id covering the whole thing.
    private func selectable<V: View>(_ content: V, _ model: RowModel, selected: Bool,
                                     cornerRadius: CGFloat) -> some View {
        content
            .foregroundStyle(onHighlight(selected) ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background { highlight(selected, cornerRadius: cornerRadius) }
            .opacity(dimmed(selected))
            .animation(.easeOut(duration: 0.16), value: search.launching)
            .contentShape(Rectangle()) // hit-testing covers the row, not just the text
            .id(model.id)
            .onTapGesture { search.selection = model.id; activate() }
    }

    private func row(model: RowModel) -> some View {
        let selected = model.id == search.selection
        let content = HStack(spacing: 12) {
            icon(model.icon, size: 30, selected: selected)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                // Prettified here, for the handful of rows on screen, rather than for
                // every hit in the list.
                Text(model.subtitle ?? model.path.map { prettyPath($0) } ?? "")
                    .font(.system(size: 11)).lineLimit(1)
                    .foregroundStyle(onHighlight(selected) ? AnyShapeStyle(.white.opacity(0.75))
                                                           : AnyShapeStyle(.secondary))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.rowHeight - 2)
        return selectable(content, model, selected: selected, cornerRadius: 16)
    }

    // MARK: Actions

    private func move(_ delta: Int) -> KeyPress.Result {
        let count = search.rowCount
        guard count > 0 else { return .ignored }
        search.selection = wrap(search.selection, by: delta, count: count)
        return .handled
    }

    /// An app is LAUNCHED, not opened as an item. Through `open(_:)` the bundle is handled
    /// like any document, and on the way LaunchServices, inside this process, tries to
    /// write into it — most likely the last-used metadata Finder keeps on opened items.
    /// For a bundle the user owns (Prism Launcher) that is a write into another app, and
    /// macOS stops it with "SpotVibe was prevented from modifying apps on your Mac".
    /// Seen in the TCC log before the target process had even started; gone with this.
    private func open(_ url: URL) {
        guard url.pathExtension == "app" else { NSWorkspace.shared.open(url); return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func activate() {
        guard search.rowCount > 0 else { return }
        if search.webRowSelected {
            // The system exposes no API for the browser's own choice of engine, so it is a
            // setting. NSWorkspace still routes the URL to whichever browser is default.
            if let url = settings.engine.url(for: search.text) {
                NSWorkspace.shared.open(url)
            }
        } else if let hit = search.selectedHit {
            // Already on its way: a second Return inside the animation window would
            // otherwise queue a second launch of the same app.
            guard search.launching == nil else { return }
            search.record(hit)
            search.launching = hit.id
            // Let the pop play, then launch and dismiss. Esc or a click outside during those
            // 190 ms runs reset(), which cancels this — and then the app must not launch.
            search.launchTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(190))
                guard !Task.isCancelled else { return }
                open(hit.url)
                onClose()
            }
            return
        }
        onClose()
    }

}
