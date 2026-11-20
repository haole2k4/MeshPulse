import Foundation

/// Wire payload for a single 16 KB fragment of a multi-hop image or file transfer.
public struct MediaChunkPayload: Codable, Sendable, Equatable {
    public let transferID: UUID
    public let caption: String
    public let mimeType: String
    public let chunkIndex: Int
    public let totalChunks: Int
    public let totalBytes: Int
    public let chunkData: Data
    public let coordinate: GeoCoordinate?

    public init(
        transferID: UUID,
        caption: String = "",
        mimeType: String = "image/jpeg",
        chunkIndex: Int,
        totalChunks: Int,
        totalBytes: Int,
        chunkData: Data,
        coordinate: GeoCoordinate? = nil
    ) {
        self.transferID = transferID
        self.caption = caption
        self.mimeType = mimeType
        self.chunkIndex = chunkIndex
        self.totalChunks = totalChunks
        self.totalBytes = totalBytes
        self.chunkData = chunkData
        self.coordinate = coordinate
    }
}

/// Live transfer progress snapshot emitted as chunks arrive across multi-hop mesh links.
public struct MediaTransferProgress: Sendable, Equatable, Codable, Identifiable {
    public let transferID: UUID
    public let senderID: String
    public let senderName: String
    public let targetID: String
    public let caption: String
    public let mimeType: String
    public var receivedChunks: Int
    public let totalChunks: Int
    public let totalBytes: Int
    public var routeNames: [String]
    public var hopCount: Int
    public var isEncrypted: Bool
    public var assembledData: Data?
    public let timestamp: Date

    public var id: UUID { transferID }

    public var fractionCompleted: Double {
        guard totalChunks > 0 else { return 0.0 }
        return min(1.0, Double(receivedChunks) / Double(totalChunks))
    }

    public var isCompleted: Bool {
        assembledData != nil && receivedChunks >= totalChunks
    }

    public init(
        transferID: UUID,
        senderID: String,
        senderName: String,
        targetID: String,
        caption: String,
        mimeType: String,
        receivedChunks: Int,
        totalChunks: Int,
        totalBytes: Int,
        routeNames: [String],
        hopCount: Int,
        isEncrypted: Bool,
        assembledData: Data? = nil,
        timestamp: Date = Date()
    ) {
        self.transferID = transferID
        self.senderID = senderID
        self.senderName = senderName
        self.targetID = targetID
        self.caption = caption
        self.mimeType = mimeType
        self.receivedChunks = receivedChunks
        self.totalChunks = totalChunks
        self.totalBytes = totalBytes
        self.routeNames = routeNames
        self.hopCount = hopCount
        self.isEncrypted = isEncrypted
        self.assembledData = assembledData
        self.timestamp = timestamp
    }

    /// Convenience initializer for lightweight progress tracking (e.g. Live Activities / outgoing placeholders).
    public init(
        transferID: UUID,
        totalChunks: Int,
        receivedChunks: Int,
        totalBytes: Int,
        isComplete _: Bool
    ) {
        self.init(
            transferID: transferID,
            senderID: "",
            senderName: "",
            targetID: "",
            caption: "",
            mimeType: "image/jpeg",
            receivedChunks: receivedChunks,
            totalChunks: totalChunks,
            totalBytes: totalBytes,
            routeNames: [],
            hopCount: 0,
            isEncrypted: false
        )
    }
}

/// Splits compressed media (`Data`) into fixed-size `16 KB` chunks for multi-hop mesh routing.
public enum MeshChunker: Sendable {
    public static let defaultChunkSizeBytes = 16_384 // 16 KB per chunk

    public static func chunkCount(for byteCount: Int, chunkSize: Int = defaultChunkSizeBytes) -> Int {
        let effectiveChunkSize = max(256, chunkSize)
        return max(1, (byteCount + effectiveChunkSize - 1) / effectiveChunkSize)
    }

    public static func split(
        data: Data,
        transferID: UUID = UUID(),
        caption: String = "",
        mimeType: String = "image/jpeg",
        coordinate: GeoCoordinate? = nil,
        chunkSize: Int = defaultChunkSizeBytes
    ) -> [MediaChunkPayload] {
        let effectiveChunkSize = max(256, chunkSize)
        guard !data.isEmpty else {
            return [
                MediaChunkPayload(
                    transferID: transferID,
                    caption: caption,
                    mimeType: mimeType,
                    chunkIndex: 0,
                    totalChunks: 1,
                    totalBytes: 0,
                    chunkData: Data(),
                    coordinate: coordinate
                )
            ]
        }

        let totalBytes = data.count
        let totalChunks = (totalBytes + effectiveChunkSize - 1) / effectiveChunkSize
        var chunks: [MediaChunkPayload] = []
        chunks.reserveCapacity(totalChunks)

        var offset = 0
        var index = 0
        while offset < totalBytes {
            let end = min(totalBytes, offset + effectiveChunkSize)
            let slice = data.subdata(in: offset..<end)
            chunks.append(
                MediaChunkPayload(
                    transferID: transferID,
                    caption: caption,
                    mimeType: mimeType,
                    chunkIndex: index,
                    totalChunks: totalChunks,
                    totalBytes: totalBytes,
                    chunkData: slice,
                    coordinate: index == 0 ? coordinate : nil
                )
            )
            offset = end
            index += 1
        }
        return chunks
    }
}

