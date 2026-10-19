import XCTest

/// Headless checks for the Pill and Dot styles: style storage and fallbacks, the side slots,
/// the window sizes they drive, the recording clock and the synthetic input of the settings
/// preview. No window is created.
final class RecorderStyleTests: XCTestCase {
    // MARK: - Style storage and migration

    func testExistingStoredStylesKeepTheirMeaning() {
        XCTAssertEqual(RecorderPanelStyle(storedValue: "mini"), .mini)
        XCTAssertEqual(RecorderPanelStyle(storedValue: "notch"), .notch)
    }

    func testNewStylesAreStoredByName() {
        XCTAssertEqual(RecorderPanelStyle(storedValue: "pill"), .pill)
        XCTAssertEqual(RecorderPanelStyle(storedValue: "dot"), .dot)
    }

    func testMissingOrUnknownStoredStyleIsMini() {
        XCTAssertEqual(RecorderPanelStyle(storedValue: nil), .mini)
        XCTAssertEqual(RecorderPanelStyle(storedValue: ""), .mini)
        XCTAssertEqual(RecorderPanelStyle(storedValue: "hologram"), .mini)
    }

    func testPickerOrderIsMiniNotchPillDot() {
        XCTAssertEqual(RecorderPanelStyle.allCases, [.mini, .notch, .pill, .dot])
    }

    func testOnlyNotchUsesTheNotchPanel() {
        XCTAssertEqual(RecorderPanelStyle.allCases.filter { !$0.usesMiniPanel }, [.notch])
    }

    func testDotHasNoSidesAndNoLiveText() {
        XCTAssertFalse(RecorderPanelStyle.dot.hasSideSlots)
        XCTAssertFalse(RecorderPanelStyle.dot.showsLiveTranscript)
        for style in [RecorderPanelStyle.mini, .notch, .pill] {
            XCTAssertTrue(style.hasSideSlots, style.rawValue)
            XCTAssertTrue(style.showsLiveTranscript, style.rawValue)
        }
    }

    // MARK: - Style fallback

    func testDotBecomesPillWhileTheAssistantIsOpen() {
        XCTAssertEqual(RecorderDisplayPlanner.layoutStyle(for: .dot, assistantVisible: false), .dot)
        XCTAssertEqual(RecorderDisplayPlanner.layoutStyle(for: .dot, assistantVisible: true), .pill)
    }

    func testOtherStylesKeepTheirLayoutWithTheAssistant() {
        for style in [RecorderPanelStyle.mini, .notch, .pill] {
            XCTAssertEqual(RecorderDisplayPlanner.layoutStyle(for: style, assistantVisible: true), style)
            XCTAssertEqual(RecorderDisplayPlanner.layoutStyle(for: style, assistantVisible: false), style)
        }
    }

    func testNotchFallbackStillGivesMiniNotPill() {
        let plain = RecorderDisplayInfo(id: 1, name: "Built-in", isBuiltIn: true, hasNotch: false)
        XCTAssertEqual(RecorderDisplayPlanner.effectiveStyle(requested: .notch, display: plain), .mini)
        for style in [RecorderPanelStyle.mini, .pill, .dot] {
            XCTAssertEqual(RecorderDisplayPlanner.effectiveStyle(requested: style, display: plain), style)
        }
    }

    // MARK: - Side slots

    func testDefaultsKeepTodaysLookForMiniAndNotch() {
        for style in [RecorderPanelStyle.mini, .notch] {
            let slots = RecorderSideSlots.defaults(for: style)
            XCTAssertEqual(slots.left, .none, style.rawValue)
            XCTAssertEqual(slots.right, .level, style.rawValue)
        }
    }

    func testPillDefaultsToTimerAndLevel() {
        XCTAssertEqual(RecorderSideSlots.defaults(for: .pill), RecorderSideSlots(left: .timer, right: .level))
    }

