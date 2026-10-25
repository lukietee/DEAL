import SwiftUI
import PhotosUI
#if os(iOS)
import UIKit
#endif

/// B3 "Check condition" (Marketplace meetups): photograph the item and/or type what you see.
/// `POST /sessions/:id/condition-check` compares it with the listing's claims and returns
/// discrepancies ("Listing: new tires · Seen: worn · ask $40 off"). The backend also inserts a
/// cue event, so the matching cue reaches the glasses through the normal sync path.
struct ConditionCheckSheet: View {
    var store: SessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var observation = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var photoBase64: String?
    @State private var photoPreview: Image?
    @State private var showCamera = false
    @State private var result: ConditionCheckResult?
    @State private var error: String?

    private var canCheck: Bool {
        !store.isCheckingCondition
            && (photoBase64 != nil || !observation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let claims = store.listing?.conditionClaims, !claims.isEmpty {
                    Section("Listing says") {
                        ClaimChips(claims: claims, flagged: Set(store.discrepancies.map(\.claim)), wrap: true)
                    }
                }

                Section {
                    if CameraPicker.isAvailable {
                        Button { showCamera = true } label: { Label("Take photo", systemImage: "camera.fill") }
                    }
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label(CameraPicker.isAvailable ? "Choose photo" : "Choose photo from library",
                              systemImage: "photo.on.rectangle")
                    }
                    if let photoPreview {
                        HStack {
                            photoPreview.resizable().scaledToFill()
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            Spacer()
                            Button("Remove photo", role: .destructive) { clearPhoto() }
                                .buttonStyle(.borderless)
                        }
                    }
                    TextField("What do you see? (e.g. tires look worn)", text: $observation, axis: .vertical)
                        .lineLimit(2...4)
                        .accessibilityIdentifier("conditionObservation")
                    if !CameraPicker.isAvailable {
                        // Simulator / no camera: a canned observation that matches the demo listing.
                        Button("Use sample observation") { observation = MarketplaceDemo.sampleObservation }
                            .font(.footnote)
                    }
                } header: {
                    Text("What you see")
                } footer: {
                    Text("Compared with what the listing claims. Mismatches become a cue on your glasses.")
                }

                Section {
                    Button {
                        Task { await check() }
                    } label: {
                        HStack {
                            if store.isCheckingCondition { ProgressView().tint(.white) }
                            Text("Check against listing")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!canCheck)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }

                if let result {
                    Section("Result") {
                        if result.discrepancies.isEmpty {
                            Label("Matches the listing. No mismatches found.", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                        }
                        ForEach(result.discrepancies) { d in
                            DiscrepancyCard(discrepancy: d)
                                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                        }
                    }
                }

                let earlier = store.discrepancies.filter { d in !(result?.discrepancies.contains(d) ?? false) }
                if !earlier.isEmpty {
                    Section("Earlier checks") {
                        ForEach(earlier) { d in
                            DiscrepancyCard(discrepancy: d, compact: true)
                                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                        }
                    }
                }
            }
            .navigationTitle("Check condition")
            .dealInlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { await loadPhoto(item) }
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in
                    photoBase64 = ImageEncoding.jpegBase64(from: image)
                    photoPreview = Image(uiImage: image)
                }
                .ignoresSafeArea()
            }
            #endif
        }
        .presentationDetents([.large])
    }

    private func check() async {
        error = nil
        do {
            result = try await store.checkCondition(observation: observation, imageBase64: photoBase64)
            Platform.haptic((result?.discrepancies.isEmpty ?? true) ? .success : .warning)
        } catch {
            self.error = "Condition check failed. \(error.localizedDescription)"
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let base64 = ImageEncoding.jpegBase64(from: data) else {
            error = "Couldn't read that photo."
            return
        }
        photoBase64 = base64
        #if os(iOS)
        if let ui = UIImage(data: data) { photoPreview = Image(uiImage: ui) }
        #endif
    }

    private func clearPhoto() {
        photoItem = nil
        photoBase64 = nil
        photoPreview = nil
    }
}

#if os(iOS)
/// The system camera (UIImagePickerController). Only offered when a camera exists, so the
/// Simulator falls back to PhotosPicker and the sample observation.
struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
#else
enum CameraPicker { static var isAvailable: Bool { false } }
#endif
