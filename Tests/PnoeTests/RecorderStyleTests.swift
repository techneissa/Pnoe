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

    func testEveryStyleWithSidesDefaultsToLevelInTheCentreAndTimerOnTheRight() {
        for style in [RecorderPanelStyle.mini, .notch, .pill] {
            let slots = RecorderSideSlots.defaults(for: style)
            XCTAssertEqual(slots.left, .none, style.rawValue)
            XCTAssertEqual(slots.center, .level, style.rawValue)
            XCTAssertEqual(slots.right, .timer, style.rawValue)
        }
    }

    func testTheCentreShowsTheLevelUnlessASideShowsIt() {
        XCTAssertEqual(RecorderSideSlots(left: .none, right: .none).center, .level)
        XCTAssertEqual(RecorderSideSlots(left: .timer, right: .modeName).center, .level)
        XCTAssertEqual(RecorderSideSlots(left: .level, right: .timer).center, .none)
        XCTAssertEqual(RecorderSideSlots(left: .timer, right: .level).center, .none)
    }

    func testSlotsKeepTheirPositions() {
        // Left stays the left slot and right the right one, whatever else is chosen.
        let slots = RecorderSideSlots(left: .timer, right: .modeName)
        XCTAssertEqual(slots.content(on: .left), .timer)
        XCTAssertEqual(slots.content(on: .right), .modeName)
        XCTAssertEqual(slots.center, .level)
        XCTAssertEqual(slots.storedValue, "timer,modeName")
        let parsed = RecorderSideSlots(storedValue: "timer,modeName", style: .pill)
        XCTAssertEqual([parsed.left, parsed.center, parsed.right], [.timer, .level, .modeName])
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
            RecorderSideSlots(left: .modeName, right: .timer))
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

    func testDefaultMiniBarWidth() {
        let slots = RecorderSideSlots.defaults(for: .mini)
        // 65 for the buttons, 94 for the centred level meter with its gaps, 46 for the timer.
        let width = 10 + 21 + 12 + 22 + (RecorderLevelMetrics.meterWidth + 20) + (RecorderSlotContent.timer.width + 10)
        XCTAssertEqual(RecorderBarMetrics.miniBarWidth(slots: slots), width)
        XCTAssertEqual(RecorderBarMetrics.miniExpandedBarWidth(slots: slots), 300)
    }

    func testMiniBarGrowsForWideSlots() {
        let narrow = RecorderSideSlots.defaults(for: .mini)
        let wide = RecorderSideSlots(left: .modeName, right: .timer)
        XCTAssertEqual(
            RecorderBarMetrics.miniBarWidth(slots: wide) - RecorderBarMetrics.miniBarWidth(slots: narrow),
            RecorderSlotContent.modeName.width + 10)
    }

    func testMiniBarWithTheLevelOnASideHasNoCentre() {
        let side = RecorderSideSlots(left: .none, right: .level)
        XCTAssertEqual(
            RecorderBarMetrics.miniBarWidth(slots: side),
            max(184, 10 + 21 + 12 + 22 + RecorderLevelMetrics.meterWidth + 10))
    }

    func testPillBarFitsItsSlots() {
        let level = RecorderSideSlots(left: .none, right: .level)
        let both = RecorderSideSlots.defaults(for: .pill)
        XCTAssertGreaterThan(
            RecorderBarMetrics.pillBarWidth(slots: both), RecorderBarMetrics.pillBarWidth(slots: level))
        XCTAssertEqual(
            RecorderBarMetrics.pillBarWidth(slots: both),
            10 + 21 + (RecorderLevelMetrics.meterWidth + 20) + (RecorderSlotContent.timer.width + 10) + 12)
    }

    func testDefaultNotchReach() {
        let slots = RecorderSideSlots.defaults(for: .notch)
        // The level meter sits beside the notch and the timer at the outer edge.
        let right = 16 + 14 + RecorderLevelMetrics.meterWidth + 14 + RecorderSlotContent.timer.width
        XCTAssertEqual(RecorderBarMetrics.notchSideExpansion(base: 90, edgePadding: 16, slots: slots), right)
        XCTAssertEqual(
            RecorderBarMetrics.notchSideExpansion(base: 110, edgePadding: 20, slots: slots), right + 4)
        XCTAssertEqual(RecorderBarMetrics.notchSideExpansion(base: 230, edgePadding: 20, slots: slots), 230)
        XCTAssertEqual(RecorderPanelSizing.notchMaxSideExpansion(compact: true, slots: slots), right)
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

    func testMiniHostSizeForTheDefaults() {
        let slots = RecorderSideSlots.defaults(for: .mini)
        XCTAssertEqual(
            RecorderPanelSizing.miniHostSize(style: .mini, compact: false, assistantVisible: false, slots: slots),
            CGSize(width: 540, height: 430))
        let compact = RecorderPanelSizing.miniHostSize(
            style: .mini, compact: true, assistantVisible: false, slots: slots)
        XCTAssertEqual(compact.width, RecorderBarMetrics.miniBarWidth(slots: slots) + 16)
        XCTAssertEqual(compact.height, 48)
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

    func testOnlyIdleRecordingAndTheOutcomesAcceptAClickOnTheRecordControl() {
        XCTAssertTrue(RecordingState.idle.allowsRecordButton)
        XCTAssertTrue(RecordingState.recording.allowsRecordButton)
        XCTAssertTrue(RecordingState.done.allowsRecordButton)
        XCTAssertTrue(RecordingState.failed.allowsRecordButton)
        for state in [RecordingState.starting, .transcribing, .enhancing, .busy] {
            XCTAssertFalse(state.allowsRecordButton, "\(state)")
        }
    }

    // MARK: - Recording clock

    func testClockCountsFromStartAndFreezesOnStop() {
        var clock = RecordingClock()
        XCTAssertEqual(clock.elapsed(at: 1000), 0)
        clock.start(at: 1000)
        XCTAssertEqual(clock.elapsed(at: 1007.4), 7.4, accuracy: 0.001)
        clock.stop(at: 1012)
        XCTAssertEqual(clock.elapsed(at: 1500), 12, accuracy: 0.001)
        clock.stop(at: 1020)
        XCTAssertEqual(clock.elapsed(at: 1500), 12, accuracy: 0.001)
        clock.start(at: 1100)
        XCTAssertEqual(clock.elapsed(at: 1103), 3, accuracy: 0.001)
    }

    func testStoppingAClockThatNeverStartedDoesNothing() {
        var clock = RecordingClock()
        clock.stop(at: 50)
        XCTAssertEqual(clock, RecordingClock())
        XCTAssertEqual(clock.elapsed(at: 60), 0)
    }

    func testClockNeverGoesNegative() {
        XCTAssertEqual(RecordingClock(startedAt: 1000).elapsed(at: 995), 0)
    }

    func testClockReadsTheMonotonicUptimeNotTheWallClock() {
        // The recorder starts and stops with `RecordingClock.now`; it must be system uptime.
        let before = ProcessInfo.processInfo.systemUptime
        let now = RecordingClock.now
        let after = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue((before...after).contains(now))
        var clock = RecordingClock()
        clock.start(at: RecordingClock.now)
        // Even a far-away wall clock date cannot enter: only uptime values do.
        XCTAssertLessThan(clock.elapsed(at: RecordingClock.now), 1)
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
        let base: TimeInterval = 90 * 40
        XCTAssertEqual(RecordingClock.looping(period: 90, at: base).elapsed(at: base), 0, accuracy: 0.001)
        XCTAssertEqual(
            RecordingClock.looping(period: 90, at: base + 30).elapsed(at: base + 30), 30, accuracy: 0.001)
        XCTAssertEqual(
            RecordingClock.looping(period: 90, at: base + 95).elapsed(at: base + 95), 5, accuracy: 0.001)
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
