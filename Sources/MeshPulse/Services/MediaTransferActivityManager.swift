#if canImport(SwiftUI)
import Foundation
import MeshCore
import Observation
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

#if canImport(ActivityKit) && os(iOS)
import ActivityKit

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

/// Manages media preparation (downscaling, compression) and progress tracking across
/// Dynamic Island (ActivityKit) and in-app chat bubble progress indicators.
@Observable
@MainActor
public final class MediaTransferActivityManager {
    public static let shared = MediaTransferActivityManager()

    public private(set) var activeTransfers: [UUID: MediaTransferProgress] = [:]

    #if canImport(ActivityKit) && os(iOS)
    private var liveActivities: [UUID: Activity<MeshMediaTransferAttributes>] = [:]
    #endif

    public init() {}

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

    // MARK: - Transfer Lifecycle & Dynamic Island Integration

    public func trackTransferStarted(
        transferID: UUID,
        totalChunks: Int,
        totalBytes: Int,
        isOutgoing: Bool,
        filename: String = "Hình ảnh Mesh"
    ) {
        let initial = MediaTransferProgress(
            transferID: transferID,
            totalChunks: totalChunks,
            receivedChunks: 0,
            totalBytes: totalBytes,
            isComplete: false
        )
        activeTransfers[transferID] = initial

        #if canImport(ActivityKit) && os(iOS)
        if ActivityAuthorizationInfo().areActivitiesEnabled {
            let attributes = MeshMediaTransferAttributes(
                transferID: transferID.uuidString,
                filename: filename,
                isOutgoing: isOutgoing
            )
            let initialState = MeshMediaTransferAttributes.ContentState(
                progress: 0.0,
                receivedChunks: 0,
                totalChunks: totalChunks,
                statusNote: isOutgoing ? "Đang gửi mảnh 0/\(totalChunks)..." : "Đang nhận mảnh 0/\(totalChunks)..."
            )

            do {
                let activity = try Activity.request(
                    attributes: attributes,
                    content: .init(state: initialState, staleDate: nil)
                )
                liveActivities[transferID] = activity
            } catch {
                print("[MediaTransferActivityManager] Failed to start Live Activity: \(error)")
            }
        }
        #endif
    }

    public func updateProgress(
        transferID: UUID,
        receivedChunks: Int,
        totalChunks: Int,
        isOutgoing: Bool = false
    ) {
        let isComplete = receivedChunks >= totalChunks
        let progress = MediaTransferProgress(
            transferID: transferID,
            totalChunks: totalChunks,
            receivedChunks: receivedChunks,
            totalBytes: (activeTransfers[transferID]?.totalBytes) ?? (totalChunks * 16_384),
            isComplete: isComplete
        )
        activeTransfers[transferID] = progress

        #if canImport(ActivityKit) && os(iOS)
        if let activity = liveActivities[transferID] {
            let state = MeshMediaTransferAttributes.ContentState(
                progress: progress.fractionCompleted,
                receivedChunks: receivedChunks,
                totalChunks: totalChunks,
                statusNote: isComplete
                    ? "✓ Hoàn tất truyền nhận (\(totalChunks) mảnh)"
                    : (isOutgoing ? "Đang gửi mảnh \(receivedChunks)/\(totalChunks)..." : "Đang nhận mảnh \(receivedChunks)/\(totalChunks)...")
            )
            Task {
                await activity.update(.init(state: state, staleDate: nil))
                if isComplete {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await activity.end(dismissalPolicy: .immediate)
                    await MainActor.run {
                        self.liveActivities.removeValue(forKey: transferID)
                    }
                }
            }
        }
        #endif

        if isComplete {
            // Keep in activeTransfers briefly for UI animation, then clear
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await MainActor.run {
                    self.activeTransfers.removeValue(forKey: transferID)
                }
            }
        }
    }
}
#endif
