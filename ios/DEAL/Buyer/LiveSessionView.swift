import SwiftUI

/// B3. Live Session (main screen), "DEAL Redesign" B3-Live-Mid / B3-Live-Done:
/// sand hero (item, numbers, listing claims, the ON GLASSES cue), the current-offer card
/// overlapping the hero's notch, terms chips + transcript, and a white bottom bar with the
/// Scripted mode toggle and [Pause] [Fix a term] [Lock Deal].
struct LiveSessionView: View {
    @Environment(AppModel.self) private var model
    var store: SessionStore
    var onBackToAgreement: (() -> Void)? = nil

    /// The user's Scripted mode choice; nil = default (on only with demo shortcuts).
    @State private var scriptedChoice: Bool?
    /// Scripted playback is a demo shortcut: without it the live mic is the only input.
    private var scriptedMode: Bool { model.settings.demoShortcuts && (scriptedChoice ?? true) }
    @State private var showJoinCode = false
    @State private var showTeleprompter = false
    @State private var fixingTerm: Term?
    @State private var showTermPicker = false
    @State private var paused = false
    @State private var typedLine = ""
    @State private var didAutoShowJoin = false
    @State private var showConditionCheck = false

    fileprivate static let quietFill = Color(hex: 0xE3E3E3)

    var body: some View {
        let state = store.state
        let session = state.session
        GeometryReader { geo in
            // Small phones (SE / mini class) get a tighter pinned panel so the transcript keeps room.
            let compact = geo.size.height < 640
            VStack(spacing: 0) {
                // Pinned: hero (header + ON GLASSES cue) and the current offer card.
                // These never scroll away while the script plays.
                pinnedPanel(state, compact: compact)
                // Scrolling: suggested phrases (kept at the top, refreshed after every line),
                // live research, terms so far, transcript.
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            SuggestedPhrasesCard(suggestions: state.suggestions)
                                .id("phrases")
                            ResearchPanel(research: state.research, onRerun: { Task { await store.restartResearch() } })
                            termsSection(state)
                            transcriptSection(state)
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                    }
                    .frame(minHeight: compact ? 100 : 150)
                    .clipped()
                    // Fresh phrases arrive after each transcript line: bring them back into view.
                    .onChange(of: state.suggestions?.forEventId) {
                        withAnimation { proxy.scrollTo("phrases", anchor: .top) }
                    }
                }
                controls(state)
            }
        }
        .font(DealFont.body)
        .foregroundStyle(Palette.ink)
        .tint(Palette.ink)
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Live")
        .dealInlineTitle()
        .dealKeepAwake()
        .toolbarBackground(Palette.sand, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) { liveChip }
            ToolbarItemGroup(placement: .dealTrailing) {
                // Needs the session's listing: the backend compares against its condition claims.
                if store.listing != nil {
                    Button { showConditionCheck = true } label: { Image(systemName: "camera.viewfinder") }
                        .accessibilityLabel("Check condition")
                }
                Button { showTeleprompter = true } label: { Image(systemName: "eyeglasses") }
                    .accessibilityLabel("Open teleprompter")
                Button { showJoinCode = true } label: { Image(systemName: "qrcode") }
                    .accessibilityLabel("Show seller join code")
            }
        }
        .sheet(isPresented: $showJoinCode) {
            ScrollView {
                JoinCodeCard(code: session.joinCode, waiting: state.events.isEmpty) { showJoinCode = false }
            }
            .scrollBounceBehavior(.basedOnSize)
            .dealSheetChrome()
            .presentationDetents([.fraction(0.82), .large])
        }
        .sheet(isPresented: $showConditionCheck) {
            ConditionCheckSheet(store: store)
        }
        .sheet(item: $fixingTerm) { term in
            FixTermSheet(term: term, source: state.event(id: term.sourceEventId)) { correction in
                Task { await store.fixTerm(term, correction: correction) }
            }
        }
        .sheet(isPresented: $showTermPicker) {
            TermPickerSheet(terms: state.visibleTerms, state: state) { term, correction in
                Task { await store.fixTerm(term, correction: correction) }
            }
        }
        .dealFullScreenCover(isPresented: $showTeleprompter) {
            TeleprompterView(display: model.teleprompter)
        }
        .onAppear {
            if !didAutoShowJoin, state.events.isEmpty, onBackToAgreement == nil {
                didAutoShowJoin = true
                showJoinCode = true
            }
        }
    }

    // MARK: Sections

    private var liveChip: some View {
        HStack(spacing: 6) {
            PulsingDot(color: paused ? Palette.faint : Palette.liveDot, pulsing: !paused)
            Text(paused ? "PAUSED" : "LIVE")
                .font(DealFont.jakarta(12, .extrabold))
                .kerning(1.4)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule().fill(Palette.ink.opacity(0.12)))
        .foregroundStyle(Palette.ink)
    }

    private func pinnedPanel(_ state: SessionState, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Sand hero
            VStack(alignment: .leading, spacing: compact ? 10 : 16) {
                header(state.session, compact: compact)
                GlassesCueCard(cue: model.teleprompter.currentCue, displayName: model.glasses.name, compact: compact)
                    .onTapGesture { showTeleprompter = true }
                    .animation(.default, value: model.teleprompter.currentCue?.text)
            }
            .padding(.horizontal, 20)
            .padding(.top, compact ? 2 : 6)
            .padding(.bottom, compact ? 50 : 62)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                UnevenRoundedRectangle(bottomLeadingRadius: 56, style: .continuous)
                    .fill(Palette.sand)
                    .ignoresSafeArea(edges: .top)
            )

            // Notch area: offer card overlapping the hero, then a pinned mismatch (Marketplace).
            VStack(alignment: .leading, spacing: 10) {
                offerCard(state, compact: compact)
                    .padding(.trailing, 20)
                    .padding(.top, -34)
                if let latest = store.discrepancies.first {
                    Button { showConditionCheck = true } label: {
                        DiscrepancyCard(discrepancy: latest, compact: true, moreCount: store.discrepancies.count - 1)
                    }
                    .buttonStyle(.plain)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .top) {
                ZStack(alignment: .top) {
                    Palette.sand.frame(height: 56)
                    UnevenRoundedRectangle(topTrailingRadius: 56, style: .continuous)
                        .fill(Palette.background)
                }
            }
        }
        .animation(.default, value: store.discrepancies.first?.id)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func header(_ session: Session, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.item)
                .font(DealFont.jakarta(18, .extrabold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            (Text("Ask \(Money.format(session.askingPrice)) → Target \(Money.format(session.targetPrice))")
             + Text(compact ? "" : " · Max \(Money.format(session.maxBudget)) · \(session.style.capitalized) · ")
             + Text(compact ? "" : session.joinCode).font(DealFont.mono(13, .medium)))
                .font(DealFont.caption)
                .foregroundStyle(Palette.mutedWarm)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            // Marketplace: what the listing claims, one scrolling line; contradicted claims turn red.
            if let claims = store.listing?.conditionClaims, !claims.isEmpty {
                HStack(spacing: 8) {
                    Text("Listing says")
                        .font(DealFont.jakarta(12, .bold))
                        .foregroundStyle(Palette.mutedWarm)
                        .fixedSize()
                    ClaimChips(claims: claims, flagged: Set(store.discrepancies.map(\.claim)), fill: Palette.surface)
                }
                .padding(.top, 8)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("listingClaims")
            }
        }
    }

    private func offerCard(_ state: SessionState, compact: Bool) -> some View {
        let session = state.session
        let offerEvent = state.sortedEvents.last(where: { $0.extractedOffer != nil })
        let byLine: String = {
            guard let by = state.currentOfferBy else { return state.currentOffer == nil ? "No offer yet" : "" }
            let who = "by \(by == .buyer ? "you" : "seller")"
            return offerEvent?.timestamp.map { "\(who) · \(TimeFormat.clock($0))" } ?? who
        }()
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CURRENT OFFER")
                        .font(DealFont.jakarta(11, .extrabold)).kerning(1.3)
                        .foregroundStyle(Palette.muted)
                    Text(byLine).font(DealFont.jakarta(13, .bold))
                }
                Spacer(minLength: 8)
                Text(Money.format(state.currentOffer, placeholder: "—"))
                    .font(DealFont.jakarta(compact ? 34 : 44, .extrabold))
                    .kerning(-1.6)
                    .foregroundStyle(state.currentOffer == nil ? Palette.faint : Palette.ink)
                    .contentTransition(.numericText())
                    .animation(.default, value: state.currentOffer)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            OfferProgressBar(asking: session.askingPrice, target: session.targetPrice,
                             maxBudget: session.maxBudget, offer: state.currentOffer)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Palette.surface)
                .shadow(color: .black.opacity(0.12), radius: 9, y: 6)
        )
    }

    @ViewBuilder
    private func termsSection(_ state: SessionState) -> some View {
        let terms = state.visibleTerms
        if !terms.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(terms) { term in
                    Button { fixingTerm = term } label: {
                        HStack(spacing: 4) {
                            Text(TermDisplay.text(term))
                            if term.uncertain { Text("?").foregroundStyle(Palette.muted) }
                            if term.corrected {
                                Image(systemName: "pencil").font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Palette.muted)
                            }
                        }
                        .font(DealFont.jakarta(13, .semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background {
                            if term.uncertain {
                                Capsule().strokeBorder(Palette.faint, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                            } else {
                                Capsule().fill(Palette.surface)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func transcriptSection(_ state: SessionState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if state.events.isEmpty {
                Text(scriptedMode ? "Tap Play script to start the sample conversation." : "Tap the mic to start listening, or type a line.")
                    .font(DealFont.jakarta(14)).foregroundStyle(Palette.muted)
            }
            ForEach(state.sortedEvents) { event in
                if event.isConditionCheck {
                    ConditionCheckLineView(event: event)
                } else {
                    TranscriptLineView(event: event)
                }
            }
            if !store.partialTranscript.isEmpty {
                Text("\(store.micSpeaker.displayName): \(store.partialTranscript)…")
                    .font(DealFont.jakarta(14)).italic().foregroundStyle(Palette.muted)
            }
        }
    }

    // MARK: Controls

    private func controls(_ state: SessionState) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Text(statusText(state))
                    .font(DealFont.jakarta(13, .semibold))
                    .foregroundStyle(state.script?.error != nil ? Palette.red : Palette.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                if model.settings.demoShortcuts {
                    Toggle(isOn: Binding(get: { scriptedMode }, set: { scriptedChoice = $0 })) {
                        Text("Scripted mode")
                            .font(DealFont.jakarta(13, .semibold))
                            .foregroundStyle(Palette.muted)
                    }
                    .toggleStyle(.switch)
                    .tint(Palette.sand)
                    .fixedSize()
                }
            }
            .onChange(of: scriptedMode) { _, scripted in
                if scripted { store.stopMic() }
            }

            if scriptedMode {
                if !store.scriptStarted {
                    Button {
                        Task { await store.playScript() }
                    } label: {
                        Label(scriptButtonTitle(state), systemImage: "play.fill")
                    }
                    .buttonStyle(PillButtonStyle(kind: .ink, height: 50))
                    .disabled(store.isBusy)
                }
            } else {
                micControls
            }

            GeometryReader { geo in
                let unit = (geo.size.width - 16) / 3.4
                HStack(spacing: 8) {
                    Button {
                        togglePause()
                    } label: {
                        Text(paused ? "Resume" : "Pause")
                    }
                    .buttonStyle(BarButtonStyle(fill: Self.quietFill))
                    .frame(width: unit)

                    Button {
                        showTermPicker = true
                    } label: {
                        Text("Fix a term")
                    }
                    .buttonStyle(BarButtonStyle(fill: Self.quietFill))
                    .disabled(state.visibleTerms.isEmpty)
                    .frame(width: unit)

                    if let onBackToAgreement {
                        Button(action: onBackToAgreement) {
                            Label("Agreement", systemImage: "doc.text").labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(BarButtonStyle(fill: Palette.sand))
                        .accessibilityLabel("Agreement")
                    } else {
                        let ready = state.script?.done == true && !store.isBusy
                        Button {
                            Task { await store.lockDeal() }
                        } label: {
                            HStack(spacing: 6) {
                                if store.isBusy { ProgressView().tint(Palette.ink) }
                                Label("Lock Deal", systemImage: "lock.fill").labelStyle(.titleAndIcon)
                            }
                        }
                        .buttonStyle(BarButtonStyle(fill: Palette.sand, ring: ready ? Palette.green : nil))
                        .disabled(state.events.isEmpty || store.isBusy)
                        .accessibilityLabel("Lock Deal")
                    }
                }
            }
            .frame(height: 54)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous)
                .fill(Palette.surface)
                .ignoresSafeArea(edges: .bottom)
                .shadow(color: .black.opacity(0.05), radius: 10, y: -2)
        )
    }

    @ViewBuilder
    private var micControls: some View {
        @Bindable var store = store
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Picker("Speaker", selection: $store.micSpeaker) {
                    Text("You").tag(Speaker.buyer)
                    Text("Seller").tag(Speaker.seller)
                }
                .pickerStyle(.segmented)
                Button {
                    Task {
                        if store.isListening { store.stopMic() } else { await store.startMic(using: AppleSpeechTranscriber()) }
                    }
                } label: {
                    Image(systemName: store.isListening ? "mic.fill" : "mic.slash")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(store.isListening ? .white : Palette.ink)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(store.isListening ? Palette.red : Palette.sand))
                }
                .buttonStyle(.plain)
                .disabled(paused)
                .accessibilityLabel(store.isListening ? "Stop listening" : "Start listening")
            }
            HStack(spacing: 8) {
                TextField("Or type a line…", text: $typedLine)
                    .font(DealFont.jakarta(15))
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .background(Capsule().fill(Palette.surfaceWarm))
                    .onSubmit(sendTyped)
                Button("Send", action: sendTyped)
                    .buttonStyle(PillButtonStyle(kind: .ink, height: 44, fullWidth: false))
                    .disabled(typedLine.isEmpty)
                    .opacity(typedLine.isEmpty ? 0.4 : 1)
            }
        }
    }

    private func statusText(_ state: SessionState) -> String {
        guard scriptedMode else {
            return store.isListening ? "Listening · \(store.micSpeaker.displayName)" : (paused ? "Paused" : "Mic off")
        }
        let id = state.session.category.defaultScriptID
        guard let run = state.script else {
            return store.scriptStarted ? "Starting \(id)…" : "Scripted · \(id)"
        }
        if let error = run.error { return "Script error: \(error)" }
        if run.done { return "Script finished \(run.played)/\(run.total)" }
        return "Scripted · \(run.scriptId) \(run.played)/\(run.total)"
    }

    private func scriptButtonTitle(_ state: SessionState) -> String {
        let id = state.session.category.defaultScriptID
        guard let run = state.script else {
            return store.scriptStarted ? "Starting \(id)…" : "Play script (\(id))"
        }
        if let error = run.error { return "Script error: \(error)" }
        if run.done { return "Script finished (\(run.played)/\(run.total))" }
        return "Playing \(run.scriptId) · \(run.played)/\(run.total)"
    }

    private func sendTyped() {
        let line = typedLine
        typedLine = ""
        Task { await store.postTranscriptLine(line, speaker: store.micSpeaker) }
    }

    /// Pause stops the mic and freezes input. (The v1 API has no endpoint to pause a playing
    /// script, so scripted lines already scheduled by the backend keep arriving.)
    private func togglePause() {
        paused.toggle()
        if paused { store.stopMic() }
    }
}

