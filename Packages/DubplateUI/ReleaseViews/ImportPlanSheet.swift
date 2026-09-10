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

    /// Version matches the person has chosen to accept after all.
    @State private var promoted: Set<UUID> = []

    /// A plan only needs confirming when Dubplate has guessed at something.
    public static func requiresConfirmation(_ plan: ImportPlan) -> Bool {
        !plan.newVersions.isEmpty || !plan.uncertainVersions.isEmpty
            || !plan.rejected.isEmpty || plan.wasTruncated
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DubplateLayout.xl) {
            VStack(alignment: .leading, spacing: DubplateLayout.xs) {
                Text("Adding to \(releaseTitle)")
                    .dubplateDisplayStyle(.sheet)
                    .foregroundStyle(DubplateColor.primaryText)
                Text(plan.summary)
                    .dubplateFont(DubplateType.metadata)
                    .foregroundStyle(DubplateColor.tertiaryText)
            }

            if plan.wasTruncated {
                Text(
                    "That drop held more than \(DroppedFiles.perDropLimit) files. "
                    + "Dubplate is adding the first \(DroppedFiles.perDropLimit); "
                    + "drop the rest in afterwards."
                )
                .dubplateFont(DubplateType.metadata)
                .foregroundStyle(DubplateColor.primaryText)
                .padding(DubplateLayout.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DubplateColor.sunken, in: RoundedRectangle(cornerRadius: DubplateLayout.controlRadius))
            }

            ScrollView {
                VStack(alignment: .leading, spacing: DubplateLayout.xl) {
                    if !plan.newVersions.isEmpty {
                        VStack(alignment: .leading, spacing: DubplateLayout.s) {
                            SectionHeader("New mixes")
                            ForEach(plan.newVersions) { planned in
                                versionRow(planned)
                            }
                        }
                    }
                    if !plan.uncertainVersions.isEmpty {
                        VStack(alignment: .leading, spacing: DubplateLayout.s) {
                            SectionHeader("Not sure about these")
                            ForEach(plan.uncertainVersions) { planned in
                                uncertainRow(planned)
                            }
                        }
                    }
                    if !visibleNewTracks.isEmpty {
                        VStack(alignment: .leading, spacing: DubplateLayout.s) {
                            SectionHeader("New tracks")
                            ForEach(visibleNewTracks) { planned in
                                HStack(spacing: DubplateLayout.m) {
                                    Text("\(planned.trackNumber)")
                                        .dubplateFont(DubplateType.metadata)
                                        .foregroundStyle(DubplateColor.tertiaryText)
                                        .frame(width: 22, alignment: .trailing)
                                    Text(planned.title)
                                        .dubplateFont(DubplateType.rowTitle)
                                        .foregroundStyle(DubplateColor.primaryText)
                                    Spacer()
                                    if planned.candidates.count > 1 {
                                        Text("\(planned.candidates.count) mixes")
                                            .dubplateFont(DubplateType.metadata)
                                            .foregroundStyle(DubplateColor.tertiaryText)
                                    }
                                }
                            }
                        }
                    }
                    if !plan.rejected.isEmpty {
                        VStack(alignment: .leading, spacing: DubplateLayout.s) {
                            SectionHeader("Not added")
                            ForEach(plan.rejected) { rejected in
                                Text("\(rejected.filename) — \(rejected.reason)")
                                    .dubplateFont(DubplateType.metadata)
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
                    .dubplateFont(DubplateType.metadata)
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
                    .dubplateFont(DubplateType.rowTitle)
                    .foregroundStyle(DubplateColor.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(isDemoted
                     ? "Will be added as a new track"
                     : "New mix of \(planned.match.trackTitle) — \(planned.match.reason.lowercased())")
                    .dubplateFont(DubplateType.metadata)
                    .foregroundStyle(DubplateColor.tertiaryText)
            }
            Spacer(minLength: DubplateLayout.s)
            Button(isDemoted ? "Make It a Mix" : "New Track Instead") {
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

    /// The uncertain band: offered, never assumed.
    private func uncertainRow(_ planned: PlannedVersion) -> some View {
        let isPromoted = promoted.contains(planned.id)
        return HStack(alignment: .top, spacing: DubplateLayout.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(planned.candidate.filename)
                    .dubplateFont(DubplateType.rowTitle)
                    .foregroundStyle(DubplateColor.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(isPromoted
                     ? "Will be a new mix of \(planned.match.trackTitle)"
                     : "Might be \(planned.match.trackTitle) — \(planned.match.reason.lowercased()). Adding as a new track.")
                    .dubplateFont(DubplateType.metadata)
                    .foregroundStyle(DubplateColor.tertiaryText)
            }
            Spacer(minLength: DubplateLayout.s)
            Button(isPromoted ? "New Track Instead" : "Mix of \(planned.match.trackTitle)") {
                if isPromoted {
                    promoted.remove(planned.id)
                } else {
                    promoted.insert(planned.id)
                }
            }
            .buttonStyle(DubplateQuietButtonStyle())
            .controlSize(.small)
        }
        .padding(.vertical, DubplateLayout.xs)
    }

    /// New tracks that have not been promoted into mixes of an existing track.
    private var visibleNewTracks: [PlannedTrack] {
        let promotedTrackIDs = Set(
            plan.uncertainVersions.filter { promoted.contains($0.id) }.compactMap(\.fallbackTrackID)
        )
        return plan.newTracks.filter { !promotedTrackIDs.contains($0.id) }
    }

    private var orderingNote: String {
        switch plan.orderingSignal {
        case .filenameNumbers: return "Ordered by the numbers in the filenames"
        case .dropOrder: return "Ordered the way you dropped them"
        case .filename: return "Ordered by filename — drag to re-sequence"
        }
    }

    /// Applies the person's overrides to produce the plan that will actually run.
    private var resolvedPlan: ImportPlan {
        var updated = plan

        // Anything the person accepted becomes a mix, and stops being a new track.
        if !promoted.isEmpty {
            let accepted = plan.uncertainVersions.filter { promoted.contains($0.id) }
            updated.newVersions.append(contentsOf: accepted)
            let removedTrackIDs = Set(accepted.compactMap(\.fallbackTrackID))
            updated.newTracks.removeAll { removedTrackIDs.contains($0.id) }
        }
        updated.uncertainVersions = []

        guard !demoted.isEmpty else { return updated }
        var nextNumber = (updated.newTracks.map(\.trackNumber).max() ?? 0) + 1
        var keptVersions: [PlannedVersion] = []
        for planned in updated.newVersions {
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
