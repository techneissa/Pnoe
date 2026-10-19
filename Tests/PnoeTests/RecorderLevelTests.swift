import CoreGraphics
import XCTest

/// Headless checks for the recorder's level display: decibel mapping, the ring buffer, and the
/// sizes the Bars and Wave styles are drawn with.
final class RecorderLevelTests: XCTestCase {
    // MARK: - Level mapping

    func testRoomNoiseReadsFlat() {
        for decibels: Float in [-160, -70, -60, -55, -50] {
            XCTAssertEqual(LevelMapping.level(fromDecibels: decibels), 0, accuracy: 0.0001, "\(decibels) dB")
        }
    }

    func testNormalSpeechFillsMostOfTheHeight() {
        for decibels: Float in [-28, -24, -20] {
            XCTAssertGreaterThan(LevelMapping.level(fromDecibels: decibels), 0.65, "\(decibels) dB")
        }
        XCTAssertLessThan(LevelMapping.level(fromDecibels: -42), 0.3)
    }

    func testPeaksAreClippedNotOverflowing() {
        XCTAssertEqual(LevelMapping.level(fromDecibels: LevelMapping.ceilingDecibels), 1, accuracy: 0.0001)
        XCTAssertEqual(LevelMapping.level(fromDecibels: -6), 1)
        XCTAssertEqual(LevelMapping.level(fromDecibels: 0), 1)
        XCTAssertEqual(LevelMapping.level(fromDecibels: 12), 1)
        XCTAssertEqual(LevelMapping.level(fromDecibels: .infinity), 1)
    }

    func testUnreadableValuesAreSilence() {
        XCTAssertEqual(LevelMapping.level(fromDecibels: .nan), 0)
        XCTAssertEqual(LevelMapping.level(fromDecibels: -.infinity), 0)
    }

    func testMappingRisesWithLoudness() {
        var previous: Float = -1
        for decibels in stride(from: Float(-60), through: 0, by: 1) {
            let level = LevelMapping.level(fromDecibels: decibels)
            XCTAssertGreaterThanOrEqual(level, previous)
            previous = level
        }
    }

    func testSmoothingAttacksAtOnceAndReleasesSlowly() {
        XCTAssertEqual(LevelMapping.smoothed(previous: 0.2, next: 0.9), 0.9)
        let released = LevelMapping.smoothed(previous: 0.8, next: 0, release: 0.25)
        XCTAssertEqual(released, 0.6, accuracy: 0.0001)
        XCTAssertEqual(LevelMapping.smoothed(previous: 0.5, next: 0.5), 0.5)
    }

    // MARK: - Ring buffer

    func testEmptyHistory() {
        let history = LevelHistory(capacity: 4)
        XCTAssertEqual(history.count, 0)
        XCTAssertNil(history.latest)
        XCTAssertEqual(history.recent(4), [])
        XCTAssertEqual(history.levels, [])
    }