/// Reassembles out-of-order `.mediaChunk` packets at the destination node and emits incremental progress.
public struct ChunkAssembler: Sendable {
    private struct PartialTransfer: Sendable {
        let transferID: UUID
        let senderID: String
        let senderName: String
        let targetID: String
        var caption: String
        let mimeType: String
        let totalChunks: Int
        let totalBytes: Int
        var coordinate: GeoCoordinate?
        var chunksByIndex: [Int: Data]
        var latestRouteNames: [String]
        var latestHopCount: Int
        var isEncrypted: Bool
        let startedAt: Date
    }

    private var transfers: [UUID: PartialTransfer] = [:]

    public init() {}

    public mutating func ingest(
        chunk: MediaChunkPayload,
        senderID: String,
        senderName: String,
        targetID: String,
        routeNames: [String],
        hopCount: Int,
        isEncrypted: Bool,
        now: Date = Date()
    ) -> MediaTransferProgress? {
        guard chunk.totalChunks > 0,
              chunk.chunkIndex >= 0,
              chunk.chunkIndex < chunk.totalChunks
        else {
            return nil
        }

        var partial = transfers[chunk.transferID] ?? PartialTransfer(
            transferID: chunk.transferID,
            senderID: senderID,
            senderName: senderName,
            targetID: targetID,
            caption: chunk.caption,
            mimeType: chunk.mimeType,
            totalChunks: chunk.totalChunks,
            totalBytes: chunk.totalBytes,
            coordinate: chunk.coordinate,
            chunksByIndex: [:],
            latestRouteNames: routeNames,
            latestHopCount: hopCount,
            isEncrypted: isEncrypted,
            startedAt: now
        )

        if !chunk.caption.isEmpty {
            partial.caption = chunk.caption
        }
        if let coord = chunk.coordinate {
            partial.coordinate = coord
        }
        partial.chunksByIndex[chunk.chunkIndex] = chunk.chunkData
        partial.latestRouteNames = routeNames
        partial.latestHopCount = hopCount
        partial.isEncrypted = partial.isEncrypted || isEncrypted

        let receivedCount = partial.chunksByIndex.count
        if receivedCount >= partial.totalChunks {
            var fullData = Data()
            fullData.reserveCapacity(max(0, partial.totalBytes))
            for idx in 0..<partial.totalChunks {
                guard let part = partial.chunksByIndex[idx] else {
                    transfers[chunk.transferID] = partial
                    return nil
                }
                fullData.append(part)
            }
            transfers.removeValue(forKey: chunk.transferID)
            return MediaTransferProgress(
                transferID: partial.transferID,
                senderID: partial.senderID,
                senderName: partial.senderName,
                targetID: partial.targetID,
                caption: partial.caption,
                mimeType: partial.mimeType,
                receivedChunks: partial.totalChunks,
                totalChunks: partial.totalChunks,
                totalBytes: fullData.count,
                routeNames: partial.latestRouteNames,
                hopCount: partial.latestHopCount,
                isEncrypted: partial.isEncrypted,
                assembledData: fullData,
                timestamp: partial.startedAt
            )
        } else {
            transfers[chunk.transferID] = partial
            return MediaTransferProgress(
                transferID: partial.transferID,
                senderID: partial.senderID,
                senderName: partial.senderName,
                targetID: partial.targetID,
                caption: partial.caption,
                mimeType: partial.mimeType,
                receivedChunks: receivedCount,
                totalChunks: partial.totalChunks,
                totalBytes: partial.totalBytes,
                routeNames: partial.latestRouteNames,
                hopCount: partial.latestHopCount,
                isEncrypted: partial.isEncrypted,
                assembledData: nil,
                timestamp: partial.startedAt
            )
        }
    }

    public mutating func pruneStaleTransfers(olderThan maxAge: TimeInterval = 3600, now: Date = Date()) {
        transfers = transfers.filter { _, partial in
            now.timeIntervalSince(partial.startedAt) < maxAge
        }
    }
}
