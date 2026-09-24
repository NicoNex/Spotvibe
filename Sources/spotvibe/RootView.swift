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

    private static let columns = 7
    private static let cellWidth: CGFloat = 114
    private static let cellHeight: CGFloat = 132
    private static let cellGap: CGFloat = 8
    private static let rowHeight: CGFloat = 48
    private static let panelWidth = cellWidth * CGFloat(columns)
    private static let outerPadding: CGFloat = 34
    /// The window is a FIXED size and the content moves inside it. A window resize is a
    /// single AppKit step that cannot agree with a SwiftUI interpolation, so animating the
    /// gap in a self-sizing window would jolt the panel on every frame of the separation.
    static let panelSize = CGSize(width: panelWidth + outerPadding * 2, height: 660)
    /// Past `mergeDistance`, so the bridge has snapped and the two are plainly apart.
    private static let restingGap: CGFloat = 26
    /// Deep overlap: at rest the two droplets are one body, and the union has a single
    /// silhouette to draw. Pulling apart takes them through the thinning bridge on the way.
    private static let mergedGap: CGFloat = -178
    /// How far apart two glass shapes still count as one body.
    private static let mergeDistance: CGFloat = 20
    /// While they are still droplets they stand further apart than they will as panels, so
    /// the moment of being TWO of them is unmistakable before either starts to stretch.
    private static let splitGap: CGFloat = 54
    private static let fieldHeight: CGFloat = 92
    /// The two droplets the panel is born as: a small one above, a larger one below.
    private static let fieldDrop: CGFloat = 150
    private static let listDrop: CGFloat = 212

    /// Phase one: 0 = the two droplets sit inside each other as a single drop, 1 = they
    /// are apart. Only the gap reads from this.
    private var split: CGFloat { search.separated ? 1 : 0 }
    /// Phase two: 0 = still round droplets, 1 = the search bar and the panel.
    private var shape: CGFloat { search.shaped ? 1 : 0 }

    private func lerp(_ drop: CGFloat, _ panel: CGFloat, _ t: CGFloat) -> CGFloat {
        drop + (panel - drop) * t
    }

    /// The gap the separation hangs on. `glassEffectUnion` merges two glass shapes by
    /// proximity, so pulling them apart makes the system's own bridge between them thin
    /// out and snap — there is no hand-drawn neck anywhere in here.
    private var gap: CGFloat {
        lerp(Self.mergedGap, lerp(Self.splitGap, Self.restingGap, shape), split)
    }

    private var fieldSize: CGSize {
        CGSize(width: lerp(Self.fieldDrop, Self.panelWidth, shape),
               height: lerp(Self.fieldDrop, Self.fieldHeight, shape))
    }

    private var listSize: CGSize {
        CGSize(width: lerp(Self.listDrop, Self.panelWidth, shape),
               height: lerp(Self.listDrop, resultsHeight, shape))
    }

    /// Fully round while it is a droplet, settling to the panel's own radius.
    private var fieldShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: lerp(Self.fieldDrop / 2, 28, shape), style: .continuous)
    }

    private var listShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: lerp(Self.listDrop / 2, 26, shape), style: .continuous)
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
        // A droplet is nearly all backdrop: .clear is the transparent member of the family,
        // and it takes no tint, so the drop reads as a lens rather than a panel. .opacity()
        // is not an option here — it forces the subtree offscreen and the glass stops
        // sampling the live backdrop, which is the whole effect.
        guard search.shaped else { return .clear.interactive() }
        // interactive() is the one thing macOS 27 added to the material (AppKit spells it
        // NSGlassEffectView.effectIsInteractive, API_AVAILABLE(macos(27.0))): the glass
        // answers the light with a live specular response instead of a static sheen, which
        // is most of what makes the rim read as a solid edge rather than a drawn outline.
        // The tint is deliberately slight — pigment fills the specular in and flattens it.
        return .regular.tint(accent.opacity(0.07 * search.glassTint)).interactive()
    }

    private var solidFallback: AnyShapeStyle {
        search.reduceTransparency ? AnyShapeStyle(.windowBackground) : AnyShapeStyle(.clear)
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

            GlassEffectContainer(spacing: Self.mergeDistance) {
                VStack(spacing: gap) {
                    field
                        // Animating a frame is layout, not a transform: it does not force
                        // the subtree offscreen the way scaleEffect would, so the glass
                        // keeps sampling the live backdrop all the way through the morph.
                        .frame(width: fieldSize.width, height: fieldSize.height)
                        .background(solidFallback, in: fieldShape)
                        .glassEffect(glass, in: fieldShape)
                        .glassEffectID("field", in: _ns.wrappedValue)
                        .glassEffectUnion(id: "panel", namespace: _ns.wrappedValue)
                        .glassEffectTransition(.matchedGeometry)

                    if search.rowCount > 0, search.expanded {
                        results
                            .frame(width: listSize.width, height: listSize.height)
                            .background(solidFallback, in: listShape)
                            .glassEffect(glass, in: listShape)
                            .glassEffectID("results", in: _ns.wrappedValue)
                            .glassEffectUnion(id: "panel", namespace: _ns.wrappedValue)
                            .glassEffectTransition(.matchedGeometry)
                    }
                }
                .padding(Self.outerPadding)
            }
            // Two springs, both lightly damped, and the overshoot IS the bounce: each value
            // runs past its resting point and settles back, the way liquid rebounds after
            // letting go. The split is the springier of the two, since that is the moment
            // the bridge between the droplets snaps.
            .animation(.spring(response: 0.48, dampingFraction: 0.46), value: search.separated)
            .animation(.spring(response: 0.52, dampingFraction: 0.62), value: search.shaped)
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
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Cerca app e file", text: query)
                .textFieldStyle(.plain)
                .font(.system(size: 25, weight: .regular))
                .foregroundStyle(.primary)
                .focused(_focused.projectedValue)
                .onSubmit(activate)
                .onKeyPress(.leftArrow) { move(-1) }
                .onKeyPress(.rightArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-step) }
                .onKeyPress(.downArrow) { move(step) }
        }
        .padding(.horizontal, 24)
        .frame(height: Self.fieldHeight)
        .opacity(search.contentVisible ? 1 : 0)
        .animation(.smooth(duration: 0.3), value: search.contentVisible)
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
                                title: "Cerca «\(search.text)» sul web",
                                subtitle: "Apre il browser predefinito"))
        }
        return out
    }

    /// Moving inside the app grid steps by a whole row; moving in the file list steps by one.
    private var step: Int { search.selection < search.appCount ? Self.columns : 1 }

    private var appRows: [RowModel] { Array(rows.prefix(search.appCount)) }
    private var fileRows: [RowModel] { Array(rows.dropFirst(search.appCount)) }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !appRows.isEmpty {
                        header("Applicazioni")
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.cellWidth), spacing: 0),
                                                 count: Self.columns), spacing: Self.cellGap) {
                            ForEach(appRows) { cell(model: $0) }
                        }
                        .padding(.bottom, 10)
                    }
                    if !fileRows.isEmpty {
                        if !appRows.isEmpty { header("Altri risultati") }
                        LazyVStack(spacing: 2) {
                            ForEach(fileRows) { row(model: $0) }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    }
                }
                .padding(.top, 4)
                // Inside the glass, so this touches the content and not the glass layer.
                .opacity(search.contentVisible ? 1 : 0)
                .blur(radius: search.contentVisible ? 0 : 7)
                .offset(y: search.contentVisible ? 0 : 12)
                .animation(.smooth(duration: 0.34), value: search.contentVisible)
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: resultsHeight)
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
        if !appRows.isEmpty {
            let lines = (appRows.count + Self.columns - 1) / Self.columns
            height += Self.headerHeight + CGFloat(min(lines, 4)) * Self.cellHeight + 10 - Self.cellGap
        }
        if !fileRows.isEmpty {
            if !appRows.isEmpty { height += Self.headerHeight }
            height += CGFloat(min(fileRows.count, 5)) * Self.rowHeight + 8
        }
        // The window is a fixed size now, so the slab cannot grow past what fits in it.
        return min(height, 452)
    }

    private static let headerHeight: CGFloat = 26

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
            search.separated = false // the panel flows back into one body as it swallows the pick
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
