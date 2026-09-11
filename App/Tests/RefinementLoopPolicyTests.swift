import XCTest
import Shared
@testable import App

final class RefinementLoopPolicyTests: XCTestCase {
    func testAutomaticRefinementLoopIsDisabledByDefault() {
        XCTAssertFalse(AppCoordinator.shouldStartAutomaticRefinementLoop(
            defaultsValue: nil,
            environmentValue: nil
        ))
    }

    func testAutomaticRefinementLoopCanBeEnabledExplicitlyForManualDiagnostics() {
        XCTAssertTrue(AppCoordinator.shouldStartAutomaticRefinementLoop(
            defaultsValue: nil,
            environmentValue: "true"
        ))
    }

    func testHighResolutionSegmentsFinalizeBeforeRawWALBecomesHuge() {
        XCTAssertEqual(
            VideoSegmentSizingPolicy.maxFramesPerSegment(width: 1280, height: 720),
            VideoSegmentSizingPolicy.defaultMaxFramesPerSegment
        )

        let fiveKLimit = VideoSegmentSizingPolicy.maxFramesPerSegment(width: 5120, height: 2880)
        XCTAssertLessThan(fiveKLimit, VideoSegmentSizingPolicy.defaultMaxFramesPerSegment)
        XCTAssertGreaterThanOrEqual(fiveKLimit, VideoSegmentSizingPolicy.minimumMaxFramesPerSegment)
        XCTAssertLessThanOrEqual(
            VideoSegmentSizingPolicy.estimatedRawBytes(width: 5120, height: 2880, frames: fiveKLimit),
            VideoSegmentSizingPolicy.activeWALBudgetBytes + VideoSegmentSizingPolicy.estimatedRawBytes(width: 5120, height: 2880, frames: 1)
        )
    }

    func testFramesWithDurableWALMappingsBecomeReadableBeforeVideoFlush() {
        XCTAssertTrue(FrameReadinessPolicy.shouldMarkReadableAfterWALRegistration(true))
        XCTAssertFalse(FrameReadinessPolicy.shouldBufferUntilVideoFlush(didRegisterWALMapping: true))

        XCTAssertFalse(FrameReadinessPolicy.shouldMarkReadableAfterWALRegistration(false))
        XCTAssertTrue(FrameReadinessPolicy.shouldBufferUntilVideoFlush(didRegisterWALMapping: false))
    }

    func testDashboardFrameReadsUseBothBackingsAcrossFinalizationRaces() {
        XCTAssertEqual(
            LiveFrameReadPolicy.orderedSources(frameSource: .native, isVideoFinalized: false),
            [.activeWAL, .video]
        )
        XCTAssertEqual(
            LiveFrameReadPolicy.orderedSources(frameSource: .native, isVideoFinalized: true),
            [.video, .activeWAL]
        )
        XCTAssertEqual(
            LiveFrameReadPolicy.orderedSources(frameSource: .rewind, isVideoFinalized: true),
            [.video]
        )
    }
}