    func testEmptyStorageGivesTheDefaults() {
        for style in RecorderPanelStyle.allCases {
            XCTAssertEqual(RecorderSideSlots(storedValue: nil, style: style), .defaults(for: style))
            let defaults = UserDefaults(suiteName: "pnoe.tests.slots.\(UUID().uuidString)")!
            XCTAssertEqual(RecorderSideSlots(defaults: defaults, style: style), .defaults(for: style))
        }
    }

    func testStoredSlotsRoundTrip() {
        for left in RecorderSlotContent.allCases {
            for right in RecorderSlotContent.allCases {
                let slots = RecorderSideSlots(left: left, right: right)
                XCTAssertEqual(RecorderSideSlots(storedValue: slots.storedValue, style: .mini), slots)
            }
        }
    }

    func testMalformedStorageFallsBackPerSide() {
        XCTAssertEqual(RecorderSideSlots(storedValue: "timer", style: .mini), .defaults(for: .mini))
        XCTAssertEqual(RecorderSideSlots(storedValue: "timer,level,none", style: .mini), .defaults(for: .mini))
        XCTAssertEqual(RecorderSideSlots(storedValue: "", style: .pill), .defaults(for: .pill))
        // An unknown token (a newer build wrote it) takes that side's default only.
        XCTAssertEqual(
            RecorderSideSlots(storedValue: "waveform,timer", style: .mini),
            RecorderSideSlots(left: .none, right: .timer))
        XCTAssertEqual(
            RecorderSideSlots(storedValue: "modeName,waveform", style: .mini),
            RecorderSideSlots(left: .modeName, right: .level))
    }

    func testTheSameItemOnBothSidesKeepsTheLeftOne() {
        let slots = RecorderSideSlots(storedValue: "timer,timer", style: .pill)
        XCTAssertEqual(slots, RecorderSideSlots(left: .timer, right: .none))
        // "Nothing" on both sides is allowed.
        XCTAssertEqual(RecorderSideSlots(left: .none, right: .none).right, .none)
    }

    func testPickingWhatTheOtherSideShowsSwapsTheSides() {
        let slots = RecorderSideSlots(left: .timer, right: .level)
        XCTAssertEqual(slots.setting(.left, to: .level), RecorderSideSlots(left: .level, right: .timer))
        XCTAssertEqual(slots.setting(.right, to: .timer), RecorderSideSlots(left: .level, right: .timer))
    }

    func testPickingSomethingElseOnlyChangesThatSide() {
        let slots = RecorderSideSlots(left: .timer, right: .level)
        XCTAssertEqual(slots.setting(.left, to: .modeName), RecorderSideSlots(left: .modeName, right: .level))
        XCTAssertEqual(slots.setting(.right, to: .none), RecorderSideSlots(left: .timer, right: .none))
        // Nothing next to Nothing is not a swap.
        let empty = RecorderSideSlots(left: .none, right: .level)
        XCTAssertEqual(empty.setting(.right, to: .none), RecorderSideSlots(left: .none, right: .none))
        XCTAssertEqual(empty.setting(.left, to: .none), empty)
    }

    func testSettingsReadSlotsPerStyleAndDefaultWhenUnset() {
        let suite = "pnoe.tests.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(RecorderIndicatorSettings(defaults: defaults), RecorderIndicatorSettings())

        defaults.set("modeName,timer", forKey: RecorderSideSlots.storageKey(for: .pill))
        let settings = RecorderIndicatorSettings(defaults: defaults)
        XCTAssertEqual(settings.slots(for: .pill), RecorderSideSlots(left: .modeName, right: .timer))
        XCTAssertEqual(settings.slots(for: .mini), .defaults(for: .mini))
        XCTAssertNotEqual(settings, RecorderIndicatorSettings())
    }

    func testSlotKeysDifferPerStyle() {
        let keys = Set(RecorderPanelStyle.allCases.map(RecorderSideSlots.storageKey(for:)))
        XCTAssertEqual(keys.count, RecorderPanelStyle.allCases.count)
    }

