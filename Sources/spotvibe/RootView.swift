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
    private var focused: Bool {
        get { _focused.wrappedValue }
        nonmutating set { _focused.wrappedValue = newValue }
    }

    private var _ns = Namespace()

    private var query: Binding<String> {
        Binding(get: { search.text }, set: { search.text = $0 })
    }

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
    /// window would jolt the panel on every frame of the entrance spring.
    static let panelSize = CGSize(width: panelWidth + outerPadding * 2, height: 850)
    /// Where the panel sits, measured from the top of the screen.
    private static let topInset: CGFloat = 188
    private static let gap: CGFloat = 26
    private static let fieldHeight: CGFloat = 56

    /// The entrance: the slabs spring from slightly under full size up to it, overshooting
    /// once on a lightly damped spring. Done with the FRAME, never with scaleEffect — a
    /// transform forces the subtree offscreen and the glass stops sampling the live
    /// backdrop, which is the whole effect.
    private static let openScale: CGFloat = 0.94
    private var scale: CGFloat {
        search.opened || search.reduceMotion ? 1 : Self.openScale
    }

    /// A capsule: radius is half the height, so the ends are true semicircles. Spotlight's
    /// field is one, and at 28 mine read as a rounded box next to it.
    private var fieldShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.fieldHeight * scale / 2, style: .continuous)
    }
    /// 40, not 26. Lensing happens at the rim, and on a slab this size the rim is a
    /// hairline around a large frosted field — a wider curve puts more of the edge at an
    /// angle where it actually bends what is behind it.
    private var listShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 40, style: .continuous)
    }

    /// The live system accent. Color.accentColor resolves to the asset-catalog accent and
    /// only falls back to the system one, so it is not the same guarantee.
    private var accent: Color {
        _ = search.appearanceToken // re-resolve when System Settings changes the accent
        return Color(nsColor: .controlAccentColor)
    }

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
        return .regular.tint(accent.opacity(0.16 * search.glassTint)).interactive()
    }

    private var solidFallback: AnyShapeStyle {
        search.reduceTransparency ? AnyShapeStyle(.windowBackground) : AnyShapeStyle(.clear)
    }

    /// A hairline just inside the rim. The glass draws its own edge, but over a busy or
    /// low-contrast backdrop that edge washes out and the slab loses its outline. `.primary`
    /// so it inverts with the appearance, and `strokeBorder` so the line sits inside the
    /// shape instead of straddling it. An overlay composites above the glass — it does not
    /// filter the subtree, so the backdrop sampling underneath is untouched.
    private func rim(_ shape: RoundedRectangle) -> some View {
        shape.strokeBorder(.primary.opacity(0.10), lineWidth: 0.5)
    }

    /// Two glass slabs in one container sharing a namespace: they sample the same backdrop
    /// and lens into each other across the gap, which is where the Liquid Glass distortion
    /// actually comes from. A single flat slab shows almost none of it.
    var body: some View {
        ZStack(alignment: .top) {
            // Clicking the margin dismisses, the way clicking outside the panel does. The
            // window is deliberately larger than the glass, so without this the transparent
            // area around it would swallow those clicks.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)

            GlassEffectContainer(spacing: 0) {
                VStack(spacing: Self.gap) {
                    field
                        // Animating a frame is layout, not a transform: it does not force
                        // the subtree offscreen the way scaleEffect would, so the glass
                        // keeps sampling the live backdrop through the whole entrance.
                        .frame(width: Self.panelWidth * scale, height: Self.fieldHeight * scale)
                        .background(solidFallback, in: fieldShape)
                        .glassEffect(glass, in: fieldShape)
                        .overlay { rim(fieldShape) }
                        .glassEffectID("field", in: _ns.wrappedValue)

                    if search.rowCount > 0, search.expanded {
                        results
                            .frame(width: Self.panelWidth * scale, height: resultsHeight * scale)
                            // Clipped to the slab, and clipped BEFORE the glass: a selected
                            // cell scrolled past the rounded edge was drawing outside the
                            // panel. Applied after .glassEffect it would clip the glass
                            // layer itself, which rasterises it offscreen and costs the
                            // backdrop sampling.
                            .clipShape(listShape)
                            .background(solidFallback, in: listShape)
                            .glassEffect(glass, in: listShape)
                            .overlay { rim(listShape) }
                            .glassEffectID("results", in: _ns.wrappedValue)
                    }
                }
                .padding(.horizontal, Self.outerPadding)
                .padding(.top, Self.topInset)
            }
            // Lightly damped, and the overshoot IS the elastic: the slabs run just past
            // full size and settle back.
            .animation(.spring(response: 0.34, dampingFraction: 0.62), value: search.opened)
        }
        .frame(width: Self.panelSize.width, height: Self.panelSize.height, alignment: .top)
        // Nothing here wraps the glass container in opacity, blur, scale or shadow. Every
        // one of those forces the subtree offscreen, and a glass layer that renders
        // offscreen stops sampling the live backdrop — it degrades to a flat blur with no
        // rim refraction. Present and dismiss are animated on the NSPanel, in AppShell.
        .onAppear { focused = true }
        // The hosting view outlives every hide, so re-show has to re-assert focus itself.
        .onChange(of: search.focusToken) { _, _ in focused = true }
        .onExitCommand(perform: onClose)
        .task(id: search.text) {
            // `try?` here would swallow the cancellation and run the search anyway,
            // firing once per keystroke — the exact thrash this debounce exists to stop.
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            search.run(search.text)
        }
    }

    private var field: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(loc("Search apps and files"), text: query)
                .textFieldStyle(.plain)
                .font(.system(size: 19, weight: .regular))
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

    private enum RowIcon { case file(URL), symbol(String) }

    private struct RowModel: Identifiable {
        let id: Int
        let icon: RowIcon
        let title: String
        let subtitle: String
    }

    /// One list built in one pass, so row identities can never collide between renders
    /// and the web row can never disagree with `rowCount` about whether it exists.
    private var rows: [RowModel] {
        var out = search.hits.enumerated().map { index, hit in
            RowModel(id: index, icon: .file(hit.url), title: hit.name, subtitle: prettyPath(hit.id))
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
        guard down else { return Self.columns }
        return min(Self.columns, search.appCount - search.selection)
    }

    /// Section sizes, read straight off the counts rather than off `rows`. Building the row
    /// models is O(hits) with a `prettyPath` per row, and `body` can run many times per
    /// frame during the entrance — so nothing that only needs a COUNT is allowed to build
    /// them. `results` materialises the models exactly once and slices that one array.
    private var appGridCount: Int { search.appCount - search.recentCount }
    private var listCount: Int { search.rowCount - search.appCount }

    private func grid(_ models: [RowModel]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.cellWidth), spacing: 0),
                                 count: Self.columns), spacing: Self.cellGap) {
            ForEach(models) { cell(model: $0) }
        }
    }

    private var results: some View {
        // Built once here, then sliced. Going through the `rows` getter per section would
        // rebuild the whole array for every access, several times per body evaluation.
        let all = rows
        let recentRows = Array(all.prefix(search.recentCount))
        let appRows = Array(all.dropFirst(search.recentCount).prefix(appGridCount))
        let listRows = Array(all.dropFirst(search.appCount))

        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !recentRows.isEmpty {
                        header(loc("Recent"))
                        grid(recentRows)
                    }
                    if !appRows.isEmpty {
                        if !recentRows.isEmpty { separator }
                        header(loc("Applications"))
                        grid(appRows)
                            .padding(.bottom, 10)
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
                .padding(.top, 4)
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .overlay {
                if search.launching != nil {
                    // The same matched highlight, now the size of the slab: it grows out of
                    // the chosen cell and floods the panel as the app comes up.
                    listShape.fill(accent)
                        .matchedGeometryEffect(id: "selection", in: _ns.wrappedValue)
                        .allowsHitTesting(false)
                }
            }
            .animation(.spring(response: 0.26, dampingFraction: 0.78), value: search.selection)
            .animation(.spring(response: 0.34, dampingFraction: 0.82), value: search.launching)
            .onChange(of: search.selection) { _, new in
                proxy.scrollTo(new)
            }
        }
    }

    /// Snapped to whole rows and whole grid lines, so neither section ends half-drawn.
    private var resultsHeight: CGFloat {
        var height: CGFloat = 4
        // Every section but the first is preceded by a separator, so this tracks whether
        // one has already been drawn.
        var following = false
        if search.recentCount > 0 {
            height += Self.headerHeight + Self.cellHeight - Self.cellGap // always one row
            following = true
        }
        if appGridCount > 0 {
            if following { height += Self.separatorBlock }
            let lines = (appGridCount + Self.columns - 1) / Self.columns
            height += Self.headerHeight + CGFloat(min(lines, 4)) * Self.cellHeight + 10 - Self.cellGap
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
    /// The rule plus the padding around it, which `resultsHeight` has to account for.
    private static let separatorBlock: CGFloat = 13

    /// A hairline between sections, not a hard rule: the panel is one surface.
    private var separator: some View {
        Divider()
            .opacity(0.6)
            .padding(.horizontal, 18)
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

    /// One highlight rect shared through the namespace, so moving the selection slides it.
    @ViewBuilder
    private func highlight(_ selected: Bool, cornerRadius: CGFloat) -> some View {
        // While launching, the single matched highlight belongs to the overlay instead,
        // which is what makes it grow from this cell to fill the slab.
        if selected, search.launching == nil {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(accent)
                .matchedGeometryEffect(id: "selection", in: _ns.wrappedValue)
        }
    }

    @ViewBuilder
    private func icon(_ icon: RowIcon, size: CGFloat, selected: Bool) -> some View {
        switch icon {
        case let .file(url):
            Image(nsImage: Icons.icon(forPath: url.path))
                .resizable().frame(width: size, height: size)
        case let .symbol(name):
            Image(systemName: name)
                .font(.system(size: size * 0.66))
                .frame(width: size, height: size)
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(accent))
        }
    }

    // ponytail: the selection highlight is a plain tinted rect, NOT glass. Glass cannot
    // sample glass, so nesting a second glass layer inside the slab renders wrong.
    private func cell(model: RowModel) -> some View {
        let selected = model.id == search.selection
        return VStack(spacing: 7) {
            // 72, not 57: a macOS app icon carries about 20% transparent margin inside its
            // canvas, so the glyph you actually see is ~0.8 of the frame. Spotlight shows a
            // 57pt glyph, which is this frame.
            icon(model.icon, size: 72, selected: selected)
                // Scales one icon, well inside the slab. Scaling anything that *contains*
                // the glass would rasterise it and cost the edge refraction.
                .scaleEffect(selected ? 1.06 : 1)
                .animation(.spring(response: 0.28, dampingFraction: 0.62), value: selected)
            Text(model.title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .lineLimit(2).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .frame(width: Self.cellWidth - 10, height: Self.cellHeight - Self.cellGap)
        .background { highlight(selected, cornerRadius: 14) }
        .contentShape(Rectangle())
        .id(model.id)
        .onTapGesture { search.selection = model.id; activate() }
    }

    private func row(model: RowModel) -> some View {
        let selected = model.id == search.selection
        return HStack(spacing: 12) {
            icon(model.icon, size: 30, selected: selected)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text(model.subtitle).font(.system(size: 11)).lineLimit(1)
                    .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.secondary))
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 12)
        .frame(height: Self.rowHeight - 2)
        .background { highlight(selected, cornerRadius: 10) }
        .contentShape(Rectangle()) // hit-testing covers the row, not just the text
        .id(model.id)
        .onTapGesture { search.selection = model.id; activate() }
    }

    // MARK: Actions

    private func move(_ delta: Int) -> KeyPress.Result {
        let count = search.rowCount
        guard count > 0 else { return .ignored }
        search.selection = wrap(search.selection, by: delta, count: count)
        return .handled
    }

    private func activate() {
        guard search.rowCount > 0 else { return }
        if search.webRowSelected {
            let term = search.text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            // ponytail: the system exposes no API for the browser's chosen search engine,
            // so the engine is hardcoded. NSWorkspace still routes it to the default browser.
            if let url = URL(string: "https://duckduckgo.com/?q=\(term)") {
                NSWorkspace.shared.open(url)
            }
        } else if let hit = search.selectedHit {
            search.record(hit)
            search.launching = hit.id
            // Let the flood play, then launch and dismiss.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.19) {
                NSWorkspace.shared.open(hit.url)
                onClose()
            }
            return
        }
        onClose()
    }

}
