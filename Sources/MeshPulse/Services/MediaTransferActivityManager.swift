#if canImport(SwiftUI)
import Foundation
import MeshCore
import Observation
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

#if canImport(ActivityKit) && os(iOS)
@preconcurrency import ActivityKit

public struct MeshMediaTransferAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var progress: Double
        public var receivedChunks: Int
        public var totalChunks: Int
        public var statusNote: String
    }

    public var transferID: String
    public var filename: String
    public var isOutgoing: Bool
}
#endif

/// Snapshot used by the in-app Live Transfer Pill to display active media transfers.
public struct ActiveTransferDisplay: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let filename: String
    public let isOutgoing: Bool
    public let receivedChunks: Int
    public let totalChunks: Int
    public let progress: Double
    public let isComplete: Bool
    public let statusNote: String
    public let updatedAt: Date

    public var percentComplete: Int {
        Int((min(max(progress, 0.0), 1.0) * 100.0).rounded())
    }

    public init(
        id: UUID,
        filename: String,
        isOutgoing: Bool,
        receivedChunks: Int,
        totalChunks: Int,
        progress: Double,
        isComplete: Bool,
        statusNote: String,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.filename = filename
        self.isOutgoing = isOutgoing
        self.receivedChunks = receivedChunks
        self.totalChunks = totalChunks
        self.progress = progress
        self.isComplete = isComplete
        self.statusNote = statusNote
        self.updatedAt = updatedAt
    }
}

/// Manages media preparation (downscaling, compression) and in-app progress tracking
/// across the Live Transfer Pill and chat bubble progress indicators.
@Observable
@MainActor
public final class MediaTransferActivityManager {
    public static let shared = MediaTransferActivityManager()

    public private(set) var activeTransfers: [UUID: MediaTransferProgress] = [:]
    public private(set) var activeDisplays: [UUID: ActiveTransferDisplay] = [:]

    private var cleanupTasks: [UUID: Task<Void, Never>] = [:]

    /// Most relevant active transfer for the in-app Live Transfer Pill.
    public var primaryActiveDisplay: ActiveTransferDisplay? {
        activeDisplays.values.max { lhs, rhs in
            if lhs.isComplete != rhs.isComplete {
                // Prefer in-progress transfers over completed ones.
                return lhs.isComplete && !rhs.isComplete
            }
            return lhs.updatedAt < rhs.updatedAt
        }
    }

    public init() {
        cleanupOrphanedLiveActivities()
    }

    /// Ends any orphaned Live Activities from previous app builds so iOS never leaves
    /// an empty black Dynamic Island on the user's device.
    public func cleanupOrphanedLiveActivities() {
        #if canImport(ActivityKit) && os(iOS)
        Task { @MainActor in
            for activity in Activity<MeshMediaTransferAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        #endif
    }

    // MARK: - Image Downscaling & Compression (Spec: max 800px width, quality 0.4)

    public static func prepareImageForMesh(data: Data, maxDimension: CGFloat = 800, quality: CGFloat = 0.4) -> Data? {
        #if canImport(UIKit)
        guard let sourceImage = UIImage(data: data) else { return data }

        let originalSize = sourceImage.size
        let maxSide = max(originalSize.width, originalSize.height)

        let targetImage: UIImage
        if maxSide > maxDimension {
            let scaleFactor = maxDimension / maxSide
            let targetSize = CGSize(width: originalSize.width * scaleFactor, height: originalSize.height * scaleFactor)

            let renderer = UIGraphicsImageRenderer(size: targetSize)
            targetImage = renderer.image { _ in
                sourceImage.draw(in: CGRect(origin: .zero, size: targetSize))
            }
        } else {
            targetImage = sourceImage
        }

        return targetImage.jpegData(compressionQuality: quality) ?? data
        #else
        return data
        #endif
    }

    // MARK: - In-App Transfer Lifecycle

    public func trackTransferStarted(
        transferID: UUID,
        totalChunks: Int,
        totalBytes: Int,
        isOutgoing: Bool,
        filename: String = "Hình ảnh Mesh"
    ) {
        let safeTotalChunks = max(1, totalChunks)
        let initial = MediaTransferProgress(
            transferID: transferID,
            totalChunks: safeTotalChunks,
            receivedChunks: 0,
            totalBytes: totalBytes,
            isComplete: false
        )
        activeTransfers[transferID] = initial

        let display = ActiveTransferDisplay(
            id: transferID,
            filename: filename,
            isOutgoing: isOutgoing,
            receivedChunks: 0,
            totalChunks: safeTotalChunks,
            progress: 0.0,
            isComplete: false,
            statusNote: Self.statusNote(
                receivedChunks: 0,
                totalChunks: safeTotalChunks,
                isOutgoing: isOutgoing,
                isComplete: false
            )
        )
        activeDisplays[transferID] = display
        scheduleCleanup(for: transferID, delayNanoseconds: 12_000_000_000)
    }

    public func updateProgress(
        transferID: UUID,
        receivedChunks: Int,
        totalChunks: Int,
        isOutgoing: Bool = false
    ) {
        let safeTotalChunks = max(1, totalChunks)
        let clampedReceived = min(max(0, receivedChunks), safeTotalChunks)
        let isComplete = clampedReceived >= safeTotalChunks

        let progress = MediaTransferProgress(
            transferID: transferID,
            totalChunks: safeTotalChunks,
            receivedChunks: clampedReceived,
            totalBytes: (activeTransfers[transferID]?.totalBytes) ?? (safeTotalChunks * 16_384),
            isComplete: isComplete
        )
        activeTransfers[transferID] = progress

        let existing = activeDisplays[transferID]
        let effectiveOutgoing = existing?.isOutgoing ?? isOutgoing
        let filename = existing?.filename ?? "Hình ảnh Mesh"

        activeDisplays[transferID] = ActiveTransferDisplay(
            id: transferID,
            filename: filename,
            isOutgoing: effectiveOutgoing,
            receivedChunks: clampedReceived,
            totalChunks: safeTotalChunks,
            progress: progress.fractionCompleted,
            isComplete: isComplete,
            statusNote: Self.statusNote(
                receivedChunks: clampedReceived,
                totalChunks: safeTotalChunks,
                isOutgoing: effectiveOutgoing,
                isComplete: isComplete
            )
        )

        if isComplete {
            // Keep briefly for completion feedback animation, then clear.
            scheduleCleanup(for: transferID, delayNanoseconds: 2_500_000_000)
        } else {
            scheduleCleanup(for: transferID, delayNanoseconds: 20_000_000_000)
        }
    }

    // MARK: - Helpers

    private static func statusNote(
        receivedChunks: Int,
        totalChunks: Int,
        isOutgoing: Bool,
        isComplete: Bool
    ) -> String {
        if isComplete {
            return "Hoàn tất \(totalChunks) mảnh"
        }
        return isOutgoing
            ? "Đang gửi mảnh \(receivedChunks)/\(totalChunks)"
            : "Đang nhận mảnh \(receivedChunks)/\(totalChunks)"
    }

    private func scheduleCleanup(for transferID: UUID, delayNanoseconds: UInt64) {
        cleanupTasks[transferID]?.cancel()
        cleanupTasks[transferID] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.activeTransfers.removeValue(forKey: transferID)
            self.activeDisplays.removeValue(forKey: transferID)
            self.cleanupTasks.removeValue(forKey: transferID)
        }
    }
}
#endif
