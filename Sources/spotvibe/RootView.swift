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
    /// Tall enough to reach from the top edge of the screen — the notch — down past the
    /// panel's resting place, because the drop falls that whole way inside this window.
    static let panelSize = CGSize(width: panelWidth + outerPadding * 2, height: 850)
    /// Where the panel comes to rest, measured from the top of the screen. Chosen so the
    /// drop lands around the middle of the display rather than up under the notch.
    private static let restingTop: CGFloat = 188
    /// How much the drop swells in the instant before it bursts.
    private static let popSwell: CGFloat = 1.26

    // The hanging drop, while it is still a drop. One glass shape, authored by PendantDrop,
    // rather than two shapes the union tries to bridge — see that file for why.
    private var dropTopRadius: CGFloat { lerp(Self.listDrop / 2, Self.neckBead / 2, drip) * pop }
    private var dropBottomRadius: CGFloat { Self.listDrop / 2 * pop }
    /// From "as wide as the drop" (no neck at all, just one ball) down to nothing.
    private var dropWaist: CGFloat { lerp(Self.listDrop / 2, 0, drip) * pop }
    private var dropWidth: CGFloat { Self.listDrop * pop }
    private var dropHeight: CGFloat { lerp(Self.listDrop, Self.fallGap + Self.listDrop, drip) * pop }

    /// The bar's outline once it is a bar; the whole pendant drop before that.
    private var fieldGlassShape: AnyShape {
        guard !search.shaped else { return AnyShape(fieldShape) }
        return AnyShape(PendantDrop(topRadius: dropTopRadius,
                                    bottomRadius: dropBottomRadius,
                                    waist: dropWaist))
    }
    /// How far the lower droplet descends while the upper one is still held in the notch.
    /// This is the neck: the union's bridge spans it, thinning as the gap opens, and snaps
    /// once the gap passes the merge distance.
    private static let fallGap: CGFloat = 286
    /// Where the drop starts: tucked up behind the notch, so it is seen seeping out of it.
    /// Negative, so the window clips it and only the emerging part shows.
    private static let notchTop: CGFloat = -96
    /// Past `mergeDistance`, so the bridge has snapped and the two are plainly apart.
    private static let restingGap: CGFloat = 26
    /// Barely drawn out at all. The corner radius is half the WIDTH, so any real
    /// difference between the two turns the droplet into a vertical capsule instead of a
    /// ball — which is exactly what it looked like. A falling drop is an egg, not a pill.
    private static let hangingWidth: CGFloat = 0.96
    private static let hangingHeight: CGFloat = 1.08
    /// How far apart two glass shapes still count as one body — the container's spacing,
    /// and the thing that decides how long the neck between them lasts. The system draws
    /// its bridge only while the gap is under this, so it has to span whatever is being
    /// crossed at the time: at 76 against a 286pt fall the neck vanished after the first
    /// quarter, which is why it never looked like it was thinning.
    private static let fallMerge: CGFloat = 340
    private static let splitMerge: CGFloat = 96
    /// Must stay under `restingGap`, or the two settle back into one body.
    private static let restingMerge: CGFloat = 6

    private var mergeDistance: CGFloat {
        if search.shaped { return Self.restingMerge }
        return search.separated ? Self.splitMerge : Self.fallMerge
    }
    /// While they are still droplets they stand further apart than they will as panels, so
    /// the moment of being TWO of them is unmistakable before either starts to stretch.
    private static let splitGap: CGFloat = 108
    private static let fieldHeight: CGFloat = 74
    /// The two droplets the panel is born as: a small one above, a larger one below.
    private static let fieldDrop: CGFloat = 128
    private static let listDrop: CGFloat = 232

    /// Phase zero: 0 = hanging in the notch, drawn out; 1 = landed and round.
    private var drip: CGFloat { search.dripped ? 1 : 0 }
    /// Phase one: 0 = the two droplets sit inside each other as a single drop, 1 = they
    /// are apart. Only the gap reads from this.
    private var split: CGFloat { search.separated ? 1 : 0 }
    /// Phase two: 0 = still round droplets, 1 = the search bar and the panel.
    private var shape: CGFloat { search.shaped ? 1 : 0 }

    private func lerp(_ drop: CGFloat, _ panel: CGFloat, _ t: CGFloat) -> CGFloat {
        drop + (panel - drop) * t
    }

    /// Surface tension gives out all at once: the drop swells for an instant, then goes.
    private var pop: CGFloat { search.popping ? Self.popSwell : 1 }

    private var dropW: CGFloat { lerp(Self.hangingWidth, 1, drip) * pop }
    private var dropH: CGFloat { lerp(Self.hangingHeight, 1, drip) * pop }

    /// What is left hanging at the notch once the mass has flowed down.
    private static let neckBead: CGFloat = 52

    /// While it is one drop the upper droplet is the SAME size as the lower one, so the two
    /// coincide exactly and their union is precisely that circle — two concentric circles
    /// of different diameters get unioned into a superellipse instead, which is where the
    /// rounded-square look came from.
    ///
    /// Then, as the lower one falls away, this one EMPTIES into it. That is what makes the
    /// neck thin: the system's bridge is no wider than the smaller of the two shapes it
    /// spans, so a top that is draining pinches the column off. Moving the two ends further
    /// apart, on its own, only makes a longer column of the same width — which is exactly
    /// what it looked like.
    private var upperDrop: CGFloat { lerp(Self.listDrop, Self.neckBead, drip) }

    private var mergedGap: CGFloat { -(upperDrop + Self.listDrop) * dropH / 2 }

    /// The union exists only for the morph. Left on at rest it fuses the two into a single
    /// slab and the search bar stops reading as a search bar, so once they are shaped they
    /// go back to being two independent bodies of glass.
    private var unionID: String? { search.shaped ? nil : "panel" }

    /// The gap the separation hangs on. `glassEffectUnion` merges two glass shapes by
    /// proximity, so pulling them apart makes the system's own bridge between them thin
    /// out and snap — there is no hand-drawn neck anywhere in here.
    private var gap: CGFloat {
        // Three stages in one expression: merged inside each other, then pulled apart by
        // the fall — that stretch is the neck — then closed up to the resting gap as the
        // droplets become the bar and the panel.
        let fallen = lerp(mergedGap, Self.fallGap, drip)
        let apart = lerp(fallen, Self.splitGap, split)
        return lerp(apart, Self.restingGap, shape)
    }

    /// The fall. The window's top edge sits on the top edge of the screen, so a negative
    /// inset puts the drop behind the notch and the window clips whatever is still up
    /// there — it seeps out, falls, and settles where the panel belongs.
    private var dripOffset: CGFloat {
        // Driven by `shape`, not by `drip`: through the whole fall the upper droplet stays
        // up in the notch and only the lower one descends. That is what leaves a neck
        // between them — and it costs no third glass shape, which is the one thing that
        // reliably pins the main thread inside NSHostingView's key-view walk.
        return lerp(Self.notchTop, Self.restingTop, shape)
    }

    private var fieldSize: CGSize {
        CGSize(width: lerp(upperDrop * dropW, Self.panelWidth, shape),
               height: lerp(upperDrop * dropH, Self.fieldHeight, shape))
    }

    private var listSize: CGSize {
        CGSize(width: lerp(Self.listDrop * dropW, Self.panelWidth, shape),
               height: lerp(Self.listDrop * dropH, resultsHeight, shape))
    }

    /// A true circle while it is a droplet, settling to the panel's own radius.
    ///
    /// The style has to swap on the way. `.continuous` is Apple's squircle and never
    /// reaches a circle: at half the side it still reads as a rounded square, which is
    /// what made the droplet look boxy. `.circular` at half the side is an actual circle.
    /// The swap happens once the shape has elongated enough for the two to be
    /// indistinguishable, so the panel still rests on the squircle everything else uses.
    private func dropletShape(side: CGFloat, radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: lerp(side * dropW / 2, radius, shape),
                         style: shape < 0.45 ? .circular : .continuous)
    }

    /// A capsule: radius is half the height, so the ends are true semicircles. Spotlight's
    /// field is one, and at 28 mine read as a rounded box next to it.
    private var fieldShape: RoundedRectangle {
        dropletShape(side: upperDrop, radius: Self.fieldHeight / 2)
    }
    /// 40, not 26. Lensing happens at the rim, and on a slab this size the rim is a
    /// hairline around a large frosted field — a wider curve puts more of the edge at an
    /// angle where it actually bends what is behind it.
    private var listShape: RoundedRectangle { dropletShape(side: Self.listDrop, radius: 40) }

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
        // A droplet is nearly all backdrop: .clear is the transparent member of the family
        // and takes no tint, so it reads as a lens. .opacity() is not an option here — it
        // forces the subtree offscreen and the glass stops sampling the live backdrop,
        // which is the whole effect.
        guard search.shaped else { return .clear.interactive() }
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

            // The spacing IS the merge distance, and it merges nearby glass whether or not
            // a union id is set — so a wide one left in place refused the bar and the panel
            // back into a single slab at rest. Wide only while they are coming apart.
            GlassEffectContainer(spacing: mergeDistance) {
                VStack(spacing: gap) {
                    field
                        // Animating a frame is layout, not a transform: it does not force
                        // the subtree offscreen the way scaleEffect would, so the glass
                        // keeps sampling the live backdrop all the way through the morph.
                        .frame(width: search.shaped ? fieldSize.width : dropWidth,
                               height: search.shaped ? fieldSize.height : dropHeight)
                        .background(solidFallback, in: fieldGlassShape)
                        .glassEffect(glass, in: fieldGlassShape)
                        .glassEffectID("field", in: _ns.wrappedValue)
                        .glassEffectUnion(id: unionID, namespace: _ns.wrappedValue)
                        .glassEffectTransition(.matchedGeometry)

                    if search.rowCount > 0, search.expanded, search.shaped {
                        results
                            .frame(width: listSize.width, height: listSize.height)
                            .background(solidFallback, in: listShape)
                            .glassEffect(glass, in: listShape)
                            .glassEffectID("results", in: _ns.wrappedValue)
                            .glassEffectUnion(id: unionID, namespace: _ns.wrappedValue)
                            .glassEffectTransition(.matchedGeometry)
                    }
                }
                .padding(.horizontal, Self.outerPadding)
                .padding(.top, dripOffset)
            }
            // Two springs, both lightly damped, and the overshoot IS the bounce: each value
            // runs past its resting point and settles back, the way liquid rebounds after
            // letting go. The split is the springier of the two, since that is the moment
            // the bridge between the droplets snaps.
            // Three beats, three springs, each given room to be seen. Driven together they
            // cancel out: the drop is already a slab by the time the gap opens.
            // Low damping on the landing so the drop wobbles as it settles, the way a real
            // one does. tempo only stretches it for debugging; it is 1 by default.
            .animation(.spring(response: 0.34 * Controller.tempo, dampingFraction: 0.48), value: search.dripped)
            // easeOut and short: a bubble stretches for a moment and lets go. A spring
            // would bring it back, which is the one thing a burst never does.
            .animation(.easeOut(duration: 0.13 * Controller.tempo), value: search.popping)
            // Smoother than the rest on purpose: the neck has to be seen thinning, and a
            // snappy spring crosses the whole merge distance before the eye catches it.
            .animation(.spring(response: 0.38 * Controller.tempo, dampingFraction: 0.62), value: search.separated)
            .animation(.spring(response: 0.30 * Controller.tempo, dampingFraction: 0.68), value: search.shaped)
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
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Cerca app e file", text: query)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .regular))
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