    func testHistoryKeepsOldestFirstUntilFull() {
        var history = LevelHistory(capacity: 4)
        history.append(0.1)
        history.append(0.2)
        history.append(0.3)
        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history.levels, [0.1, 0.2, 0.3])
        XCTAssertEqual(history.latest, 0.3)
        XCTAssertEqual(history.recent(2), [0.2, 0.3])
        XCTAssertEqual(history.recent(10), [0.1, 0.2, 0.3])
        XCTAssertEqual(history.recent(0), [])
        XCTAssertEqual(history.recent(-3), [])
    }

    func testHistoryOverwritesTheOldestWhenFull() {
        var history = LevelHistory(capacity: 3)
        for level: Float in [0.1, 0.2, 0.3, 0.4, 0.5] { history.append(level) }
        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history.levels, [0.3, 0.4, 0.5])
        XCTAssertEqual(history.latest, 0.5)
        XCTAssertEqual(history.recent(2), [0.4, 0.5])
    }

    func testHistoryWrapsManyTimes() {
        var history = LevelHistory(capacity: 5)
        for index in 0..<103 { history.append(Float(index % 10) / 10) }
        XCTAssertEqual(history.count, 5)
        XCTAssertEqual(history.levels, [0.8, 0.9, 0.0, 0.1, 0.2])
    }

    func testHistoryClipsAndSanitizesLevels() {
        var history = LevelHistory(capacity: 4)
        history.append(1.7)
        history.append(-0.4)
        history.append(.nan)
        XCTAssertEqual(history.levels, [1, 0, 0])
    }

    func testRemoveAllEmptiesTheHistory() {
        var history = LevelHistory(capacity: 3)
        for level: Float in [0.1, 0.2, 0.3, 0.4] { history.append(level) }
        history.removeAll()
        XCTAssertEqual(history.count, 0)
        XCTAssertNil(history.latest)
        history.append(0.9)
        XCTAssertEqual(history.levels, [0.9])
    }

    func testHistoryHasAtLeastOneSlot() {
        var history = LevelHistory(capacity: 0)
        history.append(0.5)
        history.append(0.6)
        XCTAssertEqual(history.levels, [0.6])
    }

    func testDefaultCapacityHoldsTwoSecondsAtTheSamplingRate() {
        XCTAssertEqual(
            Double(LevelHistory().capacity) / RecorderLevelMetrics.samplesPerSecond, 2, accuracy: 0.0001)
    }

    // MARK: - History to bars

    func testBarHeightsPlaceTheNewestLevelAtTheTrailingEnd() {
        let history = LevelHistory(levels: [0, 0.5, 1], capacity: 10)
        let heights = LevelDisplayGeometry.barHeights(history: history, barCount: 3, minHeight: 4, maxHeight: 28)
        XCTAssertEqual(heights, [4, 16, 28])
    }

    func testShortHistoryPadsTheLeadingBarsAtMinimumHeight() {
        let history = LevelHistory(levels: [1, 1], capacity: 10)
        let heights = LevelDisplayGeometry.barHeights(history: history, barCount: 5, minHeight: 4, maxHeight: 28)
        XCTAssertEqual(heights, [4, 4, 4, 28, 28])
    }

    func testBarsShowOnlyTheNewestLevelsWhenHistoryIsLonger() {
        let history = LevelHistory(levels: [1, 0.5, 0, 0], capacity: 10)
        let heights = LevelDisplayGeometry.barHeights(history: history, barCount: 3, minHeight: 4, maxHeight: 28)
        XCTAssertEqual(heights, [16, 4, 4])
    }

    func testBarsScrollAsLevelsArrive() {
        var history = LevelHistory(capacity: 10)
        history.append(0.5)
        let first = LevelDisplayGeometry.barHeights(history: history, barCount: 3, minHeight: 4, maxHeight: 28)
        history.append(1)
        let second = LevelDisplayGeometry.barHeights(history: history, barCount: 3, minHeight: 4, maxHeight: 28)
        XCTAssertEqual(first, [4, 4, 16])
        XCTAssertEqual(second, [4, 16, 28])
    }

    func testEmptyHistoryGivesFlatBars() {
        let heights = LevelDisplayGeometry.barHeights(
            history: LevelHistory(), barCount: 4, minHeight: 4, maxHeight: 28)
        XCTAssertEqual(heights, [4, 4, 4, 4])
    }

    func testBarHeightsNeverLeaveTheRange() {
        var history = LevelHistory(capacity: 6)
        for level: Float in [-3, 0, 0.4, 1, 9, .nan] { history.append(level) }
        let heights = LevelDisplayGeometry.barHeights(history: history, barCount: 6, minHeight: 4, maxHeight: 28)
        XCTAssertEqual(heights.count, 6)
        XCTAssertTrue(heights.allSatisfy { $0 >= 4 && $0 <= 28 })
    }

    func testZeroBarsGiveNothing() {
        XCTAssertEqual(
            LevelDisplayGeometry.barHeights(history: LevelHistory(), barCount: 0, minHeight: 4, maxHeight: 28), [])
    }

    // MARK: - History to wave

    func testWaveHalfHeightsFollowTheHistoryAndKeepAThinLineWhenSilent() {
        let history = LevelHistory(levels: [0, 1, 0.5], capacity: 10)
        let halves = LevelDisplayGeometry.waveHalfHeights(
            history: history, pointCount: 5, minHalfHeight: 2, maxHalfHeight: 14)
        XCTAssertEqual(halves, [2, 2, 2, 14, 8])
    }

    func testWaveWithNoPointsIsEmpty() {
        XCTAssertEqual(
            LevelDisplayGeometry.waveHalfHeights(
                history: LevelHistory(), pointCount: 0, minHalfHeight: 2, maxHalfHeight: 14), [])
    }

    // MARK: - Reduce Motion level bar

    func testMeterFractionIsTheNewestLevel() {
        XCTAssertEqual(LevelDisplayGeometry.meterFraction(history: LevelHistory()), 0)
        XCTAssertEqual(LevelDisplayGeometry.meterFraction(history: LevelHistory(levels: [0.9, 0.25])), 0.25)
    }

    func testVisualizerFitsTheNotchSideArea() {
        // The Notch layout gives the status display 90 pt minus 16 pt of edge padding.
        XCTAssertLessThanOrEqual(AudioVisualizer.width, 74)
        XCTAssertEqual(AudioVisualizer.width, CGFloat(RecorderLevelMetrics.barCount) * 2.5 - 1)
    }

    // MARK: - Setting

    func testLevelDisplayDefaultsAndNames() {
        XCTAssertEqual(RecorderLevelDisplay.allCases, [.bars, .wave])
        XCTAssertEqual(RecorderLevelDisplay(rawValue: "bars"), .bars)
        XCTAssertEqual(RecorderLevelDisplay(rawValue: "wave"), .wave)
        XCTAssertNil(RecorderLevelDisplay(rawValue: "sine"))
        XCTAssertEqual(RecorderLevelDisplay.bars.displayName, "Bars")
        XCTAssertEqual(RecorderLevelDisplay.wave.displayName, "Wave")
    }
}