    // MARK: - Bar and window sizes

    func testDefaultMiniBarKeepsItsWidth() {
        let slots = RecorderSideSlots.defaults(for: .mini)
        XCTAssertEqual(RecorderBarMetrics.miniBarWidth(slots: slots), 184)
        XCTAssertEqual(RecorderBarMetrics.miniExpandedBarWidth(slots: slots), 300)
    }

    func testMiniBarGrowsForWideSlots() {
        let slots = RecorderSideSlots(left: .modeName, right: .level)
        XCTAssertGreaterThan(RecorderBarMetrics.miniBarWidth(slots: slots), 184)
        XCTAssertEqual(
            RecorderBarMetrics.miniBarWidth(slots: slots),
            RecorderBarMetrics.miniChrome + 64 + 10 + RecorderLevelMetrics.meterWidth)
    }

    func testPillBarFitsItsSlots() {
        let none = RecorderSideSlots(left: .none, right: .none)
        let both = RecorderSideSlots.defaults(for: .pill)
        XCTAssertLessThan(
            RecorderBarMetrics.pillBarWidth(slots: none), RecorderBarMetrics.pillBarWidth(slots: both))
        XCTAssertEqual(
            RecorderBarMetrics.pillBarWidth(slots: both),
            10 + 21 + 10 + RecorderSlotContent.timer.width + 10 + RecorderLevelMetrics.meterWidth + 12)
    }

    func testDefaultNotchReachIsUnchanged() {
        let slots = RecorderSideSlots.defaults(for: .notch)
        XCTAssertEqual(RecorderBarMetrics.notchSideExpansion(base: 90, edgePadding: 16, slots: slots), 90)
        XCTAssertEqual(RecorderBarMetrics.notchSideExpansion(base: 110, edgePadding: 20, slots: slots), 110)
        XCTAssertEqual(RecorderBarMetrics.notchSideExpansion(base: 230, edgePadding: 20, slots: slots), 230)
        XCTAssertEqual(RecorderPanelSizing.notchMaxSideExpansion(compact: true, slots: slots), 100)
        XCTAssertEqual(RecorderPanelSizing.notchMaxSideExpansion(compact: false, slots: slots), 240)
    }

    func testNotchReachGrowsForALeftSlot() {
        let slots = RecorderSideSlots(left: .timer, right: .level)
        // 16 edge + 21 + 14 + 20 + 14 + the timer.
        let needed: CGFloat = 16 + 21 + 14 + 20 + 14 + RecorderSlotContent.timer.width
        XCTAssertEqual(RecorderBarMetrics.notchSideExpansion(base: 90, edgePadding: 16, slots: slots), needed)
        XCTAssertGreaterThan(needed, 90)
        XCTAssertGreaterThanOrEqual(RecorderPanelSizing.notchMaxSideExpansion(compact: true, slots: slots), needed)
    }

    func testMiniHostSizeIsUnchangedForTheDefaults() {
        let slots = RecorderSideSlots.defaults(for: .mini)
        XCTAssertEqual(
            RecorderPanelSizing.miniHostSize(style: .mini, compact: false, assistantVisible: false, slots: slots),
            CGSize(width: 540, height: 430))
        XCTAssertEqual(
            RecorderPanelSizing.miniHostSize(style: .mini, compact: true, assistantVisible: false, slots: slots),
            CGSize(width: 200, height: 48))
    }

    func testCompactPillWindowIsOnlyAsLargeAsItsBar() {
        let slots = RecorderSideSlots.defaults(for: .pill)
        let size = RecorderPanelSizing.miniHostSize(
            style: .pill, compact: true, assistantVisible: false, slots: slots)
        XCTAssertEqual(size.width, RecorderBarMetrics.pillBarWidth(slots: slots) + 16)
        XCTAssertLessThan(size.height, 60)
    }

