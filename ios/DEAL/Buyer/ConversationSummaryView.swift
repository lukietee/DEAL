import SwiftUI

/// B3 "End" -> the conversation's summary (`POST /sessions/:id/end` -> `session.summary`):
/// outcome chip, final price, headline and key points. Done returns to B1.
struct ConversationSummarySheet: View {
    var session: Session
    var onDone: () -> Void

    private var finalPrice: Int? { session.summary?.finalPrice ?? session.finalPrice }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SheetGrabber().frame(maxWidth: .infinity).padding(.top, 12)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("CONVERSATION ENDED")
                            .font(DealFont.eyebrow).kerning(1.2)
                            .foregroundStyle(Palette.muted)
                        Text(session.displayItem)
                            .font(DealFont.jakarta(28, .extrabold))
                            .kerning(-0.8)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("summaryItem")
                    }
                    .padding(.horizontal, 4)

                    HStack(alignment: .center, spacing: 12) {
                        OutcomeChip(outcome: session.historyOutcome, large: true)
                            .accessibilityIdentifier("summaryOutcome")
                        Spacer(minLength: 8)
                        if let finalPrice {
                            Text(Money.format(finalPrice))
                                .font(DealFont.jakarta(36, .extrabold))
                                .kerning(-1.2)
                                .lineLimit(1).minimumScaleFactor(0.6)
                        }
                    }
                    .padding(.horizontal, 4)

                    if let summary = session.summary {
                        ConversationSummaryCard(summary: summary)
                    } else {
                        SurfaceCard(padding: 20) {
                            Text("Saved without a summary").font(DealFont.jakarta(16, .extrabold))
                            Text("The transcript is in History.")
                                .font(DealFont.jakarta(14)).foregroundStyle(Palette.muted)
                        }
                    }

                    Label("Saved to History", systemImage: "checkmark.circle.fill")
                        .font(DealFont.jakarta(13, .semibold))
                        .foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            Button("Done", action: onDone)
                .buttonStyle(PillButtonStyle(kind: .ink, height: 58))
                .accessibilityIdentifier("summaryDone")
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.background.ignoresSafeArea())
        .presentationBackground(Palette.background)
        .presentationDetents([.large])
        .presentationCornerRadius(40)
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled()
    }
}

/// Headline and key points of a conversation summary (summary sheet and Deal Detail).
struct ConversationSummaryCard: View {
    var summary: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Summary").font(DealFont.jakarta(22, .extrabold)).kerning(-0.4)
            if !summary.headline.isEmpty {
                Text(summary.headline)
                    .font(DealFont.jakarta(17, .bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("summaryHeadline")
            }
            if !summary.keyPoints.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(summary.keyPoints.enumerated()), id: \.offset) { _, point in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Circle().fill(Palette.ink).frame(width: 6, height: 6)
                                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] + 4 }
                            Text(point)
                                .font(DealFont.jakarta(15))
                                .foregroundStyle(Palette.inkSoft)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Palette.surface))
    }
}
