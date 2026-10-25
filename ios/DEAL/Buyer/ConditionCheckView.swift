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
    @Environment(AppModel.self) private var model
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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center) {
                    Text("Check condition")
                        .font(DealFont.jakarta(28, .extrabold)).kerning(-0.8)
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(PillButtonStyle(kind: .sand, height: 44, fullWidth: false))
                }

                if let claims = store.listing?.conditionClaims, !claims.isEmpty {
                    SurfaceCard(padding: 16) {
                        Text("Listing says")
                            .font(DealFont.jakarta(12, .bold))
                            .foregroundStyle(Palette.muted)
                        ClaimChips(claims: claims, flagged: Set(store.discrepancies.map(\.claim)), wrap: true)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "What you see")
                    SurfaceCard(padding: 14) {
                        HStack(spacing: 8) {
                            if CameraPicker.isAvailable {
                                Button { showCamera = true } label: { Label("Take photo", systemImage: "camera.fill") }
                                    .buttonStyle(PillButtonStyle(kind: .ink, height: 44))
                            }
                            PhotosPicker(selection: $photoItem, matching: .images) {
                                Label(CameraPicker.isAvailable ? "Choose photo" : "Choose photo from library",
                                      systemImage: "photo.on.rectangle")
                            }
                            .buttonStyle(PillButtonStyle(kind: .sand, height: 44))
                        }
                        if let photoPreview {
                            HStack(spacing: 12) {
                                photoPreview.resizable().scaledToFill()
                                    .frame(width: 72, height: 72)
                                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                Spacer()
                                Button("Remove photo", role: .destructive) { clearPhoto() }
                                    .font(DealFont.jakarta(14, .bold))
                                    .foregroundStyle(Palette.red)
                                    .buttonStyle(.plain)
                            }
                        }
                        TextField("What do you see? (e.g. tires look worn)", text: $observation, axis: .vertical)
                            .font(DealFont.jakarta(15))
                            .lineLimit(2...4)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.surfaceWarm))
                            .accessibilityIdentifier("conditionObservation")
                        if !CameraPicker.isAvailable && model.settings.demoShortcuts {
                            // Simulator / no camera: a canned observation that matches the demo listing.
                            Button("Use sample observation") { observation = MarketplaceDemo.sampleObservation }
                                .buttonStyle(PillButtonStyle(kind: .surface, height: 36, fullWidth: false))
                                .overlay(Capsule().strokeBorder(Palette.divider, lineWidth: 1.5))
                        }
                    }
                    Text("Compared with what the listing claims. Mismatches become a cue on your glasses.")
                        .font(DealFont.jakarta(12)).foregroundStyle(Palette.muted)
                        .padding(.horizontal, 6)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        Task { await check() }
                    } label: {
                        HStack(spacing: 8) {
                            if store.isCheckingCondition { ProgressView().tint(.white) }
                            Text("Check against listing")
                        }
                    }
                    .buttonStyle(PillButtonStyle(kind: .ink))
                    .disabled(!canCheck)
                    .opacity(canCheck || store.isCheckingCondition ? 1 : 0.4)
                    if let error {
                        Text(error).font(DealFont.caption).foregroundStyle(Palette.red)
                    }
                }

                if let result {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Result")
                        if result.discrepancies.isEmpty {
                            HStack(spacing: 12) {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .background(Circle().fill(Palette.greenText))
                                Text("Matches the listing. No mismatches found.")
                                    .font(DealFont.jakarta(15, .bold))
                                    .foregroundStyle(Palette.greenText)
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Palette.surface))
                            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .strokeBorder(Palette.green, lineWidth: 2))
                        }
                        ForEach(result.discrepancies) { d in
                            DiscrepancyCard(discrepancy: d)
                        }
                    }
                }

                let earlier = store.discrepancies.filter { d in !(result?.discrepancies.contains(d) ?? false) }
                if !earlier.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Earlier checks")
                            .font(DealFont.jakarta(18, .extrabold))
                        ForEach(earlier) { d in
                            DiscrepancyCard(discrepancy: d, compact: true)
                        }
                    }
                }
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .font(DealFont.body)
        .tint(Palette.ink)
        .background(Palette.background.ignoresSafeArea())
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
        .presentationDetents([.large])
        .presentationBackground(Palette.background)
        .presentationCornerRadius(40)
        .presentationDragIndicator(.visible)
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