    func testDotWindowIsSmallUntilTheAssistantOpens() {
        let slots = RecorderSideSlots.defaults(for: .pill)
        for compact in [false, true] {
            XCTAssertEqual(
                RecorderPanelSizing.miniHostSize(
                    style: .dot, compact: compact, assistantVisible: false, slots: slots),
                RecorderPanelSizing.dotHostSize)
        }
        XCTAssertEqual(
            RecorderPanelSizing.miniHostSize(style: .dot, compact: false, assistantVisible: true, slots: slots),
            RecorderPanelSizing.miniHostSize)
        // An idle, compact dot that gets the assistant opens the full window too.
        XCTAssertEqual(
            RecorderPanelSizing.miniHostSize(style: .dot, compact: true, assistantVisible: true, slots: slots),
            RecorderPanelSizing.miniHostSize)
    }

    func testDotFitsItsWindow() {
        XCTAssertLessThanOrEqual(RecorderDotMetrics.width(showsTimer: true), RecorderPanelSizing.dotHostSize.width)
        XCTAssertLessThanOrEqual(RecorderDotMetrics.capsuleHeight, RecorderPanelSizing.dotHostSize.height)
    }

    // MARK: - Dot

    func testDotHaloFollowsTheLevelAndStaysInItsArea() {
        XCTAssertEqual(RecorderDotMetrics.haloScale(level: 0), 1)
        XCTAssertEqual(RecorderDotMetrics.haloScale(level: 1), 2)
        XCTAssertEqual(RecorderDotMetrics.haloScale(level: 5), 2)
        XCTAssertEqual(RecorderDotMetrics.haloScale(level: -1), 1)
        XCTAssertLessThan(
            RecorderDotMetrics.diameter * RecorderDotMetrics.haloScale(level: 1), RecorderDotMetrics.areaSize)
    }

    func testDotShowsItsTimerWhileTheTakeIsProcessed() {
        XCTAssertTrue(RecorderDotView.showsTimer(for: .recording))
        XCTAssertTrue(RecorderDotView.showsTimer(for: .transcribing))
        XCTAssertTrue(RecorderDotView.showsTimer(for: .enhancing))
        XCTAssertFalse(RecorderDotView.showsTimer(for: .idle))
        XCTAssertFalse(RecorderDotView.showsTimer(for: .starting))
    }

    func testOnlyIdleAndRecordingAcceptAClickOnTheRecordControl() {
        XCTAssertTrue(RecordingState.idle.allowsRecordButton)
        XCTAssertTrue(RecordingState.recording.allowsRecordButton)
        for state in [RecordingState.starting, .transcribing, .enhancing, .busy] {
            XCTAssertFalse(state.allowsRecordButton, "\(state)")
        }
    }

    // MARK: - Recording clock

