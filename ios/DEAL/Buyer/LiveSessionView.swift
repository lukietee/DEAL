import SwiftUI

/// B3. Live Session (main screen). Layout follows the Section 4 ASCII:
/// header + LIVE, asking -> target, current offer + progress, ON GLASSES card,
/// terms so far, transcript, [Pause] [Fix a term] [Lock Deal], Scripted mode toggle.
struct LiveSessionView: View {
    @Environment(AppModel.self) private var model
    var store: SessionStore
    var onBackToAgreement: (() -> Void)? = nil

    @State private var scriptedMode = true
    @State private var showJoinCode = false
    @State private var showTeleprompter = false
    @State private var fixingTerm: Term?
    @State private var showTermPicker = false
    @State private var paused = false
    @State private var typedLine = ""
    @State private var didAutoShowJoin = false

    var body: some View {
        let state = store.state
        let session = state.session
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header(session)
                        offerSection(state)
                        GlassesCueCard(cue: model.teleprompter.currentCue, displayName: model.glasses.name)
                            .onTapGesture { showTeleprompter = true }
                        termsSection(state)
                        transcriptSection(state)
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding()
                }
                .onChange(of: state.events.count) {
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            controls(state)
        }
        .navigationTitle("Live")
        .dealInlineTitle()
        .dealKeepAwake()
        .toolbar {
            ToolbarItemGroup(placement: .dealTrailing) {
                Button { showTeleprompter = true } label: { Image(systemName: "eyeglasses") }
                    .accessibilityLabel("Open teleprompter")
                Button { showJoinCode = true } label: { Image(systemName: "qrcode") }
                    .accessibilityLabel("Show seller join code")
            }
        }
        .sheet(isPresented: $showJoinCode) {
            NavigationStack {
                JoinCodeCard(code: session.joinCode)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showJoinCode = false } } }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $fixingTerm) { term in
            FixTermSheet(term: term) { correction in
                Task { await store.fixTerm(term, correction: correction) }
            }
        }
        .confirmationDialog("Fix which term?", isPresented: $showTermPicker) {
            ForEach(state.visibleTerms) { term in
                Button("\(term.label)\(term.amount.map { " · " + Money.format($0) } ?? "")") { fixingTerm = term }
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

    private func header(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.item).font(.title2.weight(.bold)).lineLimit(2)
                Spacer()
                if paused {
                    LiveBadge(text: "PAUSED", color: .gray)
                } else {
                    LiveBadge()
                }
            }
            Text("Asking \(Money.format(session.askingPrice)) → Target \(Money.format(session.targetPrice))")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("Max \(Money.format(session.maxBudget)) · \(session.style.capitalized) · Code \(session.joinCode)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func offerSection(_ state: SessionState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Current offer:").font(.headline)
                Spacer()
                Text(Money.format(state.currentOffer, placeholder: "—"))
                    .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                    .animation(.default, value: state.currentOffer)
            }
            if let by = state.currentOfferBy {
                Text("by \(by == .buyer ? "you" : "seller")").font(.caption).foregroundStyle(.secondary)
            }
            OfferProgressBar(asking: state.session.askingPrice, target: state.session.targetPrice,
                             maxBudget: state.session.maxBudget, offer: state.currentOffer)
        }
    }

    private func termsSection(_ state: SessionState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Terms so far").font(.headline)
            let terms = state.visibleTerms
            if terms.isEmpty {
                Text("None yet").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(terms) { term in
                Button { fixingTerm = term } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text(TermDisplay.text(term)).foregroundStyle(.primary)
                        if term.uncertain { Text("(?)").foregroundStyle(.orange).bold() }
                        if term.corrected {
                            Image(systemName: "pencil.circle.fill").foregroundStyle(.secondary).font(.caption)
                        }
                        Spacer()
                    }
                    .font(.subheadline)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func transcriptSection(_ state: SessionState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcript").font(.headline)
            if state.events.isEmpty {
                Text(scriptedMode ? "Tap Play script to start the sample conversation." : "Listening will appear here.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(state.sortedEvents) { event in
                TranscriptLineView(event: event)
            }
            if !store.partialTranscript.isEmpty {
                Text("\(store.micSpeaker.displayName): \(store.partialTranscript)…")
                    .font(.subheadline).italic().foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Controls

    private func controls(_ state: SessionState) -> some View {
        VStack(spacing: 10) {
            Divider()
            HStack {
                Toggle(isOn: $scriptedMode) {
                    Label("Scripted mode", systemImage: "text.badge.play")
                        .font(.subheadline)
                }
                .toggleStyle(.switch)
                .onChange(of: scriptedMode) { _, scripted in
                    if scripted { store.stopMic() }
                }
            }
            .padding(.horizontal)

            if scriptedMode {
                Button {
                    Task { await store.playScript() }
                } label: {
                    Label(scriptButtonTitle(state), systemImage: state.script?.isPlaying == true ? "waveform" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(store.scriptStarted || store.isBusy)
                .padding(.horizontal)
            } else {
                micControls
            }

            HStack(spacing: 10) {
                Button {
                    togglePause()
                } label: {
                    Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    showTermPicker = true
                } label: {
                    Label("Fix a term", systemImage: "pencil").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(state.visibleTerms.isEmpty)

                if let onBackToAgreement {
                    Button(action: onBackToAgreement) {
                        Label("Agreement", systemImage: "doc.text").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        Task { await store.lockDeal() }
                    } label: {
                        HStack(spacing: 4) {
                            if store.isBusy { ProgressView() }
                            Label("Lock Deal", systemImage: "lock.fill")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.events.isEmpty || store.isBusy)
                }
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .background(.bar)
    }

    @ViewBuilder
    private var micControls: some View {
        @Bindable var store = store
        VStack(spacing: 8) {
            HStack {
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
                        .foregroundStyle(store.isListening ? .red : .primary)
                        .frame(width: 44, height: 32)
                }
                .buttonStyle(.bordered)
                .disabled(paused)
            }
            HStack {
                TextField("Or type a line…", text: $typedLine)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(sendTyped)
                Button("Send", action: sendTyped).disabled(typedLine.isEmpty)
            }
        }
        .padding(.horizontal)
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

/// B3 "Fix a term": correct an AI mistake (label / amount / remove).
struct FixTermSheet: View {
    var term: Term
    var onSave: (TermCorrection) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var amount: String

    init(term: Term, onSave: @escaping (TermCorrection) -> Void) {
        self.term = term
        self.onSave = onSave
        _label = State(initialValue: term.label)
        _amount = State(initialValue: term.amount.map(Money.editableString) ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Term") {
                    TextField("Label", text: $label)
                    HStack {
                        Text("$").foregroundStyle(.secondary)
                        TextField("Amount", text: $amount).dealKeyboard(.decimal)
                    }
                }
                Section {
                    Button("Remove this term", role: .destructive) {
                        onSave(TermCorrection(label: nil, amount: nil, removed: true))
                        dismiss()
                    }
                }
            }
            .navigationTitle("Fix a term")
            .dealInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let newAmount = Money.parseDollars(amount)
                        onSave(TermCorrection(label: label == term.label ? nil : label,
                                              amount: newAmount == term.amount ? nil : newAmount,
                                              removed: nil))
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
