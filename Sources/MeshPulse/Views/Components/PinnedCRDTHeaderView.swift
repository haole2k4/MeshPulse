#if canImport(SwiftUI)
import Foundation
import MeshCore
import SwiftUI

/// Pinned collapsible interactive header card in Broadcast Channel for CRDT Safety Roll Call & Micro-Polls.
public struct PinnedCRDTHeaderView: View {
    public let localNodeID: String
    public let rollCall: SafetyRollCallState?
    public let poll: MeshPollState?
    public let onVoteRollCall: ((SafetyStatus) -> Void)?
    public let onVotePoll: ((Int) -> Void)?
    public let onDismissRollCall: (() -> Void)?
    public let onDismissPoll: (() -> Void)?

    @State private var isExpanded: Bool = true

    public init(
        localNodeID: String,
        rollCall: SafetyRollCallState? = nil,
        poll: MeshPollState? = nil,
        onVoteRollCall: ((SafetyStatus) -> Void)? = nil,
        onVotePoll: ((Int) -> Void)? = nil,
        onDismissRollCall: (() -> Void)? = nil,
        onDismissPoll: (() -> Void)? = nil
    ) {
        self.localNodeID = localNodeID
        self.rollCall = rollCall
        self.poll = poll
        self.onVoteRollCall = onVoteRollCall
        self.onVotePoll = onVotePoll
        self.onDismissRollCall = onDismissRollCall
        self.onDismissPoll = onDismissPoll
    }

    public var body: some View {
        if rollCall != nil || poll != nil {
            VStack(spacing: 10) {
                if let rollCall {
                    rollCallCard(rollCall)
                }

                if let poll {
                    pollCard(poll)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Safety Roll Call Card

    private func rollCallCard(_ rc: SafetyRollCallState) -> some View {
        let myVote = rc.responses[localNodeID]

        return VStack(alignment: .leading, spacing: 10) {
            // Header Bar
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "shield.checkered")
                        .font(.subheadline)
                        .foregroundStyle(MeshTheme.emerald)
                    Text("ĐIỂM DANH AN TOÀN")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(MeshTheme.emerald)
                }

                Spacer()

                HStack(spacing: 12) {
                    // Summary counts
                    HStack(spacing: 6) {
                        Text("\(rc.safeCount) ✅")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(MeshTheme.emerald)
                        if rc.needsHelpCount > 0 {
                            Text("\(rc.needsHelpCount) ⚠️")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(MeshTheme.sosCrimson)
                        }
                    }

                    Button(action: { withAnimation(.spring(response: 0.3)) { isExpanded.toggle() } }) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(MeshTheme.secondaryText)
                    }

                    if rc.createdByNodeID == localNodeID {
                        Button(action: { onDismissRollCall?() }) {
                            Image(systemName: "xmark")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(MeshTheme.secondaryText)
                        }
                    }
                }
            }

            Text(rc.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MeshTheme.primaryText)

            if isExpanded {
                // Interactive 1-touch voting buttons
                HStack(spacing: 10) {
                    Button(action: {
                        onVoteRollCall?(.safe)
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Tôi An Toàn")
                        }
                        .font(.caption.weight(.bold))
                        .foregroundStyle(myVote?.status == .safe ? .black : MeshTheme.emerald)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            myVote?.status == .safe ? MeshTheme.emerald : MeshTheme.emerald.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(MeshTheme.emerald.opacity(myVote?.status == .safe ? 1.0 : 0.3), lineWidth: 1)
                        )
                    }

                    Button(action: {
                        onVoteRollCall?(.needsHelp)
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text("Cần Hỗ Trợ")
                        }
                        .font(.caption.weight(.bold))
                        .foregroundStyle(myVote?.status == .needsHelp ? .white : MeshTheme.sosCrimson)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            myVote?.status == .needsHelp ? MeshTheme.sosCrimson : MeshTheme.sosCrimson.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(MeshTheme.sosCrimson.opacity(myVote?.status == .needsHelp ? 1.0 : 0.3), lineWidth: 1)
                        )
                    }
                }

                // Respondent list summary
                if !rc.responses.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Phản hồi gần nhất:")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(MeshTheme.secondaryText)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(Array(rc.responses.values).sorted(by: { $0.updatedAt > $1.updatedAt }), id: \.voterName) { resp in
                                    HStack(spacing: 4) {
                                        Text(resp.status == .safe ? "✅" : "⚠️")
                                            .font(.system(size: 9))
                                        Text(resp.voterName)
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(MeshTheme.primaryText)
                                    }
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.white.opacity(0.06), in: Capsule())
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(12)
        .background(MeshTheme.cardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(MeshTheme.emerald.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: - Mesh Micro-Poll Card

    private func pollCard(_ p: MeshPollState) -> some View {
        let myVote = p.votes[localNodeID]

        return VStack(alignment: .leading, spacing: 10) {
            // Header Bar
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.subheadline)
                        .foregroundStyle(MeshTheme.meshCyan)
                    Text("BÌNH CHỌN MESH CRDT")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(MeshTheme.meshCyan)
                }

                Spacer()

                HStack(spacing: 8) {
                    Text("\(p.totalVotes) phiếu")
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(MeshTheme.secondaryText)

                    if p.createdByNodeID == localNodeID {
                        Button(action: { onDismissPoll?() }) {
                            Image(systemName: "xmark")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(MeshTheme.secondaryText)
                        }
                    }
                }
            }

            Text(p.question)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MeshTheme.primaryText)

            // Options List
            VStack(spacing: 6) {
                ForEach(p.options.indices, id: \.self) { idx in
                    let isSelected = myVote?.optionIndex == idx
                    let count = p.voteCounts[idx] ?? 0
                    let pct = p.percentages[idx] ?? 0.0

                    Button(action: {
                        onVotePoll?(idx)
                    }) {
                        VStack(spacing: 4) {
                            HStack {
                                HStack(spacing: 6) {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .font(.caption)
                                        .foregroundStyle(isSelected ? MeshTheme.meshCyan : MeshTheme.secondaryText)
                                    Text(p.options[idx])
                                        .font(.caption.weight(isSelected ? .bold : .medium))
                                        .foregroundStyle(MeshTheme.primaryText)
                                }
                                Spacer()
                                Text("\(count) (\(Int(pct * 100))%)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(isSelected ? MeshTheme.meshCyan : MeshTheme.secondaryText)
                            }

                            // Progress Bar
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.white.opacity(0.08))
                                        .frame(height: 4)
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(isSelected ? MeshTheme.meshCyan : MeshTheme.emerald.opacity(0.7))
                                        .frame(width: geo.size.width * CGFloat(pct), height: 4)
                                }
                            }
                            .frame(height: 4)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .background(isSelected ? MeshTheme.meshCyan.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(MeshTheme.cardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(MeshTheme.meshCyan.opacity(0.35), lineWidth: 1)
        )
    }
}
#endif