    func testClockCountsFromStartAndFreezesOnStop() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        var clock = RecordingClock()
        XCTAssertEqual(clock.elapsed(at: start), 0)
        clock.start(at: start)
        XCTAssertEqual(clock.elapsed(at: start.addingTimeInterval(7.4)), 7.4, accuracy: 0.001)
        clock.stop(at: start.addingTimeInterval(12))
        XCTAssertEqual(clock.elapsed(at: start.addingTimeInterval(500)), 12, accuracy: 0.001)
        clock.stop(at: start.addingTimeInterval(20))
        XCTAssertEqual(clock.elapsed(at: start.addingTimeInterval(500)), 12, accuracy: 0.001)
        clock.start(at: start.addingTimeInterval(100))
        XCTAssertEqual(clock.elapsed(at: start.addingTimeInterval(103)), 3, accuracy: 0.001)
    }

    func testStoppingAClockThatNeverStartedDoesNothing() {
        var clock = RecordingClock()
        clock.stop(at: Date())
        XCTAssertEqual(clock, RecordingClock())
        XCTAssertEqual(clock.elapsed(at: Date()), 0)
    }

    func testClockNeverGoesNegative() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let clock = RecordingClock(startedAt: start)
        XCTAssertEqual(clock.elapsed(at: start.addingTimeInterval(-5)), 0)
    }

    func testClockFormat() {
        XCTAssertEqual(RecordingClock.format(0), "0:00")
        XCTAssertEqual(RecordingClock.format(7.9), "0:07")
        XCTAssertEqual(RecordingClock.format(59.99), "0:59")
        XCTAssertEqual(RecordingClock.format(60), "1:00")
        XCTAssertEqual(RecordingClock.format(723), "12:03")
        XCTAssertEqual(RecordingClock.format(3723), "1:02:03")
        XCTAssertEqual(RecordingClock.format(-4), "0:00")
        XCTAssertEqual(RecordingClock.format(.nan), "0:00")
        XCTAssertEqual(RecordingClock.format(.infinity), "0:00")
    }

    func testLoopingClockRestartsEveryPeriod() {
        let base = Date(timeIntervalSinceReferenceDate: 90 * 40)
        let atStart = RecordingClock.looping(period: 90, at: base)
        XCTAssertEqual(atStart.elapsed(at: base), 0, accuracy: 0.001)
        let later = base.addingTimeInterval(30)
        XCTAssertEqual(RecordingClock.looping(period: 90, at: later).elapsed(at: later), 30, accuracy: 0.001)
        let wrapped = base.addingTimeInterval(95)
        XCTAssertEqual(RecordingClock.looping(period: 90, at: wrapped).elapsed(at: wrapped), 5, accuracy: 0.001)
    }

    // MARK: - Synthetic input for the preview

    func testSyntheticLevelsStayInRange() {
        for step in 0..<2000 {
            let level = SyntheticLevels.level(at: 5000 + Double(step) * 0.017)
            XCTAssertTrue((0...1).contains(level), "\(level)")
        }
    }

    func testSyntheticLevelsAreDeterministic() {
        XCTAssertEqual(SyntheticLevels.level(at: 1234.5), SyntheticLevels.level(at: 1234.5))
        XCTAssertEqual(
            SyntheticLevels.history(endingAt: 1234.5).levels, SyntheticLevels.history(endingAt: 1234.5).levels)
    }

    func testSyntheticHistoryFillsTheWholeRingAndMoves() {
        let history = SyntheticLevels.history(endingAt: 321.0)
        XCTAssertEqual(history.count, RecorderLevelMetrics.historyCapacity)
        XCTAssertGreaterThan((history.levels.max() ?? 0) - (history.levels.min() ?? 0), 0.4)
    }

    func testSyntheticInputSpeaksAndPauses() {
        var speaking = 0
        var quiet = 0
        for step in 0..<340 {
            let level = SyntheticLevels.level(at: Double(step) * 0.01)
            if level > 0.3 { speaking += 1 }
            if level < 0.1 { quiet += 1 }
        }
        XCTAssertGreaterThan(speaking, 20)
        XCTAssertGreaterThan(quiet, 80)
    }

    // MARK: - Preview configuration

    private func configuration(style: RecorderPanelStyle, liveText: Bool = true) -> RecorderStylePreviewConfiguration {
        RecorderStylePreviewConfiguration(
            style: style, theme: .dark, placement: .bottom, slots: .defaults(for: style),
            levelDisplay: .bars, showsLiveText: liveText, transcriptSize: .medium, modeName: "Notes")
    }

    func testPreviewShowsSampleTextOnlyWhereTheStyleCarriesIt() {
        for style in [RecorderPanelStyle.mini, .notch, .pill] {
            XCTAssertEqual(
                configuration(style: style).liveContent, .text(RecorderStylePreviewConfiguration.sampleText),
                style.rawValue)
            XCTAssertNil(configuration(style: style, liveText: false).liveContent, style.rawValue)
        }
        XCTAssertNil(configuration(style: .dot).liveContent)
    }
}
