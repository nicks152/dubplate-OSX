import SwiftUI
import DubplateCore

/// What a drop is about to do, before it does it.
///
/// Shown only when there is a decision worth confirming — bounces that look like
/// new versions of tracks already on the record. A plain drop of new material does
/// not stop to ask.
public struct ImportPlanSheet: View {
    private let plan: ImportPlan
    private let releaseTitle: String
    private let onCancel: () -> Void
    private let onConfirm: (ImportPlan) -> Void

    /// Version matches the person has chosen to treat as new tracks instead.
    @State private var demoted: Set<UUID> = []

    public init(
        plan: ImportPlan,
        releaseTitle: String,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (ImportPlan) -> Void
    ) {
        self.plan = plan
        self.releaseTitle = releaseTitle
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    /// A plan only needs confirming when Dubplate has guessed at something.
    public static func requiresConfirmation(_ plan: ImportPlan) -> Bool {
        !plan.newVersions.isEmpty || !plan.rejected.isEmpty
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DubplateLayout.xl) {
            VStack(alignment: .leading, spacing: DubplateLayout.xs) {
                Text("Adding to \(releaseTitle)")
                    .dubplateDisplayStyle(size: 22)
                    .foregroundStyle(DubplateColor.primaryText)
                Text(plan.summary)
                    .font(DubplateType.metadata)
                    .foregroundStyle(DubplateColor.tertiaryText)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: DubplateLayout.xl) {
                    if !plan.newVersions.isEmpty {
                        VStack(alignment: .leading, spacing: DubplateLayout.s) {
                            SectionHeader("Looks like new versions")
                            ForEach(plan.newVersions) { planned in
                                versionRow(planned)
                            }
                        }
                    }
                    if !plan.newTracks.isEmpty {
                        VStack(alignment: .leading, spacing: DubplateLayout.s) {
                            SectionHeader("New tracks")
                            ForEach(plan.newTracks) { planned in
                                HStack(spacing: DubplateLayout.m) {
                                    Text("\(planned.trackNumber)")
                                        .font(DubplateType.metadata)
                                        .foregroundStyle(DubplateColor.tertiaryText)
                                        .frame(width: 22, alignment: .trailing)
                                    Text(planned.title)
                                        .font(DubplateType.rowTitle)
                                        .foregroundStyle(DubplateColor.primaryText)
                                    Spacer()
                                    if planned.candidates.count > 1 {
                                        Text("\(planned.candidates.count) versions")
                                            .font(DubplateType.metadata)
                                            .foregroundStyle(DubplateColor.tertiaryText)
                                    }
                                }
                            }
                        }
                    }
                    if !plan.rejected.isEmpty {
                        VStack(alignment: .leading, spacing: DubplateLayout.s) {
                            SectionHeader("Skipped")
                            ForEach(plan.rejected) { rejected in
                                Text("\(rejected.filename) — \(rejected.reason)")
                                    .font(DubplateType.metadata)
                                    .foregroundStyle(DubplateColor.tertiaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 320)

            HStack {
                Text(orderingNote)
                    .font(DubplateType.metadata)
                    .foregroundStyle(DubplateColor.tertiaryText)
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(DubplateQuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Add") { onConfirm(resolvedPlan) }
                    .buttonStyle(DubplateFilledButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DubplateLayout.xxl)
        .frame(width: 560)
        .background(DubplateColor.raised)
    }

    private func versionRow(_ planned: PlannedVersion) -> some View {
        let isDemoted = demoted.contains(planned.id)
        return HStack(alignment: .top, spacing: DubplateLayout.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(planned.candidate.filename)
                    .font(DubplateType.rowTitle)
                    .foregroundStyle(DubplateColor.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(isDemoted
                     ? "Will be added as a new track"
                     : "New version of \(planned.match.trackTitle) — \(planned.match.reason.lowercased())")
                    .font(DubplateType.metadata)
                    .foregroundStyle(DubplateColor.tertiaryText)
            }
            Spacer(minLength: DubplateLayout.s)
            Button(isDemoted ? "Make Version" : "New Track Instead") {
                if isDemoted {
                    demoted.remove(planned.id)
                } else {
                    demoted.insert(planned.id)
                }
            }
            .buttonStyle(DubplateQuietButtonStyle())
            .controlSize(.small)
        }
        .padding(.vertical, DubplateLayout.xs)
    }

    private var orderingNote: String {
        switch plan.orderingSignal {
        case .filenameNumbers: return "Ordered by the numbers in the filenames"
        case .dropOrder: return "Ordered the way you dropped them"
        case .filename: return "Ordered by filename"
        }
    }

    /// Applies the person's overrides to produce the plan that will actually run.
    private var resolvedPlan: ImportPlan {
        guard !demoted.isEmpty else { return plan }
        var updated = plan
        var nextNumber = (plan.newTracks.map(\.trackNumber).max() ?? 0) + 1
        var keptVersions: [PlannedVersion] = []
        for planned in plan.newVersions {
            if demoted.contains(planned.id) {
                updated.newTracks.append(
                    PlannedTrack(
                        title: planned.candidate.parsed.title,
                        trackNumber: nextNumber,
                        candidates: [planned.candidate]
                    )
                )
                nextNumber += 1
            } else {
                keptVersions.append(planned)
            }
        }
        updated.newVersions = keptVersions
        return updated
    }
}