/// B3 bottom-bar capsule (54pt): Pause / Fix a term on light grey, Lock Deal on sand with an
/// optional green ring when it's time to lock.
private struct BarButtonStyle: ButtonStyle {
    var fill: Color
    var ring: Color? = nil
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DealFont.jakarta(15, .bold))
            .foregroundStyle(Palette.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Capsule().fill(fill))
            .overlay {
                if let ring {
                    Capsule().strokeBorder(ring, lineWidth: 2).padding(-5)
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private struct PulsingDot: View {
    var color: Color
    var pulsing: Bool
    @State private var dim = false

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .opacity(pulsing && dim ? 0.35 : 1)
            .animation(pulsing ? .easeInOut(duration: 0.8).repeatForever() : .default, value: dim)
            .onAppear { dim = true }
    }
}

private extension View {
    /// B3a / B3c sheet look: page background, big top radius, visible grabber.
    func dealSheetChrome() -> some View {
        self
            .background(Palette.background.ignoresSafeArea())
            .presentationBackground(Palette.background)
            .presentationCornerRadius(40)
            .presentationDragIndicator(.visible)
    }
}

enum TermDisplay {
    static func text(_ term: Term) -> String {
        switch term.type {
        case "price":
            return "Price \(Money.format(term.amount, placeholder: "?"))"
        case "item", "promise":
            return term.label.prefix(1).uppercased() + term.label.dropFirst() + (term.type == "item" ? " included" : "")
        case "fee":
            if term.amount == 0 { return "\(term.label.capitalizedFirst) waived" }
            return "\(term.label.capitalizedFirst) \(Money.format(term.amount, placeholder: "?"))"
        default:
            if let amount = term.amount, amount != 0 { return "\(term.label.capitalizedFirst) \(Money.format(amount))" }
            return term.label.capitalizedFirst
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// B3c "Fix which term?": every visible term as a row; picking one swaps the sheet to the
/// "Fix a term" form in place (one sheet, so there is no sheet-on-sheet hand-off).
struct TermPickerSheet: View {
    var terms: [Term]
    var state: SessionState
    var onSave: (Term, TermCorrection) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Term?

    var body: some View {
        Group {
            if let picked {
                FixTermForm(term: picked, source: state.event(id: picked.sourceEventId),
                            onSave: { onSave(picked, $0) }, onClose: { dismiss() })
            } else {
                picker
            }
        }
        .dealSheetChrome()
        .presentationDetents(picked == nil ? [.height(CGFloat(min(terms.count, 6)) * 72 + 250), .large]
                                           : [.fraction(0.85), .large])
    }

    private var picker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fix which term?")
                        .font(DealFont.jakarta(28, .extrabold)).kerning(-0.8)
                    Text("Correct anything the AI heard wrong before you lock.")
                        .font(DealFont.jakarta(14)).foregroundStyle(Palette.muted)
                }
                .padding(.horizontal, 4)
                VStack(spacing: 8) {
                    ForEach(terms) { term in
                        Button { picked = term } label: {
                            HStack(spacing: 12) {
                                Text(term.label.capitalizedFirst)
                                    .font(DealFont.jakarta(16, .bold))
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(Self.value(term)).font(DealFont.jakarta(17, .extrabold))
                                Image(systemName: "pencil")
                                    .font(.system(size: 15, weight: .bold))
                                    .frame(width: 44, height: 44)
                                    .background(Circle().fill(term.uncertain ? Palette.sand : LiveSessionView.quietFill))
                            }
                            .padding(.leading, 22)
                            .padding(.trailing, 10)
                            .frame(height: 64)
                            .background(Capsule().fill(Palette.surface))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(term.label) · \(Self.value(term))")
                    }
                }
                Button("Cancel") { dismiss() }
                    .buttonStyle(PillButtonStyle(kind: .surface))
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 20)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    static func value(_ term: Term) -> String {
        if let amount = term.amount { return Money.format(amount) }
        return term.type == "item" ? "Included" : "—"
    }
}

/// B3 "Fix a term": correct an AI mistake (label / amount / remove).
struct FixTermSheet: View {
    var term: Term
    var source: DealEvent? = nil
    var onSave: (TermCorrection) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        FixTermForm(term: term, source: source, onSave: onSave, onClose: { dismiss() })
            .dealSheetChrome()
            .presentationDetents([.fraction(0.85), .large])
    }
}

/// B3c-Fix-Sheet: Cancel · "Fix a term" · Save, the term name, a big amount field, where the
/// term was heard, and "Remove this term".
struct FixTermForm: View {
    var term: Term
    var source: DealEvent?
    var onSave: (TermCorrection) -> Void
    var onClose: () -> Void
    @State private var label: String
    @State private var amount: String
    @FocusState private var amountFocused: Bool

    init(term: Term, source: DealEvent?, onSave: @escaping (TermCorrection) -> Void, onClose: @escaping () -> Void) {
        self.term = term
        self.source = source
        self.onSave = onSave
        self.onClose = onClose
        _label = State(initialValue: term.label)
        _amount = State(initialValue: term.amount.map(Money.editableString) ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Button("Cancel") { onClose() }
                        .buttonStyle(PillButtonStyle(kind: .surface, height: 44, fullWidth: false))
                    Spacer()
                    Text("Fix a term").font(DealFont.jakarta(18, .extrabold))
                    Spacer()
                    Button("Save") {
                        let newAmount = Money.parseDollars(amount)
                        onSave(TermCorrection(label: label == term.label ? nil : label,
                                              amount: newAmount == term.amount ? nil : newAmount,
                                              removed: nil))
                        onClose()
                    }
                    .buttonStyle(PillButtonStyle(kind: .sand, height: 44, fullWidth: false))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Term").font(DealFont.jakarta(13, .bold)).foregroundStyle(Palette.muted).padding(.leading, 6)
                    TextField("Label", text: $label)
                        .font(DealFont.jakarta(17, .bold))
                        .padding(.horizontal, 22)
                        .frame(height: 58)
                        .background(Capsule().fill(Palette.surface))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Amount").font(DealFont.jakarta(13, .bold)).foregroundStyle(Palette.muted).padding(.leading, 6)
                    HStack(spacing: 4) {
                        Text("$").font(DealFont.jakarta(40, .extrabold)).foregroundStyle(Palette.faint)
                        TextField("0", text: $amount)
                            .font(DealFont.jakarta(48, .extrabold))
                            .kerning(-1.8)
                            .dealKeyboard(.decimal)
                            .focused($amountFocused)
                            .fixedSize()
                            .accessibilityLabel("Amount")
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity, minHeight: 104)
                    .background(RoundedRectangle(cornerRadius: 32, style: .continuous).fill(Palette.surface))
                    .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .strokeBorder(amountFocused ? Palette.ink : Palette.divider, lineWidth: 2))
                    .contentShape(Rectangle())
                    .onTapGesture { amountFocused = true }
                }

                if let source {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(heardLine(source))
                            .font(DealFont.jakarta(11, .extrabold)).kerning(1.3)
                            .foregroundStyle(Palette.muted)
                        Text("\u{201C}\(source.text)\u{201D}")
                            .font(DealFont.jakarta(15))
                            .lineSpacing(3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Palette.surface))
                }

                Button("Remove this term", role: .destructive) {
                    onSave(TermCorrection(label: nil, amount: nil, removed: true))
                    onClose()
                }
                .font(DealFont.jakarta(16, .bold))
                .foregroundStyle(Palette.red)
                .frame(maxWidth: .infinity, minHeight: 56)
                .buttonStyle(.plain)
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 20)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
    }

    private func heardLine(_ e: DealEvent) -> String {
        let who = e.speaker.displayName.uppercased()
        guard let ts = e.timestamp else { return "HEARD · \(who)" }
        return "HEARD AT \(TimeFormat.clock(ts).uppercased()) · \(who)"
    }
}
