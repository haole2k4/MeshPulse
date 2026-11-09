import Foundation

// MARK: - 1. Safety Roll Call State-based CRDT (LWW-Element-Dictionary)

public enum SafetyStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case safe
    case needsHelp

    public var labelVN: String {
        switch self {
        case .safe:
            "Tôi an toàn"
        case .needsHelp:
            "Cần hỗ trợ"
        }
    }
}

public struct RollCallVote: Codable, Sendable, Equatable {
    public let voterNodeID: String
    public var voterName: String
    public var status: SafetyStatus
    public var coordinate: GeoCoordinate?
    public var updatedAt: Date

    public init(
        voterNodeID: String,
        voterName: String,
        status: SafetyStatus,
        coordinate: GeoCoordinate? = nil,
        updatedAt: Date = Date()
    ) {
        self.voterNodeID = voterNodeID
        self.voterName = voterName
        self.status = status
        self.coordinate = coordinate
        self.updatedAt = updatedAt
    }
}

/// Convergent Replicated Data Type (CRDT) for emergency group safety roll-call.
/// Merges responses by `voterNodeID` using Last-Writer-Wins (`updatedAt`, tie-breaking deterministically).
public struct SafetyRollCallState: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var title: String
    public let createdByNodeID: String
    public var createdByName: String
    public let createdAt: Date
    public var responses: [String: RollCallVote]

    public init(
        id: UUID = UUID(),
        title: String = "Điểm danh An toàn Toàn Mạng",
        createdByNodeID: String,
        createdByName: String,
        createdAt: Date = Date(),
        responses: [String: RollCallVote] = [:]
    ) {
        self.id = id
        self.title = title
        self.createdByNodeID = createdByNodeID
        self.createdByName = createdByName
        self.createdAt = createdAt
        self.responses = responses
    }

    public var safeCount: Int {
        responses.values.filter { $0.status == .safe }.count
    }

    public var needsHelpCount: Int {
        responses.values.filter { $0.status == .needsHelp }.count
    }

    public var sortedVotes: [RollCallVote] {
        responses.values.sorted { lhs, rhs in
            if lhs.status != rhs.status {
                return lhs.status == .needsHelp
            }
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.voterNodeID < rhs.voterNodeID
        }
    }

    public mutating func recordVote(
        nodeID: String,
        displayName: String,
        status: SafetyStatus,
        coordinate: GeoCoordinate? = nil,
        at now: Date = Date()
    ) {
        let candidate = RollCallVote(
            voterNodeID: nodeID,
            voterName: displayName,
            status: status,
            coordinate: coordinate,
            updatedAt: now
        )
        if let existing = responses[nodeID] {
            if Self.shouldReplace(existing: existing, with: candidate) {
                responses[nodeID] = candidate
            }
        } else {
            responses[nodeID] = candidate
        }
    }

    /// Commutative, associative, idempotent CRDT merge.
    public mutating func merge(_ other: SafetyRollCallState) {
        guard other.id == self.id else { return }
        for (nodeID, incomingVote) in other.responses {
            if let existing = responses[nodeID] {
                if Self.shouldReplace(existing: existing, with: incomingVote) {
                    responses[nodeID] = incomingVote
                }
            } else {
                responses[nodeID] = incomingVote
            }
        }
    }

    private static func shouldReplace(existing: RollCallVote, with incoming: RollCallVote) -> Bool {
        if incoming.updatedAt != existing.updatedAt {
            return incoming.updatedAt > existing.updatedAt
        }
        // Deterministic tie-breaker: prefer `.needsHelp` over `.safe` if timestamps match to millisecond
        if incoming.status != existing.status {
            return incoming.status == .needsHelp
        }
        return incoming.voterName > existing.voterName
    }
}

// MARK: - 2. Mesh Micro-Poll State-based CRDT (LWW-Element-Dictionary)

public struct PollVote: Codable, Sendable, Equatable {
    public let voterNodeID: String
    public var voterName: String
    public var optionIndex: Int
    public var updatedAt: Date

    public init(
        voterNodeID: String,
        voterName: String,
        optionIndex: Int,
        updatedAt: Date = Date()
    ) {
        self.voterNodeID = voterNodeID
        self.voterName = voterName
        self.optionIndex = optionIndex
        self.updatedAt = updatedAt
    }
}

/// Convergent Replicated Data Type (CRDT) for distributed group micro-polls across multi-hop & DTN links.
public struct MeshPollState: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var question: String
    public var options: [String]
    public let createdByNodeID: String
    public var createdByName: String
    public let createdAt: Date
    public var votes: [String: PollVote]

    public init(
        id: UUID = UUID(),
        question: String,
        options: [String],
        createdByNodeID: String,
        createdByName: String,
        createdAt: Date = Date(),
        votes: [String: PollVote] = [:]
    ) {
        self.id = id
        self.question = question
        self.options = options
        self.createdByNodeID = createdByNodeID
        self.createdByName = createdByName
        self.createdAt = createdAt
        self.votes = votes
    }

    public var totalVotes: Int {
        votes.values.filter { $0.optionIndex >= 0 && $0.optionIndex < options.count }.count
    }

    public func voteCount(forOption index: Int) -> Int {
        guard index >= 0, index < options.count else { return 0 }
        return votes.values.filter { $0.optionIndex == index }.count
    }

    public func voteFraction(forOption index: Int) -> Double {
        let total = totalVotes
        guard total > 0 else { return 0.0 }
        return Double(voteCount(forOption: index)) / Double(total)
    }

    public func voters(forOption index: Int) -> [PollVote] {
        votes.values
            .filter { $0.optionIndex == index }
            .sorted { $0.voterName < $1.voterName }
    }

    public mutating func castVote(
        nodeID: String,
        displayName: String,
        optionIndex: Int,
        at now: Date = Date()
    ) {
        guard optionIndex >= 0, optionIndex < options.count else { return }
        let candidate = PollVote(
            voterNodeID: nodeID,
            voterName: displayName,
            optionIndex: optionIndex,
            updatedAt: now
        )
        if let existing = votes[nodeID] {
            if Self.shouldReplace(existing: existing, with: candidate) {
                votes[nodeID] = candidate
            }
        } else {
            votes[nodeID] = candidate
        }
    }

    /// Commutative, associative, idempotent CRDT merge.
    public mutating func merge(_ other: MeshPollState) {
        guard other.id == self.id else { return }
        for (nodeID, incomingVote) in other.votes {
            guard incomingVote.optionIndex >= 0, incomingVote.optionIndex < options.count else {
                continue
            }
            if let existing = votes[nodeID] {
                if Self.shouldReplace(existing: existing, with: incomingVote) {
                    votes[nodeID] = incomingVote
                }
            } else {
                votes[nodeID] = incomingVote
            }
        }
    }

    private static func shouldReplace(existing: PollVote, with incoming: PollVote) -> Bool {
        if incoming.updatedAt != existing.updatedAt {
            return incoming.updatedAt > existing.updatedAt
        }
        return incoming.optionIndex > existing.optionIndex
    }
}
