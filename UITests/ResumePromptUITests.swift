import XCTest
import UIKit

final class ResumePromptUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func assertTwoMediaModes70(_ identifier: String) -> XCUIElement {
        let picker = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(picker.waitForExistence(timeout: 8))
        XCTAssertTrue(picker.buttons["图片"].exists && picker.buttons["视频"].exists)
        XCTAssertFalse(picker.buttons["全部"].exists, "Only the mixed media option is removed")
        XCTAssertEqual(picker.buttons["图片"].frame.width, picker.buttons["视频"].frame.width, accuracy: 1)
        return picker
    }

    func testPlayback174TailBaseline() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "--qa-header-motion", "--qa-drag-performance167", "-muted", "YES", "-autoplay", "NO"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        heightOpen("author-video", expected: 28_037_102)
        waitUntil("Author video is focused") { self.watchFocus() == 28_037_102 }
        heightDeck().swipeUp()
        waitUntil("The last author video is focused") { self.watchFocus() == 28_037_104 }
        let seek = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "播放进度")).allElementsBoundByIndex.first(where: \.isHittable)
        print("PLAYBACK174_GEOMETRY seek=\(seek?.frame ?? .zero);footer=\(mainTabBar().frame);header=\(floatingPageTitle("作者作品").frame)")
        let ended = app.staticTexts["feed.continuation.ended"].firstMatch
        XCTAssertTrue(ended.waitForExistence(timeout: 5), "A settled final page keeps its continuation status")
        if ended.exists {
            print("PLAYBACK174_ENDED \(ended.frame)")
            XCTAssertGreaterThanOrEqual(ended.frame.minY, floatingPageTitle("作者作品").frame.maxY + 4)
        }
        XCTAssertNotNil(seek)
        if let seek { XCTAssertLessThanOrEqual(seek.frame.maxY, mainTabBar().frame.minY + 1, "Seek hit area must clear the floating footer") }
        attachScreenshot(named: "playback174-author-tail-before")
        print("PERF174_READY epoch=\(Date().timeIntervalSince1970)")
        let window = app.windows.firstMatch
        for _ in 0..<12 {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.70))
                .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.34)), withVelocity: XCUIGestureVelocity(rawValue: 200), thenHoldForDuration: 0.1)
        }
        print("PERF174_END epoch=\(Date().timeIntervalSince1970)")
        print("PERF174_CADENCE " + app.staticTexts["performance.cadence172"].valueDescription)
        XCTAssertEqual(watchFocus(), 28_037_104)
        attachScreenshot(named: "playback174-author-tail-after")
    }

    func testPlayback174BoundaryMotionDoesNotRepublishHosts() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "--qa-pager-touch-trace",
                               "-muted", "YES", "-autoplay", "NO"]
        app.launch()
        heightOpen("author-video", expected: 28_037_102)
        heightDeck().swipeUp()
        waitUntil("The final author video settles") { self.watchFocus() == 28_037_104 }
        let window = app.windows.firstMatch
        func drag() {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.70))
                .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.34)),
                       withVelocity: XCUIGestureVelocity(rawValue: 200), thenHoldForDuration: 0.1)
        }
        func state() -> [String: Any] {
            let data = Data(app.staticTexts["pager.qa.trace"].valueDescription.utf8)
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return object?["current"] as? [String: Any] ?? [:]
        }
        drag()
        waitUntil("The boundary state is committed before measuring finger motion") {
            state()["latestBoundaryWaiting"] as? Bool == true && state()["transitionActive"] as? Bool == false
        }
        let before = state()
        XCTAssertNotNil(before["hostRootAssignments"])
        for _ in 0..<4 { drag() }
        let after = state()
        XCTAssertEqual(after["instance"] as? String, before["instance"] as? String)
        XCTAssertEqual(after["hostRootAssignments"] as? Int, before["hostRootAssignments"] as? Int)
        XCTAssertEqual(after["hostContentPublishes"] as? Int, before["hostContentPublishes"] as? Int,
                       "Finger motion cannot republish unchanged media pages")
        print("HOST174 before=\(before);after=\(after)")
        attachEdgeTrace("174-boundary-publication")
    }

    func testPlayback174CachedAuthorStaysOpen() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "--qa-collection-batch-manage", "--qa-header-motion", "--qa-pager-touch-trace", "--qa-caption-hit174", "-muted", "YES", "-autoplay", "NO"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        heightOpen("collections", expected: 28_037_102)
        waitUntil("Cached video is focused") { self.watchFocus() == 28_037_102 }
        let author = app.buttons["media.author.28037102"].firstMatch
        waitUntil("Cached video author control settles") {
            author.isHittable && (!self.app.staticTexts["page.interaction-lock"].exists || self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0"))
        }
        let originalPlayer = playerFields()["player"]
        XCTAssertNotNil(originalPlayer)
        for _ in 0..<3 {
            print("AUTHOR174_CANDIDATES " + self.app.buttons.matching(identifier: "media.author.28037102").allElementsBoundByIndex.map { "\($0.frame):hittable=\($0.isHittable):enabled=\($0.isEnabled)" }.joined(separator: ";"))
            print("AUTHOR174_PARENT " + self.app.staticTexts["media.qa.parent-ready"].valueDescription)
            print("AUTHOR174_PLAYER " + self.app.staticTexts["media.qa.player"].valueDescription)
            author.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let header = self.app.descendants(matching: .any)["creator.top-bar"]
            let opened = header.waitForExistence(timeout: 8)
            if !opened {
                print("AUTHOR174_TRACE " + self.app.staticTexts["pager.qa.trace"].valueDescription)
                attachEdgeTrace("174-cached-author-rejection")
                attachScreenshot(named: "174-cached-author-failure")
            }
            XCTAssertTrue(opened)
            let unexpectedlyClosed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !header.exists }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [unexpectedlyClosed], timeout: 4), .timedOut, "The author page must stay open rather than return to playback")
            attachScreenshot(named: "playback174-cached-author-open")
            header.buttons["navigation.back"].tap()
            waitUntil("Returning restores the cached video") { self.watchFocus() == 28_037_102 }
            waitUntil("Returning reuses the original cached player") {
                self.playerFields()["player"] == originalPlayer && self.playerFields()["ready"] == "true"
            }
        }

    }

    func testPlayback174VideoChromeKeepsPlayerAndIntent() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "-muted", "YES", "-autoplay", "YES"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        heightOpen("collections", expected: 28_037_102)
        waitUntil("The local video starts playing") {
            let state = self.playerFields()
            return state["ready"] == "true" && (Double(state["rate"] ?? "") ?? 0) > 0
        }
        heightDeck().tap()
        waitUntil("The user explicitly pauses the local video") {
            let state = self.playerFields()
            return state["ready"] == "true" && state["intent"] == "false"
        }
        let original = playerFields()
        let close = app.buttons["playback.close"]
        for _ in 0..<2 {
            centralPress()
            waitUntil("Long press hides the playback title") { !close.exists || !close.isHittable }
            waitUntil("Hiding controls retains the same paused player") {
                let state = self.playerFields()
                return state["player"] == original["player"] && state["ready"] == "true" &&
                    state["intent"] == "false" && state["rate"] == "0.0" &&
                    abs((Double(state["nativePosition"] ?? "") ?? -100) - (Double(original["nativePosition"] ?? "") ?? 0)) < 0.75
            }
            centralPress()
            waitUntil("Long press restores the playback title") { close.exists && close.isHittable }
            XCTAssertEqual(playerFields()["player"], original["player"])
            XCTAssertLessThanOrEqual(Int(playerFields()["poolCount"] ?? "99") ?? 99, 2)
        }
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
    }

    func testRoot174EdgeDragDoesNotActivateSourceRow() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-author-activity58", "--qa-header-motion",
                               "--qa-body-motion", "-muted", "YES", "-autoplay", "NO"]
        app.launch()
        let window = app.windows.firstMatch
        func idle() {
            waitUntil("The root gesture releases its interaction lease") {
                !self.app.staticTexts["page.interaction-lock"].exists ||
                self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0")
            }
        }
        for right in [false, true] {
            mainTabButton("作者榜").tap(); idle()
            let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "leaderboard.author.")).element(boundBy: 3)
            XCTAssertTrue(row.waitForExistence(timeout: 8)); XCTAssertTrue(row.isHittable)
            let x = right ? window.frame.width - 24 : 24
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: row.frame.midY))
            XCTAssertTrue(row.frame.contains(CGPoint(x: x, y: row.frame.midY)), "The drag starts inside the actual row hit area")
            let short = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x + (right ? -28 : 28), dy: row.frame.midY))
            start.press(forDuration: 0.05, thenDragTo: short, withVelocity: XCUIGestureVelocity(rawValue: 90), thenHoldForDuration: 0.15)
            idle()
            XCTAssertTrue(mainTabButton("作者榜").isSelected)
            XCTAssertFalse(app.otherElements["creator.top-bar"].exists, "Cancelling an edge drag must not tap the source row")
            let finish = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: window.frame.midX, dy: row.frame.midY))
            start.press(forDuration: 0.05, thenDragTo: finish, withVelocity: XCUIGestureVelocity(rawValue: 180), thenHoldForDuration: 0.1)
            waitUntil("The completed edge selects the adjacent root") { self.mainTabButton(right ? "搜索" : "时间线").isSelected }
            idle()
            mainTabButton("作者榜").tap(); idle()
            XCTAssertFalse(app.otherElements["creator.top-bar"].exists, "Completing an edge drag must not navigate inside its source")
            row.tap()
            let author = app.otherElements["creator.top-bar"]
            XCTAssertTrue(author.waitForExistence(timeout: 6), "The same source row remains tappable")
            author.buttons["navigation.back"].tap(); idle()
        }
    }

    func testMediaModes70TimelineSourcesAndReset() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-visual-controls", "-muted", "YES", "-autoplay", "NO", "-timeline.presentation", "stream"]
        XCUIDevice.shared.orientation = .portrait; app.launch()
        mainTabButton("时间线").tap()
        selectTimelineSource("推荐")
        let picker = assertTwoMediaModes70("timeline.media-kind")
        for title in ["图片", "视频"] {
            picker.buttons[title].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(picker.buttons[title].isSelected)
        }
        let original = app.staticTexts["qa.controls.filter"].valueDescription
        XCTAssertTrue(original.hasPrefix("kind=video;"))
        selectTimelineSource("关注")
        assertTwoMediaModes70("timeline.media-kind").buttons["图片"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        openTimelineTool("我的关注")
        XCTAssertTrue(floatingPageTitle("我的关注").waitForExistence(timeout: 5))
        app.buttons["navigation.back"].tap()
        selectTimelineSource("推荐")
        XCTAssertTrue(picker.buttons["视频"].isSelected, "Following mode changes must not overwrite recommendation")
        openTimelineTool("浏览条件", screenshot: "header77-tools")
        app.buttons["filter.period"].tap(); XCTAssertTrue(app.buttons["全部时间"].waitForExistence(timeout: 5)); app.buttons["全部时间"].tap()
        app.buttons["完成"].tap()
        XCTAssertTrue(timelineTools().valueDescription.contains("筛选已启用"))
        openTimelineTool("浏览条件")
        let reset = app.buttons["重置筛选"]
        for _ in 0..<8 { if reset.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(reset.isHittable); reset.tap(); app.buttons["完成"].tap()
        XCTAssertTrue(picker.buttons["视频"].isSelected, "Reset preserves the selected media mode")
        XCTAssertTrue(timelineTools().valueDescription.contains("默认筛选"), "Selecting video alone must not indicate an active filter")
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); image.name = "media70-timeline-video"; image.lifetime = .keepAlways; add(image)
        openTimelineTool("最近浏览")
        XCTAssertTrue(floatingPageTitle("最近浏览").waitForExistence(timeout: 5))
    }

    func testMediaModes70SearchFilterAndResults() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "-muted", "YES", "-autoplay", "NO"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let searchTab = mainTabButton("搜索")
        XCTAssertTrue(searchTab.waitForExistence(timeout: 8))
        searchTab.tap()
        let title = app.textFields["search-title-input"]
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["匹配说明"].exists)
        attachScreenshot(named: "search108-compact-toolbar")
        let range = app.buttons["search.range"]
        for _ in 0..<5 { if range.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(range.isHittable); range.tap()
        let defaultsPicker = assertTwoMediaModes70("filter.media-kind")
        defaultsPicker.buttons["视频"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(defaultsPicker.buttons["视频"].isSelected); app.buttons["完成"].tap()
        // Configure the range before focusing the text field; whole-app swipes over the keyboard do not scroll this form.
        for _ in 0..<5 { if title.isHittable { break }; app.swipeDown() }
        XCTAssertTrue(title.isHittable); title.tap(); title.typeText("Paging\n")
        XCTAssertTrue(app.descendants(matching: .any)["search.results"].waitForExistence(timeout: 8))
        XCTAssertTrue(title.isHittable)
        XCTAssertFalse(app.descendants(matching: .any)["search-results.top-bar"].exists)
        XCTAssertTrue(range.label.contains("视频"))
        let video = app.buttons["media.grid.cell.28037102"]
        let image = app.buttons["media.grid.cell.28037100"]
        XCTAssertTrue(video.waitForExistence(timeout: 8))
        XCTAssertFalse(image.exists)
        chooseSearchMedia("图片")
        XCTAssertTrue(range.label.contains("图片"))
        XCTAssertTrue(image.waitForExistence(timeout: 8))
        XCTAssertFalse(video.exists)
        title.tap()
        title.typeText("x")
        XCTAssertTrue(image.waitForNonExistence(timeout: 5), "Editing the query clears the previous results")
        app.buttons["清空全部条件"].tap()
        XCTAssertTrue(app.buttons["清空全部条件"].waitForNonExistence(timeout: 5))

    }

    private func chooseSearchMedia(_ label: String) {
        let range = app.buttons["search.range"]
        XCTAssertTrue(range.waitForExistence(timeout: 5))
        range.tap()
        let media = app.descendants(matching: .any)["filter.media-kind"].buttons[label]
        XCTAssertTrue(media.waitForExistence(timeout: 5))
        media.tap()
        app.buttons["完成"].tap()
        XCTAssertTrue(range.waitForExistence(timeout: 5))
    }

    func testResume62RemainsPastTenSecondsAndFilterChange() {
        launchQA("dismiss")
        let prompt = app.buttons["timeline.resume"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        RunLoop.main.run(until: Date().addingTimeInterval(11))
        XCTAssertTrue(prompt.exists, "Elapsed time must never consume an actionable resume offer")
        app.otherElements["timeline.media-kind"].buttons["图片"].tap()
        XCTAssertTrue(prompt.exists, "A filter change preserves the prior viewing checkpoint")
        mainTabButton("收藏").tap(); mainTabButton("时间线").tap()
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["qa-state"].valueDescription.contains("state=browsing"))
        attachScreenshot(named: "resume62-still-actionable-after-eleven-seconds")
        let state = app.descendants(matching: .any)["qa-state"]
        let requestsBefore = Int(qaFields(state.valueDescription)["recFirstPageRequests"] ?? "-1") ?? -1
        XCTAssertGreaterThanOrEqual(requestsBefore, 0)
        mainTabButton("时间线").doubleTap()
        XCTAssertTrue(state.waitForValueToContain("recFirstPageRequests=\(requestsBefore + 1)", timeout: 10))
        XCTAssertTrue(prompt.waitForExistence(timeout: 5), "Refreshing the current list cannot close its saved resume offer")
        XCTAssertTrue(prompt.isEnabled)
        attachScreenshot(named: "resume62-remains-after-real-tab-refresh")
        app.buttons["timeline.resume.close"].tap()
        XCTAssertTrue(prompt.waitForNonExistence(timeout: 3))
    }

    func testResume62HideReappearAndManualCloseStayIndependent() {
        launchQA("dismiss-video")
        let prompt = app.buttons["timeline.resume"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        mainTabButton("收藏").tap()
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        mainTabButton("时间线").tap()
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        app.buttons["timeline.resume.close"].tap()
        XCTAssertTrue(prompt.waitForNonExistence(timeout: 3))
        mainTabButton("收藏").tap(); mainTabButton("时间线").tap()
        XCTAssertFalse(prompt.exists, "Manual close remains consumed after tab return")
        XCTAssertTrue(app.descendants(matching: .any)["qa-state"].valueDescription.contains("state=browsing"))
        attachScreenshot(named: "resume61-manual-close-after-reappearance")
    }

    func testResume62DetailsOverlayPreservesActionableOffer() {
        launchQA("dismiss")
        let prompt = app.buttons["timeline.resume"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        let details = app.buttons.matching(NSPredicate(format: "label == %@", "作品详情")).allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(details); details?.tap()
        XCTAssertTrue(floatingPageTitle("作品详情").waitForExistence(timeout: 5))
        RunLoop.main.run(until: Date().addingTimeInterval(11))
        app.buttons["details.back"].tap()
        XCTAssertTrue(prompt.waitForExistence(timeout: 5), "An offer covered by details must not expire underneath the sheet")
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        XCTAssertTrue(prompt.exists, "Returning from details keeps the offer available until an explicit action")
        attachScreenshot(named: "resume62-details-overlay-keeps-offer")
    }

    func testSettings61SteppedConcurrencyPersistsAndGestureHelpExpands() {
        for large in [false, true] {
            visualLaunch(width: large ? 320 : 375, large: large, landscape: false, extra: ["-muted", "YES"])
            openAccountSettings()
            let slider = app.sliders["settings.prefetch-concurrency"]
            for _ in 0..<14 where !slider.isHittable { app.swipeUp() }
            XCTAssertTrue(slider.isHittable)
            let original = slider.value as? String
            let positions: [String: CGFloat] = ["2 路": 0.04, "4 路": 0.35, "6 路": 0.65, "8 路": 0.96]
            func drag(to target: String) {
                let current = slider.value as? String ?? ""
                guard current != target else { return }
                guard let start = positions[current], let end = positions[target] else {
                    XCTFail("Unexpected prefetch concurrency: \(current)")
                    return
                }
                slider.coordinate(withNormalizedOffset: CGVector(dx: start, dy: 0.5))
                    .press(forDuration: 0.1, thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: end, dy: 0.5)))
                XCTAssertEqual(slider.value as? String, target)
            }
            drag(to: "8 路")
            drag(to: "2 路")
            drag(to: "4 路")
            drag(to: "6 路")
            attachScreenshot(named: "settings61-numbered-concurrency-large-\(large)")
            app.terminate(); app.launch(); openAccountSettings()
            for _ in 0..<14 where !slider.isHittable { app.swipeUp() }
            XCTAssertTrue(slider.isHittable); XCTAssertEqual(slider.value as? String, "6 路")
            drag(to: original ?? "4 路")
            let help = app.buttons["settings.gesture-help"]
            for _ in 0..<12 where !help.isHittable { app.swipeUp() }
            XCTAssertTrue(help.isHittable)
            XCTAssertFalse(app.staticTexts["中央长按"].exists, "Gesture instructions start collapsed")
            attachScreenshot(named: "settings61-gesture-help-collapsed-large-\(large)")
            help.tap()
            // DisclosureGroup supplies its identifier to descendants on this
            // SDK; find the actual combined row by its spoken content instead.
            let center = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "中央长按", "清屏／恢复")).firstMatch
            for _ in 0..<4 where !center.isHittable { app.swipeUp() }
            if !center.isHittable { print("GESTURE61_EXPANDED_AX \(app.debugDescription)"); attachScreenshot(named: "settings61-expanded-inspection") }
            XCTAssertTrue(center.isHittable)
            XCTAssertTrue(center.label.contains("中央长按") && center.label.contains("清屏／恢复"))
            attachScreenshot(named: "settings61-gesture-help-expanded-large-\(large)")
            app.terminate()
        }
    }

    private func presetRow59(_ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "preset.library.apply.", name)).firstMatch
    }
    private func savePreset59(_ name: String) {
        let save = app.buttons["preset.library.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5)); XCTAssertTrue(save.isEnabled); save.tap()
        let field = app.textFields["preset.name.input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.press(forDuration: 1.1)
        let all = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["Select All", "全选"])).firstMatch
        if !all.waitForExistence(timeout: 3) {
            print("PRESETS60_SELECTION_MENU \(app.debugDescription)")
            attachScreenshot(named: "presets60-name-selection-menu")
        }
        XCTAssertTrue(all.exists); all.tap(); field.typeText(name)
        XCTAssertEqual(field.value as? String, name)
        attachScreenshot(named: "presets59-name-and-readonly-preview")
        app.buttons["preset.name.save"].tap()
        XCTAssertTrue(presetRow59(name).waitForExistence(timeout: 6))
    }

    func testPresets59TimelineSaveApplyScopeIsolationAndPlayback() {
        visualLaunch(width: 0, large: false, landscape: false, extra: ["-muted", "YES", "--qa-continuous59", "-civitviewer.automaticRotation", "YES"])
        app.otherElements["timeline.media-kind"].buttons["视频"].tap()
        waitPlayingFixture()
        let name = "Video-" + String(UUID().uuidString.prefix(6))
        openTimelineTool("已存条件")
        XCTAssertTrue(app.descendants(matching: .any)["preset.library"].waitForExistence(timeout: 5))
        savePreset59(name)
        XCTAssertTrue(presetRow59(name).valueDescription.contains("应用方案"))
        attachScreenshot(named: "presets59-timeline-compact-list")
        app.buttons["preset.library.done"].tap()
        app.otherElements["timeline.media-kind"].buttons["图片"].tap()
        app.buttons["手动切换横竖屏"].tap()
        heightWaitOrientation(landscape: true)
        openTimelineTool("已存条件")
        XCTAssertTrue(presetRow59(name).waitForExistence(timeout: 5))
        XCTAssertFalse(presetRow59(name).valueDescription.contains("当前筛选"))
        presetRow59(name).tap()
        XCTAssertTrue(app.otherElements["timeline.media-kind"].buttons["视频"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["timeline.media-kind"].buttons["视频"].isSelected)
        waitPlayingFixture()
        // Restore the requested device orientation after the playback route's
        // manual orientation lease has returned to its opening direction.
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.orientation = .landscapeLeft
        let timelineRotated = NSPredicate { _, _ in
            let frame = self.app.windows.firstMatch.frame
            return frame.width > frame.height
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: timelineRotated, object: nil)], timeout: 5), .completed)
        // Compare the actual panel outer edge, not a union of inset button targets.
        let timelineFrame = heightValues(app.staticTexts["qa.controls.row"].valueDescription)
        guard let x = timelineFrame["x"], let width = timelineFrame["w"] else {
            XCTFail("Missing actual timeline panel frame"); return
        }
        let timelineHeader = CGRect(x: x, y: 0, width: width, height: 44)
        for (tab, headerID) in [("作者榜", "leaderboard.top-bar"), ("搜索", "search.top-bar"), ("收藏", "collections.top-bar")] {
            mainTabButton(tab).tap()
            let header = app.otherElements[headerID]
            XCTAssertTrue(header.waitForExistence(timeout: 5), tab)
            XCUIDevice.shared.orientation = .portrait
            XCUIDevice.shared.orientation = .landscapeLeft
            let rotated = NSPredicate { _, _ in
                let window = self.app.windows.firstMatch.frame
                return window.width > window.height
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: rotated, object: nil)], timeout: 5), .completed, tab)
            XCTAssertEqual(header.frame.midX, timelineHeader.midX, accuracy: 1, tab)
            XCTAssertEqual(header.frame.minX, timelineHeader.minX, accuracy: 1, tab)
            XCTAssertEqual(header.frame.maxX, timelineHeader.maxX, accuracy: 1, tab)
            attachScreenshot(named: "app-landscape-\(headerID)")
        }
        XCUIDevice.shared.orientation = .portrait
        let lockedWindow = app.windows.firstMatch.frame
        XCTAssertGreaterThan(lockedWindow.width, lockedWindow.height, "The lock must survive on an ordinary page")
        // Match the simulated device to the locked window before tapping the settings list.
        XCUIDevice.shared.orientation = .landscapeLeft
        openAccountSettings()
        let rotate = app.buttons["settings.rotation.toggle"]
        tapAboveMainBar(rotate)
        waitUntil("Settings can return the whole app to portrait") {
            let window = self.app.windows.firstMatch.frame
            return window.height > window.width
        }
        closeAccountSettings()
        mainTabButton("时间线").tap()
        selectTimelineSource("关注")
        openTimelineTool("已存条件")
        XCTAssertTrue(floatingPageTitle("已存条件 · 关注").waitForExistence(timeout: 5))
        XCTAssertFalse(presetRow59(name).exists, "Recommendation presets must not appear in following")
        attachScreenshot(named: "presets59-following-scope-isolated")
        app.buttons["preset.library.done"].tap()
        selectTimelineSource("推荐")
        waitPlayingFixture()
        attachScreenshot(named: "presets59-playback-resumes-after-apply")
    }

    func testPresets59SearchRestoresTagsTextAndRangeWithoutAutoSearch() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-theme-ui", "--qa-style48", "--qa-visual-controls", "--qa-control-width=320", "-muted", "YES", "-app.appearance", "light"]
        app.launch(); mainTabButton("搜索").tap()
        let longTitle = "City lights along the river after midnight in the spring"
        let title = app.textFields["search-title-input"]
        XCTAssertTrue(title.waitForExistence(timeout: 6)); title.tap(); title.typeText(longTitle)
        app.buttons["search-tag-picker"].tap()
        let portrait = app.buttons["tag-directory.tag.42001"], night = app.buttons["tag-directory.tag.42002"]
        XCTAssertTrue(portrait.waitForExistence(timeout: 6)); portrait.tap(); night.tap(); app.buttons["完成"].tap()
        let range = app.buttons["search.range"]
        for _ in 0..<3 where !range.isHittable { app.swipeUp() }
        if !range.isHittable {
            print("PRESETS59_SEARCH_RANGE_UNREACHABLE \(app.debugDescription)")
            attachScreenshot(named: "presets59-search-range-unreachable")
        }
        XCTAssertTrue(range.isHittable); range.tap()
        app.otherElements["filter.media-kind"].buttons["视频"].tap()
        app.buttons["filter.period"].tap(); app.buttons["本月"].tap()
        app.buttons["filter.sort"].tap(); app.buttons["热度"].tap()
        attachScreenshot(named: "presets59-search-range-before-save")
        app.buttons["完成"].tap()
        XCTAssertTrue(floatingPageTitle("浏览条件").waitForNonExistence(timeout: 5))
        let presets = app.buttons["search.presets"]
        waitUntil("The search toolbar is interactive after closing the filter") { presets.isHittable }
        presets.tap()
        XCTAssertTrue(floatingPageTitle("已存条件 · 搜索").waitForExistence(timeout: 5))
        let name = "Night-" + String(UUID().uuidString.prefix(6)) + " across a very long skyline"
        savePreset59(name)
        app.buttons["preset.library.done"].tap()
        let clear = app.buttons["清空全部条件"]
        if !clear.isHittable { app.swipeDown() }; XCTAssertTrue(clear.isHittable); clear.tap()
        app.buttons["search.presets"].tap(); XCTAssertTrue(presetRow59(name).waitForExistence(timeout: 5)); presetRow59(name).tap()
        XCTAssertEqual(title.value as? String, longTitle)
        XCTAssertEqual(app.buttons["search-tag-picker"].valueDescription, "已选择 2 个标签")
        XCTAssertTrue(range.label.contains("视频") && range.label.contains("本月") && range.label.contains("热度"))
        XCTAssertFalse(app.descendants(matching: .any)["search.results"].exists, "Loading a saved search must leave explicit search under user control")
        attachScreenshot(named: "presets59-search-complete-conditions-restored")
        let submit = app.buttons["search-submit"]
        waitUntil("The search control must be interactive after applying a saved search") {
            submit.isHittable && submit.isEnabled
        }
        submit.tap()
        XCTAssertTrue(app.descendants(matching: .any)["search.results"].waitForExistence(timeout: 8))
        XCTAssertTrue(title.isHittable)
        attachScreenshot(named: "presets59-search-results-with-saved-range")
        app.buttons["search.presets"].tap()
        let presetHeader = floatingPageTitle("已存条件 · 搜索")
        XCTAssertTrue(presetHeader.waitForExistence(timeout: 5))
        let saved = presetRow59(name)
        XCTAssertEqual(saved.label, name)
        XCTAssertEqual(saved.valueDescription, "应用方案")
        XCTAssertFalse(app.staticTexts["当前条件"].exists)
        attachScreenshot(named: "search-compact-saved-conditions")
        saved.press(forDuration: 1)
        let rename = app.buttons["重命名"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        attachScreenshot(named: "search-saved-context-menu")
        rename.tap()
        let editor = app.textFields["preset.name.input"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, name)
        floatingPageTitle("重命名").buttons["navigation.back"].tap()
        XCTAssertTrue(presetRow59(name).waitForExistence(timeout: 5))
        app.buttons["preset.library.done"].tap()
        XCTAssertTrue(app.buttons["search.presets"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["search.results"].waitForExistence(timeout: 5))
        XCTAssertTrue(title.isHittable)
    }

    func testPresets60CompactEditorRenameAndCancel() {
        visualLaunch(width: 320, large: true, landscape: false, extra: ["-muted", "YES"])
        openTimelineTool("已存条件")
        let save = app.buttons["preset.library.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5)); XCTAssertTrue(save.isHittable)
        attachScreenshot(named: "presets60-large-type-library-bottom-action")
        let name = "Compact-" + String(UUID().uuidString.prefix(5))
        savePreset59(name)
        presetRow59(name).press(forDuration: 1)
        app.buttons["重命名"].tap()
        let field = app.textFields["preset.name.input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, name)
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        field.typeText("-R")
        let renamed = name + "-R"
        XCTAssertEqual(field.value as? String, renamed)
        let commit = app.buttons["preset.name.save"]
        XCTAssertTrue(commit.isHittable); XCTAssertTrue(commit.isEnabled)
        attachScreenshot(named: "presets60-compact-rename-structured-conditions")
        commit.tap()
        XCTAssertTrue(presetRow59(renamed).waitForExistence(timeout: 5))
        app.buttons["preset.library.save"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        app.buttons["navigation.back"].tap()
        XCTAssertTrue(presetRow59(renamed).waitForExistence(timeout: 5))
        XCTAssertFalse(field.exists, "Cancel/back pops to the same library without saving an unnamed plan")
        presetRow59(renamed).press(forDuration: 1)
        app.buttons["删除"].tap()
        XCTAssertTrue(app.buttons["删除方案"].waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
        XCTAssertTrue(presetRow59(renamed).isHittable)
        presetRow59(renamed).press(forDuration: 1)
        app.buttons["删除"].tap()
        app.buttons["删除方案"].tap()
        XCTAssertTrue(presetRow59(renamed).waitForNonExistence(timeout: 5))
        app.buttons["preset.library.done"].tap()
        XCTAssertTrue(timelineTools().waitForExistence(timeout: 5))
    }

    func testGrid55RetryStaysWithErrorAndDoesNotOpenWork() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-grid-retry55", "-muted", "YES"]
        app.launch()
        assertGrid55RetryLayout()
        attachScreenshot(named: "grid55-centered-image-and-poster-retry")
    }

    func testGrid55RetryRemainsVisibleAtLargeType() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-grid-retry55", "--qa-grid-retry-large55", "-muted", "YES"]
        app.launch()
        assertGrid55RetryLayout()
        attachScreenshot(named: "grid55-centered-retry-large-type")
    }

    func testDetails55ImageFailureRetryStaysOutsideBlur() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-poster-details50", "--qa-image-failure55", "-muted", "YES"]
        app.launch()
        let retry = app.buttons["details.image.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10)); XCTAssertTrue(retry.isHittable)
        let frame = retry.frame
        XCTAssertGreaterThan(frame.width, 70); XCTAssertGreaterThan(frame.height, 43)
        retry.tap()
        XCTAssertTrue(retry.waitForExistence(timeout: 8))
        XCTAssertLessThan(abs(retry.frame.midX - frame.midX), 1)
        attachScreenshot(named: "details55-image-retry-outside-media-blur")
    }

    func testTags71SingleBrowseSelectorWithLocalObservations() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-theme-ui", "--qa-tag-availability55", "-muted", "YES"]
        app.launch()
        mainTabButton("搜索").tap()
        app.buttons["search-tag-picker"].tap()
        let enough = app.buttons["tag-directory.tag.42001"]
        let sparse = app.buttons["tag-directory.tag.42002"]
        let unknown = app.buttons["tag-directory.tag.42003"]
        XCTAssertTrue(enough.waitForExistence(timeout: 8))
        XCTAssertTrue(unknown.waitForNonExistence(timeout: 5), "Unverified failures are not recommendations")
        let hidden = sparse.waitForNonExistence(timeout: 8)
        print("TAG55_READBACK \(app.descendants(matching: .any)["qa.tag-availability55"].firstMatch.valueDescription)")
        if !hidden { print(app.debugDescription); attachScreenshot(named: "tags55-sparse-not-hidden") }
        XCTAssertTrue(hidden, "Only exhausted zero is hidden by default")
        let toggle = app.otherElements["tag-directory.mode"]
        XCTAssertTrue(toggle.isHittable)
        attachScreenshot(named: "tags113-initial")
        XCTAssertEqual(toggle.buttons.allElementsBoundByIndex.filter(\.isHittable).count, 2)
        let input = app.textFields["tag-search-input"]
        input.tap()
        let inputFrame = input.frame
        let toggleFrame = toggle.frame
        let prefix = app.buttons["tag-directory.prefix"]
        let prefixFrame = prefix.frame
        input.typeText("city")
        XCTAssertTrue(unknown.waitForExistence(timeout: 5), "A name query finds tags outside the common recommendations")
        XCTAssertTrue(toggle.buttons["全部标签"].isSelected)
        XCTAssertEqual(input.frame, inputFrame)
        XCTAssertEqual(toggle.frame, toggleFrame)
        XCTAssertEqual(prefix.frame, prefixFrame)
        XCTAssertGreaterThanOrEqual(unknown.frame.height, 32, "The shared tag chip uses a 32 pt target at standard Dynamic Type")
        XCTAssertTrue(unknown.isHittable)
        attachScreenshot(named: "tags71-compact-results-and-clear")
        app.buttons["清空标签名称"].tap()
        XCTAssertTrue(toggle.buttons["常用"].isSelected)
        XCTAssertEqual(input.frame, inputFrame)
        toggle.buttons["全部标签"].tap()
        XCTAssertTrue(sparse.waitForExistence(timeout: 5)); XCTAssertTrue(unknown.exists)
        XCTAssertTrue(sparse.valueDescription.contains("近期搜索未显示作品"))
        XCTAssertTrue(unknown.valueDescription.contains("暂无浏览样本"))
        XCTAssertTrue(app.buttons["tag-directory.prefix"].isHittable)
        attachScreenshot(named: "tags-catalog-compact-filters")
        let header = floatingPageTitle("选择标签")
        let back = header.buttons["navigation.back"]
        let done = header.buttons["完成"]
        XCTAssertTrue(back.isHittable && done.isHittable)
        XCTAssertFalse(app.buttons["tag-directory.actions"].exists)
        let beforeSelection = done.frame
        sparse.tap()
        XCTAssertEqual(done.frame, beforeSelection)
        XCTAssertEqual(done.valueDescription, "已选 1 / 8")
        toggle.buttons["常用"].tap()
        XCTAssertTrue(sparse.waitForExistence(timeout: 5), "A selected sparse tag remains available when returning to common tags")
        XCTAssertTrue(sparse.valueDescription.contains("已选择"))
        XCTAssertTrue(unknown.waitForNonExistence(timeout: 5))
        let readback = app.descendants(matching: .any)["qa.tag-availability55"].firstMatch.valueDescription
        XCTAssertTrue(readback.contains("probeReads=0;"), "Tag estimates must not request per-tag works")
        attachScreenshot(named: "tags71-one-browse-selector")
        input.tap(); input.typeText("city")
        XCTAssertTrue(unknown.waitForExistence(timeout: 5))
        XCTAssertTrue(sparse.valueDescription.contains("已选择"), "A draft tag stays reachable outside the current query")
        sparse.tap()
        XCTAssertEqual(done.valueDescription, "已选 0 / 8")
        app.buttons["清空标签名称"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.buttons["全部标签"].tap()
        XCTAssertTrue(sparse.waitForExistence(timeout: 5)); sparse.tap()
        let tagPicker = app.buttons["search-tag-picker"]
        back.tap()
        XCTAssertTrue(tagPicker.waitForValueToContain("已选择 1 个标签", timeout: 5), "A successful return commits local tag selection")
        tagPicker.tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.buttons["全部标签"].tap()
        XCTAssertTrue(sparse.waitForExistence(timeout: 5))
        XCTAssertTrue(sparse.valueDescription.hasPrefix("已选择"))
        sparse.tap()
        done.tap()
        XCTAssertTrue(tagPicker.waitForValueToContain("未选择", timeout: 5))
    }

    func testTagDirectoryAutomaticallyPagesAndRetriesAtEnd() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-theme-ui", "--qa-tag-directory-pagination", "-muted", "YES"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        mainTabButton("搜索").tap()
        app.buttons["search-tag-picker"].tap()
        let catalog = app.otherElements["tag-directory.mode"].buttons["全部标签"]
        XCTAssertTrue(catalog.waitForExistence(timeout: 5))
        if !catalog.isSelected { catalog.tap() }

        let scroll = app.scrollViews["tag-directory.scroll"]
        let retries = app.buttons.matching(identifier: "tag-directory.retry")
        let retry = retries.firstMatch
        let prefix = app.buttons["tag-directory.prefix"]
        let input = app.textFields["tag-search-input"]
        let firstTag = app.buttons["tag-directory.tag.43001"]
        let lastTag = app.buttons["tag-directory.tag.43043"]

        func reveal(_ element: XCUIElement, towardEnd: Bool) {
            for _ in 0..<6 where !element.isHittable {
                if towardEnd { scroll.swipeUp() }
                else { scroll.swipeDown() }
            }
            XCTAssertTrue(element.isHittable)
        }
        XCTAssertTrue(firstTag.waitForExistence(timeout: 5))
        firstTag.tap()
        reveal(retry, towardEnd: true)
        XCTAssertEqual(retry.label, "重试标签")
        XCTAssertFalse(app.staticTexts["更多标签未加载"].exists)
        XCTAssertEqual(retries.count, 1)
        XCTAssertFalse(prefix.exists)
        XCTAssertEqual(retry.frame.midY, input.frame.midY, accuracy: 2)
        XCTAssertGreaterThanOrEqual(retry.frame.minX, input.frame.maxX)
        attachScreenshot(named: "tag-directory-header-retry")
        reveal(firstTag, towardEnd: false)
        XCTAssertTrue(firstTag.valueDescription.contains("已选择"))

        XCTAssertTrue(retry.isHittable)
        retry.tap()
        reveal(lastTag, towardEnd: true)
        XCTAssertEqual(lastTag.label, "paging fixture 43 with an unusually long tag name for narrow layouts")
        XCTAssertLessThan(lastTag.frame.width, scroll.frame.width / 2)
        XCTAssertTrue(retry.waitForNonExistence(timeout: 5))
        XCTAssertTrue(prefix.exists)
        XCTAssertFalse(app.buttons["继续加载标签"].exists)
        attachScreenshot(named: "tag-directory-pagination-end")
        reveal(firstTag, towardEnd: false)
        XCTAssertTrue(firstTag.valueDescription.contains("已选择"))
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["search-tag-picker"].waitForValueToContain("已选择 1 个标签", timeout: 5))
    }

    func testTags70RequiresBothMediaToWithdrawLocalSuggestion() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-theme-ui", "--qa-tag-availability55", "--qa-tag-empty-result56", "-muted", "YES"]
        app.launch()
        mainTabButton("搜索").tap(); app.buttons["search-tag-picker"].tap()
        let tag = app.buttons["tag-directory.tag.42001"]
        XCTAssertTrue(tag.waitForExistence(timeout: 8)); tag.tap(); app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["search-tag-picker"].waitForValueToContain("已选择 1 个标签", timeout: 5))
        let submit = app.buttons["search-submit"]
        waitUntil("The selected tag can be submitted after returning to Search") { submit.isHittable && submit.isEnabled }
        submit.tap()
        let empty = app.staticTexts["没有符合条件的作品"]
        let ended = empty.waitForExistence(timeout: 8)
        if !ended { print("TAGS56_EMPTY_STATE \(app.debugDescription)"); attachScreenshot(named: "tags56-unexpected-empty-state") }
        XCTAssertTrue(ended)
        XCTAssertFalse(app.buttons["调整筛选"].exists)
        XCTAssertFalse(app.buttons["重置筛选"].exists)
        XCTAssertTrue(app.buttons["search.range"].isHittable)
        app.buttons["清空全部条件"].tap()
        app.buttons["search-tag-picker"].tap()
        XCTAssertTrue(tag.waitForExistence(timeout: 8), "An empty image search alone cannot rule out video matches")
        tag.tap(); app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["search-tag-picker"].waitForValueToContain("已选择 1 个标签", timeout: 5))
        waitUntil("Search is ready for the second tag request") { submit.isHittable && submit.isEnabled }
        submit.tap()
        XCTAssertTrue(empty.waitForExistence(timeout: 8))
        chooseSearchMedia("视频")
        XCTAssertTrue(app.buttons["search.range"].label.contains("视频"))
        XCTAssertTrue(empty.waitForExistence(timeout: 8))
        app.buttons["清空全部条件"].tap()
        app.buttons["search-tag-picker"].tap()
        XCTAssertTrue(tag.waitForNonExistence(timeout: 8), "Two completed empty searches in the same scope withdraw the suggestion")
        app.otherElements["tag-directory.mode"].buttons["全部标签"].tap()
        XCTAssertTrue(tag.waitForExistence(timeout: 5)); XCTAssertTrue(tag.valueDescription.contains("近期搜索未显示作品"))
        attachScreenshot(named: "tags70-two-media-empty-feedback")
    }

    private func assertGrid55RetryLayout() {
        for id in [55_001, 55_002] {
            let button = app.buttons["media.grid.retry.\(id)"]
            let appeared = button.waitForExistence(timeout: 8)
            if !appeared { print("GRID55_MISSING_RETRY \(app.debugDescription)"); attachScreenshot(named: "grid55-missing-retry-\(id)") }
            XCTAssertTrue(appeared); XCTAssertTrue(button.isHittable)
            let cell = app.buttons["media.grid.cell.\(id)"]
            XCTAssertTrue(cell.exists)
            XCTAssertLessThan(abs(button.frame.midX - cell.frame.midX), 2)
            XCTAssertGreaterThan(button.frame.height, 43)
            XCTAssertLessThan(button.frame.maxY, cell.frame.maxY - 20, "Retry belongs beside the error, above the card bottom")
            button.tap()
            XCTAssertTrue(button.waitForExistence(timeout: 8))
            XCTAssertEqual(app.staticTexts["grid.retry.qa.opens"].label, "opened=0", "Retry must not activate the sibling open button")
        }
    }

    private func launchQA(_ scenario: String) {
        app = XCUIApplication()
        let runID = UUID().uuidString
        print("RESUME_QA_RUN_ID=\(runID)")
        app.launchArguments = [
            "--qa-resume-prompt",
            "--qa-resume-prompt-ui",
            "--qa-resume-prompt-reset",
            "--qa-scenario=\(scenario)",
            "--qa-run-id=\(runID)"
        ]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["qa-state"].waitForExistence(timeout: 20), "QA observer must become available")
    }

    func testRestore58ConsumesCheckpointWithoutSuccessToast() {
        launchQA("restore-legacy-nil")
        let resume = app.buttons["timeline.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        resume.tap()
        XCTAssertTrue(app.descendants(matching: .any)["qa-state"].waitForValueToContain("state=resumed-", timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["timeline.notice"].exists,
                       "Normal cache restoration must not cover the media with a success toast")
        attachScreenshot(named: "loading58-restored-checkpoint-without-toast")
        activeMediaDeck().swipeUp()
        mainTabButton("作者榜").tap()
        mainTabButton("时间线").tap()
        XCTAssertFalse(resume.exists, "The consumed checkpoint stays dismissed after paging and a tab cycle")
        XCTAssertFalse(app.descendants(matching: .any)["timeline.notice"].exists)
    }

    func testVideoSeek58RemainsTouchableAfterSilentCacheRestore() {
        launchQA("restore-video-legacy-nil")
        let resume = app.buttons["timeline.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        let player = app.descendants(matching: .any)["qa.player.muted"].firstMatch
        XCTAssertTrue(player.waitForValueToContain("muted", timeout: 20), "The native AVPlayerLayer must be present and muted before timing the notice")
        XCTAssertEqual(player.value as? String, "muted", "QA must remain silent at the player instance")
        let seekElements = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "播放进度"))
        XCTAssertEqual(seekElements.count, 1, "There must be exactly one exposed playback seek control")
        let seek = seekElements.firstMatch
        XCTAssertTrue(seek.waitForExistence(timeout: 10), "VideoSeekControl should be accessible by its production label")
        XCTAssertEqual(seek.label, "播放进度")
        let page = app.descendants(matching: .any)["media-page-28029101"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        let seekFrame = seek.frame
        let pageFrame = page.frame
        let deckFrame = activeMediaDeck().frame
        let frameReceipt = "label=\(seek.label); seekFrame=\(seekFrame); pageFrame=\(pageFrame); deckFrame=\(deckFrame); seekHierarchy=\(seek.debugDescription)"
        print("RESUME_SEEK_FRAME \(frameReceipt)")
        XCTContext.runActivity(named: "Exact playback seek UI element and frame") { activity in
            activity.add(XCTAttachment(string: frameReceipt))
        }
        XCTAssertEqual(seekFrame.height, 44, accuracy: 1, "The exact playback seek accessibility element must expose the production 44pt UIControl frame. \(frameReceipt)")
        XCTAssertGreaterThan(seekFrame.midY, pageFrame.midY, "The seek control must sit in the lower portion of the media page. \(frameReceipt)")
        XCTAssertGreaterThanOrEqual(pageFrame.maxY - seekFrame.maxY, -1, "The seek control must stay within the media page bottom. \(frameReceipt)")
        XCTAssertLessThanOrEqual(pageFrame.maxY - seekFrame.maxY, 160, "The seek control must be near the bottom footer of the media page. \(frameReceipt)")
        XCTAssertTrue(seek.isHittable, "The active 44pt seek control must be ready before the notice timer starts")

        resume.tap()
        let notice = app.descendants(matching: .any)["timeline.notice"]
        XCTAssertTrue(app.descendants(matching: .any)["qa-state"].waitForValueToContain("state=resumed-", timeout: 10))
        XCTAssertFalse(notice.exists, "Successful cache restoration stays silent")
        XCTAssertTrue(seek.isHittable, "The real seek control remains usable after cache restoration")
        let before = seek.valueDescription
        attachScreenshot(named: "loading58-video-seek-after-silent-restore")
        let beforeSeconds = seekSeconds(before)
        XCTAssertNotNil(beforeSeconds, "Could not parse the player's current progress: \(before)")
        let didSeek = expectation(for: NSPredicate(format: "value != %@", before), evaluatedWith: seek)
        seek.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.5)).tap()
        wait(for: [didSeek], timeout: 3)
        let after = seek.valueDescription
        guard let afterSeconds = seekSeconds(after), let beforeSeconds else {
            XCTFail("Could not parse the seek readback before=\(before) after=\(after)")
            return
        }
        XCTAssertLessThanOrEqual(abs(afterSeconds - 21), 2, "A real tap at 70% of the 30-second fixture should seek near 21 seconds. before=\(before), after=\(after)")
        XCTAssertGreaterThanOrEqual(abs(afterSeconds - beforeSeconds), 5, "The actual playback position must jump well beyond natural playback drift. before=\(before), after=\(after)")
        attachScreenshot(named: "video-seek-landed-near-21-seconds")
    }

    func testRestoreFailureRemainsVisibleUntilTappedClosed() {
        launchQA("restore-failure")
        let resume = app.buttons["timeline.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        resume.tap()

        let notice = app.descendants(matching: .any)["timeline.notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertTrue(notice.valueDescription.contains("错误"))
        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(notice.exists, "Error notice must not use the informational auto-expiry")
        let before = app.descendants(matching: .any)["qa-state"].valueDescription
        app.buttons["timeline.notice.close"].tap()
        XCTAssertTrue(notice.waitForNonExistence(timeout: 3))
        XCTAssertTrue(before.contains("focus=28029101"), "Failed restore should preserve the visible focus")
        XCTAssertFalse(resume.exists, "The failed checkpoint is consumed when the user taps resume")
    }

    func testExpiredSuccessTimerCannotClearLaterRestartError() {
        launchQA("restore-legacy-nil-then-restart-failure")
        let resume = app.buttons["timeline.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        resume.tap()

        let notice = app.descendants(matching: .any)["timeline.notice"]
        XCTAssertTrue(app.descendants(matching: .any)["qa-state"].waitForValueToContain("state=resumed-", timeout: 10))
        XCTAssertFalse(notice.exists, "The informational restoration event must stay out of the watching UI")
        attachScreenshot(named: "loading58-silent-restore-before-restart-error")
        let pageState = app.descendants(matching: .any)["qa-state"]
        let beforeRestart = pageState.valueDescription
        let firstPageCount = metric("firstPageRequests", in: beforeRestart)
        let requestCount = metric("pageRequests", in: beforeRestart)
        mainTabButton("时间线").doubleTap()
        XCTAssertTrue(app.buttons["timeline.notice.retry"].waitForExistence(timeout: 12))
        XCTAssertTrue(notice.valueDescription.contains("错误"))
        XCTAssertTrue(pageState.waitForValueToContain("lastCursor=nil", timeout: 10))
        XCTAssertEqual(metric("pageRequests", in: pageState.valueDescription) - requestCount, 1, "The actual timeline tab double tap must emit exactly one request")
        XCTAssertEqual(metric("firstPageRequests", in: pageState.valueDescription) - firstPageCount, 1, "The actual timeline tab double tap must issue exactly one first page")

        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(notice.exists, "The older success timer must not clear the newer persistent error")
        XCTAssertTrue(notice.valueDescription.contains("错误"))
        let beforeClosingError = pageState.valueDescription
        let firstPagesBeforeClose = metric("firstPageRequests", in: beforeClosingError)
        app.buttons["timeline.notice.close"].tap()
        XCTAssertTrue(notice.waitForNonExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 5)
        mainTabButton("作者榜").tap()
        mainTabButton("时间线").tap()
        Thread.sleep(forTimeInterval: 5)
        XCTAssertEqual(metric("firstPageRequests", in: pageState.valueDescription), firstPagesBeforeClose,
                       "Closing a retry-from-start error must not trigger an implicit retry during ten seconds including a real tab cycle")
    }

    func testFailedSavedCursorCanBeRetriedFromFirstPageByRealTap() {
        launchQA("restore-stale-cursor")
        let resume = app.buttons["timeline.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        resume.tap()
        let viewport = activeMediaDeck()
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        viewport.swipeUp()
        viewport.swipeUp()

        let retry = app.buttons["feed.continuation.restart"]
        XCTAssertTrue(retry.waitForExistence(timeout: 15), "A failed saved cursor should expose the production recovery action")
        let notice = app.descendants(matching: .any)["timeline.notice"]
        XCTAssertTrue(notice.valueDescription.contains("错误"))
        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(notice.exists, "Retryable error notice must remain until action")
        let beforeRetry = app.descendants(matching: .any)["qa-state"].valueDescription
        let requestsBeforeRetry = metric("pageRequests", in: beforeRetry)
        let firstPagesBeforeRetry = metric("firstPageRequests", in: beforeRetry)
        retry.tap()
        let state = app.descendants(matching: .any)["qa-state"]
        XCTAssertTrue(state.waitForValueToContain("lastCursor=nil", timeout: 15))
        XCTAssertEqual(metric("pageRequests", in: state.valueDescription) - requestsBeforeRetry, 1, "The real retry tap must produce one new request")
        XCTAssertEqual(metric("firstPageRequests", in: state.valueDescription) - firstPagesBeforeRetry, 1, "The retry tap must issue exactly one first-page request")
        XCTAssertTrue(state.valueDescription.contains("lastSource=recommendation"))
    }

    func testNonTimelineDoubleTapDoesNotRefreshAndTimelineDoubleTapUsesFirstPage() {
        launchQA("restart-recommendation-retained-tail")
        let state = app.descendants(matching: .any)["qa-state"]
        waitUntil("The recommendation fixture must retain its original queue and cursor", timeout: 15) {
            let value = state.valueDescription
            return value.contains("recQueueCount=8") && value.contains("recCursor=qa-next")
        }
        let initialState = state.valueDescription
        XCTAssertTrue(initialState.contains("recFocus=28029101"))
        let firstPages = metric("recSelectedFirstPageRequests", in: initialState)
        XCTAssertGreaterThanOrEqual(firstPages, 0)

        let authorTab = mainTabButton("作者榜")
        let timelineTab = mainTabButton("时间线")
        authorTab.doubleTap()
        waitForTimelineGestureTestTab("作者榜")
        timelineTab.tap()
        waitForTimelineGestureTestTab("时间线")
        XCTAssertEqual(metric("recSelectedFirstPageRequests", in: state.valueDescription), firstPages,
                       "Other tab double tap must not restart")
        XCTAssertTrue(state.valueDescription.contains("recFocus=28029101"), "Single selection must preserve focus")
        XCTAssertTrue(state.valueDescription.contains("recCursor=qa-next"), "Single selection must preserve the old cursor")
        XCTAssertTrue(state.valueDescription.contains("recQueueCount=8"), "Single selection must preserve the loaded queue")

        authorTab.tap()
        waitForTimelineGestureTestTab("作者榜")
        XCTAssertEqual(metric("recSelectedFirstPageRequests", in: state.valueDescription), firstPages,
                       "Leaving Timeline must not request a new first page")
        timelineTab.doubleTap()
        waitForTimelineGestureTestTab("时间线")
        XCTAssertTrue(state.waitForValueToContain("recQueueCount=5", timeout: 10), "Double tap must replace the retained queue with the first page")
        XCTAssertTrue(state.valueDescription.contains("recCursor=nil"), "Restart request must leave the recommendation lane at its initial-page cursor")
        XCTAssertTrue(state.valueDescription.contains("recFocus=28029101"), "A successful restart should focus the first returned item")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(metric("recSelectedFirstPageRequests", in: state.valueDescription), firstPages + 1,
                       "One double tap must issue exactly one new first-page request")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "接着看")).firstMatch.exists)
    }

    func testDoubleTapTimelineFromAnotherTabRestartsFollowingQueueWithExistingFilter() {
        launchQA("restart-following")
        let state = app.descendants(matching: .any)["qa-state"]
        XCTAssertTrue(state.waitForValueToContain("followQueueCount=5", timeout: 15))

        selectTimelineSource("关注")
        XCTAssertTrue(state.waitForValueToContain("source=following", timeout: 10))
        XCTAssertTrue(state.valueDescription.contains("kind=video"))
        XCTAssertTrue(state.valueDescription.contains("sort=Most Comments"))
        XCTAssertTrue(state.valueDescription.contains("period=Month"))
        activeMediaDeck().swipeUp()
        waitUntil("The existing Following queue is on its second work") {
            self.metric("followFocus", in: state.valueDescription) == 28_029_102
        }

        let beforeLeaving = state.valueDescription
        let firstPageBeforeLeaving = metric("followSelectedFirstPageRequests", in: beforeLeaving)
        XCTAssertGreaterThanOrEqual(firstPageBeforeLeaving, 0)
        mainTabButton("作者榜").tap()
        waitForTimelineGestureTestTab("作者榜")
        let afterSingleWorksTap = state.valueDescription
        XCTAssertEqual(metric("followSelectedFirstPageRequests", in: afterSingleWorksTap), firstPageBeforeLeaving,
                       "Single navigation to Works must not restart the selected Following feed")
        mainTabButton("时间线").doubleTap()
        waitForTimelineGestureTestTab("时间线")
        waitUntil("Double tap must request the first page using the selected Following filter", timeout: 15) {
            self.metric("followSelectedFirstPageRequests", in: state.valueDescription) == firstPageBeforeLeaving + 1
        }
        waitUntil("The refreshed Following queue returns to its first work") {
            self.metric("followFocus", in: state.valueDescription) == 28_029_101
        }
        let readback = state.valueDescription
        XCTAssertTrue(readback.contains("lastSource=following"), "Refresh from Works must apply to the active followed lane")
        XCTAssertTrue(readback.contains("lastKind=video;lastSort=Most Comments;lastPeriod=Month"), "Refresh must retain filter and sort")
        XCTAssertTrue(readback.contains("lastCursor=nil"), "Refresh must discard the old continuation cursor")
        XCTAssertTrue(readback.contains("followFocus=28029101"), "The first returned item should become focused")
        XCTAssertTrue(readback.contains("followQueueCount=5"), "The refreshed queue should use the first page")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(metric("followSelectedFirstPageRequests", in: state.valueDescription), firstPageBeforeLeaving + 1,
                       "One double tap from Works must issue exactly one new first-page request")
    }

    private func waitForTimelineGestureTestTab(_ title: String) {
        waitUntil("The \(title) tab must be committed and the timeline button hittable", timeout: 8) {
            self.mainTabButton(title).isSelected && self.mainTabButton("时间线").isHittable
        }
    }

    func testSelectedTimelineSingleTapReturnsToTopAndDoubleTapRestarts() {
        launchQA("restart-recommendation")
        let state = app.descendants(matching: .any)["qa-state"]
        XCTAssertTrue(state.waitForValueToContain("recQueueCount=5", timeout: 15))
        let deck = activeMediaDeck()
        deck.swipeUp()
        XCTAssertTrue(state.waitForValueToContain("recFocus=28029102", timeout: 10), state.valueDescription)
        deck.swipeUp()
        XCTAssertTrue(state.waitForValueToContain("recFocus=28029103", timeout: 10), state.valueDescription)
        let before = state.valueDescription
        let firstPages = metric("recFirstPageRequests", in: before)
        let timeline = mainTabButton("时间线")
        timeline.tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(state.waitForValueToContain("recFocus=28029101", timeout: 5), "Single reselect must return to the first loaded work; actual=\(state.valueDescription)")
        XCTAssertEqual(metric("recFirstPageRequests", in: state.valueDescription), firstPages)
        timeline.doubleTap()
        XCTAssertTrue(state.waitForValueToContain("recFirstPageRequests=\(firstPages + 1)", timeout: 10), state.valueDescription)
        XCTAssertTrue(state.waitForValueToContain("recFocus=28029101", timeout: 10), state.valueDescription)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(metric("recFirstPageRequests", in: state.valueDescription), firstPages + 1)
    }

    func testFollowingReselectReturnsToItsOwnTopAndDoubleTapRefreshesOnlyFollowing() {
        launchQA("restart-following")
        let state = app.descendants(matching: .any)["qa-state"]
        XCTAssertTrue(state.waitForValueToContain("recQueueCount=5", timeout: 15))
        activeMediaDeck().swipeUp()
        XCTAssertTrue(state.waitForValueToContain("recFocus=28029102", timeout: 10), state.valueDescription)
        selectTimelineSource("关注")
        XCTAssertTrue(state.waitForValueToContain("followQueueCount=5", timeout: 15))
        activeMediaDeck().swipeUp()
        XCTAssertTrue(state.waitForValueToContain("followFocus=28029102", timeout: 10), state.valueDescription)
        let before = state.valueDescription
        let followingPages = metric("followFirstPageRequests", in: before)
        let recommendationPages = metric("recFirstPageRequests", in: before)
        mainTabButton("时间线").tap()
        XCTAssertTrue(state.waitForValueToContain("followFocus=28029101", timeout: 5), state.valueDescription)
        XCTAssertTrue(state.valueDescription.contains("recFocus=28029102"), "Return-to-top must not move the inactive recommendation lane")
        XCTAssertEqual(metric("followFirstPageRequests", in: state.valueDescription), followingPages)
        mainTabButton("时间线").doubleTap()
        XCTAssertTrue(state.waitForValueToContain("followFirstPageRequests=\(followingPages + 1)", timeout: 10), state.valueDescription)
        let readback = state.valueDescription
        XCTAssertTrue(readback.contains("lastSource=following"))
        XCTAssertTrue(readback.contains("lastKind=video;lastSort=Most Comments;lastPeriod=Month;lastCursor=nil"))
        XCTAssertTrue(readback.contains("recFocus=28029102"), "Following refresh must preserve the inactive recommendation focus")
        XCTAssertEqual(metric("recFirstPageRequests", in: readback), recommendationPages)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(metric("followFirstPageRequests", in: state.valueDescription), followingPages + 1)
    }

    func testShortQueueSingleTapDoesNotRetryContinuation() {
        for count in 2...4 {
            launchQA("restart-short-\(count)")
            let state = app.descendants(matching: .any)["qa-state"]
            XCTAssertTrue(state.waitForValueToContain("recQueueCount=\(count)", timeout: 15))
            activeMediaDeck().swipeUp()
            XCTAssertTrue(state.waitForValueToContain("recFocus=28029102", timeout: 10), state.valueDescription)
            XCTAssertTrue(app.buttons["加载失败，点此重试"].waitForExistence(timeout: 10), "The fixture must have a failed ordinary continuation before reselecting")
            Thread.sleep(forTimeInterval: 1)
            let before = state.valueDescription
            XCTAssertTrue(before.contains("recCursor=qa-next"))
            let totalRequests = metric("pageRequests", in: before)
            let firstPages = metric("recFirstPageRequests", in: before)
            mainTabButton("时间线").tap()
            XCTAssertTrue(state.waitForValueToContain("recFocus=28029101", timeout: 5), state.valueDescription)
            Thread.sleep(forTimeInterval: 2)
            let after = state.valueDescription
            XCTAssertEqual(metric("pageRequests", in: after), totalRequests, "A single return-to-top must not retry a failed continuation for \(count) rows")
            XCTAssertEqual(metric("recFirstPageRequests", in: after), firstPages)
            XCTAssertTrue(after.contains("recQueueCount=\(count)"))
            XCTAssertTrue(after.contains("recCursor=qa-next"))
            attachScreenshot(named: "short-queue-\(count)-after-return-to-top")
            activeMediaDeck().swipeUp()
            XCTAssertTrue(state.waitForValueToContain("pageRequests=\(totalRequests + 1);", timeout: 10), "An actual swipe after return-to-top must re-enable ordinary loading")
        }
    }

    func testFavoritesDownloadAndAccountNavigation() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "--qa-download-tasks",
                               "-app.appearance", "light", "-muted", "YES", "-autoplay", "NO"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let favorites = mainTabButton("收藏")
        XCTAssertTrue(favorites.waitForExistence(timeout: 8))
        XCTAssertFalse(mainTabButton("我").exists)
        favorites.tap()
        let collections = app.descendants(matching: .any)["collections.top-bar"]
        XCTAssertTrue(collections.waitForExistence(timeout: 5))
        let downloads = collections.buttons["collections.downloads"]
        let media = collections.otherElements["collection.media-kind"]
        XCTAssertFalse(app.navigationBars["收藏"].exists)
        XCTAssertTrue(downloads.isHittable && media.isHittable)
        XCTAssertEqual(media.frame.midY, downloads.frame.midY, accuracy: 2)
        let first = app.buttons["media.grid.cell.28037100"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["collections.folder-picker"].exists)
        XCTAssertFalse(app.buttons["新建私密收藏夹"].exists)
        let filter = app.buttons["collection-filter-menu"]
        XCTAssertTrue(filter.isHittable)
        attachScreenshot(named: "favorites84-filter-light")
        filter.tap()
        let pg = app.buttons["collection-only-pg"]
        XCTAssertTrue(pg.waitForExistence(timeout: 5))
        attachScreenshot(named: "favorites-pg-menu-icon")
        pg.tap()
        filter.tap()
        app.buttons["筛选条件"].tap()
        let filterHeader = floatingPageTitle("收藏筛选")
        XCTAssertTrue(filterHeader.waitForExistence(timeout: 5))
        let pgSwitch = app.switches["仅看 PG"]
        XCTAssertEqual(pgSwitch.value as? String, "1")
        pgSwitch.tap()
        filterHeader.buttons["navigation.back"].tap()
        XCTAssertTrue(filterHeader.waitForNonExistence(timeout: 5))
        downloads.tap()
        XCTAssertTrue(floatingPageTitle("下载管理").waitForExistence(timeout: 5))
        let active = app.staticTexts["视频 #28037601"]
        let progress = app.descendants(matching: .any)["downloads.progress.28037601"]
        let action = app.buttons["downloads.task-action.28037601"]
        let retry = app.buttons["downloads.task-action.28037602"]
        let queued = app.buttons["downloads.task-action.28037603"]
        XCTAssertTrue(active.waitForExistence(timeout: 5))
        XCTAssertTrue(progress.exists && action.isHittable)
        XCTAssertGreaterThan(progress.frame.midY, active.frame.maxY)
        XCTAssertTrue(action.label.hasPrefix("暂停下载作品"))
        XCTAssertTrue(app.staticTexts["图片 #28037603"].exists)
        XCTAssertTrue(app.staticTexts["图片 #28037602"].exists)
        XCTAssertTrue(retry.exists && !retry.isEnabled)
        XCTAssertTrue(queued.exists && !queued.isEnabled)
        for status in ["下载中", "已完成", "下载失败"] {
            XCTAssertFalse(app.staticTexts[status].exists, "The row uses progress and action instead of duplicate status copy")
        }
        XCTAssertTrue(retry.label.hasPrefix("重试下载作品") && queued.label.hasPrefix("下载作品"))
        for button in [retry, queued] {
            XCTAssertEqual(button.frame.width, action.frame.width, accuracy: 1)
            XCTAssertEqual(button.frame.height, action.frame.height, accuracy: 1)
        }
        XCTAssertGreaterThanOrEqual(action.frame.height, 43)
        XCTAssertFalse(floatingPageTitle("下载管理").buttons["downloads.queue-action"].exists)
        XCTAssertFalse(app.buttons["settings.downloads"].exists)
        XCTAssertFalse(app.buttons["downloads.offline"].exists)
        attachScreenshot(named: "downloads86-queue-active")
        action.tap()
        waitUntil("The paused task exposes its continue action") { action.label.hasPrefix("继续下载作品") }
        XCTAssertTrue(retry.isEnabled && queued.isEnabled)
        action.tap()
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        XCTAssertTrue(action.label.hasPrefix("暂停下载作品"))
        openAccountSettings()
        heightTap(app.buttons["settings.downloads"])
        XCTAssertTrue(floatingPageTitle("下载设置").waitForExistence(timeout: 5))
        for identifier in ["downloads.auto-save", "downloads.wifi-only", "downloads.capacity"] {
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: identifier).firstMatch.exists)
        }
        floatingPageTitle("下载设置").buttons["navigation.back"].tap()
        openAccountSettings()
        heightTap(app.buttons["settings.offline-library"])
        XCTAssertTrue(floatingPageTitle("离线收藏与空间").waitForExistence(timeout: 5))
        let offlineState = app.buttons["作品状态"]
        tapAboveMainBar(offlineState)
        let allStates = app.buttons["全部状态"]
        XCTAssertTrue(allStates.waitForExistence(timeout: 5))
        allStates.tap()
        let storageActions = app.buttons["更多空间操作"]
        tapAboveMainBar(storageActions)
        XCTAssertLessThanOrEqual(storageActions.frame.maxY, mainTabBar().frame.minY + 1)
        let clearBrowserCache = app.buttons["offline.storage.clear-browser-cache"]
        let menuOpened = clearBrowserCache.waitForExistence(timeout: 5)
        attachScreenshot(named: "offline-storage-last-row-menu")
        if !menuOpened { print(app.debugDescription) }
        XCTAssertTrue(menuOpened)
    }

    func testAuthorBatchFavoriteRetriesOnlyUnconfirmedWork() {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-batch-favorite-partial", "-muted", "YES", "-autoplay", "NO"])
        visualButton("media.author.28037100").tap()
        let author = app.descendants(matching: .any)["creator.top-bar"]
        let entry = author.buttons["creator.actions"]
        XCTAssertTrue(entry.waitForExistence(timeout: 8))
        entry.tap()
        let select = app.buttons["favorite-batch.select"]
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        select.tap()
        let cancel = mainTabBar().buttons["favorite-batch.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
        let first = visualButton("media.grid.cell.28037100")
        let second = visualButton("media.grid.cell.28037101")
        XCTAssertTrue(first.isHittable && second.isHittable)
        let original = first.frame
        let originalBar = mainTabBar().frame
        first.press(forDuration: 0.65)
        let selection = mainTabBar().buttons["favorite-batch.open"]
        XCTAssertTrue(selection.waitForExistence(timeout: 5))
        XCTAssertEqual(mainTabBar().frame, originalBar, "Selecting must keep the same bottom-bar frame")
        XCTAssertEqual(selection.label, "收藏 1")
        XCTAssertEqual(first.frame.width, original.width, accuracy: 1)
        XCTAssertEqual(first.frame.minY, original.minY, accuracy: 1)
        second.tap()
        XCTAssertEqual(selection.label, "收藏 2")
        XCTAssertFalse(app.buttons["关闭作品"].exists, "Selection must not open the viewer")
        attachScreenshot(named: "favorites86-author-selection")
        selection.tap()
        let save = app.buttons["favorite-batch.save"]
        waitUntil("Default folder is ready") { save.exists && save.isEnabled }
        save.tap()
        waitUntil("Only the unconfirmed work remains after a partial failure") {
            self.app.staticTexts["待收藏 1 项作品"].exists && save.label == "重试" && save.isEnabled
        }
        save.tap()
        XCTAssertTrue(app.staticTexts["已收藏 2 项作品"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertTrue(mainTabButton("时间线").waitForExistence(timeout: 5))
        XCTAssertEqual(mainTabBar().frame, originalBar)
    }

    func testCollectionLongPressBatchRemovalKeepsOtherFolder() {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-multiple-collections", "--qa-collection-batch-manage", "--qa-batch-favorite-partial", "-autoplay", "NO"])
        mainTabButton("收藏").tap()
        let bar = app.descendants(matching: .any)["collections.top-bar"]
        let first = visualButton("media.grid.cell.28037100")
        let second = visualButton("media.grid.cell.28037101")
        let original = first.frame
        let originalBar = mainTabBar().frame
        first.press(forDuration: 0.65)
        let back = mainTabBar().buttons["collection-batch.back"]
        let remove = mainTabBar().buttons["collection-batch.remove"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertTrue(remove.exists)
        XCTAssertFalse(mainTabBar().buttons["collection-batch.manage"].exists)
        XCTAssertEqual(mainTabBar().frame, originalBar)
        XCTAssertEqual(first.frame.width, original.width, accuracy: 1)
        XCTAssertEqual(first.frame.minY, original.minY, accuracy: 1)
        XCTAssertFalse(app.buttons["关闭作品"].exists)
        second.tap()
        XCTAssertTrue(remove.isEnabled)
        XCTAssertEqual(mainTabBar().frame, originalBar, "Long press exposes the final single-row actions directly")
        attachScreenshot(named: "favorites-single-row-add-remove-back")
        remove.tap()
        XCTAssertTrue(floatingPageTitle("批量移除").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["分页测试收藏"].exists)
        XCTAssertFalse(app.staticTexts["另一个收藏夹"].exists)
        let save = app.buttons["favorite-batch.save"]
        waitUntil("The current folder has been verified") { save.isEnabled }
        save.tap()
        let partial = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.app.staticTexts["待移除 1 项作品"].exists && save.label == "重试"
        }, object: nil)
        let partialResult = XCTWaiter.wait(for: [partial], timeout: 8)
        if partialResult != .completed {
            attachScreenshot(named: "favorite169-partial-removal-failure")
            print("BATCH169_PARTIAL_FAILURE " + app.debugDescription)
        }
        XCTAssertEqual(partialResult, .completed, "After partial removal only the unconfirmed work remains")
        save.tap()
        XCTAssertTrue(app.staticTexts["已移除 2 项作品"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        XCTAssertTrue(first.waitForNonExistence(timeout: 5))
        XCTAssertFalse(second.exists)
        XCTAssertTrue(mainTabButton("收藏").waitForExistence(timeout: 5))
        XCTAssertEqual(mainTabBar().frame, originalBar)

        bar.buttons["collections.folder-picker"].tap()
        app.buttons["collections.folder.28037003"].tap()
        app.buttons["collections.folder.28037002"].tap()
        app.buttons["collections.apply-folders"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 8), "The same work must remain in the other folder")
        XCTAssertFalse(second.exists)
    }

    func testHistoryBatchFavoriteConfirmsBothWorks() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "-app.appearance", "light", "-muted", "YES", "-autoplay", "NO"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let timeline = mainTabButton("时间线")
        XCTAssertTrue(timeline.waitForExistence(timeout: 8))
        if !timeline.isSelected { timeline.tap() }
        XCTAssertTrue(timelineTools().waitForExistence(timeout: 8))
        openTimelineTool("最近浏览")
        let history = floatingPageTitle("最近浏览")
        XCTAssertTrue(history.waitForExistence(timeout: 8))
        let first = app.buttons["history.item.28037100"]
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        first.press(forDuration: 0.65)
        heightTap(app.buttons["history.item.28037101"])
        let selection = mainTabBar().buttons["favorite-batch.open"]
        XCTAssertEqual(selection.label, "收藏 2")
        attachScreenshot(named: "favorites86-history-selection")
        selection.tap()
        let save = app.buttons["favorite-batch.save"]
        waitUntil("Default folder is ready") { save.exists && save.isEnabled }
        save.tap()
        XCTAssertTrue(app.staticTexts["已收藏 2 项作品"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["history.item.28037101"].exists)
        XCTAssertFalse(mainTabBar().buttons["favorite-batch.open"].exists)
    }

    func testFavoritesRestoreCachedListBeforeFreshAccountResponse() {
        app = XCUIApplication()
        let cache = "--qa-collection-cache-key=\(UUID().uuidString)"
        let common = ["--qa-collection-paging", "--qa-collection-cache-controlled", cache,
                      "-app.appearance", "light", "-muted", "YES", "-autoplay", "NO"]
        XCUIDevice.shared.orientation = .portrait
        let previous = app.buttons["media.grid.cell.28037100"]
        let fresh = app.buttons["media.grid.cell.28037106"]
        let receipt = app.staticTexts["collection-cache.qa"]
        let progress = app.descendants(matching: .any)["feed.continuation.loading"]
        let release = app.buttons["collection-cache.qa.release"]

        app.launchArguments = common
        app.launch()
        XCTAssertTrue(mainTabButton("收藏").isSelected)
        XCTAssertFalse(previous.exists, "The cold list has to wait for the controlled server reads")
        XCTAssertTrue(progress.waitForExistence(timeout: 8), "The initial request shows feedback when no cards are available")
        release.tap()
        XCTAssertTrue(previous.waitForExistence(timeout: 12))
        waitUntil("The first confirmed list must be persisted before relaunching") { receipt.exists && receipt.label == "stored" }

        app.terminate()
        app.launchArguments = common + ["--qa-collection-cache-update"]
        app.launch()
        XCTAssertTrue(mainTabButton("收藏").isSelected)
        XCTAssertTrue(previous.waitForExistence(timeout: 8), "The previous list should appear before the held cloud response")
        XCTAssertFalse(progress.exists, "A cached grid does not show the initial loading indicator")
        XCTAssertFalse(fresh.exists)
        attachScreenshot(named: "collection90-cached-before-network")
        release.tap()
        XCTAssertTrue(fresh.waitForExistence(timeout: 12))
        XCTAssertFalse(previous.exists, "A work removed upstream should disappear after reconciliation")
        waitUntil("The refreshed list replaces the stored preview") { receipt.exists && receipt.label == "stored" }
        attachScreenshot(named: "collection90-reconciled")

        app.buttons["collection-filter-menu"].tap()
        app.buttons["刷新作品"].tap()
        XCTAssertTrue(receipt.waitForValueToContain("loading", timeout: 3))
        XCTAssertTrue(fresh.isHittable, "The last confirmed single-card grid stays usable during refresh")
        XCTAssertFalse(progress.exists, "A background refresh does not add a spinner to a usable grid")
        release.tap()
        XCTAssertTrue(receipt.waitForValueToContain("settled", timeout: 8))

        let videos = app.otherElements["collection.media-kind"].buttons["视频"]
        videos.tap()
        waitUntil("The video pane is ready for input after its transition") { videos.isSelected && release.isHittable }
        XCTAssertTrue(receipt.waitForValueToContain("loading", timeout: 3))
        XCTAssertFalse(app.staticTexts["feed.continuation.ended"].exists,
                       "A cold video pane must not claim an empty result before its first response")
        XCTAssertTrue(progress.waitForExistence(timeout: 3),
                      "A cold empty pane keeps its pending feedback while the first response is held")
        release.tap()
        let ended = app.staticTexts["feed.continuation.ended"]
        XCTAssertTrue(ended.waitForExistence(timeout: 8), "An empty scoped cloud result settles instead of spinning")
        XCTAssertTrue(receipt.waitForValueToContain("settled", timeout: 3))
        XCTAssertFalse(fresh.exists, "Changing media kind never shows the previous kind's cached work")
        XCTAssertFalse(progress.exists)

        app.buttons["collection-filter-menu"].tap()
        app.buttons["刷新作品"].tap()
        XCTAssertTrue(receipt.waitForValueToContain("loading", timeout: 3),
                      "The refresh request is held after the pane has confirmed empty")
        XCTAssertTrue(ended.waitForExistence(timeout: 2),
                      "A confirmed empty pane keeps its empty presentation as refresh starts")
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        XCTAssertTrue(ended.exists,
                      "A confirmed empty pane stays empty after the delayed-spinner threshold")
        XCTAssertFalse(progress.exists,
                       "A quiet refresh of a confirmed empty pane does not replace it with a spinner")
        release.tap()
        XCTAssertTrue(receipt.waitForValueToContain("settled", timeout: 8))
        XCTAssertTrue(ended.exists, "The empty presentation remains after refresh settles")
    }

    func testFavoritesLoadsNextPageSilentlyWhileCardsAreVisible() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-collection-cache-controlled", "--qa-collection-second-page",
                               "--qa-collection-cache-key=\(UUID().uuidString)", "-muted", "YES", "-autoplay", "NO"]
        app.launch()
        let release = app.buttons["collection-cache.qa.release"]
        let spinner = app.descendants(matching: .any)["feed.continuation.loading"]
        XCTAssertTrue(spinner.waitForExistence(timeout: 8))
        release.tap()
        let first = app.buttons["media.grid.cell.28037100"]
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        let receipt = app.staticTexts["collection-cache.qa"]
        XCTAssertTrue(receipt.waitForValueToContain("loading", timeout: 8))
        XCTAssertTrue(first.isHittable)
        XCTAssertFalse(spinner.exists)
        release.tap()
        XCTAssertTrue(app.buttons["media.grid.cell.28037106"].waitForExistence(timeout: 8))
        XCTAssertTrue(receipt.waitForValueToContain("settled", timeout: 4))
    }

    func testFavoritesOpensLocalWorkWhileCloudListIsLoading() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-collection-cache-controlled", "--qa-visual-controls", "--qa-height-audit",
                               "--qa-collection-cache-key=\(UUID().uuidString)", "--qa-collection-cache-fail",
                               "-muted", "YES", "-autoplay", "NO"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let favorites = mainTabButton("收藏")
        XCTAssertTrue(favorites.waitForExistence(timeout: 8))
        favorites.tap()
        waitUntil("The floating tab selects the collection page while its data is pending") { favorites.isSelected }
        let card = visualButton("media.grid.cell.28037100")
        let progress = app.descendants(matching: .any)["feed.continuation.loading"]
        let retry = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["feed.continuation.retry", "feed.continuation.restart"])).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 8), "A downloaded work can appear before the held first cloud page")
        XCTAssertFalse(retry.exists, "The held request hasn't returned its controlled failure yet")
        XCTAssertFalse(progress.exists)
        XCTAssertTrue(card.isHittable)
        card.tap()
        let close = app.buttons["关闭作品"]
        XCTAssertTrue(close.waitForExistence(timeout: 4), "Opening the local card presents the collection viewer")
        let geometry = app.staticTexts.matching(identifier: "collection.qa.geometry")
            .matching(NSPredicate(format: "label BEGINSWITH %@", "focused=28037100;")).firstMatch
        XCTAssertTrue(geometry.waitForExistence(timeout: 4))
        close.tap()
        app.buttons["collection-cache.qa.release"].tap()
        XCTAssertTrue(retry.waitForExistence(timeout: 9), "Returning to the list still surfaces a cloud failure with retry")
        XCTAssertTrue(card.isHittable, "A cloud read failure preserves playable local works")
        XCTAssertFalse(progress.exists)
    }

    func testFavoritesSelectMultipleFoldersInPlace() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-multiple-collections",
                               "-app.appearance", "dark", "-muted", "YES", "-autoplay", "NO"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let favorites = mainTabButton("收藏")
        XCTAssertTrue(favorites.waitForExistence(timeout: 8)); favorites.tap()

        let bar = app.descendants(matching: .any)["collections.top-bar"]
        let picker = bar.buttons["collections.folder-picker"]
        let first = app.buttons["collections.folder.28037002"]
        let second = app.buttons["collections.folder.28037003"]
        let apply = app.buttons["collections.apply-folders"]
        let firstWork = app.buttons["media.grid.cell.28037100"]
        let secondWork = app.buttons["media.grid.cell.28037106"]
        let firstOnly = app.buttons["media.grid.cell.28037101"]
        XCTAssertTrue(firstWork.waitForExistence(timeout: 8), "A multi-folder account opens directly to works")
        XCTAssertEqual(picker.value as? String, "分页测试收藏")
        XCTAssertLessThan(picker.frame.maxY, firstWork.frame.minY)
        XCTAssertEqual(picker.frame.midY, bar.buttons["collections.downloads"].frame.midY, accuracy: 4)
        let media = bar.otherElements["collection.media-kind"]
        let filter = bar.buttons["collection-filter-menu"]
        XCTAssertEqual(picker.frame.minX - bar.buttons["collections.downloads"].frame.maxX, 4, accuracy: 1)
        XCTAssertEqual(media.frame.minX - picker.frame.maxX, 4, accuracy: 1)
        XCTAssertEqual(filter.frame.minX - media.frame.maxX, 4, accuracy: 1)
        XCTAssertEqual(media.buttons["图片"].frame.width, media.buttons["视频"].frame.width, accuracy: 1)
        XCTAssertFalse(app.navigationBars["收藏"].exists)
        picker.tap()
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        attachScreenshot(named: "favorites84-folder-default-dark")
        XCTAssertEqual(first.value as? String, "已选")
        XCTAssertEqual(second.value as? String, "未选")
        second.tap()
        XCTAssertEqual(first.value as? String, "已选")
        XCTAssertEqual(second.value as? String, "已选")
        attachScreenshot(named: "favorites84-toolbar-dropdown-dark")
        apply.tap()
        XCTAssertTrue(secondWork.waitForExistence(timeout: 5))
        XCTAssertTrue(firstOnly.exists)
        XCTAssertEqual(app.buttons.matching(identifier: "media.grid.cell.28037100").count, 1)
        XCTAssertEqual(picker.value as? String, "已选 2 个收藏夹")
        attachScreenshot(named: "favorites84-toolbar-merged-dark")

        picker.tap(); first.tap(); apply.tap()
        XCTAssertTrue(secondWork.waitForExistence(timeout: 5))
        XCTAssertFalse(firstOnly.exists)
        XCTAssertEqual(picker.value as? String, "另一个收藏夹")
        XCTAssertTrue(bar.exists)
        XCTAssertFalse(bar.buttons["navigation.back"].exists)

        let video = app.otherElements["collection.media-kind"].buttons["视频"]
        video.tap()
        XCTAssertTrue(app.staticTexts["没有符合条件的作品"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["调整筛选"].exists)
        let filterMenu = app.buttons["collection-filter-menu"]
        XCTAssertTrue(filterMenu.isHittable)
        attachScreenshot(named: "favorites88-empty-filter")
        filterMenu.tap()
        app.buttons["筛选条件"].tap()
        XCTAssertTrue(floatingPageTitle("收藏筛选").waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        picker.tap(); first.tap(); apply.tap()
        XCTAssertTrue(app.buttons["media.grid.cell.28037102"].waitForExistence(timeout: 5))
        XCTAssertEqual(picker.value as? String, "已选 2 个收藏夹")
        XCTAssertTrue(video.isSelected)

        bar.buttons["collections.downloads"].tap()
        let back = floatingPageTitle("下载管理").buttons["navigation.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5)); back.tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        XCTAssertEqual(picker.value as? String, "已选 2 个收藏夹")
        XCTAssertTrue(video.isSelected)
    }

    func testCollectionViewerPagesAfterRealFavoritesEntryAndRotation() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "-muted", "YES"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        mainTabButton("收藏").tap()
        attachScreenshot(named: "favorites-grid-before-opening")
        for index in [0, 1, 2, 4, 5, 0] {
            let video = index == 2 || index == 4
            let mode = app.otherElements["collection.media-kind"].buttons[video ? "视频" : "图片"]
            XCTAssertTrue(mode.waitForExistence(timeout: 5))
            if !mode.isSelected { mode.tap() }
            let nextIndex = [0: 1, 1: 3, 2: 4][index]
            let cell = app.buttons["media.grid.cell.\(28_037_100 + index)"]
            if !cell.waitForExistence(timeout: 10) { app.swipeDown() }
            XCTAssertTrue(cell.waitForExistence(timeout: 10))
            if !cell.isHittable { if index == 0 { app.swipeDown() } else { app.swipeUp() } }
            cell.tap()
            let geometry = app.staticTexts["collection.qa.geometry"]
            XCTAssertTrue(geometry.waitForExistence(timeout: 10))
            XCTAssertTrue(geometry.waitForValueToContain("focused=\(28_037_100 + index)", timeout: 10))
            attachScreenshot(named: "favorites-entry-\(index)")
            print("COLLECTION_GEOMETRY_ENTRY \(geometry.valueDescription)")
            assertCollectionPageAligned(geometry)
            if index == 2 {
                app.buttons["手动切换横竖屏"].tap()
                XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
                attachScreenshot(named: "favorites-video-landscape")
                print("COLLECTION_GEOMETRY_LANDSCAPE \(geometry.valueDescription)")
                app.buttons["手动切换横竖屏"].tap()
                attachScreenshot(named: "favorites-video-return-portrait")
                assertCollectionPageAligned(geometry)
                viewportDoubleTapAuthorAndReturn()
            }
            let viewport = app.scrollViews.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? app.scrollViews.firstMatch
            XCTAssertTrue(viewport.exists)
            if let nextIndex {
                viewport.swipeUp()
                XCTAssertTrue(geometry.waitForValueToContain("focused=\(28_037_100 + nextIndex)", timeout: 5), "An upward swipe must select the next work of the selected media type")
                attachScreenshot(named: "favorites-after-swipe-\(index)")
                print("COLLECTION_GEOMETRY_SWIPE \(geometry.valueDescription)")
                assertCollectionPageAligned(geometry)
            }
            app.buttons["关闭作品"].tap()
            XCTAssertTrue(cell.waitForExistence(timeout: 5))
        }
    }

    func testCollectionVideoShowsSharedTabBarAndRoutesAfterClosing() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-chrome-geometry", "-muted", "YES", "-civitviewer.automaticRotation", "NO"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        mainTabButton("收藏").tap()
        let bar = app.otherElements["collections.top-bar"]
        let video = bar.otherElements["collection.media-kind"].buttons["视频"]
        let downloads = bar.buttons["collections.downloads"]
        let filter = bar.buttons["collection-filter-menu"]
        XCTAssertTrue(video.waitForExistence(timeout: 5))
        video.tap()
        let cell = app.buttons["media.grid.cell.28037102"]
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        let portraitCover = cell.frame
        XCTAssertLessThan(downloads.frame.maxX, video.frame.minX)
        XCTAssertLessThan(video.frame.maxX, filter.frame.minX)
        cell.tap()
        let playbackHeader = floatingPageTitle("作品")
        let close = playbackHeader.buttons["playback.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        let share = playbackHeader.buttons["playback.share"]
        let rotate = app.buttons["手动切换横竖屏"]
        XCTAssertLessThan(close.frame.midX, playbackHeader.frame.midX)
        XCTAssertTrue(rotate.isHittable)
        XCTAssertTrue(share.isHittable)
        XCTAssertGreaterThan(share.frame.midX, playbackHeader.frame.midX)
        XCTAssertEqual(close.frame.size, share.frame.size)
        XCTAssertGreaterThan(rotate.frame.minY, playbackHeader.frame.maxY)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "手动切换横竖屏")).allElementsBoundByIndex.filter(\.isHittable).count, 1)
        rotate.tap()
        heightWaitOrientation(landscape: true)
        close.tap()
        waitUntil("Closing a manually rotated work restores its opening orientation") {
            let window = self.app.windows.firstMatch.frame
            return window.width > 0 && window.height > window.width
        }
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        XCTAssertTrue(video.isSelected)
        XCTAssertEqual(cell.frame.height, portraitCover.height, accuracy: 1)
        XCTAssertEqual(cell.frame.minX, bar.frame.minX, accuracy: 1)
        XCTAssertEqual(cell.frame.width * 2 + 8, bar.frame.width, accuracy: 2)
        attachScreenshot(named: "collection-video-portrait-grid-after-closing-landscape")
        cell.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        let tabs = app.descendants(matching: .any)["playback.tabs"]
        let search = tabs.buttons["main.tab.4"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        XCTAssertTrue(tabs.buttons["main.tab.3"].isSelected)
        waitUntil("The player's search tab must be tappable") { search.isHittable }
        assertVideoReachesVerticalEdges()
        attachScreenshot(named: "collection-video-shared-tabs")
        search.tap()
        XCTAssertTrue(app.textFields["search-title-input"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["playback.close"].exists)
        mainTabButton("收藏").tap()
        XCTAssertTrue(video.waitForExistence(timeout: 5))
        XCTAssertTrue(video.isSelected)
    }

    func testTimelinePresetKeepsTabsAndDoesNotSuppressCollectionPlaybackChrome() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-chrome-geometry", "-muted", "YES", "-app.appearance", "dark"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()

        let timeline = mainTabButton("时间线")
        XCTAssertTrue(timeline.waitForExistence(timeout: 8))
        if !timeline.isSelected { timeline.tap() }
        XCTAssertTrue(timelineTools().waitForExistence(timeout: 8))
        heightCloseNotices()
        openTimelineTool("已存条件")
        let presetHeader = floatingPageTitle("已存条件 · 推荐")
        XCTAssertTrue(presetHeader.waitForExistence(timeout: 5))
        XCTAssertTrue(mainTabButton("收藏").isHittable)
        mainTabButton("收藏").tap()
        let video = app.otherElements["collection.media-kind"].buttons["视频"]
        XCTAssertTrue(video.waitForExistence(timeout: 5))
        video.tap()
        let cell = app.buttons["media.grid.cell.28037102"]
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        cell.tap()
        let playbackTabs = app.descendants(matching: .any)["playback.tabs"]
        XCTAssertTrue(playbackTabs.waitForExistence(timeout: 5))
        let playbackTimeline = playbackTabs.buttons["main.tab.timeline"]
        XCTAssertTrue(chromeState().waitForValueToContain("hidden=false", timeout: 5))
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        center.press(forDuration: 0.65)
        XCTAssertTrue(chromeState().waitForValueToContain("hidden=true", timeout: 5))
        XCTAssertFalse(playbackTimeline.isHittable)
        center.press(forDuration: 0.65)
        XCTAssertTrue(chromeState().waitForValueToContain("hidden=false", timeout: 5))
        playbackTimeline.tap()
        XCTAssertTrue(presetHeader.waitForExistence(timeout: 5))
        app.buttons["preset.library.done"].tap()
        XCTAssertTrue(app.buttons["timeline.tools"].waitForExistence(timeout: 5))
    }

    private func assertVideoReachesVerticalEdges() {
        waitUntil("The video layer reaches both physical vertical edges") {
            guard let geometry = self.videoGeometryReadback()?.fields,
                  let surface = geometry["surfaceWindow"] as? [String: Double],
                  let window = geometry["window"] as? [String: Double],
                  let y = surface["y"], let height = surface["height"], let fullHeight = window["height"] else { return false }
            return abs(y) < 1 && abs(height - fullHeight) < 1
        }
        if let raw = videoGeometryReadback()?.raw { print("EDGE_VIDEO_GEOMETRY \(raw)") }
    }

    private func assertCollectionPageAligned(_ geometry: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate { _, _ in
            let pairs = geometry.valueDescription.split(separator: ";").compactMap { entry -> (String, Double)? in
                let parts = entry.split(separator: "="); guard parts.count == 2, let number = Double(parts[1]) else { return nil }
                return (String(parts[0]), number)
            }
            let values = Dictionary(uniqueKeysWithValues: pairs)
            guard let py = values["pageY"], let vy = values["viewportY"], let ph = values["pageH"], let vh = values["viewportH"] else { return false }
            return abs(py - vy) < 1 && abs(ph - vh) < 1
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: geometry)], timeout: 5), .completed,
                       "A settled page must fill and align with its viewport: \(geometry.valueDescription)", file: file, line: line)
    }

    private func viewportDoubleTapAuthorAndReturn(screenshotName: String = "favorites-video-double-tap-author", statusBarScheme: String? = nil) {
        let viewport = app.scrollViews.matching(identifier: "media.viewer.deck").firstMatch
        XCTAssertTrue(viewport.exists)
        viewport.doubleTap()
        XCTAssertTrue(app.descendants(matching: .any)["creator.top-bar"].waitForExistence(timeout: 5))
        if let statusBarScheme {
            let legible = NSPredicate { _, _ in self.statusBarGlyphPixels(scheme: statusBarScheme) > 100 }
            let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: legible, object: nil)], timeout: 5)
            if let image = UIImage(data: app.screenshot().pngRepresentation)?.cgImage {
                print("THEME_STATUS_FORMAT bits=\(image.bitsPerComponent)/\(image.bitsPerPixel) alpha=\(image.alphaInfo.rawValue) bitmap=\(image.bitmapInfo.rawValue) size=\(image.width)x\(image.height)")
            }
            print("THEME_STATUS_BAR_\(statusBarScheme) glyphPixels=\(statusBarGlyphPixels(scheme: statusBarScheme))")
            print("THEME_STATUS_AX \(app.statusBars.debugDescription.prefix(2400))")
            attachScreenshot(named: screenshotName + "-status-check")
            XCTAssertEqual(result, .completed,
                           "The status clock must have visible foreground pixels over the ordinary author page")
        }
        attachScreenshot(named: screenshotName)
        let back = app.otherElements["creator.top-bar"].buttons["navigation.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5)); back.tap()
        XCTAssertTrue(app.buttons["关闭作品"].waitForExistence(timeout: 5))
    }

    func testTimelinePresentationSharesQueueAndPreservesGridReturn() {
        launchQA("restart-presentation")
        let state = app.descendants(matching: .any)["qa-state"]
        XCTAssertTrue(state.waitForValueToContain("queueCount=3", timeout: 10))
        XCTAssertFalse(mainTabButton("作品榜").exists)
        let mode = timelineTools()
        XCTAssertTrue(mode.waitForValueToContain("双列网格", timeout: 5))
        attachScreenshot(named: "timeline-grid-shared-queue")
        let initial = metric("pageRequests", in: state.valueDescription)
        XCTAssertEqual(initial, 0, "The controlled fixture seeds three works and a live continuation without issuing an initial request")
        toggleTimelinePresentation()
        XCTAssertTrue(mode.waitForValueToContain("信息流", timeout: 5))
        XCTAssertTrue(state.waitForValueToContain("queueCount=4", timeout: 10))
        XCTAssertTrue(state.valueDescription.contains("lastCursor=qa-next"),
                      "The stream can refill a sparse queue using its existing continuation")
        XCTAssertEqual(metric("firstPageRequests", in: state.valueDescription), 0,
                       "Changing presentation must not replace the current queue")
        XCTAssertEqual(metric("pageRequests", in: state.valueDescription), initial + 1)
        toggleTimelinePresentation()
        XCTAssertTrue(mode.waitForValueToContain("双列网格", timeout: 5))
        let cell = app.buttons["media.grid.cell.28029104"]
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        let originalFrame = cell.frame
        cell.tap()
        XCTAssertTrue(app.buttons["关闭作品"].waitForExistence(timeout: 5))
        attachScreenshot(named: "timeline-grid-selected-fullscreen")
        app.buttons["关闭作品"].tap()
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        XCTAssertEqual(cell.frame.minY, originalFrame.minY, accuracy: 2)
        XCTAssertEqual(metric("pageRequests", in: state.valueDescription), initial + 1)
        XCTAssertEqual(metric("firstPageRequests", in: state.valueDescription), 0)
        attachScreenshot(named: "timeline-grid-return-original-position")
    }

    func testSearchAndCollectionFiltersCommitOnlyOnDone() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "-muted", "YES"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()

        mainTabButton("搜索").tap()
        let searchFilter = app.buttons["search.range"]
        XCTAssertTrue(searchFilter.waitForExistence(timeout: 5))
        let initialSummary = searchFilter.label
        searchFilter.tap()
        let searchHeader = floatingPageTitle("浏览条件")
        let searchVideos = app.otherElements["filter.media-kind"].buttons["视频"]
        XCTAssertTrue(searchVideos.waitForExistence(timeout: 5)); searchVideos.tap()
        searchHeader.buttons["navigation.back"].tap()
        XCTAssertTrue(searchFilter.waitForExistence(timeout: 5))
        XCTAssertEqual(searchFilter.label, initialSummary)
        searchFilter.tap()
        XCTAssertTrue(searchVideos.waitForExistence(timeout: 5))
        XCTAssertFalse(searchVideos.isSelected)
        searchVideos.tap()
        searchHeader.buttons["完成"].tap()
        XCTAssertTrue(searchFilter.waitForExistence(timeout: 5))
        XCTAssertTrue(searchFilter.label.contains("视频"))

        mainTabButton("收藏").tap()
        let videoTab = app.otherElements["collection.media-kind"].buttons["视频"]
        XCTAssertTrue(videoTab.waitForExistence(timeout: 5)); videoTab.tap()
        let collectionMenu = app.buttons["collection-filter-menu"]
        let collectionHeader = floatingPageTitle("收藏筛选")
        let onlyPG = app.switches["filter.only-pg"]
        func openCollectionFilter() {
            collectionMenu.tap()
            app.buttons["collection-show-filter"].tap()
            XCTAssertTrue(collectionHeader.waitForExistence(timeout: 5))
        }
        openCollectionFilter()
        let initialPG = onlyPG.value as? String
        XCTAssertNotNil(initialPG)
        onlyPG.tap()
        XCTAssertNotEqual(onlyPG.value as? String, initialPG)
        collectionHeader.buttons["navigation.back"].tap()
        openCollectionFilter()
        XCTAssertEqual(onlyPG.value as? String, initialPG)
        onlyPG.tap()
        collectionHeader.buttons["完成"].tap()
        openCollectionFilter()
        XCTAssertNotEqual(onlyPG.value as? String, initialPG)
        app.buttons["重置筛选"].tap()
        collectionHeader.buttons["完成"].tap()
        XCTAssertTrue(videoTab.isSelected)
    }

    func testDurationRangeUsesActualTwoThumbDragsAndReset() {
        app = XCUIApplication(); app.launchArguments = ["--qa-collection-paging", "--qa-duration-filter", "-app.appearance", "dark", "-muted", "YES", "-autoplay", "NO"]; app.launch()
        let state = app.staticTexts["duration.qa.state"]
        XCTAssertTrue(state.waitForValueToContain("none", timeout: 5))
        let lower = durationHandle(lower: true), upper = durationHandle(lower: false)
        let enabled = app.switches["duration.range.enabled"]
        XCTAssertEqual(enabled.value as? String, "0")
        XCTAssertFalse(lower.exists); XCTAssertFalse(upper.exists)
        attachScreenshot(named: "duration71-disabled")
        durationExposeHandles()
        let rail = (left: lower.frame.midX, right: upper.frame.midX)
        let trackY = lower.frame.midY
        XCTAssertEqual(upper.frame.midY, trackY, accuracy: 1, "Both handles belong on the same rail")
        let minimumMenu = app.buttons["duration.range.minimum.menu"]
        let maximumMenu = app.buttons["duration.range.maximum.menu"]
        let menuSpacing = maximumMenu.frame.midY - minimumMenu.frame.midY
        XCTAssertEqual(menuSpacing, 0, accuracy: 1)
        attachScreenshot(named: "duration71-enabled")
        durationDrag(lower: true, seconds: 17, rail: rail, touchOffset: 10)
        XCTAssertTrue(lower.waitForValueToContain("00:17", timeout: 5))
        XCTAssertEqual(lower.frame.midY, trackY, accuracy: 1, "Starting the range must keep the lower handle in place")
        XCTAssertEqual(upper.frame.midY, trackY, accuracy: 1, "Starting the range must keep the upper handle in place")
        durationMenu(lower: true, action: "增加1秒"); XCTAssertTrue(lower.waitForValueToContain("00:18", timeout: 5))
        durationMenu(lower: true, action: "减少1秒"); XCTAssertTrue(lower.waitForValueToContain("00:17", timeout: 5))
        durationDrag(lower: false, seconds: 75, rail: rail)
        XCTAssertTrue(upper.waitForValueToContain("01:15", timeout: 5))
        durationMenu(lower: false, action: "增加1秒"); XCTAssertTrue(upper.waitForValueToContain("01:16", timeout: 5))
        durationMenu(lower: false, action: "不限"); XCTAssertTrue(upper.waitForValueToContain("不限", timeout: 5))
        durationDrag(lower: true, seconds: nil, rail: rail)
        XCTAssertTrue(lower.waitForValueToContain("超过02:00", timeout: 5))
        XCTAssertEqual(lower.frame.midX, upper.frame.midX, accuracy: 1)
        XCTAssertEqual(upper.frame.midY, trackY, accuracy: 1)
        XCTAssertEqual(maximumMenu.frame.midY - minimumMenu.frame.midY, menuSpacing, accuracy: 1)
        attachScreenshot(named: "duration71-overlap-terminal")
        durationDrag(lower: true, seconds: 120, rail: rail)
        XCTAssertTrue(lower.waitForValueToContain("02:00", timeout: 5)); XCTAssertFalse(lower.valueDescription.contains("超过"))
        XCTAssertTrue(upper.valueDescription.contains("不限"), "Dragging left at the shared terminal opens the minimum")
        durationDrag(lower: false, seconds: 120, rail: rail)
        XCTAssertTrue(upper.waitForValueToContain("02:00", timeout: 5)); XCTAssertFalse(upper.valueDescription.contains("不限"))
        XCTAssertEqual(upper.frame.midY, trackY, accuracy: 1)
        XCTAssertEqual(lower.frame.midX, upper.frame.midX, accuracy: 1)
        durationDrag(lower: false, seconds: nil, rail: rail)
        XCTAssertTrue(upper.waitForValueToContain("不限", timeout: 5), "Dragging right at an equal finite value opens the maximum")
        XCTAssertFalse(lower.valueDescription.contains("超过"))
        let reset = app.buttons["重置筛选"]
        for _ in 0..<3 { if !reset.isHittable { app.swipeUp() } }
        XCTAssertTrue(reset.isHittable); reset.tap()
        XCTAssertTrue(state.waitForValueToContain("none", timeout: 5))
        XCTAssertEqual(enabled.value as? String, "0")
        XCTAssertFalse(lower.exists); XCTAssertFalse(upper.exists)
    }

    func testDurationLegacy120AndCollectionActualMetadata() {
        app = XCUIApplication(); app.launchArguments = ["--qa-collection-paging", "--qa-duration-filter", "--qa-duration-legacy", "-muted", "YES", "-autoplay", "NO"]; app.launch()
        durationExposeHandles()
        let lower = durationHandle(lower: true)
        XCTAssertTrue(lower.valueDescription.contains("02:00")); XCTAssertFalse(lower.valueDescription.contains("超过"))
        XCTAssertTrue(app.staticTexts["duration.qa.state"].valueDescription.contains("02:00—不限"), "The real old-JSON fixture must remain an inclusive finite lower bound")
        durationMenu(lower: true, action: "减少1秒"); XCTAssertTrue(lower.waitForValueToContain("01:59", timeout: 5))
        durationMenu(lower: true, action: "增加1秒"); XCTAssertTrue(lower.waitForValueToContain("02:00", timeout: 5)); XCTAssertFalse(lower.valueDescription.contains("超过"))
        attachScreenshot(named: "duration40-legacy-inclusive-120")
        app.terminate()
        app.launchArguments = ["--qa-collection-paging", "-muted", "YES", "-autoplay", "NO"]; app.launch()
        mainTabButton("收藏").tap()
        app.buttons["收藏筛选与刷新"].tap(); app.buttons["筛选条件"].tap()
        durationExposeHandles(); XCTAssertFalse(app.staticTexts["排序与范围"].exists)
        let rail = (left: durationHandle(lower: true).frame.midX, right: durationHandle(lower: false).frame.midX)
        durationDrag(lower: false, seconds: 120, rail: rail)
        XCTAssertTrue(durationHandle(lower: false).waitForValueToContain("02:00", timeout: 5))
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["media.grid.cell.28037102"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["media.grid.cell.28037104"].exists, "119.9 is below the finite <=120 upper bound; 120.1 is above it")
        attachScreenshot(named: "duration40-collection-finite-upper-119point9")
        app.buttons["收藏筛选与刷新"].tap(); app.buttons["筛选条件"].tap()
        durationExposeHandles(); durationMenu(lower: false, action: "不限")
        durationDrag(lower: true, seconds: nil, rail: rail)
        XCTAssertTrue(durationHandle(lower: true).waitForValueToContain("超过02:00", timeout: 5))
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["media.grid.cell.28037104"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["media.grid.cell.28037102"].exists, "The strict terminal must retain 120.1 and exclude 119.9")
        attachScreenshot(named: "duration40-collection-strict-lower-120point1")
    }

    private func durationHandle(lower: Bool) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: lower ? "duration.range.minimum" : "duration.range.maximum").firstMatch
    }
    private func durationExposeHandles() {
        let toggle = app.switches["duration.range.enabled"]
        for _ in 0..<6 { if !toggle.isHittable { app.swipeUp() } }
        XCTAssertTrue(toggle.isHittable)
        if toggle.value as? String == "0" {
            // The switch accessibility frame includes the row label. Tap the actual control.
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
                .withOffset(CGVector(dx: -24, dy: 0)).tap()
            waitUntil("The duration switch opens the range") { toggle.value as? String == "1" }
        }
        for _ in 0..<6 {
            if durationHandle(lower: true).isHittable && durationHandle(lower: false).isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(durationHandle(lower: true).isHittable); XCTAssertTrue(durationHandle(lower: false).isHittable)
    }
    private func durationDrag(lower: Bool, seconds: Int?, rail: (left: CGFloat, right: CGFloat), touchOffset: CGFloat = 0) {
        let width = rail.right - rail.left
        let finiteWidth = width - min(52, width * 0.25)
        let x = seconds.map { rail.left + CGFloat($0 - 2) / 118 * finiteWidth } ?? rail.right
        let handle = durationHandle(lower: lower)
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: touchOffset, dy: 0)).press(forDuration: 0.15,
                thenDragTo: app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x + touchOffset, dy: handle.frame.midY)))
    }
    private func durationMenu(lower: Bool, action: String) {
        let menu = app.buttons[lower ? "duration.range.minimum.menu" : "duration.range.maximum.menu"]
        for _ in 0..<3 { if !menu.isHittable { app.swipeDown() } }
        XCTAssertTrue(menu.isHittable); menu.tap()
        let choice = app.buttons[action]; XCTAssertTrue(choice.waitForExistence(timeout: 3)); choice.tap()
    }

    func testBiographyTwoLinesExpandCollapseAcrossTextAndFontCases() {
        for variant in ["short", "empty", "chinese", "english", "url", "narrow", "dynamic"] {
            app = XCUIApplication(); app.launchArguments = ["--qa-collection-paging", "--qa-biography-case=\(variant)"]; app.launch()
            let body = app.descendants(matching: .any).matching(identifier: "creator.biography.body").firstMatch
            let toggle = app.buttons["creator.biography.toggle"]
            if variant == "empty" {
                XCTAssertFalse(body.exists); XCTAssertFalse(toggle.exists)
            } else if variant == "short" {
                XCTAssertTrue(body.waitForExistence(timeout: 5)); XCTAssertFalse(toggle.exists)
            } else {
                XCTAssertTrue(toggle.waitForExistence(timeout: 5))
                let collapsed = body.frame
                attachScreenshot(named: "biography-\(variant)-before-layout-check")
                print("BIOGRAPHY_FRAMES case=\(variant) body=\(collapsed) toggle=\(toggle.frame)")
                // Native selectable Text exposes external AX selection padding;
                // compare the visible button-label center, with pixel review too.
                XCTAssertGreaterThanOrEqual(toggle.frame.midY, collapsed.maxY - 1)
                XCTAssertLessThanOrEqual(body.frame.maxX, app.frame.maxX + 1, "Selectable text's AX selection padding must remain within the screen")
                XCTAssertLessThanOrEqual(body.frame.width, (variant == "narrow" || variant == "dynamic" ? 320 : app.frame.width) + 1)
                attachScreenshot(named: "biography-\(variant)-collapsed-two-lines")
                toggle.tap()
                XCTAssertTrue(toggle.waitForValueToContain("已展开", timeout: 5))
                XCTAssertGreaterThan(body.frame.height, collapsed.height)
                attachScreenshot(named: "biography-\(variant)-expanded")
                for _ in 0..<4 { if !toggle.isHittable { app.swipeUp() } }
                XCTAssertTrue(toggle.isHittable)
                toggle.tap()
                XCTAssertTrue(toggle.waitForValueToContain("已收起", timeout: 5))
                XCTAssertEqual(body.frame.height, collapsed.height, accuracy: 1)
            }
            attachScreenshot(named: "biography-\(variant)-final")
            app.terminate()
        }
    }

    func testAppearanceAcrossTabsSheetsAndImmersiveReturn() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-theme-ui", "-muted", "YES", "-autoplay", "NO"]
        app.launch()
        for (title, raw) in [("浅色", "light"), ("深色", "dark")] {
            chooseAppearance(title)
            XCTAssertTrue(app.descendants(matching: .any)["qa.theme.state"].waitForValueToContain("theme=\(raw)", timeout: 5))
            attachScreenshot(named: "theme-\(raw)-settings")
            mainTabButton("收藏").tap()
            attachScreenshot(named: "theme-\(raw)-collections")
            let first = app.buttons["media.grid.cell.28037100"]
            XCTAssertTrue(first.waitForExistence(timeout: 5)); first.tap()
            XCTAssertTrue(app.buttons["关闭作品"].waitForExistence(timeout: 5))
            attachScreenshot(named: "theme-\(raw)-immersive-image")
            app.buttons["作品详情"].tap()
            let detailsHeader = floatingPageTitle("作品详情")
            XCTAssertTrue(detailsHeader.waitForExistence(timeout: 5))
            XCTAssertEqual(detailsHeader.staticTexts["作品详情"].frame.midX, detailsHeader.frame.midX, accuracy: 1)
            attachScreenshot(named: "theme-\(raw)-details-over-media")
            app.buttons["details.back"].tap()
            XCTAssertTrue(app.staticTexts["collection.qa.geometry"].waitForValueToContain("focused=28037100", timeout: 5))
            let favorite = visualButton("favorite-28037100")
            XCTAssertTrue(favorite.waitForExistence(timeout: 5))
            openFavoriteFolders(favorite)
            XCTAssertTrue(floatingPageTitle("收藏图片").waitForExistence(timeout: 5))
            attachScreenshot(named: "theme-\(raw)-favorite-editor-over-media")
            app.buttons["取消"].tap()
            viewportDoubleTapAuthorAndReturn(screenshotName: "theme-\(raw)-author-over-media", statusBarScheme: raw)
            attachScreenshot(named: "theme-\(raw)-immersive-return")
            app.buttons["关闭作品"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["collections.top-bar"].waitForExistence(timeout: 5))
            mainTabButton("作者榜").tap()
            XCTAssertTrue(app.otherElements["leaderboard.board"].buttons["Seasonal"].waitForExistence(timeout: 5))
            attachScreenshot(named: "theme-\(raw)-authors")
            mainTabButton("搜索").tap()
            let field = app.textFields["search-title-input"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            if field.valueDescription != "Pattern" { field.tap(); field.typeText("Pattern\n") }
            else { app.buttons["search-submit"].tap() }
            let searchFilter = app.buttons["search.range"]
            XCTAssertTrue(searchFilter.waitForExistence(timeout: 5)); searchFilter.tap()
            XCTAssertTrue(floatingPageTitle("浏览条件").waitForExistence(timeout: 5))
            attachScreenshot(named: "theme-\(raw)-search-filter")
            app.buttons["完成"].tap()
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            XCTAssertEqual(field.valueDescription, "Pattern", "Switching appearance and tabs must preserve search criteria")
            attachScreenshot(named: "theme-\(raw)-search")
            mainTabButton("时间线").tap()
            closeAccountSettings()
            let mode = timelineTools()
            XCTAssertTrue(mode.waitForExistence(timeout: 5))
            if raw == "dark" {
                XCTAssertTrue(mode.valueDescription.contains("双列网格"), "Theme changes must preserve the timeline presentation")
                XCTAssertTrue(app.otherElements["timeline.media-kind"].buttons["图片"].isSelected, "Theme changes must preserve the current media filter")
            }
            if !mode.valueDescription.contains("信息流") { toggleTimelinePresentation() }
            XCTAssertTrue(mode.waitForValueToContain("信息流", timeout: 5))
            attachScreenshot(named: "theme-\(raw)-timeline-stream")
            app.otherElements["timeline.media-kind"].buttons["图片"].tap()
            toggleTimelinePresentation()
            XCTAssertTrue(mode.waitForValueToContain("双列网格", timeout: 5))
            XCTAssertTrue(app.buttons["media.grid.cell.28037100"].waitForExistence(timeout: 5))
            attachScreenshot(named: "theme-\(raw)-timeline-grid")
        }
        chooseAppearance("跟随系统")
    }

    func testLightAppearanceTransitionsFromTimeline() {
        app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--qa-collection-paging", "--qa-theme-ui", "-app.appearance", "light",
                               "-muted", "YES", "-autoplay", "YES", "-timeline.presentation", "stream"]
        func mark(_ route: String) {
            print("APPEARANCE82 \(route) \(Date().timeIntervalSince1970)")
        }
        func enterTimeline() {
            mainTabButton("时间线").tap()
            waitUntil("The timeline must display its image before checking transitions") {
                self.watchFocus() == 28_037_100 && self.visualButton("media.author.28037100").isHittable
            }
            heightCloseNotices()
        }
        func expectLightClock(_ page: String) {
            waitUntil("\(page) must have a dark status clock on the light canvas", timeout: 5) {
                self.statusBarGlyphPixels(scheme: "light") > 100
            }
        }

        mark("cold-launch")
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["collections.top-bar"].waitForExistence(timeout: 8))
        expectLightClock("Collections")
        for (tab, header, key) in [("搜索", "search.top-bar", "search"), ("作者榜", "leaderboard.top-bar", "authors"), ("收藏", "collections.top-bar", "collections")] {
            enterTimeline()
            waitUntil("The dark viewer must retain readable status text", timeout: 5) {
                self.statusBarGlyphPixels(scheme: "dark") > 100
            }
            mark("timeline-to-" + key)
            mainTabButton(tab).tap()
            XCTAssertTrue(app.otherElements[header].waitForExistence(timeout: 5))
            expectLightClock(tab)
        }

        enterTimeline()
        mark("timeline-to-settings")
        openAccountSettings()
        expectLightClock("Settings")
        closeAccountSettings()
        waitUntil("Returning from settings restores the timeline") { self.watchFocus() == 28_037_100 && self.timelineTools().isHittable }

        enterTimeline()
        mark("timeline-to-creator")
        visualButton("media.author.28037100").tap()
        XCTAssertTrue(app.descendants(matching: .any)["creator.top-bar"].waitForExistence(timeout: 5))
        expectLightClock("Creator")
        app.descendants(matching: .any)["creator.top-bar"].buttons["navigation.back"].tap()
        waitUntil("The original timeline work remains visible") { self.watchFocus() == 28_037_100 }

        mark("timeline-to-details")
        visualOpenDetails(itemID: 28_037_100)
        floatingPageTitle("作品详情").buttons["details.back"].tap()
        XCTAssertTrue(floatingPageTitle("作品详情").waitForNonExistence(timeout: 5))
        mark("timeline-to-filter")
        openTimelineTool("浏览条件")
        XCTAssertTrue(floatingPageTitle("浏览条件").waitForExistence(timeout: 5))
        floatingPageTitle("浏览条件").buttons["完成"].tap()
        XCTAssertTrue(floatingPageTitle("浏览条件").waitForNonExistence(timeout: 5))
    }

    func testSystemAppearanceUsesCurrentDeviceTrait() {
        app = XCUIApplication(); app.launchArguments = ["--qa-collection-paging", "--qa-theme-ui", "-muted", "YES", "-autoplay", "NO", "-timeline.presentation", "stream"]; app.launch()
        chooseAppearance("跟随系统")
        let state = app.descendants(matching: .any)["qa.theme.state"]
        XCTAssertTrue(state.waitForValueToContain("preference=system", timeout: 5))
        let systemTheme = state.valueDescription
        print("THEME_SYSTEM_OBSERVATION \(systemTheme)")
        attachScreenshot(named: "theme-system-current-device-settings")
        closeAccountSettings()
        waitUntil("The native timeline is displaying a work") { self.watchFocus() > 0 && self.heightDeck().isHittable }
        print("THEME_SYSTEM_DURING_PLAYBACK \(state.valueDescription)")
        XCTAssertEqual(state.valueDescription.components(separatedBy: ";scene=").first,
                       systemTheme.components(separatedBy: ";scene=").first,
                       "Inline playback must not change the system theme used for ordinary pages")
        openTimelineTool("浏览条件")
        let filter = floatingPageTitle("浏览条件")
        XCTAssertTrue(filter.waitForExistence(timeout: 5)); filter.buttons["完成"].tap()
        XCTAssertTrue(filter.waitForNonExistence(timeout: 5))
        mainTabButton("搜索").tap()
        XCTAssertTrue(app.textFields["search-title-input"].waitForExistence(timeout: 5))
        attachScreenshot(named: "theme-system-current-device-search")
    }

    func testThemeCompactDynamicTypeKeepsControlsUsable() {
        app = XCUIApplication(); app.launchArguments = ["--qa-collection-paging", "--qa-theme-ui", "--qa-theme-compact"]; app.launch()
        for title in ["浅色", "深色"] {
            chooseAppearance(title)
            attachScreenshot(named: "theme-compact-dynamic-\(title)-settings")
            closeAccountSettings()
            mainTabButton("搜索").tap()
            XCTAssertTrue(app.textFields["search-title-input"].waitForExistence(timeout: 5))
            attachScreenshot(named: "theme-compact-dynamic-\(title)-search")
        }
        chooseAppearance("跟随系统")
    }

    private func statusBarGlyphPixels(scheme: String) -> Int {
        guard let image = UIImage(data: app.screenshot().pngRepresentation)?.cgImage,
              image.bitsPerComponent == 8, image.colorSpace?.model == .rgb,
              let bytes = image.dataProvider?.data else { return 0 }
        let values = CFDataGetBytePtr(bytes)!
        let pixelBytes = image.bitsPerPixel / 8
        guard pixelBytes >= 3 else { return 0 }
        let firstAlpha: Set<CGImageAlphaInfo> = [.first, .premultipliedFirst, .noneSkipFirst]
        let colorOffset = firstAlpha.contains(image.alphaInfo) ? 1 : 0
        // The clock occupies this fixed, portrait status-bar region. Nav titles,
        // media and QA labels lie outside it, so they cannot satisfy this check.
        var glyphs = 0
        var background = 0
        var samples = 0
        for y in Int(Double(image.height) * 0.018)..<Int(Double(image.height) * 0.055) {
            for x in Int(Double(image.width) * 0.11)..<Int(Double(image.width) * 0.29) {
                let start = y * image.bytesPerRow + x * pixelBytes + colorOffset
                let mean = (Int(values[start]) + Int(values[start + 1]) + Int(values[start + 2])) / 3
                if scheme == "light" ? mean < 80 : mean > 190 { glyphs += 1 }
                if scheme == "light" ? mean > 190 : mean < 80 { background += 1 }
                samples += 1
            }
        }
        return background > samples * 3 / 4 ? glyphs : 0
    }

    private func chooseAppearance(_ title: String) {
        openAccountSettings()
        let picker = app.buttons["settings-appearance-picker"]
        // A large swipe can leave this row partially underneath an opaque nav
        // bar. Existence/hittability alone does not guarantee its center is exposed.
        app.swipeDown()
        let window = app.windows.firstMatch
        let navBottom = floatingPageTitle("账号与设置").frame.maxY
        let tabTop = mainTabBar().frame.minY
        for _ in 0..<8 {
            if picker.exists, picker.isHittable, picker.frame.midY > navBottom + 22, picker.frame.midY < tabTop - 22 { break }
            let downward = picker.exists && picker.frame.midY < navBottom + 22
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: downward ? 0.35 : 0.60))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: downward ? 0.60 : 0.35)))
        }
        XCTAssertTrue(picker.isHittable)
        XCTAssertGreaterThan(picker.frame.midY, navBottom + 22)
        XCTAssertLessThan(picker.frame.midY, tabTop - 22)
        attachScreenshot(named: "theme-picker-exposed-\(title)")
        picker.tap()
        let raw = ["浅色": "light", "深色": "dark", "跟随系统": "system"][title]!
        let option = app.buttons["value-selector.option." + raw]
        let appeared = option.waitForExistence(timeout: 5)
        if !appeared { attachScreenshot(named: "theme-picker-option-missing-\(title)"); print(String(app.debugDescription.prefix(12000))) }
        XCTAssertTrue(appeared); option.tap()
        XCTAssertTrue(picker.waitForValueToContain(title, timeout: 5))
    }

    func testVisualControlsPortraitMatrix() {
        for (width, large) in [(0, false), (375, false), (320, true)] {
            visualLaunch(width: width, large: large, landscape: false)
            visualTypeControls(caseName: "portrait-\(width)-large\(large)")
            visualSocialStates(caseName: "portrait-\(width)-large\(large)")
            app.terminate()
        }
    }

    func testVisualControlsLandscapeMatrix() {
        for (width, large) in [(440, false), (0, true)] {
            visualLaunch(width: width, large: large, landscape: true)
            visualTypeControls(caseName: "landscape-\(width)-large\(large)")
            visualSocialStates(caseName: "landscape-\(width)-large\(large)")
            app.terminate(); XCUIDevice.shared.orientation = .portrait
        }
    }

    func testTimelineSegmentsFillTheSpaceBetweenToolbarButtons() {
        visualLaunch(width: 320, large: true, landscape: false, extra: ["--qa-leaderboard-three-digits"])
        let account = app.buttons["timeline.account"]
        let tools = timelineTools()
        let source = app.otherElements["timeline.source"]
        let media = app.otherElements["timeline.media-kind"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertEqual(source.frame.width, media.frame.width, accuracy: 1)
        let left = source.frame.minX - account.frame.maxX
        let right = tools.frame.minX - media.frame.maxX
        XCTAssertEqual(left, right, accuracy: 1)
        XCTAssertEqual(left, 4, accuracy: 1, "The track begins at the panel inset beside the button target")
        XCTAssertTrue(source.buttons["推荐"].isSelected)
        XCTAssertEqual(source.frame.maxX, media.frame.minX, accuracy: 1)
        attachScreenshot(named: "chrome105-timeline")
        media.buttons["视频"].tap()
        XCTAssertTrue(media.buttons["视频"].isSelected)
        XCTAssertTrue(source.buttons["推荐"].isSelected)
        source.buttons["关注"].tap()
        XCTAssertTrue(source.buttons["关注"].isSelected)
        source.buttons["推荐"].tap()
        XCTAssertTrue(source.buttons["推荐"].isSelected)
        XCTAssertTrue(media.buttons["视频"].isSelected)

        mainTabButton("作者榜").tap()
        let board = app.otherElements["leaderboard.board"]
        XCTAssertTrue(board.buttons["Seasonal"].waitForExistence(timeout: 5))
        XCTAssertTrue(board.buttons["Seasonal"].isSelected)
        attachScreenshot(named: "chrome105-leaderboard")
        board.buttons["Legacy"].tap()
        XCTAssertTrue(board.buttons["Legacy"].isSelected)
        let author = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "leaderboard.author.")).firstMatch
        XCTAssertTrue(author.waitForExistence(timeout: 5))
        attachScreenshot(named: "leaderboard107-cards")
        author.tap()
        XCTAssertTrue(app.otherElements["creator.top-bar"].waitForExistence(timeout: 5))
        app.buttons["navigation.back"].tap()


        mainTabButton("搜索").tap()
        XCTAssertTrue(app.textFields["search-title-input"].waitForExistence(timeout: 5))
        attachScreenshot(named: "chrome105-search")
    }

    func testFourMainTabsShareChromeAlignmentAtTheSameWidth() {
        visualLaunch(width: 375, large: false, landscape: false)
        let originalBar = mainTabBar().frame
        attachScreenshot(named: "chrome111-timeline")

        for (tab, bar, shot) in [
            ("作者榜", "leaderboard.top-bar", "leaderboard"),
            ("搜索", "search.top-bar", "search"),
            ("收藏", "collections.top-bar", "favorites")
        ] {
            mainTabButton(tab).tap()
            XCTAssertTrue(app.otherElements[bar].waitForExistence(timeout: 8))
            let frame = mainTabBar().frame
            XCTAssertEqual(frame.minX, originalBar.minX, accuracy: 1, tab)
            XCTAssertEqual(frame.maxX, originalBar.maxX, accuracy: 1, tab)
            XCTAssertEqual(frame.midY, originalBar.midY, accuracy: 1, tab)
            attachScreenshot(named: "chrome111-" + shot)
        }
    }

    func testTimelineHeaderStaysCenteredInBothSources() {
        func assertSingleRow(source title: String, context: String) {
            let source = app.otherElements["timeline.source"]
            let media = app.otherElements["timeline.media-kind"]
            let tools = timelineTools()
            let sourceFrame = source.frame, mediaFrame = media.frame, toolsFrame = tools.frame
            XCTAssertTrue(source.buttons[title].isSelected, context)
            XCTAssertEqual(sourceFrame.union(mediaFrame).midX, heightDeck().frame.midX, accuracy: 1, context)
            XCTAssertEqual(sourceFrame.midY, mediaFrame.midY, accuracy: 1, context)
            XCTAssertEqual(sourceFrame.height, mediaFrame.height, accuracy: 1, context)
            XCTAssertEqual(sourceFrame.width, mediaFrame.width, accuracy: 1, context)
            XCTAssertEqual(toolsFrame.midY, mediaFrame.midY, accuracy: 1, context)
            XCTAssertTrue(tools.isHittable, context)
            XCTAssertGreaterThanOrEqual(toolsFrame.width + 0.01, 44, context)
            XCTAssertGreaterThanOrEqual(toolsFrame.height + 0.01, 44, context)
            let accountFrame = app.buttons["timeline.account"].frame
            XCTAssertEqual(sourceFrame.minX - accountFrame.maxX, 4, accuracy: 1, context)
            XCTAssertEqual(mediaFrame.minX - sourceFrame.maxX, 0, accuracy: 1, context)
            XCTAssertEqual(toolsFrame.minX - mediaFrame.maxX, 4, accuracy: 1, context)
        }
        for (name, width, large, landscape) in [("portrait", 0, false, false), ("narrow-A2", 320, true, false), ("landscape", 0, false, true)] {
            visualLaunch(width: width, large: large, landscape: landscape)
            for (source, title) in [("following", "关注"), ("recommendation", "推荐")] {
                selectTimelineSource(title)
                heightCloseNotices()
                app.otherElements["timeline.media-kind"].buttons["图片"].tap()
                waitUntil("The selected source must really show the first image") { self.watchFocus() == 28_037_100 }
                if landscape { visualEnsureLandscape() }
                heightWaitOrientation(landscape: landscape)
                let initialToolX = timelineTools().frame.midX
                assertSingleRow(source: title, context: "\(name)/\(source)/image")
                attachScreenshot(named: "header77-\(name)-\(source)-image")
                if width == 320 && source == "recommendation" {
                    openTimelineTool("已存条件")
                    XCTAssertTrue(app.descendants(matching: .any)["preset.library"].waitForExistence(timeout: 5))
                    app.buttons["preset.library.done"].tap()
                }
                app.otherElements["timeline.media-kind"].buttons["视频"].tap()
                waitPlayingFixture()
                if landscape { visualEnsureLandscape(); waitPlayingFixture() }
                heightWaitOrientation(landscape: landscape)
                assertSingleRow(source: title, context: "\(name)/\(source)/video")
                XCTAssertEqual(timelineTools().frame.midX, initialToolX, accuracy: 1)
                attachScreenshot(named: "header77-\(name)-\(source)-video")
            }
            app.terminate(); XCUIDevice.shared.orientation = .portrait
        }
    }

    func testFloatingHeaderAndBarRevealTallMedia() {
        app = XCUIApplication(); XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "--qa-chrome-geometry", "--qa-theme-timeline", "-app.appearance", "light"]
        app.launch(); heightOpen("recommendation", expected: 28_037_100)
        heightCloseNotices(); heightAssert("recommendation", phase: "floating44-tall-image", expected: 28_037_100)
        let image = captureChromePixels(named: "floating44-transparent-tall-image")
        let deck = heightDeck().frame, source = app.otherElements["timeline.source"].frame, tabs = mainTabBar().frame
        // Sample the shared tinted track at its join, above the white fixture stripe.
        let trackSample = CGRect(x: deck.midX - 0.5, y: source.midY - 6, width: 1, height: 3)
        let sideGapX = app.buttons["timeline.account"].frame.maxX - 2
        let gapSample = CGRect(x: sideGapX - 0.5, y: trackSample.minY, width: 1, height: 3)
        guard let trackColor = floating45MeanRGB(image, in: trackSample),
              let gapColor = floating45MeanRGB(image, in: gapSample) else {
            XCTFail("The track and adjacent media pixels must be measurable"); return
        }
        XCTAssertGreaterThan(trackColor[2], trackColor[0] + 20, "The blue fixture remains visible under the joined track")
        XCTAssertGreaterThan(trackColor[2], gapColor[2] * 0.35, "The track retains the media color")
        XCTAssertLessThan(trackColor[2], gapColor[2] * 0.85, "The shared tint is continuous through the join")
        for (name, y) in [("below-header", source.minY + 80), ("bar", tabs.minY + 10)] {
            let sample = CGRect(x: deck.midX - 2, y: y, width: 4, height: 4)
            XCTAssertGreaterThan(floating44BlueFraction(image, in: sample) ?? -1, 0.8, "Underlying blue image must be visible through \(name)")
        }
        let baseSample = CGRect(x: deck.midX - 2, y: source.minY + 80, width: 4, height: 4)
        let barSample = CGRect(x: deck.midX - 2, y: tabs.minY + 10, width: 4, height: 4)
        guard let baseColor = floating45MeanRGB(image, in: baseSample), let barColor = floating45MeanRGB(image, in: barSample) else {
            XCTFail("Actual image and navigation background pixels must be measurable"); return
        }
        XCTAssertLessThanOrEqual(barColor[0], baseColor[0] + 20, "The navigation strip must not add the former pale opaque material tint")
        XCTAssertLessThan(barColor[2], baseColor[2] * 0.85, "The sample must include the tint inside the visible bar")
        XCTAssertGreaterThan(barColor[2], baseColor[2] * 0.5, "At least half the underlying blue signal must remain visible through the navigation strip")
        print("BAR45_ACTUAL_RGB base=\(baseColor);bar=\(barColor)")
        app.otherElements["timeline.media-kind"].buttons["视频"].tap()
        waitPlayingFixture()
        XCTAssertTrue(videoGeometryReadback() != nil)
        attachScreenshot(named: "floating44-transparent-tall-video")
        app.terminate()
    }

    func testLightTimelineBackgroundingPreservesViewingChrome() {
        app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "--qa-chrome-geometry",
                               "--qa-theme-timeline", "-app.appearance", "light", "-muted", "YES",
                               "-autoplay", "YES", "-timeline.presentation", "stream"]
        app.launch()
        heightOpen("recommendation", expected: 28_037_100)
        heightCloseNotices()
        app.otherElements["timeline.media-kind"].buttons["视频"].tap()
        waitPlayingFixture()
        let focused = watchFocus()
        attachScreenshot(named: "switcher77-foreground")

        func backgroundAndReturn() {
            XCUIDevice.shared.press(.home)
            waitUntil("The player must actually leave the foreground", timeout: 5) {
                self.app.state == .runningBackground || self.app.state == .runningBackgroundSuspended
            }
            app.activate()
            waitUntil("Returning from multitasking must preserve the current video") { self.watchFocus() == focused }
        }
        backgroundAndReturn()
        XCTAssertTrue(mainTabBar().isHittable)
        attachScreenshot(named: "switcher77-return")
        centralPress()
        XCTAssertTrue(chromeState().waitForValueToContain("hidden=true", timeout: 5))
        backgroundAndReturn()
        XCTAssertTrue(chromeState().waitForValueToContain("hidden=true", timeout: 5),
                      "A background transition must preserve the viewer's presentation state")
        app.terminate()
    }

    func testTimelineKeepsMediaPositionAfterAuthorReturn() {
        app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "--qa-theme-timeline",
                               "--qa-native-layout64", "-muted", "YES", "-autoplay", "YES",
                               "-app.appearance", "light", "-timeline.presentation", "stream"]
        app.launch()
        heightOpen("recommendation", expected: 28_037_100)
        heightCloseNotices()
        for (kind, first, second) in [("图片", 28_037_100, 28_037_101), ("视频", 28_037_102, 28_037_104)] {
            app.otherElements["timeline.media-kind"].buttons[kind].tap()
            waitUntil("The selected media type must open on its first work") { self.watchFocus() == first }
            if kind == "视频" { waitPlayingFixture() }
            heightDeck().swipeUp()
            heightAssert("recommendation", phase: "author-position-before-\(kind)", expected: second)
            let before = heightDeck().frame
            let author = visualButton("media.author.\(second)")
            XCTAssertTrue(author.isHittable); author.tap()
            XCTAssertTrue(app.descendants(matching: .any)["creator.top-bar"].waitForExistence(timeout: 8))
            app.buttons["navigation.back"].tap()
            heightAssert("recommendation", phase: "author-position-after-\(kind)", expected: second)
            let after = heightDeck().frame
            XCTAssertEqual(after.minY, before.minY, accuracy: 1)
            XCTAssertEqual(after.height, before.height, accuracy: 1)
            if kind == "视频" { waitPlayingFixture() }
        }
        app.terminate()
    }

    private func swipeSegmentEdge(right: Bool, distance: CGFloat = 110) {
        let window = app.windows.firstMatch
        let frame = window.frame
        let x = right ? frame.width - 12 : 12
        let start = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: frame.height * 0.55))
        let end = start.withOffset(CGVector(dx: right ? -distance : distance, dy: 0))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: XCUIGestureVelocity(rawValue: 160), thenHoldForDuration: 0.1)
        waitUntil("The actual page motion finishes before the next gesture") {
            let readbacks = self.app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "segment.content.")).allElementsBoundByIndex
            return !readbacks.isEmpty && readbacks.allSatisfy { $0.valueDescription.contains("phase=idle") }
        }
    }

    private func swipeSegmentCenter(right: Bool, distance: CGFloat = 110) {
        let window = app.windows.firstMatch
        let frame = window.frame
        let x = frame.width * (right ? 0.7 : 0.3)
        let start = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: frame.height * 0.55))
        let end = start.withOffset(CGVector(dx: right ? -distance : distance, dy: 0))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: XCUIGestureVelocity(rawValue: 160), thenHoldForDuration: 0.1)
        waitUntil("The actual center page motion finishes before the next gesture") {
            let readbacks = self.app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "segment.content.")).allElementsBoundByIndex
            return !readbacks.isEmpty && readbacks.allSatisfy { $0.valueDescription.contains("phase=idle") }
        }
    }

    func testSegmentedEdgeNavigationPinsHeaderAndTabBar() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-visual-controls", "--qa-segment-edge", "-muted", "YES", "-civitviewer.automaticRotation", "YES"]
        app.launch()
        mainTabButton("作者榜").tap()
        let picker = app.otherElements["leaderboard.board"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.buttons["Seasonal"].tap()
        let header = app.otherElements["leaderboard.top-bar"]
        let top = header.frame, bottom = mainTabBar().frame
        swipeSegmentEdge(right: true)
        XCTAssertTrue(picker.buttons["Legacy"].isSelected)
        XCTAssertEqual(header.frame, top)
        XCTAssertEqual(mainTabBar().frame, bottom)
        swipeSegmentEdge(right: false, distance: 20)
        XCTAssertTrue(picker.buttons["Legacy"].isSelected, "A short slow drag must return to the current segment")
        let trace = heightValues(app.staticTexts["segment.trace.leaderboard.board"].valueDescription)
        XCTAssertGreaterThan(trace["samples"] ?? 0, 1)
        XCTAssertGreaterThan(trace["peak"] ?? 0, 0)
        XCTAssertLessThan(trace["peak"] ?? 1, 0.5)
        let content = heightValues(app.staticTexts["segment.content.leaderboard.board"].valueDescription)
        XCTAssertGreaterThan(content["renderedPeak"] ?? 0, 1, "The real content pane must move, not just the selected segment")
        XCTAssertEqual(content["both"], 1, "Both real adjacent panes must enter the viewport during the drag")
        XCTAssertLessThan(content["renderedPeak"] ?? 999, 24, "A 20pt cancelled drag cannot move a full page")
        swipeSegmentEdge(right: false)
        XCTAssertTrue(picker.buttons["Seasonal"].isSelected)
        XCTAssertEqual(header.frame, top)
        XCTAssertEqual(mainTabBar().frame, bottom)
        attachScreenshot(named: "segment-edge-leaderboard")
        mainTabButton("收藏").tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        waitUntil("Collections rotates to landscape") { self.app.windows.firstMatch.frame.width > self.app.windows.firstMatch.frame.height }
        let collectionBottom = mainTabBar().frame
        let media = app.otherElements["collection.media-kind"]
        XCTAssertTrue(media.waitForExistence(timeout: 5))
        media.buttons["图片"].tap()
        let collectionHeader = app.otherElements["collections.top-bar"].frame
        swipeSegmentEdge(right: true)
        print("EDGE_COLLECTION " + app.staticTexts["segment.trace.collection.media-kind"].valueDescription)
        XCTAssertTrue(media.buttons["视频"].isSelected)
        XCTAssertEqual(app.otherElements["collections.top-bar"].frame, collectionHeader)
        XCTAssertEqual(mainTabBar().frame, collectionBottom)
        swipeSegmentEdge(right: false)
        XCTAssertTrue(media.buttons["图片"].isSelected)
        attachScreenshot(named: "segment-edge-collections")
        app.terminate()
    }

    func testAuthorBothEdgesSwitchKindAndBackButtonReturns() {
        for _ in 0..<3 { verifyAuthorEdgeNavigation(reduceMotion: false) }
    }

    func testAuthorEdgeNavigationWithReducedMotion() {
        verifyAuthorEdgeNavigation(reduceMotion: true)
    }

    private func verifyAuthorEdgeNavigation(reduceMotion: Bool) {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-segment-edge", "-muted", "YES", "-app.appearance", "light"]
        if reduceMotion { app.launchArguments.append("--qa-reduce-motion") }
        app.launch()
        mainTabButton("作者榜").tap()
        heightTap(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Pattern Creator 1")).firstMatch)
        let header = app.otherElements["creator.top-bar"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        let top = header.frame, bottom = mainTabBar().frame
        let media = app.otherElements["creator.media-kind"]
        media.buttons["图片"].tap()
        swipeSegmentEdge(right: true)
        print("EDGE_AUTHOR " + app.staticTexts["segment.trace.creator.media-kind"].valueDescription)
        XCTAssertTrue(media.buttons["视频"].isSelected)
        XCTAssertEqual(header.frame, top)
        XCTAssertEqual(mainTabBar().frame, bottom)
        swipeSegmentEdge(right: true)
        XCTAssertTrue(media.buttons["图片"].isSelected)
        XCTAssertTrue(app.staticTexts["segment.trace.creator.media-kind"].valueDescription.contains("enabled=true"), "Edge switching must not accidentally present a work or enter management")
        waitUntil("The content pager is idle before beginning a native navigation return") {
            self.app.staticTexts["segment.content.creator.media-kind"].valueDescription.contains("phase=idle")
        }
        swipeSegmentEdge(right: false)
        XCTAssertTrue(media.buttons["视频"].isSelected)
        XCTAssertTrue(header.exists, "Both edges belong to browsing tabs")
        header.buttons["navigation.back"].tap()
        let returned = app.otherElements["leaderboard.top-bar"].waitForExistence(timeout: 5)
        XCTAssertTrue(returned)
        XCTAssertFalse(header.isHittable)
        app.terminate()
    }

    func testRoot181PlaybackWaitsForVisualHandoff() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "--qa-theme-timeline", "--qa-root-activation181",
                               "--qa-header-motion", "--qa-body-motion", "-muted", "YES", "-autoplay", "YES",
                               "-timeline.presentation", "stream", "-app.appearance", "light"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let tabs = mainTabBar()
        XCTAssertTrue(tabs.waitForExistence(timeout: 10))
        let bottom = tabs.frame
        app.otherElements["timeline.media-kind"].buttons["视频"].tap()
        let player = app.staticTexts["media.qa.player"].firstMatch
        waitUntil("The silent local video actually starts", timeout: 10) {
            player.exists && (self.numericReadback(player.valueDescription)["rate"] ?? 0) > 0
        }
        mainTabButton("作者榜").tap()
        waitUntil("The source root is settled before re-entering playback") {
            self.mainTabButton("作者榜").isSelected
                && self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0")
        }
        mainTabButton("时间线").tap()
        let activation = app.staticTexts["root.activation181.qa"]
        waitUntil("The committed target remains silent while live chrome is held") {
            activation.valueDescription.contains("allowed=false;playing=0")
                && self.mainTabButton("时间线").isSelected
        }
        XCTAssertFalse(app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0"))
        waitUntil("Only terminal handoff releases playback and input", timeout: 10) {
            activation.valueDescription.contains("allowed=true")
                && self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0")
                && player.exists && (self.numericReadback(player.valueDescription)["rate"] ?? 0) > 0
        }
        XCTAssertEqual(mainTabBar().frame, bottom)
        XCTAssertLessThanOrEqual(numericReadback(player.valueDescription)["poolCount"] ?? 99, 2)
        XCTAssertTrue(player.valueDescription.contains("muted=true"))
        app.terminate()
    }

    func testRootMissingPanTerminalRestoresTouchAndNextSwipe() {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-drop-root-pan-terminal-and-reset", "--qa-header-motion",
                             "--qa-body-motion", "-autoplay", "NO", "-muted", "YES"])
        let locks = app.staticTexts["page.interaction-lock"]
        let body = app.staticTexts["body.motion.qa"]
        mainTabButton("作者榜").tap()
        XCTAssertTrue(locks.waitForValueToContain("locks=0", timeout: 5))
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5))
        let finish = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: finish, withVelocity: XCUIGestureVelocity(rawValue: 180), thenHoldForDuration: 0.9)
        XCTAssertTrue(body.waitForValueToContain("reason=root-touch-ended-without-terminal", timeout: 5), body.valueDescription)
        XCTAssertTrue(mainTabButton("作者榜").isSelected)
        XCTAssertTrue(locks.waitForValueToContain("locks=0", timeout: 3), locks.valueDescription)

        let author = app.buttons["leaderboard.author.28037001"]
        XCTAssertTrue(author.waitForExistence(timeout: 6))
        author.tap()
        let authorBar = app.otherElements["creator.top-bar"]
        XCTAssertTrue(authorBar.waitForExistence(timeout: 5))
        XCTAssertTrue(locks.waitForValueToContain("locks=0", timeout: 3))
        authorBar.buttons["navigation.back"].tap()
        XCTAssertTrue(authorBar.waitForNonExistence(timeout: 5))
        start.press(forDuration: 0.05, thenDragTo: finish, withVelocity: XCUIGestureVelocity(rawValue: 180), thenHoldForDuration: 0.1)
        waitUntil("A second real root swipe commits") { self.mainTabButton("搜索").isSelected }
        XCTAssertTrue(locks.waitForValueToContain("locks=0", timeout: 3))
        mainTabButton("时间线").tap()
        waitUntil("The footer is responsive after the next swipe") { self.mainTabButton("时间线").isSelected }
    }

    func testTimelineMissingPanTerminalRestoresTouchAndNextSwipe() {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-drop-timeline-pan-terminal-and-reset", "--qa-pager-touch-trace",
                             "--qa-header-motion", "-autoplay", "NO", "-muted", "YES"])
        let locks = app.staticTexts["page.interaction-lock"]
        let motion = app.staticTexts["timeline.page-motion.qa"]
        let source = app.otherElements["timeline.source"]
        let media = app.otherElements["timeline.media-kind"]
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.34))
        let finish = window.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.34))
        start.press(forDuration: 0.05, thenDragTo: finish, withVelocity: XCUIGestureVelocity(rawValue: 180), thenHoldForDuration: 0.9)
        XCTAssertTrue(motion.waitForValueToContain("reason=timeline-touch-ended-without-terminal", timeout: 5), motion.valueDescription)
        XCTAssertTrue(source.buttons["推荐"].isSelected)
        XCTAssertTrue(locks.waitForValueToContain("locks=0", timeout: 3), locks.valueDescription)
        XCTAssertGreaterThan(heightValues(motion.valueDescription)["peak"] ?? 0, 8, "The held timeline drag must have started moving")

        start.press(forDuration: 0.05, thenDragTo: finish, withVelocity: XCUIGestureVelocity(rawValue: 180), thenHoldForDuration: 0.1)
        waitUntil("A second real timeline swipe commits") { source.buttons["关注"].isSelected }
        XCTAssertTrue(locks.waitForValueToContain("locks=0", timeout: 3))
        media.buttons["视频"].tap()
        waitUntil("The timeline header is responsive after the next swipe") { media.buttons["视频"].isSelected }
        XCTAssertTrue(locks.waitForValueToContain("locks=0", timeout: 3))
        mainTabButton("作者榜").tap()
        XCTAssertTrue(app.otherElements["leaderboard.top-bar"].waitForExistence(timeout: 5))
    }

    func testCommittedSearchAcceptsNextFooterTapBeforeHeaderAcknowledgement() {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-header-motion", "--qa-body-motion", "--qa-delay-search-terminal196",
                             "-muted", "YES", "-autoplay", "NO"])
        let favoritesFrame = mainTabButton("收藏").frame
        mainTabButton("搜索").tap()
        let body = app.staticTexts["body.motion.qa"]
        XCTAssertTrue(body.waitForValueToContain("waiting-search-terminal196", timeout: 6))
        let lock = app.staticTexts["page.interaction-lock"]
        XCTAssertTrue(lock.valueDescription.contains("locks=1"))
        tapScreenFrame(favoritesFrame)
        waitUntil("A single footer tap during the committed search handoff opens Favorites", timeout: 10) {
            self.mainTabButton("收藏").isSelected && lock.valueDescription.contains("locks=0")
        }
    }

    func testRootTerminalFrameLossReleasesInputOnTheCommittedPage() {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-header-motion", "--qa-body-motion", "--qa-drop-root-terminal-frame",
                             "-autoplay", "NO", "-muted", "YES"])
        let locks = app.staticTexts["page.interaction-lock"]
        let body = app.staticTexts["body.motion.qa"]
        mainTabButton("作者榜").tap()
        XCTAssertTrue(body.waitForValueToContain("reason=terminal-handoff-timeout", timeout: 6),
                      body.valueDescription)
        XCTAssertTrue(mainTabButton("作者榜").isSelected)
        XCTAssertTrue(locks.waitForValueToContain("locks=0", timeout: 3), locks.valueDescription)
        let author = app.buttons["leaderboard.author.28037001"]
        XCTAssertTrue(author.waitForExistence(timeout: 6))
        author.tap()
        let authorBar = app.otherElements["creator.top-bar"]
        XCTAssertTrue(authorBar.waitForExistence(timeout: 5))
        XCTAssertTrue(locks.waitForValueToContain("locks=0", timeout: 3))
        authorBar.buttons["navigation.back"].tap()
        XCTAssertTrue(authorBar.waitForNonExistence(timeout: 5))
        XCTAssertTrue(mainTabButton("作者榜").isSelected)
    }

    func testNative181PlaybackWaitsForChromeOnButtonReturn() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "--qa-theme-timeline", "--qa-native-activation181",
                               "--qa-header-motion", "--qa-body-motion", "-muted", "YES", "-autoplay", "YES",
                               "-timeline.presentation", "stream", "-app.appearance", "light"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(mainTabBar().waitForExistence(timeout: 10))
        app.otherElements["timeline.media-kind"].buttons["视频"].tap()
        waitPlayingFixture()
        let bottom = mainTabBar().frame
        timelineTools().tap()
        app.buttons["浏览条件"].tap()
        let filter = floatingPageTitle("浏览条件")
        XCTAssertTrue(filter.waitForExistence(timeout: 6))
        waitUntil("Filter controls are available after native push") {
            self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0")
        }
        filter.buttons["完成"].tap()
        let activation = app.staticTexts["root.activation181.qa"]
        waitUntil("The native pop has a silent target until the real header handoff") {
            activation.valueDescription.contains("allowed=false;playing=0")
                && !self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0")
        }
        waitUntil("Native completion releases both playback and input", timeout: 10) {
            activation.valueDescription.contains("allowed=true")
                && self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0")
                && self.playerFields()["rate"] == "1.0"
        }
        XCTAssertEqual(mainTabBar().frame, bottom)
        XCTAssertEqual(playerFields()["muted"], "true")
        app.terminate()
    }

    func testOrdinary181RejectedBeforeCanvasDoesNotReplayMovement() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "--qa-page-return",
                               "--qa-return-assembly-delay181", "--qa-header-motion", "--qa-body-motion",
                               "-muted", "YES", "-autoplay", "NO", "-app.appearance", "light"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        openAccountSettings()
        let bottom = mainTabBar().frame
        let window = app.windows.firstMatch
        let header = floatingPageTitle("最近浏览")
        let qa = app.descendants(matching: .any)["page.return-motion.qa"]
        for right in [false, true] {
            tapAboveMainBar(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "最近浏览与接着看")).firstMatch)
            XCTAssertTrue(header.waitForExistence(timeout: 6))
            waitUntil("History is ready before its delayed capture") {
                self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0")
            }
            let top = header.frame
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.98 : 0.02, dy: 0.5))
            start.press(forDuration: 0.05,
                        thenDragTo: start.withOffset(CGVector(dx: right ? -20 : 20, dy: 0)),
                        withVelocity: XCUIGestureVelocity(rawValue: 160), thenHoldForDuration: 0)
            waitUntil("Preassembly rejection keeps the source without a replay") {
                qa.valueDescription.contains("phase=cancelled") && qa.valueDescription.contains("assembled=false")
            }
            XCTAssertTrue(qa.valueDescription.contains("navigationOutcome=cancelled"), qa.valueDescription)
            XCTAssertTrue(qa.valueDescription.contains("visualOutcome=cancelled"), qa.valueDescription)
            XCTAssertTrue(qa.valueDescription.contains("sourceMasked=false"), qa.valueDescription)
            XCTAssertEqual(numericReadback(qa.valueDescription)["sourceSnapshotTx"], 0)
            let stable = qa.valueDescription
            // Outlive the deliberately late capture and prove it cannot mount.
            let elapsed = expectation(description: "Late canvas deadline passes")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { elapsed.fulfill() }
            wait(for: [elapsed], timeout: 2)
            XCTAssertEqual(qa.valueDescription, stable)
            XCTAssertTrue(header.isHittable)
            XCTAssertEqual(header.frame, top)
            XCTAssertEqual(mainTabBar().frame, bottom)
            XCTAssertTrue(app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0"))
            // An accepted fast return may wait for assembly, then commits once.
            start.press(forDuration: 0.05,
                        thenDragTo: start.withOffset(CGVector(dx: right ? -170 : 170, dy: 0)),
                        withVelocity: XCUIGestureVelocity(rawValue: 900), thenHoldForDuration: 0)
            XCTAssertTrue(header.waitForNonExistence(timeout: 8))
            waitUntil("Accepted delayed return restores settings input") {
                self.floatingPageTitle("账号与设置").buttons["navigation.back"].isHittable
                    && self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0")
            }
        }
        app.terminate()
    }

    func testHistory181CenterSwitchesAndBothEdgesReturn() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "--qa-segment-edge",
                               "--qa-header-motion", "--qa-body-motion", "-muted", "YES", "-autoplay", "NO",
                               "-app.appearance", "light"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        openAccountSettings()
        let bottom = mainTabBar().frame
        let window = app.windows.firstMatch
        let header = floatingPageTitle("最近浏览")
        let media = app.otherElements["history.media-kind"]
        func idle() {
            waitUntil("The real history transition releases input") {
                let locks = self.app.staticTexts["page.interaction-lock"]
                return locks.exists && locks.valueDescription.contains("locks=0")
            }
        }
        for right in [false, true] {
            tapAboveMainBar(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "最近浏览与接着看")).firstMatch)
            XCTAssertTrue(header.waitForExistence(timeout: 5)); idle()
            let top = header.frame
            for (from, to, title) in [(0.75, 0.25, "视频"), (0.25, 0.75, "图片")] {
                window.coordinate(withNormalizedOffset: CGVector(dx: from, dy: 0.55))
                    .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: to, dy: 0.55)),
                           withVelocity: XCUIGestureVelocity(rawValue: 180), thenHoldForDuration: 0.1)
                waitUntil("The history center swipe selects \(title)") { media.buttons[title].isSelected }
                XCTAssertTrue(header.exists)
                XCTAssertEqual(header.frame, top)
                XCTAssertEqual(mainTabBar().frame, bottom)
            }
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.98 : 0.02, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: right ? -30 : 30, dy: 0)),
                        withVelocity: XCUIGestureVelocity(rawValue: 60), thenHoldForDuration: 0.1)
            idle()
            XCTAssertTrue(header.exists, "A cancelled edge return retains the history page")
            XCTAssertTrue(media.buttons["图片"].isSelected, "An edge return does not change history media kind")
            start.press(forDuration: 0.05,
                        thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.30 : 0.70, dy: 0.5)),
                        withVelocity: XCUIGestureVelocity(rawValue: 180), thenHoldForDuration: 0.1)
            XCTAssertTrue(header.waitForNonExistence(timeout: 5)); idle()
            XCTAssertTrue(floatingPageTitle("账号与设置").exists)
            XCTAssertEqual(mainTabBar().frame, bottom)
        }
        app.terminate()
    }

    func testHistoryOfflineAndTagContentEdgePaging() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "--qa-segment-edge", "-muted", "YES", "-app.appearance", "light"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        openAccountSettings()
        let bottom = mainTabBar().frame
        for (entry, title, identifier) in [("最近浏览与接着看", "最近浏览", "history.media-kind"),
                                           ("离线收藏与空间管理", "离线收藏与空间", "offline.media-kind")] {
            tapAboveMainBar(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", entry)).firstMatch)
            let header = floatingPageTitle(title)
            XCTAssertTrue(header.waitForExistence(timeout: 5))
            let top = header.frame
            let picker = app.otherElements[identifier]
            tapAboveMainBar(picker.buttons["图片"])
            XCTAssertEqual(app.otherElements.matching(identifier: identifier).count, 1, "Only the stable current pane is exposed to accessibility")
            swipeSegmentEdge(right: true)
            XCTAssertTrue(picker.buttons["视频"].isSelected)
            let state = heightValues(app.staticTexts["segment.content." + identifier].valueDescription)
            XCTAssertGreaterThan(state["renderedPeak"] ?? 0, 30)
            XCTAssertEqual(state["both"], 1)
            XCTAssertEqual(header.frame, top)
            XCTAssertEqual(mainTabBar().frame, bottom)
            swipeSegmentEdge(right: false)
            XCTAssertTrue(picker.buttons["图片"].isSelected)
            header.buttons["navigation.back"].tap()
            XCTAssertTrue(floatingPageTitle("账号与设置").waitForExistence(timeout: 5))
            for _ in 0..<3 {
                let window = app.windows.firstMatch
                window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.30))
                    .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)))
            }
        }
        mainTabButton("搜索").tap()
        app.buttons["search-tag-picker"].tap()
        let header = floatingPageTitle("选择标签")
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        let top = header.frame
        let input = app.textFields["tag-search-input"]
        input.tap(); input.typeText("portrait")
        let picker = app.otherElements["tag-directory.mode"]
        XCTAssertTrue(picker.buttons["全部标签"].isSelected)
        swipeSegmentEdge(right: true, distance: 20)
        XCTAssertEqual(input.value as? String, "portrait", "Cancelling common-mode preview must keep the catalog query")
        XCTAssertTrue(picker.buttons["全部标签"].isSelected)
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.55))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)))
        XCTAssertTrue(header.waitForNonExistence(timeout: 5), "Configuration edges return even when the page contains tabs")
        app.buttons["search-tag-picker"].tap()
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        input.tap(); input.typeText("portrait")
        picker.buttons["常用"].tap()
        waitUntil("Tapping the configuration pane finishes its content animation") { picker.buttons["常用"].isSelected }
        XCTAssertTrue(picker.buttons["常用"].isSelected)
        XCTAssertNotEqual(input.value as? String, "portrait", "Only committing common mode clears its catalog query")
        XCTAssertEqual(header.frame, top)
        let state = heightValues(app.staticTexts["segment.content.tag-directory.mode"].valueDescription)
        XCTAssertGreaterThan(state["renderedPeak"] ?? 0, 30)
        XCTAssertEqual(state["both"], 1)
        attachScreenshot(named: "content-pager-tags-common")
        app.terminate()
    }

    func testNativeListContentPagerInDarkLandscape() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-segment-edge", "-app.appearance", "dark", "-civitviewer.automaticRotation", "YES", "-muted", "YES"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        mainTabButton("作者榜").tap()
        let picker = app.otherElements["leaderboard.board"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        waitUntil("The native list host follows landscape") { self.app.windows.firstMatch.frame.width > self.app.windows.firstMatch.frame.height }
        let header = app.otherElements["leaderboard.top-bar"]
        let before = header.frame, bottom = mainTabBar().frame
        swipeSegmentEdge(right: true, distance: 20)
        XCTAssertTrue(picker.buttons["Seasonal"].isSelected)
        swipeSegmentEdge(right: true)
        XCTAssertTrue(picker.buttons["Legacy"].isSelected)
        let state = heightValues(app.staticTexts["segment.content.leaderboard.board"].valueDescription)
        XCTAssertGreaterThan(state["renderedPeak"] ?? 0, 30)
        XCTAssertEqual(state["both"], 1)
        XCTAssertEqual(state["width"] ?? 0, header.frame.width + 32, accuracy: 2)
        XCTAssertEqual(header.frame, before)
        XCTAssertEqual(mainTabBar().frame, bottom)
        XCTAssertEqual(app.buttons.matching(identifier: "leaderboard.author.28037001").count, 1)
        attachScreenshot(named: "content-pager-native-dark-landscape")
        app.terminate()
    }

    func testCollectionRefreshesChangedRevisionAfterContinuingPlayback() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-collection-batch-manage", "--qa-visual-controls", "--qa-segment-edge", "-muted", "YES", "-autoplay", "NO"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        mainTabButton("收藏").tap()
        let picker = app.otherElements["collection.media-kind"]
        let preparation = app.staticTexts["collection.preparation.qa"]
        waitUntil("The initial image first page is prepared before becoming a hidden pane") {
            let state = self.heightValues(preparation.valueDescription)
            return state["imageRevision"] == state["revision"] && (state["imageRevision"] ?? -1) >= 0
        }
        picker.buttons["视频"].tap()
        let first = app.buttons["media.grid.cell.28037102"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        waitUntil("The video first page has a confirmed collection revision") {
            let state = self.heightValues(preparation.valueDescription)
            return state["videoRevision"] == state["revision"] && (state["videoRevision"] ?? -1) >= 0
        }
        let before = heightValues(preparation.valueDescription)["revision"] ?? -1
        waitUntil("The page transition is idle before opening a work") {
            self.app.staticTexts["segment.content.collection.media-kind"].valueDescription.contains("phase=idle")
        }
        first.tap()
        let favorite = app.buttons["favorite-28037102"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 8))
        waitUntil("The fixture work starts bookmarked") { favorite.label == "已收藏" && favorite.isEnabled }
        favorite.tap()
        waitUntil("The asynchronous removal is confirmed") { favorite.label == "收藏" && favorite.isEnabled }
        let viewport = app.scrollViews.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? app.scrollViews.firstMatch
        viewport.swipeUp()
        XCTAssertTrue(app.staticTexts["collection.qa.geometry"].waitForValueToContain("focused=28037104", timeout: 8))
        app.buttons["关闭作品"].tap()
        XCTAssertTrue(first.waitForNonExistence(timeout: 12), "Returning must reconcile the original first page after the collection changed")
        XCTAssertTrue(app.buttons["media.grid.cell.28037104"].waitForExistence(timeout: 8))
        waitUntil("The visible pane records the new confirmed revision") {
            let state = self.heightValues(preparation.valueDescription)
            return (state["revision"] ?? -1) > before && state["videoRevision"] == state["revision"]
        }
        picker.buttons["图片"].tap()
        XCTAssertTrue(app.buttons["media.grid.cell.28037100"].waitForExistence(timeout: 8))
        waitUntil("A previously hidden pane also reconciles the changed revision") {
            let state = self.heightValues(preparation.valueDescription)
            return state["imageRevision"] == state["revision"]
        }
        attachScreenshot(named: "collection-content-pager-reconciled-revision")
        app.terminate()
    }

    func testLeaderboardDraggingAnAuthorRowNeverOpensAuthor() {
        for reduced in [false, true] {
            app = XCUIApplication()
            app.launchArguments = ["--qa-collection-paging", "--qa-segment-edge", "-app.appearance", "light", "-muted", "YES"]
            if reduced { app.launchArguments.append("--qa-reduce-motion") }
            XCUIDevice.shared.orientation = .portrait; app.launch()
            mainTabButton("作者榜").tap()
            let board = app.otherElements["leaderboard.board"]
            XCTAssertTrue(board.waitForExistence(timeout: 5))
            board.buttons["Seasonal"].tap()
            let window = app.windows.firstMatch
            for (right, distance) in [(true, 20.0), (true, 110.0), (true, 110.0), (false, 20.0), (false, 110.0)] {
                let row = app.buttons["leaderboard.author.28037001"]
                XCTAssertTrue(row.waitForExistence(timeout: 5))
                let y = row.frame.midY
                let x = right ? window.frame.width - 24 : 24.0
                let start = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
                let end = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x + (right ? -distance : distance), dy: y))
                start.press(forDuration: 0.05, thenDragTo: end, withVelocity: XCUIGestureVelocity(rawValue: 160), thenHoldForDuration: 0.1)
                waitUntil("Leaderboard settles after the actual author row drag") {
                    self.app.staticTexts["segment.content.leaderboard.board"].valueDescription.contains("phase=idle")
                }
                XCTAssertFalse(app.otherElements["creator.top-bar"].exists)
                XCTAssertTrue(app.otherElements["leaderboard.top-bar"].isHittable)
            }
            let locks = heightValues(app.descendants(matching: .any)["page.interaction-lock"].valueDescription)
            XCTAssertEqual(locks["locks"], 0)
            XCTAssertGreaterThan(locks["blocked"] ?? 0, 0)
            XCTAssertTrue(app.buttons["leaderboard.author.28037001"].isEnabled, "The active native list must be re-enabled after a drag")
            app.buttons["leaderboard.author.28037001"].tap()
            XCTAssertTrue(app.otherElements["creator.top-bar"].waitForExistence(timeout: 5), "A normal tap after settling still opens the author")
            app.terminate()
        }
    }

    func testSegmentedCenterReleaseAnimatesCompletionAndCancellation() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-segment-edge", "-app.appearance", "light", "-muted", "YES"]
        XCUIDevice.shared.orientation = .portrait; app.launch()
        for (tab, identifier, headerID) in [("作者榜", "leaderboard.board", "leaderboard.top-bar"),
                                           ("收藏", "collection.media-kind", "collections.top-bar")] {
            mainTabButton(tab).tap()
            XCTAssertTrue(app.otherElements[identifier].waitForExistence(timeout: 5))
            let header = app.otherElements[headerID].frame, bottom = mainTabBar().frame
            for (right, distance) in [(true, 110.0), (true, 20.0), (false, 110.0), (false, 20.0)] {
                let labels = tab == "作者榜" ? ["Legacy", "Seasonal"] : ["图片", "视频"]
                let picker = app.otherElements[identifier]
                let before = labels.first { picker.buttons[$0].isSelected }
                XCTAssertNotNil(before)
                swipeSegmentCenter(right: right, distance: distance)
                let qa = app.staticTexts["segment.content." + identifier]
                waitUntil("Release settles to the destination or returns to the source") { qa.valueDescription.contains("phase=idle") }
                let value = heightValues(qa.valueDescription)
                print("EDGE_RELEASE " + tab + " distance=\(distance) " + qa.valueDescription)
                XCTAssertGreaterThan(value["settleFrames"] ?? 0, 2, "The released pane must render a continuation, not only track the finger")
                XCTAssertGreaterThan(value["settleTravel"] ?? 0, 5)
                XCTAssertGreaterThan(value["settleBlocked"] ?? 0, 0)
                if distance >= 45 {
                    XCTAssertGreaterThan(value["renderedPeak"] ?? 0, (value["width"] ?? 0) - 3, "Completion must carry the source offscreen, not animate it back before swapping")
                    XCTAssertGreaterThan(value["settleTravel"] ?? 0, (value["width"] ?? 0) - distance - 20)
                    XCTAssertTrue(picker.buttons[labels.first { $0 != before }!].isSelected)
                } else {
                    XCTAssertLessThan(value["renderedPeak"] ?? 0, distance + 10)
                    XCTAssertTrue(picker.buttons[before!].isSelected)
                }
                XCTAssertFalse(app.otherElements["creator.top-bar"].exists)
                XCTAssertEqual(app.otherElements[headerID].frame, header)
                XCTAssertEqual(mainTabBar().frame, bottom)
                XCTAssertEqual(heightValues(app.descendants(matching: .any)["page.interaction-lock"].valueDescription)["locks"], 0)
            }
        }
        app.terminate()
    }

    func testSegmentedLostEndAndResetReleasesInput() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-segment-edge", "--qa-drop-section-pan-terminal-and-reset",
                               "-app.appearance", "light", "-autoplay", "NO", "-muted", "YES"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        mainTabButton("作者榜").tap()
        let board = app.otherElements["leaderboard.board"]
        let seasonal = board.buttons["Seasonal"], legacy = board.buttons["Legacy"]
        XCTAssertTrue(seasonal.waitForExistence(timeout: 5))
        seasonal.tap()
        let motion = app.staticTexts["segment.content.leaderboard.board"]
        let trace = app.staticTexts["segment.trace.leaderboard.board"]
        let locks = app.staticTexts["page.interaction-lock"]
        let row = app.buttons["leaderboard.author.28037001"]
        waitUntil("The selected leaderboard is ready for a real drag") {
            seasonal.isSelected && row.isHittable && motion.valueDescription.contains("phase=idle")
        }
        let acquired = heightValues(locks.valueDescription)["acquired"] ?? 0
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.55))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -110, dy: 0)),
                    withVelocity: XCUIGestureVelocity(rawValue: 160), thenHoldForDuration: 0.90)
        waitUntil("Lifting the held drag cancels the same pane without its standard callbacks") {
            trace.valueDescription.contains("decision=touch-sequence-ended") && motion.valueDescription.contains(":cancelled;phase=idle") &&
                self.heightValues(locks.valueDescription)["locks"] == 0 && seasonal.isSelected && row.isHittable
        }
        XCTAssertGreaterThan(heightValues(locks.valueDescription)["acquired"] ?? 0, acquired)
        XCTAssertEqual(app.state, .runningForeground)

        swipeSegmentCenter(right: true)
        XCTAssertTrue(legacy.isSelected, "The next real center swipe can commit")
        seasonal.tap()
        waitUntil("The real header selection and source list are actionable again") {
            seasonal.isSelected && motion.valueDescription.contains("phase=idle") && row.isHittable
        }
        mainTabButton("搜索").tap()
        waitUntil("The bottom bar can take a real tap after the recovered drag") {
            self.mainTabButton("搜索").isSelected && self.app.otherElements["search.top-bar"].isHittable &&
                self.heightValues(locks.valueDescription)["locks"] == 0
        }
    }

    func testCollectionSegmentTapMovesRealPanesAndUnlocks() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-segment-edge", "-app.appearance", "light", "-muted", "YES"]
        XCUIDevice.shared.orientation = .portrait; app.launch()
        mainTabButton("收藏").tap()
        let media = app.otherElements["collection.media-kind"]
        XCTAssertTrue(media.waitForExistence(timeout: 5))
        media.buttons["图片"].tap()
        let top = app.otherElements["collections.top-bar"].frame, bottom = mainTabBar().frame
        for label in ["视频", "图片", "视频", "图片"] {
            media.buttons[label].tap()
            XCTAssertTrue(media.buttons[label].isSelected, "The segment tap must commit before checking rendered motion")
            waitUntil("Collection content tap animation finishes") {
                self.app.staticTexts["segment.content.collection.media-kind"].valueDescription.contains("phase=idle")
            }
            let value = heightValues(app.staticTexts["segment.content.collection.media-kind"].valueDescription)
            print("COLLECTION_TAP_MOTION " + app.staticTexts["segment.content.collection.media-kind"].valueDescription)
            XCTAssertGreaterThan(value["intermediate"] ?? 0, 1, "Real content must pass through intermediate positions after a tap")
            XCTAssertGreaterThan(value["blockedMid"] ?? 0, 0, "New taps must hit the shield while content is moving")
            XCTAssertEqual(value["both"], 1)
            XCTAssertTrue(media.buttons[label].isSelected)
            XCTAssertEqual(app.otherElements["collections.top-bar"].frame, top)
            XCTAssertEqual(mainTabBar().frame, bottom)
        }
        XCTAssertEqual(heightValues(app.descendants(matching: .any)["page.interaction-lock"].valueDescription)["locks"], 0)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))
        waitUntil("The restored collection menu is hittable") { self.app.buttons["collection-filter-menu"].isHittable }
        XCTAssertEqual(heightValues(app.descendants(matching: .any)["page.interaction-lock"].valueDescription)["locks"], 0)
        XCTAssertTrue(app.buttons["collection-filter-menu"].isEnabled)
        app.buttons["collection-filter-menu"].tap()
        let menuOpened = app.buttons["筛选条件"].waitForExistence(timeout: 5)
        if !menuOpened { print("COLLECTION_RESTORE_AX " + app.debugDescription) }
        XCTAssertTrue(menuOpened)
        app.terminate()
    }

    func testCollectionCornersAndLocalPlayback162() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "--qa-collection-corners162",
                               "-app.appearance", "light", "-autoplay", "NO", "-muted", "YES"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        mainTabButton("收藏").tap()
        let progress = app.descendants(matching: .any)["collection.download.28037100"]
        let failed = app.descendants(matching: .any)["collection.download.28037101"]
        XCTAssertTrue(progress.waitForExistence(timeout: 8))
        XCTAssertTrue(progress.label.contains("下载中") && progress.label.contains("42"), progress.label)
        XCTAssertTrue(failed.label.contains("下载失败"), failed.label)
        let first = visualButton("media.grid.cell.28037100")
        XCTAssertGreaterThanOrEqual(progress.frame.minX, first.frame.minX)
        XCTAssertLessThan(progress.frame.maxX, first.frame.midX)
        first.press(forDuration: 0.65)
        XCTAssertTrue(mainTabBar().buttons["collection-batch.back"].waitForExistence(timeout: 5))
        XCTAssertTrue(mainTabBar().buttons["collection-batch.remove"].exists)
        XCTAssertFalse(mainTabBar().buttons["collection-batch.manage"].exists)
        attachScreenshot(named: "collection162-corners-and-selection")
        mainTabBar().buttons["collection-batch.back"].tap()
        let header = app.descendants(matching: .any)["collections.top-bar"]
        header.otherElements["collection.media-kind"].buttons["视频"].tap()
        let ready = visualButton("media.grid.cell.28037102")
        XCTAssertTrue(ready.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["collection.download.28037102"].exists)
        ready.tap()
        let player = app.descendants(matching: .any)["media.qa.player"]
        XCTAssertTrue(player.waitForValueToContain("source=offline", timeout: 8), player.valueDescription)
        XCTAssertTrue(visualButton("favorite-28037102").exists, "Local collection playback retains bookmark actions")
        XCTAssertFalse(app.staticTexts["离线"].exists, "Local resource location does not replace collection controls")
        attachScreenshot(named: "collection162-local-video-actions")
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.55))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.55)))
        waitUntil("The local playback edge closes to collections") { ready.isHittable && !player.isHittable }
        header.buttons["collections.downloads"].tap()
        let tasks = floatingPageTitle("下载管理")
        XCTAssertTrue(tasks.waitForExistence(timeout: 5))
        let sections = tasks.otherElements["downloads.section"]
        sections.buttons["空间"].tap()
        XCTAssertTrue(app.buttons["offline.storage.clean-unfavorited"].waitForExistence(timeout: 5))
        XCTAssertTrue(tasks.isHittable)
        XCTAssertTrue(sections.buttons["空间"].isSelected)
        XCTAssertFalse(app.descendants(matching: .any)["offline.media-kind"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["offline.storage-list"].exists)
        XCTAssertTrue(app.buttons["offline.storage.clean-unfavorited"].exists)
        attachScreenshot(named: "collection162-space-only")
    }

    func testCollectionPendingFileVerificationDoesNotHoldTabsOrOpenStaleWork() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "--qa-collection-corners162",
                               "--qa-collection-open-file-wait", "-autoplay", "NO", "-muted", "YES"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        mainTabButton("收藏").tap()
        let header = app.descendants(matching: .any)["collections.top-bar"]
        XCTAssertTrue(header.waitForExistence(timeout: 8))
        header.otherElements["collection.media-kind"].buttons["视频"].tap()
        let ready = visualButton("media.grid.cell.28037102")
        XCTAssertTrue(ready.waitForExistence(timeout: 5))
        ready.tap()
        let pending = app.staticTexts["collection.open-file.state"]
        XCTAssertTrue(pending.waitForValueToContain("entered=1;completed=0", timeout: 5))
        mainTabButton("搜索").tap()
        let search = app.textFields["search-title-input"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(search.isHittable)
        app.buttons["collection.open-file.release"].tap()
        XCTAssertTrue(pending.waitForValueToContain("entered=1;completed=1", timeout: 5))
        XCTAssertTrue(search.isHittable)
        let player = app.descendants(matching: .any)["media.qa.player"]
        XCTAssertFalse(player.exists, "A completed file check may not open playback on a different tab")
        mainTabButton("收藏").tap()
        XCTAssertTrue(ready.waitForExistence(timeout: 5))
        XCTAssertFalse(player.exists, "Returning after a stale completion leaves the collection grid active")
        ready.tap()
        XCTAssertTrue(player.waitForValueToContain("source=offline", timeout: 8), player.valueDescription)
    }

    func testCenterSegmentsAndAuthorEdgeReturn162() {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-segment-edge", "--qa-page-return", "-autoplay", "NO"])
        visualButton("media.author.28037100").tap()
        let header = app.descendants(matching: .any)["creator.top-bar"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        let fixedHeader = header.frame, fixedBottom = mainTabBar().frame
        let picker = app.otherElements["creator.media-kind"]
        let window = app.windows.firstMatch
        func drag(_ start: CGFloat, _ end: CGFloat) {
            window.coordinate(withNormalizedOffset: CGVector(dx: start, dy: 0.48))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: end, dy: 0.48)),
                       withVelocity: XCUIGestureVelocity(rawValue: 220), thenHoldForDuration: 0.1)
        }
        drag(0.76, 0.24)
        waitUntil("The author center swipe selects videos without opening a work") { picker.buttons["视频"].isSelected && header.isHittable }
        XCTAssertEqual(header.frame, fixedHeader)
        XCTAssertEqual(mainTabBar().frame, fixedBottom)
        XCTAssertFalse(app.buttons["playback.close"].exists)
        drag(0.24, 0.76)
        waitUntil("The author center swipe returns to images") { picker.buttons["图片"].isSelected && header.isHittable }
        waitUntil("The author center settlement releases input") {
            self.app.descendants(matching: .any)["segment.content.creator.media-kind"].valueDescription.contains("phase=idle")
        }
        print("AUTHOR162_BEFORE_EDGE " + app.descendants(matching: .any)["segment.content.creator.media-kind"].valueDescription)
        print("AUTHOR162_LOCK " + app.descendants(matching: .any)["page.interaction-lock"].valueDescription)
        drag(0.98, 0.55)
        attachScreenshot(named: "author162-after-right-edge")
        let returnQA = app.descendants(matching: .any)["page.return-motion.qa"]
        print("AUTHOR162_RETURN " + (returnQA.exists ? returnQA.valueDescription : "no-return-flight"))
        XCTAssertTrue(header.waitForNonExistence(timeout: 5), "Author edges return instead of changing media")
        XCTAssertTrue(timelineTools().isHittable)
        mainTabButton("作者榜").tap()
        let board = app.otherElements["leaderboard.board"]
        XCTAssertTrue(board.waitForExistence(timeout: 5))
        let before = board.buttons["Seasonal"].isSelected
        drag(0.76, 0.24)
        waitUntil("The leaderboard center swipe changes board") { board.buttons["Seasonal"].isSelected != before }
        XCTAssertFalse(app.descendants(matching: .any)["creator.top-bar"].isHittable)
        mainTabButton("收藏").tap()
        let collection = app.otherElements["collection.media-kind"]
        XCTAssertTrue(collection.waitForExistence(timeout: 5))
        let videoBefore = collection.buttons["视频"].isSelected
        drag(0.76, 0.24)
        waitUntil("The collection center swipe changes media") { collection.buttons["视频"].isSelected != videoBefore }
        drag(0.98, 0.55)
        waitUntil("Root collection edges switch to the next main page") { self.mainTabButton("时间线").isSelected }
        XCTAssertEqual(mainTabBar().frame, fixedBottom)
    }

    func testAuthor176PagingKeepsAcceptedRequestWhenScrollingAway() {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-author-paging176", "-autoplay", "NO", "-muted", "YES"])
        visualButton("media.author.28037100").tap()
        let header = app.descendants(matching: .any)["creator.top-bar"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        let state = app.staticTexts["author176.state"]
        XCTAssertTrue(state.waitForValueToContain("committed=20", timeout: 8))
        let window = app.windows.firstMatch
        for _ in 0..<7 {
            if state.valueDescription.contains("requests=2") { break }
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
        }
        XCTAssertTrue(state.waitForValueToContain("requests=2", timeout: 5), "One next-page request starts before reaching the end")
        for _ in 0..<4 {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
        }
        XCTAssertTrue(state.valueDescription.contains("cancelled=0"), "Moving away from the tail does not cancel the accepted page")
        app.buttons["author176.release"].tap()
        XCTAssertTrue(state.waitForValueToContain("committed=40", timeout: 8))
        XCTAssertTrue(state.valueDescription.contains("requests=2"), "The second page completes once without duplicate reads")
        XCTAssertTrue(state.valueDescription.contains("cancelled=0"))
        XCTAssertTrue(header.isHittable)
        attachScreenshot(named: "author176-accepted-page-survives-scroll-back")
    }

    private func openAuthorWithPendingContinuation(extra: [String] = []) {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-author-paging176", "--qa-header-motion", "--qa-drag-performance167",
                             "-autoplay", "NO", "-muted", "YES"] + extra)
        mainTabButton("作者榜").tap()
        let row = app.buttons["leaderboard.author.28037001"]
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
        let pageState = app.staticTexts["author176.state"]
        XCTAssertTrue(pageState.waitForValueToContain("committed=20", timeout: 8))
        for _ in 0..<10 {
            if pageState.valueDescription.contains("requests=2") { break }
            dragAuthorGrid(from: 0.77, to: 0.25)
        }
        assertContinuationPending()
    }

    private func assertContinuationPending(file: StaticString = #filePath, line: UInt = #line) {
        let value = app.staticTexts["author176.state"].valueDescription
        XCTAssertEqual(heightValues(value)["requests"], 2, value, file: file, line: line)
        XCTAssertEqual(heightValues(value)["committed"], 20, value, file: file, line: line)
        XCTAssertEqual(heightValues(value)["cancelled"], 0, value, file: file, line: line)
    }

    private func dragAuthorGrid(from: CGFloat, to: CGFloat, velocity: CGFloat = 560) {
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: from))
            .press(forDuration: 0.03, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: to)),
                   withVelocity: XCUIGestureVelocity(rawValue: velocity), thenHoldForDuration: 0)
    }

    func testAuthorPaginationContinuousInputBeforeAndDuringCommit() {
        openAuthorWithPendingContinuation(extra: ["--qa-author-paging-continuous", "--qa-author-paging-loaded-tag-index"])
        XCTAssertTrue(app.staticTexts["author176.state"].valueDescription.contains("tagIndexSeeded=1"))
        let first = visualButton("media.grid.cell.28037300")
        XCTAssertFalse(first.isHittable, "The first work must start above the visible viewport")
        for _ in 0..<2 {
            for _ in 0..<5 {
                if first.isHittable { break }
                dragAuthorGrid(from: 0.27, to: 0.82)
            }
            XCTAssertTrue(first.isHittable, "Reverse drag must bring the first work back while the response is held")
            assertContinuationPending()
            for _ in 0..<5 {
                dragAuthorGrid(from: 0.79, to: 0.25)
            }
            XCTAssertFalse(first.isHittable, "Forward drag must actually move the first work away")
            assertContinuationPending()
        }
        app.buttons["author176.release-on-drag"].tap()
        dragAuthorGrid(from: 0.25, to: 0.82, velocity: 150)
        let state = app.staticTexts["author176.state"]
        XCTAssertTrue(state.waitForValueToContain("committed=40", timeout: 8), state.valueDescription)
        XCTAssertTrue(state.waitForValueToContain("gestureEnd=", timeout: 5))
        let sample = heightValues(state.valueDescription)
        let start = sample["gestureStart"] ?? 0, apply = sample["pageApplied"] ?? 0, end = sample["gestureEnd"] ?? 0
        XCTAssertGreaterThan(apply, start, state.valueDescription)
        XCTAssertLessThan(apply, end, state.valueDescription)
        XCTAssertGreaterThan(sample["movesAfterApply"] ?? 0, 0, "The real drag must keep getting movement after the page is merged")
        let cadence = app.staticTexts["performance.cadence172"].valueDescription
        let payload = try? JSONSerialization.jsonObject(with: Data(cadence.utf8)) as? [String: Any]
        let gaps = (payload?["gaps"] as? [[Double]] ?? []).filter { $0.count >= 2 && $0[0] >= start && $0[0] <= end }
        let costs = payload?["cost174"] as? [String: Any]
        print("PAGINATION_LIVE " + state.valueDescription + ";gaps=" + String(describing: gaps) + ";cost=" + String(describing: costs))
        XCTAssertTrue(app.otherElements["creator.top-bar"].buttons["navigation.back"].isHittable)
    }

    private func assertAuthorCoverRequestsPending() {
        let state = app.staticTexts["author176.state"]
        waitUntil("Actual cover tasks remain pending in the visible author grid") {
            (self.heightValues(state.valueDescription)["waitingCovers"] ?? 0) > 0
        }
    }

    func testAuthorPendingPaginationAndCoversCanOpenAnExistingWork() {
        openAuthorWithPendingContinuation(extra: ["--qa-author-paging-hold-covers"])
        assertAuthorCoverRequestsPending()
        let existing = (28037312..<28037320).map { visualButton("media.grid.cell.\($0)") }.first { $0.isHittable }
        XCTAssertNotNil(existing, "An existing work is visible while both loads are pending")
        existing?.tap()
        let close = app.buttons["playback.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "Tapping the work enters its viewer before the response")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["creator.top-bar"].buttons["navigation.back"].isHittable)
    }

    func testAuthorPendingPaginationButtonAndEdgeReturnRemainOperable() {
        for method in ["button", "edge"] {
            openAuthorWithPendingContinuation(extra: ["--qa-author-paging-hold-covers"])
            assertAuthorCoverRequestsPending()
            let header = app.otherElements["creator.top-bar"]
            if method == "button" {
                header.buttons["navigation.back"].tap()
            } else {
                let window = app.windows.firstMatch
                window.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.48))
                    .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.57, dy: 0.48)),
                           withVelocity: XCUIGestureVelocity(rawValue: 180), thenHoldForDuration: 0.1)
            }
            XCTAssertTrue(header.waitForNonExistence(timeout: 5), "The \(method) return completes before the held response")
            let second = app.buttons["leaderboard.author.28037002"]
            XCTAssertTrue(second.waitForExistence(timeout: 5))
            XCTAssertTrue(second.isHittable)
            second.tap()
            XCTAssertTrue(header.waitForExistence(timeout: 5), "A subsequent real row tap navigates")
            app.terminate()
        }
    }

    func testAuthorPendingPaginationBottomTabRemainsOperable() {
        openAuthorWithPendingContinuation(extra: ["--qa-author-paging-hold-covers"])
        assertAuthorCoverRequestsPending()
        mainTabButton("搜索").tap()
        let field = app.textFields["search-title-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(field.isHittable)
        field.tap()
        field.typeText("pagination")
        XCTAssertEqual(field.value as? String, "pagination")
    }

    func testAuthorEdgeIntentPreservesVerticalScrollAndTap162() {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-segment-edge", "--qa-page-return", "--qa-author-scroll162", "-autoplay", "NO"])
        visualButton("media.author.28037100").tap()
        let header = app.descendants(matching: .any)["creator.top-bar"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch
        let first = visualButton("media.grid.cell.28037100")
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let before = first.frame.minY
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.66))
        start.press(forDuration: 0.05,
                    thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.40)),
                    withVelocity: XCUIGestureVelocity(rawValue: 220), thenHoldForDuration: 0.1)
        XCTAssertTrue(header.isHittable, "Vertical motion in the edge band scrolls rather than returning")
        let edgeY = first.frame.minY
        print("AUTHOR162_VERTICAL before=\(before);edge=\(edgeY)")
        let edgeQA = app.descendants(matching: .any)["page.return-motion.qa"]
        if edgeQA.exists { print("AUTHOR162_VERTICAL_QA " + edgeQA.valueDescription) }
        attachScreenshot(named: "author162-edge-vertical")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.66))
            .press(forDuration: 0.05,
                   thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.40)),
                   withVelocity: XCUIGestureVelocity(rawValue: 220), thenHoldForDuration: 0.1)
        print("AUTHOR162_VERTICAL center=\(first.frame.minY)")
        attachScreenshot(named: "author162-center-vertical")
        XCTAssertFalse(app.buttons["playback.close"].exists, "Scrolling must not activate a work")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.48)).tap()
        XCTAssertTrue(app.buttons["playback.close"].waitForExistence(timeout: 5), "An ordinary tile tap in the edge band still opens playback")
        XCTAssertLessThan(edgeY, before - 20)
    }

    func testSearchSortAlignsWithModeButton162() {
        app = XCUIApplication(); app.launchArguments = ["--qa-collection-paging", "-app.appearance", "light"]
        app.launch(); mainTabButton("搜索").tap()
        let mode = app.buttons["search.mode"], sort = app.buttons["search.results.sort"]
        XCTAssertTrue(sort.waitForExistence(timeout: 5))
        XCTAssertEqual(sort.frame.minX, mode.frame.minX, accuracy: 1)
        XCTAssertEqual(sort.frame.width, mode.frame.width, accuracy: 1)
        XCTAssertGreaterThan(sort.frame.minY, mode.frame.minY)
        XCTAssertEqual(sort.frame.midY, app.buttons["search-author-picker"].frame.midY, accuracy: 1)
        XCTAssertEqual(sort.frame.midY, app.buttons["search.range"].frame.midY, accuracy: 1)
        sort.tap()
        let option = app.buttons["value-selector.option.Most Reactions"]
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
        XCTAssertTrue(sort.waitForValueToContain("热度", timeout: 5))
        attachScreenshot(named: "search162-sort-second-row-aligned")
    }

    func testSearchModeHeightHasRealIntermediateFramesAndBlocksTouches() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-header-motion", "-app.appearance", "light", "-muted", "YES", "-autoplay", "NO"]
        app.launch(); mainTabButton("搜索").tap()
        let mode = app.buttons["search.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        if mode.valueDescription.contains("作者") { mode.tap() }
        let fixedBottom = mainTabBar().frame
        let fixedTop = app.otherElements["search.top-bar"].frame.minY
        for expected in ["作者", "作品", "作者", "作品"] {
            mode.tap()
            XCTAssertTrue(mode.waitForValueToContain(expected, timeout: 5))
            let qa = app.descendants(matching: .any)["header.layout-motion.qa"]
            waitUntil("Rendered header animation finishes") { qa.valueDescription.contains("phase=finished") }
            let value = heightValues(qa.valueDescription)
            print("HEADER_LAYOUT_MOTION " + qa.valueDescription)
            XCTAssertEqual(mainTabBar().frame, fixedBottom)
            XCTAssertEqual(app.otherElements["search.top-bar"].frame.minY, fixedTop, accuracy: 1)
            XCTAssertEqual(value["sourceRaster"], 1)
            XCTAssertEqual(value["destinationRaster"], 1)
            XCTAssertGreaterThan(value["intermediate"] ?? 0, 1)
            XCTAssertGreaterThan(value["blockedMid"] ?? 0, 0)
            XCTAssertLessThanOrEqual((value["topMax"] ?? 999) - (value["topMin"] ?? 0), 1)
            if expected == "作者" {
                XCTAssertGreaterThan(value["source"] ?? 0, value["target"] ?? 0)
                XCTAssertTrue(qa.valueDescription.contains("retiringLowerRow>resizing>replacingControls"), qa.valueDescription)
            } else {
                XCTAssertLessThan(value["source"] ?? 0, value["target"] ?? 0)
                XCTAssertTrue(qa.valueDescription.contains("resizing>replacingControls"), qa.valueDescription)
                XCTAssertFalse(qa.valueDescription.contains("retiringLowerRow"), qa.valueDescription)
            }
            XCTAssertEqual(heightValues(app.descendants(matching: .any)["page.interaction-lock"].valueDescription)["locks"], 0)
        }
        app.terminate()
    }

    func testRepeatedExistingFeedbackKeepsFullToastLifetime169() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-toast169", "-muted", "YES", "-autoplay", "NO"]
        app.launch()
        app.buttons["toast.qa.repeat"].tap()
        let toast = app.staticTexts["app.toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 2))
        // QA emits a distinct event at 2.6s. The original event alone expires
        // at 3.2s; a fresh identical error must retain its own full lifetime.
        Thread.sleep(forTimeInterval: 3.5)
        XCTAssertTrue(toast.exists)
        XCTAssertTrue(toast.waitForNonExistence(timeout: 5))
        app.terminate()
    }

    func testRepeatedBlockedTagFailureShowsExistingFeedback169() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "-app.appearance", "light", "-muted", "YES", "-autoplay", "NO"]
        app.launch()
        openAccountSettings()
        tapAboveMainBar(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "屏蔽标签")).firstMatch)
        let field = app.textFields["输入站点标签名"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(String(repeating: "a", count: 81))
        let add = floatingPageTitle("屏蔽标签").buttons["添加屏蔽标签"]
        let toast = app.staticTexts["app.toast"]
        for _ in 0..<2 {
            add.tap()
            XCTAssertTrue(toast.waitForExistence(timeout: 3))
            XCTAssertTrue(toast.label.contains("1—80"))
            XCTAssertTrue(toast.waitForNonExistence(timeout: 6))
        }
        app.terminate()
    }

    func testCentralExistingFeedbackToast169() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-toast169", "-muted", "YES", "-autoplay", "NO"]
        app.launch()
        let toast = app.staticTexts["app.toast"]
        XCTAssertFalse(toast.exists)
        app.buttons["toast.qa.silent"].tap()
        XCTAssertFalse(toast.exists)
        app.buttons["toast.qa.inactive"].tap()
        XCTAssertFalse(toast.exists)
        app.buttons["toast.qa.show"].tap()
        XCTAssertTrue(toast.waitForExistence(timeout: 3))
        XCTAssertEqual(toast.frame.midX, app.windows.firstMatch.frame.midX, accuracy: 2)
        XCTAssertEqual(toast.frame.midY, app.windows.firstMatch.frame.midY, accuracy: 2)
        let before = app.staticTexts["toast.qa.count"].label
        app.buttons["toast.qa.passthrough"].tap()
        XCTAssertNotEqual(app.staticTexts["toast.qa.count"].label, before)
        XCTAssertTrue(toast.exists, "The global source acknowledgement must not immediately dismiss the toast")
        attachScreenshot(named: "toast169-central-light")
        XCTAssertTrue(toast.waitForNonExistence(timeout: 6))
        app.buttons["toast.qa.long"].tap()
        XCTAssertTrue(toast.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(toast.frame.width, 342)
        XCTAssertEqual(toast.frame.midY, app.windows.firstMatch.frame.midY, accuracy: 2)
        attachScreenshot(named: "toast169-long-content")
        app.buttons["toast.qa.scope"].tap()
        XCTAssertTrue(toast.waitForNonExistence(timeout: 3))
        app.buttons["toast.qa.child"].tap()
        app.buttons["toast.qa.child-error"].tap()
        XCTAssertTrue(toast.waitForExistence(timeout: 3))
        XCTAssertEqual(toast.frame.midY, app.windows.firstMatch.frame.midY, accuracy: 2)
        app.buttons["toast.qa.close-child"].tap()
        XCTAssertTrue(toast.waitForNonExistence(timeout: 3))
        app.terminate()
    }

    func testAuthorPickerEntryAndBothEdgeReturnsKeepHeaderGeometry168() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-header-motion", "--qa-page-return", "--qa-body-motion",
                               "-app.appearance", "light", "-muted", "YES", "-autoplay", "NO"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        func idle() {
            waitUntil("The header and body finish their shared handoff") {
                self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0")
            }
        }
        mainTabButton("搜索").tap(); idle()
        let sourceHeader = app.otherElements["search.top-bar"].frame
        let bottom = mainTabBar().frame
        let window = app.windows.firstMatch
        for right in [true, false] {
            print("AUTHOR168_ENTER right=\(right);time=\(Date().timeIntervalSince1970)")
            app.buttons["search-author-picker"].tap()
            let field = app.textFields["author-picker.input"]
            XCTAssertTrue(field.waitForExistence(timeout: 5)); idle()
            let title = floatingPageTitle("选择作者")
            XCTAssertTrue(title.exists)
            let finalField = field.frame
            // Compact search and ordinary title bars have different AX wrapper
            // insets. Compare the rendered fixed surface, not those wrappers.
            let motionValue = app.descendants(matching: .any)["header.layout-motion.qa"].valueDescription
            let geometry = heightValues(motionValue)
            print("AUTHOR168_HEADER " + motionValue)
            XCTAssertEqual(geometry["topMin"] ?? -1, sourceHeader.minY, accuracy: 1)
            XCTAssertLessThanOrEqual((geometry["topMax"] ?? 999) - (geometry["topMin"] ?? 0), 1)
            XCTAssertGreaterThan(geometry["intermediate"] ?? 0, 1)
            XCTAssertLessThan(title.frame.height, sourceHeader.height)
            XCTAssertGreaterThanOrEqual(field.frame.minY, title.frame.maxY)
            XCTAssertEqual(mainTabBar().frame, bottom)
            print("AUTHOR168_ENTERED field=\(field.frame);time=\(Date().timeIntervalSince1970)")
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.98 : 0.02, dy: 0.5))
            print("AUTHOR168_CANCEL right=\(right);time=\(Date().timeIntervalSince1970)")
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: right ? -20 : 20, dy: 0)),
                        withVelocity: XCUIGestureVelocity(rawValue: 100), thenHoldForDuration: 0.1)
            idle()
            XCTAssertTrue(title.exists)
            XCTAssertEqual(field.frame.minY, finalField.minY, accuracy: 1)
            XCTAssertTrue(app.staticTexts["page.return-motion.qa"].valueDescription.contains("phase=cancelled"))
            print("AUTHOR168_RETURN right=\(right);time=\(Date().timeIntervalSince1970)")
            start.press(forDuration: 0.05,
                        thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.30 : 0.70, dy: 0.5)),
                        withVelocity: XCUIGestureVelocity(rawValue: 180), thenHoldForDuration: 0.1)
            XCTAssertTrue(field.waitForNonExistence(timeout: 5)); idle()
            let returnValue = app.staticTexts["page.return-motion.qa"].valueDescription
            print("AUTHOR168_TERMINAL " + returnValue)
            XCTAssertTrue(returnValue.contains("phase=completed"), returnValue)
            XCTAssertEqual(app.otherElements["search.top-bar"].frame, sourceHeader)
            XCTAssertEqual(mainTabBar().frame, bottom)
            print("AUTHOR168_RETURNED time=\(Date().timeIntervalSince1970)")
        }
        app.terminate()
    }

    func testSearchModeLayoutReturnsToLatestHeight() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "-app.appearance", "light"]
        app.launch()
        mainTabButton("搜索").tap()
        let mode = app.buttons["search.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        let header = app.otherElements["search.top-bar"]
        if mode.valueDescription.contains("作者") { mode.tap() }
        let works = header.frame, bottom = mainTabBar().frame
        for _ in 0..<3 {
            mode.tap()
            XCTAssertTrue(mode.waitForValueToContain("作者", timeout: 5))
            waitUntil("Search header finishes shrinking") { header.frame.height < works.height }
            let authors = header.frame
            XCTAssertEqual(authors.minY, works.minY, accuracy: 1)
            XCTAssertLessThan(authors.height, works.height)
            XCTAssertEqual(mainTabBar().frame, bottom)
            mode.tap()
            XCTAssertTrue(mode.waitForValueToContain("作品", timeout: 5))
            waitUntil("Search header finishes expanding") { abs(header.frame.height - works.height) < 1 }
            XCTAssertEqual(header.frame, works)
        }
        attachScreenshot(named: "segment-search-layout-restored")
        app.terminate()
    }

    func testRootVideoCanvasRemainsUnderFixedChrome165() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "--qa-theme-timeline",
                               "--qa-header-motion", "--qa-body-motion", "--qa-root-motion181", "-app.appearance", "light",
                               "-muted", "YES", "-autoplay", "YES", "-timeline.presentation", "stream"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(timelineTools().waitForExistence(timeout: 10))
        heightCloseNotices()
        app.otherElements["timeline.media-kind"].buttons["视频"].tap()
        waitUntil("The source timeline video is ready") { self.watchFocus() == 28_037_102 }
        let viewport = app.windows.firstMatch.frame
        let bottom = mainTabBar().frame
        let playbackHeader = timelineTools().frame
        let body = app.staticTexts["body.motion.qa"]
        let motion = app.staticTexts["root.motion181.qa"]
        func assertLiveCanvas(_ prefix: String, tab: Int) -> String? {
            let fields = rootMotionFields181(motion.valueDescription)
            XCTAssertEqual(fields["outcome"], "completed", motion.valueDescription)
            let departing = prefix == "source"
            XCTAssertEqual(fields[departing ? "source" : "destination"], String(tab), motion.valueDescription)
            let movement = departing ? "maxMoveSourceX" : "maxMoveTargetX"
            XCTAssertGreaterThan(Double(fields[movement] ?? "0") ?? 0, 0.5, motion.valueDescription)
            XCTAssertEqual(Double(fields[prefix + "Y"] ?? "999") ?? 999, viewport.minY, accuracy: 1)
            XCTAssertEqual(Double(fields[prefix + "Height"] ?? "-1") ?? -1, viewport.height, accuracy: 1)
            let surfaces = heightValues(body.valueDescription)
            XCTAssertEqual(surfaces["snapshotAvailable"], 0, body.valueDescription)
            XCTAssertEqual(surfaces["targetSnapshotAvailable"], 0, body.valueDescription)
            return tokenValue181(fields["tokens"] ?? "", tab: tab)
        }
        mainTabButton("搜索").tap()
        waitUntil("Video root departure completes") {
            self.mainTabButton("搜索").isSelected && body.valueDescription.contains("phase=completed")
        }
        let timelineToken = assertLiveCanvas("source", tab: 0)
        XCTAssertNotNil(timelineToken)
        XCTAssertEqual(mainTabBar().frame, bottom)
        print("ROOT165_VIDEO_SOURCE " + body.valueDescription)
        let window = app.windows.firstMatch
        for title in ["作者榜", "时间线"] {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                       withVelocity: XCUIGestureVelocity(rawValue: 180), thenHoldForDuration: 0.1)
            waitUntil("The root edge commits \(title)") { self.mainTabButton(title).isSelected }
            waitUntil("The destination root body releases input") {
                self.app.descendants(matching: .any)["page.interaction-lock"].valueDescription.contains("locks=0")
            }
        }
        XCTAssertEqual(assertLiveCanvas("target", tab: 0), timelineToken)
        XCTAssertEqual(mainTabBar().frame, bottom)
        XCTAssertEqual(timelineTools().frame, playbackHeader)
        XCTAssertEqual(watchFocus(), 28_037_102)
        print("ROOT165_VIDEO_TARGET " + body.valueDescription)
        attachScreenshot(named: "root165-video-header-canvas")
    }

    func testIdleRoot178MountsStayInactiveUntilAcceptedNavigation() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-theme-timeline", "--qa-root-idle178", "--qa-header-motion", "--qa-body-motion",
                               "--qa-collection-cache-key=\(UUID().uuidString)",
                               "-app.appearance", "light", "-muted", "YES", "-autoplay", "NO"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        mainTabButton("搜索").tap()
        let readback = app.staticTexts["root.idle178.qa"]
        var previousMountState = ""
        waitUntil("Both adjacent ordinary hosts mount without becoming selected") {
            let value = readback.valueDescription
            if value != previousMountState { print("IDLE178_STATE " + value); previousMountState = value }
            return value.contains("selected=4;slots=0,2,3,4;") && value.contains("hidden=0,2,3;interactive=4;")
        }
        // The fixture's folders request completes after 1.4s. Hidden mounting
        // must not start it, nor turn an inactive collection into a loaded one.
        Thread.sleep(forTimeInterval: 1.8)
        XCTAssertTrue(readback.valueDescription.contains("collectionsKnown=false"), readback.valueDescription)
        XCTAssertTrue(readback.valueDescription.contains("folders=0;pages=0;"), readback.valueDescription)
        XCTAssertFalse(app.buttons["media.grid.cell.28037100"].exists)
        let header = app.otherElements["search.top-bar"].frame
        let bottom = mainTabBar().frame
        print("IDLE178_HIDDEN " + readback.valueDescription)
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)),
                   withVelocity: XCUIGestureVelocity(rawValue: 180), thenHoldForDuration: 0.1)
        waitUntil("Accepting navigation activates the real collection task") { self.mainTabButton("收藏").isSelected }
        XCTAssertTrue(app.buttons["media.grid.cell.28037100"].waitForExistence(timeout: 12))
        waitUntil("The confirmed collection can still persist its normal preview") { self.app.staticTexts["collection-cache.qa"].label == "stored" }
        XCTAssertTrue(readback.valueDescription.contains("collectionsKnown=true"), readback.valueDescription)
        let beforeRefresh = heightValues(readback.valueDescription)
        app.buttons["collection-filter-menu"].tap()
        app.buttons["刷新作品"].tap()
        waitUntil("The actual user refresh starts its delayed page read") {
            (self.heightValues(readback.valueDescription)["pages"] ?? 0) > (beforeRefresh["pages"] ?? 0)
        }
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)),
                   withVelocity: XCUIGestureVelocity(rawValue: 180), thenHoldForDuration: 0.1)
        waitUntil("Returning restores the retained search and releases input") {
            self.mainTabButton("搜索").isSelected && self.app.otherElements["search.top-bar"].isHittable
                && self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0")
        }
        XCTAssertEqual(app.otherElements["search.top-bar"].frame, header)
        XCTAssertEqual(mainTabBar().frame, bottom)
        // The accepted refresh may finish, but its old View cannot start a
        // new folders read after its retained root becomes inactive.
        Thread.sleep(forTimeInterval: 5.2)
        XCTAssertEqual(heightValues(readback.valueDescription)["folders"], beforeRefresh["folders"], readback.valueDescription)
        XCTAssertTrue(mainTabButton("搜索").isSelected)
        print("IDLE178_RETURN " + readback.valueDescription)
        app.terminate()
    }

    func testRoot179CancelledTimelinePreviewDoesNotStartBlackCanvas() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-visual-controls", "--qa-header-motion", "--qa-body-motion",
                               "--qa-canvas-cancel179", "--qa-root-motion181", "-app.appearance", "light", "-muted", "YES", "-autoplay", "NO"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        mainTabButton("作者榜").tap()
        let header = app.otherElements["leaderboard.top-bar"]
        let qa = app.staticTexts["canvas.cancel179.qa"]
        let body = app.staticTexts["body.motion.qa"]
        let rootMotion = app.staticTexts["root.motion181.qa"]
        waitUntil("The real author board has released its entry shield") {
            header.isHittable && rootMotion.exists && self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0")
        }
        let before = heightValues(qa.valueDescription)
        let initialRoot = rootMotionFields181(rootMotion.valueDescription)
        let top = header.frame, bottom = mainTabBar().frame
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
        for round in 1...3 {
            print("CANCEL179_BEGIN round=\(round);epoch=\(Date().timeIntervalSince1970);" + qa.valueDescription)
            start.press(forDuration: 0.05,
                        thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.20, dy: 0.5)),
                        withVelocity: XCUIGestureVelocity(rawValue: 60), thenHoldForDuration: 0.12)
            waitUntil("Cancelled timeline preview restores the same board") {
                self.mainTabButton("作者榜").isSelected && header.isHittable
                    && rootMotion.valueDescription.contains("outcome=cancelled")
                    && self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0")
            }
            print("CANCEL179_END round=\(round);epoch=\(Date().timeIntervalSince1970);" + qa.valueDescription + ";body=" + body.valueDescription)
            XCTAssertEqual(heightValues(qa.valueDescription)["black"], before["black"], "Cancelling a preview must not create an opaque black canvas blend: " + qa.valueDescription)
            XCTAssertEqual(heightValues(qa.valueDescription)["prepared"], (before["prepared"] ?? 0) + Double(round))
            XCTAssertTrue(body.valueDescription.contains("kind=tab-edge;phase=cancelled"), body.valueDescription)
            let motion = rootMotionFields181(rootMotion.valueDescription)
            XCTAssertNotEqual(motion["pair"], "none", rootMotion.valueDescription)
            XCTAssertEqual(motion["source"], "2", rootMotion.valueDescription)
            XCTAssertEqual(motion["selected"], "2", rootMotion.valueDescription)
            XCTAssertEqual(motion["visibleSlots"], "2", rootMotion.valueDescription)
            XCTAssertGreaterThan(Int(motion["slotCount"] ?? "0") ?? 0, 0, rootMotion.valueDescription)
            XCTAssertLessThanOrEqual(Int(motion["slotCount"] ?? "99") ?? 99, 4, rootMotion.valueDescription)
            XCTAssertEqual(motion["sourceHidden"], "0", rootMotion.valueDescription)
            XCTAssertEqual(motion["targetHidden"], "1", rootMotion.valueDescription)
            XCTAssertEqual(motion["outcome"], "cancelled", rootMotion.valueDescription)
            XCTAssertGreaterThan(Int(motion["moveSamples"] ?? "0") ?? 0, 0, rootMotion.valueDescription)
            XCTAssertGreaterThan(Double(motion["maxMoveSourceX"] ?? "0") ?? 0, 0.5, rootMotion.valueDescription)
            XCTAssertGreaterThan(Double(motion["maxMoveTargetX"] ?? "0") ?? 0, 0.5, rootMotion.valueDescription)
            XCTAssertEqual(tokenValue181(initialRoot["tokens"] ?? "", tab: 2),
                           tokenValue181(motion["tokens"] ?? "", tab: 2), "The cancelled flight must preserve its source host identity")
            XCTAssertEqual(tokenValue181(motion["tokens"] ?? "", tab: 2), motion["sourceToken"], rootMotion.valueDescription)
            XCTAssertTrue(body.valueDescription.contains("kind=tab-edge;phase=cancelled"), body.valueDescription)
            XCTAssertEqual(heightValues(body.valueDescription)["snapshotAvailable"], 0,
                            "The root pair uses the existing host views: " + body.valueDescription)
            XCTAssertEqual(heightValues(body.valueDescription)["targetSnapshotAvailable"], 0,
                            "The root pair has no target page snapshot: " + body.valueDescription)
            XCTAssertEqual(header.frame, top)
            XCTAssertEqual(mainTabBar().frame, bottom)
        }
        app.terminate()
    }

    func testCreator179CancelledReturnKeepsSourceCanvas() {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-page-return", "--qa-body-motion", "--qa-header-motion", "--qa-canvas-cancel179", "-autoplay", "NO"])
        visualButton("media.author.28037100").tap()
        let header = app.otherElements["creator.top-bar"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        let qa = app.staticTexts["canvas.cancel179.qa"]
        let before = heightValues(qa.valueDescription)
        let window = app.windows.firstMatch
        let top = header.frame, bottom = mainTabBar().frame
        for (index, right) in [false, true, false].enumerated() {
            let from = window.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.98 : 0.02, dy: 0.5))
            from.press(forDuration: 0.05,
                       thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.91 : 0.09, dy: 0.5)),
                       withVelocity: XCUIGestureVelocity(rawValue: 60), thenHoldForDuration: 0.12)
            let motion = app.descendants(matching: .any)["page.return-motion.qa"]
            waitUntil("Cancelled author return restores its real source") {
                header.isHittable && motion.valueDescription.contains("phase=cancelled")
            }
            XCTAssertTrue(motion.valueDescription.contains("sourceMasked=false"), motion.valueDescription)
            XCTAssertEqual(heightValues(qa.valueDescription)["black"], before["black"], qa.valueDescription)
            XCTAssertEqual(header.frame, top)
            XCTAssertEqual(mainTabBar().frame, bottom)
            print("CREATOR_CANCEL179 round=\(index);" + qa.valueDescription + ";return=" + motion.valueDescription)
        }
        app.terminate()
    }

    func testCreator191CancelledReturnPreservesOrdinaryBodyColor() throws {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-page-return", "--qa-header-motion", "--qa-return-hold-travel-shot",
                             "-autoplay", "NO", "-muted", "YES"])
        visualButton("media.author.28037100").tap()
        let header = app.otherElements["creator.top-bar"]
        let back = header.buttons["navigation.back"]
        let locks = app.staticTexts["page.interaction-lock"]
        let motion = app.staticTexts.matching(identifier: "page.return-motion.qa").firstMatch
        let grid = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "media.grid.cell.")).firstMatch
        waitUntil("The light author grid is ready over the immersive timeline") {
            back.isHittable && grid.isHittable && locks.valueDescription.contains("locks=0")
        }
        let topFrame = header.frame
        let bottomFrame = mainTabBar().frame
        let swipeDistance: CGFloat = 34
        let patch = CGRect(x: app.frame.midX - 2, y: grid.frame.midY - 16, width: 4, height: 32)
        // At this row the center gutter is white and the neighboring cover is colored.
        waitUntil("The neighboring fixture cover has decoded") {
            let screenshot = UIImage(data: self.app.screenshot().pngRepresentation)
            guard let rgb = self.floating45MeanRGB(screenshot, in: patch.offsetBy(dx: swipeDistance, dy: 0)),
                  let high = rgb.max(), let low = rgb.min() else { return false }
            return high - low > 25
        }
        let before = captureChromePixels(named: "creator191-body-before")
        let baseline = try XCTUnwrap(floating45MeanRGB(before, in: patch))
        XCTAssertTrue(baseline.allSatisfy { $0 >= 235 }, "Expected the light grid gutter: \(baseline)")

        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.52))
        origin.press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: swipeDistance, dy: 0)),
                     withVelocity: XCUIGestureVelocity(rawValue: 75), thenHoldForDuration: 0.40)
        var state = logAuthorReturnMotion("CREATOR191_POST_DRAG", motion)
        waitUntil("The captured author body holds the dragged offset over the immersive timeline", timeout: 4,
                  onTimeout: { _ = self.logAuthorReturnMotion("CREATOR191_HOLD_TIMEOUT", motion) }) {
            state = motion.exists ? motion.valueDescription : "missing"
            return state.contains("event=return-travel-held-for-qa") && state.contains("liveSourceMotion=false")
                && state.contains("sourceMasked=true") && state.contains("heldFinger=true")
                && state.contains("navigationOutcome=pending")
        }
        let sample = numericReadback(state)
        XCTAssertTrue(state.contains("globalBlocked=false"), state)
        let offset = try XCTUnwrap(sample["sourceSnapshotTx"])
        XCTAssertGreaterThan(try XCTUnwrap(sample["heldSourceTx"]), 12,
                             "The captured author body must move visibly before finger lift: " + state)
        XCTAssertGreaterThan(offset, 15, state)
        let screenshot = captureChromePixels(named: "creator191-body-displaced-before-cancel")
        let captured = logAuthorReturnMotion("CREATOR191_SCREENSHOT", motion)
        XCTAssertTrue(captured.contains("event=return-travel-held-for-qa"),
                      "The screenshot must be captured before the author returns to its origin")
        let movedPatch = patch.offsetBy(dx: CGFloat(offset), dy: 0)
        let held = try XCTUnwrap(floating45MeanRGB(screenshot, in: movedPatch))
        let originalAtMovedPatch = try XCTUnwrap(floating45MeanRGB(before, in: movedPatch))
        XCTAssertGreaterThan(zip(held, originalAtMovedPatch).map { abs($0.0 - $0.1) }.max() ?? 0, 25,
                             "The gutter must replace the neighboring cover at its displaced position")
        for channel in baseline.indices {
            XCTAssertEqual(held[channel], baseline[channel], accuracy: 8,
                           "The displaced ordinary body gutter must keep its color: before=\(baseline); held=\(held)")
        }
        waitUntil("Cancellation releases input on the same author page",
                  onTimeout: { _ = self.logAuthorReturnMotion("CREATOR191_CANCEL_TIMEOUT", motion) }) {
            motion.valueDescription.contains("phase=cancelled")
                && back.isHittable && grid.isHittable && locks.valueDescription.contains("locks=0")
        }
        XCTAssertEqual(header.frame, topFrame)
        XCTAssertEqual(mainTabBar().frame, bottomFrame)
        attachScreenshot(named: "creator191-body-after-cancel")
    }

    func testReleaseDownloadSettingsEdgeHoldsAndReturns() {
        app = XCUIApplication()
        app.launchArguments = ["-muted", "YES", "-autoplay", "NO"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        heightCloseNotices()
        openAccountSettings()
        let settings = floatingPageTitle("账号与设置")
        let downloads = app.buttons["settings.downloads"]
        let header = floatingPageTitle("下载设置")
        let back = header.buttons["navigation.back"]
        let wifiOnly = app.switches["downloads.wifi-only"]
        let window = app.windows.firstMatch
        let bottom = mainTabBar()
        waitUntil("The anonymous settings page is ready") {
            settings.buttons["navigation.back"].isHittable && downloads.exists && bottom.exists
        }
        let settingsFrame = settings.frame
        let bottomFrame = bottom.frame
        attachScreenshot(named: "release-download-edge-settings-baseline")

        for (label, right, cancel) in [("left-commit", false, false), ("right-commit", true, false), ("left-cancel", false, true)] {
            tapAboveMainBar(downloads)
            waitUntil("The local download settings controls are ready") { back.isHittable && wifiOnly.isHittable }
            let headerFrame = header.frame
            XCTAssertEqual(bottom.frame, bottomFrame)
            attachScreenshot(named: "release-download-edge-\(label)-before")
            let touch = window.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.98 : 0.02, dy: 0.52))
            // A short translation must stay below the 45-point acceptance threshold on every device size.
            let travel: CGFloat = cancel ? 34 : window.frame.width * 0.45
            let end = touch.withOffset(CGVector(dx: right ? -travel : travel, dy: 0))
            print("RELEASE_DOWNLOAD_EDGE_BEGIN method=\(label);epoch=\(Date().timeIntervalSince1970);travel=\(travel);top=\(headerFrame);bottom=\(bottomFrame)")
            touch.press(forDuration: 0.05, thenDragTo: end,
                        withVelocity: XCUIGestureVelocity(rawValue: cancel ? 75 : 170), thenHoldForDuration: 1.8)
            print("RELEASE_DOWNLOAD_EDGE_END method=\(label);epoch=\(Date().timeIntervalSince1970)")
            if cancel {
                waitUntil("A short edge returns to the same usable download settings") { back.isHittable && wifiOnly.isHittable }
                XCTAssertEqual(header.frame, headerFrame)
            } else {
                waitUntil("The accepted edge returns to the real account settings") {
                    !header.exists && settings.buttons["navigation.back"].isHittable && downloads.isHittable
                }
                XCTAssertEqual(settings.frame, settingsFrame)
            }
            XCTAssertEqual(bottom.frame, bottomFrame)
            attachScreenshot(named: "release-download-edge-\(label)-after")
        }
    }

    func testLeaderboardAuthorEdgeResetBeforeAssemblyNeverAcquiresInput() {
        assertLeaderboardAuthorEdgeFaultReleasesInput(
            flag: "--qa-reset-edge-before-assembly", reason: "begin-pan-reset", right: true, expectedPhase: "guard")
    }

    func testLeaderboardAuthorEdgeResetReleasesInputAfterMissingTerminalCallback() {
        assertLeaderboardAuthorEdgeFaultReleasesInput(
            flag: "--qa-drop-edge-return-pan-terminal", reason: "return-pan-reset", right: false)
    }

    func testLeaderboardAuthorLostEndAndResetReleasesInput() {
        assertLeaderboardAuthorEdgeFaultReleasesInput(
            flag: "--qa-drop-edge-return-pan-terminal-and-reset", reason: "return-touch-ended", right: false,
            verifyNextSwipe: true)
    }

    func testLeaderboardAuthorTouchWatchRecoversWithoutTerminalCallbacks() {
        assertLeaderboardAuthorEdgeFaultReleasesInput(
            flag: "--qa-drop-edge-return-pan-terminal-reset-and-touch-end",
            reason: "return-touch-ended", right: false, verifyNextSwipe: true, recoveryProof: .touchWatch)
    }

    func testLeaderboardAuthorNewTouchRecoversStaleEdgePan() {
        assertLeaderboardAuthorEdgeFaultReleasesInput(
            flag: "--qa-stale-edge-pan-touch", reason: "return-abandoned-on-new-touch",
            right: false, verifyNextSwipe: true, recoveryProof: .nextTouch)
    }

    func testLeaderboardAuthorPendingEdgeReturnYieldsToFirstBottomTabTap() throws {
        let pending = try startUnassembledAuthorEdgeReturn { self.mainTabButton("搜索") }
        let field = app.textFields["search-title-input"]
        tapScreenFrame(pending.frame)
        waitUntil("One tap switches to Search while the accepted edge return waits for its canvas", timeout: 5) {
            self.mainTabButton("搜索").isSelected && field.isHittable
        }
        assertLateAuthorEdgeCaptureWasRejected(receipt: pending.receipt)
        XCTAssertTrue(mainTabButton("搜索").isSelected)
        XCTAssertTrue(field.isHittable)
        field.tap()
        field.typeText("edge return")
        XCTAssertEqual(field.value as? String, "edge return")
    }

    func testLeaderboardAuthorPendingEdgeReturnYieldsToFirstBackTapAndPreservesNewAuthor() throws {
        let pending = try startUnassembledAuthorEdgeReturn { self.app.otherElements["creator.top-bar"].buttons["navigation.back"] }
        let author = app.otherElements["creator.top-bar"]
        let second = app.buttons["leaderboard.author.59002"]
        tapScreenFrame(pending.frame)
        waitUntil("One Back tap returns to the leaderboard while the accepted edge waits for its canvas", timeout: 5) {
            !author.exists && second.isHittable
        }
        second.tap()
        let newAuthor = app.staticTexts["@Pattern Creator 2"]
        waitUntil("A different author opens before the first author's canvas is delivered", timeout: 5) {
            author.buttons["navigation.back"].isHittable && newAuthor.isHittable
        }
        assertLateAuthorEdgeCaptureWasRejected(receipt: pending.receipt)
        XCTAssertTrue(newAuthor.isHittable)
        author.buttons["navigation.back"].tap()
        waitUntil("The newer author keeps its own working Back action") { !author.exists && second.isHittable }
    }

    private func startUnassembledAuthorEdgeReturn(action button: () -> XCUIElement) throws -> (frame: CGRect, receipt: String) {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-author-activity58", "--qa-page-return", "--qa-header-motion",
                             "--qa-hold-edge-return-assembly-for-independent-input", "-autoplay", "NO", "-muted", "YES"])
        mainTabButton("作者榜").tap()
        let row = app.buttons["leaderboard.author.59001"]
        let locks = app.staticTexts["page.interaction-lock"]
        waitUntil("The author leaderboard can receive row taps") {
            row.isHittable && locks.valueDescription.contains("locks=0")
        }
        row.tap()
        let work = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "media.grid.cell.")).firstMatch
        let author = app.otherElements["creator.top-bar"]
        let action = button()
        waitUntil("The first author is visible with working chrome and a loaded grid") {
            author.buttons["navigation.back"].isHittable && work.isHittable && action.isHittable
                && locks.valueDescription.contains("locks=0")
        }
        let acquired = try XCTUnwrap(heightValues(locks.valueDescription)["acquired"])
        let frame = action.frame
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.52))
        start.press(forDuration: 0.05,
                    thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.57, dy: 0.52)),
                    withVelocity: XCUIGestureVelocity(rawValue: 900), thenHoldForDuration: 0)
        let motion = app.staticTexts["page.return-motion.qa"]
        XCTAssertTrue(motion.waitForValueToContain("event=settlement-deferred", timeout: 3), motion.valueDescription)
        let pending = motion.valueDescription
        XCTAssertTrue(pending.contains("settlementDeferred=true") && pending.contains("assembled=false")
                      && pending.contains("navigationOutcome=pending") && pending.contains("globalBlocked=false"), pending)
        let lockState = heightValues(locks.valueDescription)
        XCTAssertEqual(lockState["locks"], 0)
        XCTAssertEqual(lockState["acquired"], acquired)
        XCTAssertTrue(action.isHittable, "The live control must remain tappable while its canvas is pending")
        XCTAssertEqual(action.frame, frame, "The live control must keep its original position")
        let receipt = try XCTUnwrap(rootMotionFields181(pending)["receipt"])
        return (frame, receipt)
    }

    private func assertLateAuthorEdgeCaptureWasRejected(receipt: String) {
        let terminal = app.staticTexts["page.return-motion.qa"].valueDescription
        let motion = rootMotionFields181(terminal)
        XCTAssertEqual(motion["receipt"], receipt, terminal)
        XCTAssertTrue(terminal.contains("return-abandoned-on-new-touch"), terminal)
        XCTAssertEqual(motion["navigationOutcome"], "cancelled", terminal)
        let callback = app.staticTexts["page.return-late-capture.qa"]
        XCTAssertFalse(callback.exists, "The new page must become actionable before the old canvas arrives")
        XCTAssertTrue(callback.waitForValueToContain("rejected=true", timeout: 12), callback.valueDescription)
        let result = rootMotionFields181(callback.valueDescription)
        XCTAssertEqual(result["delivered"], "true", callback.valueDescription)
        XCTAssertEqual(result["captured"], "true", callback.valueDescription)
        XCTAssertEqual(result["receipt"], receipt, callback.valueDescription)
    }

    func testLeaderboardAuthorAcceptedEdgePanReleasesWhenAssemblyNeverStarts() {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-author-activity58", "--qa-page-return", "--qa-header-motion",
                             "--qa-drop-return-assembly-entry", "--qa-return-assembly-delay181",
                             "-autoplay", "NO", "-muted", "YES"])
        mainTabButton("作者榜").tap()
        let row = app.buttons["leaderboard.author.59001"]
        let author = app.otherElements["creator.top-bar"]
        let back = author.buttons["navigation.back"]
        let locks = app.staticTexts["page.interaction-lock"]
        let motion = app.descendants(matching: .any)["page.return-motion.qa"]
        let work = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "media.grid.cell.")).firstMatch
        waitUntil("The leaderboard can open the fixture author") {
            row.isHittable && locks.valueDescription.contains("locks=0")
        }
        row.tap()
        waitUntil("The author grid has finished opening") {
            back.isHittable && work.isHittable && locks.valueDescription.contains("locks=0")
        }

        let initialAcquisitions = heightValues(locks.valueDescription)["acquired"]
        XCTAssertNotNil(initialAcquisitions)
        let window = app.windows.firstMatch
        let origin = window.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.52))
        origin.press(forDuration: 0.05,
                     thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.57, dy: 0.52)),
                     withVelocity: XCUIGestureVelocity(rawValue: 900), thenHoldForDuration: 0)
        waitUntil("The accepted edge returns to the actual leaderboard even though no canvas was assembled") {
            let state = motion.valueDescription
            return state.contains("return-assembly-timeout") && state.contains("assembled=false")
                && state.contains("sourceMasked=false") && !author.exists && row.isHittable
                && locks.valueDescription.contains("locks=0")
        }
        XCTAssertEqual(heightValues(locks.valueDescription)["acquired"], initialAcquisitions)
        XCTAssertTrue(mainTabButton("作者榜").isSelected)
        row.tap()
        waitUntil("The restored leaderboard accepts a real tap to reopen the author") {
            back.isHittable && work.isHittable && locks.valueDescription.contains("locks=0")
        }

        origin.press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 28, dy: 0)),
                     withVelocity: XCUIGestureVelocity(rawValue: 160), thenHoldForDuration: 0)
        waitUntil("A rejected edge before capture keeps the author and releases input") {
            let state = motion.valueDescription
            return state.contains("phase=cancelled") && state.contains("navigationOutcome=cancelled")
                && state.contains("assembled=false") && state.contains("sourceMasked=false")
                && back.isHittable && work.isHittable && locks.valueDescription.contains("locks=0")
        }
        back.tap()
        waitUntil("The author Back button still accepts input after the rejected edge") {
            !author.exists && row.isHittable && locks.valueDescription.contains("locks=0")
        }
    }

    func testLeaderboardAuthorEdgeFollowsFingerWhenLegacyCaptureIsUnavailable() {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-author-activity58", "--qa-page-return", "--qa-header-motion",
                             "--qa-forbid-return-source-capture", "-autoplay", "NO", "-muted", "YES"])
        mainTabButton("作者榜").tap()
        let board = app.otherElements["leaderboard.top-bar"]
        let row = app.buttons["leaderboard.author.59001"]
        let author = app.otherElements["creator.top-bar"]
        let back = author.buttons["navigation.back"]
        let work = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "media.grid.cell.")).firstMatch
        let motion = app.staticTexts.matching(identifier: "page.return-motion.qa").firstMatch
        let locks = app.staticTexts["page.interaction-lock"]
        waitUntil("The leaderboard is ready before opening the author") {
            row.isHittable && board.isHittable && locks.valueDescription.contains("locks=0")
        }
        let boardFrame = board.frame
        let bottomFrame = mainTabBar().frame
        row.tap()
        waitUntil("The author page is ready before either swipe") {
            back.isHittable && work.isHittable && locks.valueDescription.contains("locks=0")
        }
        let authorFrame = author.frame
        let window = app.windows.firstMatch
        let left = window.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.52))
        left.press(forDuration: 0.05, thenDragTo: left.withOffset(CGVector(dx: 34, dy: 0)),
                   withVelocity: XCUIGestureVelocity(rawValue: 75), thenHoldForDuration: 0.40)
        _ = logAuthorReturnMotion("AUTHOR_EDGE_LIVE_SOURCE_AFTER_SHORT", motion)
        waitUntil("The normal short drag cancels and preserves the usable author page",
                  onTimeout: { _ = self.logAuthorReturnMotion("AUTHOR_EDGE_LIVE_SOURCE_CANCEL_TIMEOUT", motion) }) {
            motion.valueDescription.contains("phase=cancelled") && back.isHittable && work.isHittable
                && locks.valueDescription.contains("locks=0")
        }
        let cancelled = logAuthorReturnMotion("AUTHOR_EDGE_LIVE_SOURCE_CANCEL", motion)
        XCTAssertTrue(cancelled.contains("firstMovement=true") && cancelled.contains("heldFinger=true"), cancelled)
        XCTAssertGreaterThan(numericReadback(cancelled)["heldSourceTx"] ?? 0, 12, cancelled)
        XCTAssertEqual(author.frame, authorFrame)
        XCTAssertEqual(mainTabBar().frame, bottomFrame)

        let right = window.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.52))
        let width = window.frame.width
        right.press(forDuration: 0.05, thenDragTo: right.withOffset(CGVector(dx: -width * 0.45, dy: 0)),
                    withVelocity: XCUIGestureVelocity(rawValue: 170), thenHoldForDuration: 1.25)
        _ = logAuthorReturnMotion("AUTHOR_EDGE_LIVE_SOURCE_AFTER_LONG", motion)
        waitUntil("The normal long drag commits to the original leaderboard",
                  onTimeout: { _ = self.logAuthorReturnMotion("AUTHOR_EDGE_LIVE_SOURCE_COMMIT_TIMEOUT", motion) }) {
            motion.valueDescription.contains("phase=completed") && !author.exists && row.isHittable
                && locks.valueDescription.contains("locks=0")
        }
        let committed = logAuthorReturnMotion("AUTHOR_EDGE_LIVE_SOURCE_COMMIT", motion)
        XCTAssertTrue(committed.contains("firstMovement=true") && committed.contains("heldFinger=true"), committed)
        XCTAssertLessThan(numericReadback(committed)["heldSourceTx"] ?? 0, -Double(width * 0.30), committed)
        XCTAssertEqual(board.frame, boardFrame)
        XCTAssertEqual(mainTabBar().frame, bottomFrame)
    }

    func testLeaderboardAuthorEdgeReturnReleasesInputAfterMissingSettlementCompletion() {
        assertLeaderboardAuthorEdgeFaultReleasesInput(
            flag: "--qa-drop-edge-return-settlement-completion", reason: "return-settlement-timeout", right: true)
    }

    func testLeaderboardAuthorPendingReturnInvalidationKeepsAuthor() {
        assertLeaderboardAuthorEdgeFaultReleasesInput(
            flag: "--qa-invalidate-accepted-return-capture", reason: "source-canvas-invalid-after-capture",
            right: false, dragVelocity: XCUIGestureVelocity(rawValue: 500), dragHold: 0.05)
    }

    func testOfflineNavigationDiagnosticsWithAuthorEdgeAndMainDelay() {
        assertLeaderboardAuthorEdgeFaultReleasesInput(
            flag: "--qa-drop-edge-return-settlement-completion", reason: "return-settlement-timeout", right: true,
            extra: ["--qa-navigation-diagnostics", "--qa-navigation-main-delay", "--qa-navigation-observe-shield"])
        XCUIDevice.shared.press(.home)
        waitUntil("The diagnostic app leaves the foreground without a live profiling session", timeout: 5) {
            self.app.state == .runningBackground || self.app.state == .runningBackgroundSuspended
        }
        app.terminate()
        app.launchArguments.removeAll { $0.hasPrefix("--qa-navigation-") }
        app.launch()
        XCTAssertTrue(mainTabButton("作者榜").waitForExistence(timeout: 8))
    }

    private enum AuthorEdgeRecoveryProof {
        case defaultRecovery, touchWatch, nextTouch
    }

    private func assertLeaderboardAuthorEdgeFaultReleasesInput(flag: String, reason: String,
                                                               right: Bool, expectedPhase: String = "aborted", extra: [String] = [],
                                                               verifyNextSwipe: Bool = false,
                                                               recoveryProof: AuthorEdgeRecoveryProof = .defaultRecovery,
                                                               dragVelocity: XCUIGestureVelocity = XCUIGestureVelocity(rawValue: 175),
                                                               dragHold: TimeInterval = 0.90) {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-author-activity58", "--qa-page-return", "--qa-header-motion",
                             "-autoplay", "NO", "-muted", "YES", flag] + extra)
        mainTabButton("作者榜").tap()
        let row = app.buttons["leaderboard.author.59001"]
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
        let header = app.otherElements["creator.top-bar"]
        let back = header.buttons["navigation.back"]
        let locks = app.staticTexts["page.interaction-lock"]
        let firstWork = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "media.grid.cell.")).firstMatch
        waitUntil("The author grid is loaded and actionable before the edge gesture") {
            firstWork.isHittable && back.isHittable && locks.valueDescription.contains("locks=0")
        }
        let backFrame = back.frame
        let initialAcquisitions = heightValues(locks.valueDescription)["acquired"]
        XCTAssertNotNil(initialAcquisitions)
        let window = app.windows.firstMatch
        let motion = app.descendants(matching: .any)["page.return-motion.qa"]
        let origin = window.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.98 : 0.02, dy: 0.52))
        origin.press(forDuration: 0.05,
                     thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.79 : 0.21, dy: 0.52)),
                     withVelocity: dragVelocity, thenHoldForDuration: dragHold)
        print("AUTHOR_EDGE_POST_DRAG reason=\(reason);" + locks.valueDescription + ";" + motion.valueDescription)
        if extra.contains("--qa-navigation-observe-shield") {
            XCTAssertTrue(motion.waitForValueToContain("event=settlement-completion-dropped", timeout: 3), motion.valueDescription)
            let state = motion.valueDescription
            XCTAssertTrue(state.contains("phase=settling") && state.contains("globalBlocked=false"), state)
            XCTAssertEqual(heightValues(locks.valueDescription)["locks"], 0)
        }
        if recoveryProof == .nextTouch {
            // Keep the released gesture in the foreground through four of the old 180 ms checks.
            Thread.sleep(forTimeInterval: 0.75)
            let state = motion.valueDescription
            XCTAssertEqual(app.state, .runningForeground)
            XCTAssertEqual(heightValues(locks.valueDescription)["locks"], 0)
            XCTAssertTrue(state.contains("event=pan-terminal-dropped") && state.contains("globalBlocked=false"), state)
            XCTAssertTrue(state.contains("watchdogRecovered=false"), state)
            XCTAssertTrue(state.contains("sourceWindow=true") && state.contains("navigationOutcome=pending"), state)
            tapScreenFrame(backFrame)
        }
        waitUntil("The fault clears the edge return and keeps the page actionable") {
            let state = motion.valueDescription
            let pageActionable = recoveryProof == .nextTouch ? !header.exists && row.isHittable
                : firstWork.isHittable && back.isHittable
            return state.contains("phase=\(expectedPhase)") && state.contains(reason) &&
                (recoveryProof != .touchWatch || state.contains("watchdogRecovered=true")) &&
                state.contains("sourceMasked=false") && state.contains("globalBlocked=false") &&
                locks.valueDescription.contains("locks=0") && pageActionable
        }
        XCTAssertEqual(heightValues(locks.valueDescription)["acquired"], initialAcquisitions,
                       "The edge return and its recovery must leave window input unshielded")
        print("AUTHOR_EDGE_INPUT_RECOVERED reason=\(reason);" + locks.valueDescription + ";" + motion.valueDescription)
        if recoveryProof == .nextTouch {
            row.tap()
            waitUntil("A real list tap reopens the author without suspending the app") {
                back.isHittable && firstWork.isHittable
            }
        }
        if verifyNextSwipe {
            XCTAssertEqual(app.state, .runningForeground)
            origin.press(forDuration: 0.05,
                         thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.52)),
                         withVelocity: XCUIGestureVelocity(rawValue: 175), thenHoldForDuration: 0.90)
            waitUntil("The next real held edge swipe commits and restores the author list") {
                !header.exists && row.isHittable && locks.valueDescription.contains("locks=0")
            }
            row.tap()
            waitUntil("A real list tap can reopen the author after the next swipe") { back.isHittable && firstWork.isHittable }
        }
        back.tap()
        XCTAssertTrue(header.waitForNonExistence(timeout: 5))
        XCTAssertTrue(row.isHittable, "The next real press works and returns to the author list")
        XCTAssertTrue(locks.valueDescription.contains("locks=0"))
        if verifyNextSwipe {
            mainTabButton("搜索").tap()
            waitUntil("The bottom bar can take a real tap after the recovered return") {
                self.mainTabButton("搜索").isSelected && self.app.otherElements["search.top-bar"].isHittable
            }
        }
    }

    func testContent179AuthorAndCollectionDragAndDetails() {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-height-audit", "--qa-content-performance179", "--qa-header-motion", "--qa-body-motion",
                             "--qa-drag-performance167", "-muted", "YES", "-autoplay", "NO"])
        visualButton("media.author.28037100").tap()
        let window = app.windows.firstMatch
        let qa = app.descendants(matching: .any)["content179.state"]
        let progress = app.buttons["content179.progress"]
        let first = app.buttons["media.grid.cell.179000000"]
        let upper = window.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.30))
        let lower = window.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.73))
        for collection in [false, true] {
            let name = collection ? "collection" : "creator"
            if collection { mainTabButton("收藏").tap() }
            XCTAssertTrue(first.waitForExistence(timeout: 12))
            Thread.sleep(forTimeInterval: 2)
            let grids = app.descendants(matching: .any).matching(identifier: "collection.qa.grid").allElementsBoundByIndex
            print("CONTENT179_GRIDS page=\(name);values=" + grids.map { $0.label }.joined(separator: "|"))
            XCTAssertTrue(grids.contains { $0.label.contains("count=300;") }, "The real accumulated feed must contain 300 decoded-bitmap works")
            let before = qa.valueDescription
            progress.tap()
            Thread.sleep(forTimeInterval: 3)
            print("CONTENT179_IDLE page=\(name);before=\(before);after=\(qa.valueDescription)")
            XCTAssertGreaterThan(heightValues(qa.valueDescription)["ticks"] ?? 0, heightValues(before)["ticks"] ?? 0)
            print("CONTENT179_PHASE page=\(name);phase=drag;epoch=\(Date().timeIntervalSince1970)")
            for _ in 0..<4 {
                lower.press(forDuration: 0.02, thenDragTo: upper, withVelocity: XCUIGestureVelocity(rawValue: 400), thenHoldForDuration: 0.05)
                upper.press(forDuration: 0.02, thenDragTo: lower, withVelocity: XCUIGestureVelocity(rawValue: 400), thenHoldForDuration: 0.05)
            }
            progress.tap()
            print("CONTENT179_PHASE page=\(name);phase=details;epoch=\(Date().timeIntervalSince1970);" + qa.valueDescription)
            waitUntil("The first real work is visible after reverse scrolling") { first.isHittable }
            first.tap()
            let detailsAction = visualButton("media.details.179000000")
            XCTAssertTrue(detailsAction.waitForExistence(timeout: 8))
            for round in 0..<3 {
                detailsAction.tap()
                let details = floatingPageTitle("作品详情")
                XCTAssertTrue(details.waitForExistence(timeout: 5))
                app.buttons["details.back"].tap()
                waitUntil("Details returns to the same real media work") { detailsAction.isHittable && !details.isHittable }
                print("CONTENT179_DETAILS page=\(name);round=\(round);epoch=\(Date().timeIntervalSince1970)")
            }
            let from = window.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5))
            from.press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.5)),
                       withVelocity: XCUIGestureVelocity(rawValue: 180), thenHoldForDuration: 0.1)
            waitUntil("The viewer returns to its retained content grid") { first.isHittable }
            print("CONTENT179_SAMPLE page=\(name);epoch=\(Date().timeIntervalSince1970);state=\(qa.valueDescription);cadence=" + app.staticTexts["performance.cadence172"].valueDescription)
        }
        app.terminate()
    }

    func testContent179FixtureSetupReadback() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-visual-controls", "--qa-height-audit", "--qa-content-performance179",
                               "-app.appearance", "light", "-muted", "YES", "-autoplay", "NO"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let qa = app.descendants(matching: .any)["content179.state"]
        XCTAssertTrue(qa.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 3)
        print("CONTENT179_SETUP " + qa.valueDescription)
        print("CONTENT179_SETUP_AX " + String(app.debugDescription.prefix(6500)))
        XCTAssertTrue(qa.valueDescription.contains("setup=ready;"), qa.valueDescription)
        app.terminate()
    }

    func testPerformance181GridScrollAndCancelledReturn() {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-height-audit", "--qa-content-performance179", "--qa-header-motion",
                             "--qa-body-motion", "--qa-drag-performance167", "--qa-page-return",
                             "-muted", "YES", "-autoplay", "NO"])
        visualButton("media.author.28037100").tap()
        let first = app.buttons["media.grid.cell.179000000"].firstMatch
        waitUntil("The same 300-work local author workload is ready", timeout: 15) { first.isHittable }
        let state = app.descendants(matching: .any)["content179.state"]
        let window = app.windows.firstMatch
        let lower = window.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.73))
        let upper = window.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.30))
        let top = app.otherElements["creator.top-bar"].frame
        func tabBarGeometry() -> CGRect {
            let tabs = mainTabBar()
            if tabs.exists { return tabs.frame }
            return app.descendants(matching: .any)["main.tabs.compact.drawable"].frame
        }
        let bottom = tabBarGeometry()
        print("PERF181_START epoch=\(Date().timeIntervalSince1970);state=" + state.valueDescription
              + ";cadence=" + app.staticTexts["performance.cadence172"].valueDescription)
        for _ in 0..<4 {
            lower.press(forDuration: 0.05, thenDragTo: upper, withVelocity: XCUIGestureVelocity(rawValue: 400), thenHoldForDuration: 0.05)
            upper.press(forDuration: 0.05, thenDragTo: lower, withVelocity: XCUIGestureVelocity(rawValue: 400), thenHoldForDuration: 0.05)
        }
        waitUntil("The same first work returns after the reverse workload") { first.isHittable }
        for _ in 0..<3 {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
                    .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.07, dy: 0.5)),
                       withVelocity: XCUIGestureVelocity(rawValue: 60), thenHoldForDuration: 0.1)
            waitUntil("A short author edge drag keeps its real source and releases input") {
                first.isHittable && self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0")
            }
        }
        print("PERF181_END epoch=\(Date().timeIntervalSince1970);state=" + state.valueDescription
              + ";cadence=" + app.staticTexts["performance.cadence172"].valueDescription)
        XCTAssertEqual(app.otherElements["creator.top-bar"].frame, top)
        XCTAssertEqual(tabBarGeometry(), bottom)
        attachScreenshot(named: "performance181-author-scroll-and-cancel")
        app.terminate()
    }

    func testRoot181RejectedBeforeReadyDoesNotReplayMovement() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-theme-timeline", "--qa-header-motion", "--qa-body-motion",
                               "--qa-root-motion181", "--qa-root-layout-mismatch175", "-app.appearance", "light",
                               "-muted", "YES", "-autoplay", "NO", "-timeline.presentation", "stream"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(timelineTools().waitForExistence(timeout: 10))
        func idle() {
            waitUntil("The real source controls release their transition lease") {
                self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0")
            }
        }
        for title in ["搜索", "时间线", "作者榜"] { mainTabButton(title).tap(); idle() }
        let header = rootHeader181("作者榜")
        let top = header.frame, bottom = mainTabBar().frame
        let motion = app.staticTexts["root.motion181.qa"]
        let body = app.staticTexts["body.motion.qa"]
        let window = app.windows.firstMatch
        for right in [false, true] {
            let before = rootMotionFields181(motion.valueDescription)
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.98 : 0.02, dy: 0.5))
            start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: right ? -12 : 12, dy: 0)),
                        withVelocity: XCUIGestureVelocity(rawValue: 600), thenHoldForDuration: 0)
            waitUntil("A rejected gesture restores the source without waiting for the late target") {
                body.valueDescription.contains("kind=tab-edge") && body.valueDescription.contains("phase=cancelled")
                    && self.mainTabButton("作者榜").isSelected
                    && self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0")
            }
            let after = rootMotionFields181(motion.valueDescription)
            XCTAssertEqual(after["pair"], before["pair"], "No new body pair starts after this short gesture has ended")
            XCTAssertEqual(after["tokens"], before["tokens"])
            XCTAssertEqual(header.frame, top)
            XCTAssertEqual(mainTabBar().frame, bottom)
            XCTAssertTrue(header.isHittable)
        }
        mainTabButton("搜索").tap(); idle()
        XCTAssertTrue(rootHeader181("搜索").isHittable, "The next real root switch remains usable")
        app.terminate()
    }

    func testPerformance181RootEdgesAndTimelineLanes() {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-height-audit", "--qa-content-performance179", "--qa-header-motion",
                             "--qa-body-motion", "--qa-drag-performance167", "-muted", "YES", "-autoplay", "NO"])
        let window = app.windows.firstMatch
        let bottom = mainTabBar().frame
        let state = app.descendants(matching: .any)["content179.state"]
        let cadence = app.staticTexts["performance.cadence172"]
        func idle() {
            waitUntil("The root transition releases its input lease") {
                let locks = self.app.staticTexts["page.interaction-lock"]
                return locks.exists && locks.valueDescription.contains("locks=0")
            }
        }
        func select(_ title: String) {
            mainTabButton(title).tap()
            waitUntil("The root selection is \(title)") { self.mainTabButton(title).isSelected }
            idle()
        }
        for title in ["作者榜", "搜索", "收藏", "时间线"] { select(title) }
        let source = app.otherElements["timeline.source"]
        let media = app.otherElements["timeline.media-kind"]
        for title in ["关注", "推荐"] { source.buttons[title].tap(); idle() }
        for title in ["视频", "图片"] { media.buttons[title].tap(); idle() }
        let startState = state.valueDescription
        let startCadence = cadence.valueDescription
        print("PERFROOT181_START epoch=\(Date().timeIntervalSince1970);state=" + startState + ";cadence=" + startCadence)
        for _ in 0..<2 {
            for title in ["作者榜", "搜索", "收藏", "时间线"] { select(title) }
        }
        select("作者榜")
        for (right, target) in [(true, "搜索"), (true, "收藏"), (false, "搜索"), (false, "作者榜")] {
            window.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.98 : 0.02, dy: 0.5))
                .press(forDuration: 0.05,
                       thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                       withVelocity: XCUIGestureVelocity(rawValue: 180), thenHoldForDuration: 0.1)
            waitUntil("The accepted root edge selects \(target)") { self.mainTabButton(target).isSelected }
            idle()
        }
        for right in [false, true] {
            let from = window.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.98 : 0.02, dy: 0.5))
            from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: right ? -20 : 20, dy: 0)),
                       withVelocity: XCUIGestureVelocity(rawValue: 60), thenHoldForDuration: 0.1)
            idle()
            XCTAssertTrue(mainTabButton("作者榜").isSelected)
        }
        select("时间线")
        for _ in 0..<2 {
            for upper in [true, false] {
                let target = upper ? (source.buttons["关注"].isSelected ? "推荐" : "关注")
                    : (media.buttons["视频"].isSelected ? "图片" : "视频")
                window.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: upper ? 0.34 : 0.58))
                    .press(forDuration: 0.05,
                           thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: upper ? 0.34 : 0.58)),
                           withVelocity: XCUIGestureVelocity(rawValue: 180), thenHoldForDuration: 0.1)
                waitUntil("The timeline edge selects \(target)") { (upper ? source : media).buttons[target].isSelected }
                idle()
            }
        }
        let end = Date().timeIntervalSince1970
        print("PERFROOT181_END epoch=\(end);state=" + state.valueDescription + ";cadence=" + cadence.valueDescription)
        XCTAssertEqual(mainTabBar().frame, bottom)
        XCTAssertTrue(mainTabButton("时间线").isSelected)
        app.terminate()
    }

    func testRootEdgesSwitchAndCancel165() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "--qa-theme-timeline",
                               "--qa-header-motion", "--qa-body-motion", "--qa-root-motion181", "-app.appearance", "light",
                               "-muted", "YES", "-autoplay", "NO", "-timeline.presentation", "stream"]
        app.launch()
        XCTAssertTrue(timelineTools().waitForExistence(timeout: 10))
        let bottom = mainTabBar().frame
        let window = app.windows.firstMatch
        let body = app.staticTexts["body.motion.qa"]
        let rootMotion = app.staticTexts["root.motion181.qa"]
        func idle() {
            waitUntil("Root body releases its input lease") {
                self.app.descendants(matching: .any)["page.interaction-lock"].valueDescription.contains("locks=0")
            }
        }
        for route in [("作者榜", "搜索", false), ("搜索", "作者榜", true),
                      ("收藏", "时间线", false), ("作者榜", "时间线", true)] {
            mainTabButton(route.0).tap()
            idle()
            let tokensBeforeGesture = rootMotionFields181(rootMotion.valueDescription)["tokens"] ?? ""
            let rootHeader = rootHeader181(route.0)
            let headerFrame = rootHeader.frame
            let bodyGeometry = heightValues(body.valueDescription)
            let from = window.coordinate(withNormalizedOffset: CGVector(dx: route.2 ? 0.02 : 0.98, dy: 0.5))
            let cancel = window.coordinate(withNormalizedOffset: CGVector(dx: route.2 ? 0.09 : 0.91, dy: 0.5))
            from.press(forDuration: 0.05, thenDragTo: cancel,
                       withVelocity: XCUIGestureVelocity(rawValue: 100), thenHoldForDuration: 0.15)
            idle()
            XCTAssertTrue(mainTabButton(route.0).isSelected, "Short drag must keep source")
            waitUntil("The short drag records a cancelled host-pair flight") {
                let fields = self.rootMotionFields181(rootMotion.valueDescription)
                return fields["outcome"] == "cancelled" && (Int(fields["moveSamples"] ?? "0") ?? 0) > 0
            }
            let cancelled = rootMotionFields181(rootMotion.valueDescription)
            XCTAssertEqual(cancelled["outcome"], "cancelled", rootMotion.valueDescription)
            XCTAssertEqual(cancelled["selected"], rootTabID181(route.0), rootMotion.valueDescription)
            XCTAssertGreaterThan(Int(cancelled["moveSamples"] ?? "0") ?? 0, 0, rootMotion.valueDescription)
            XCTAssertEqual(tokenValue181(tokensBeforeGesture, tab: Int(rootTabID181(route.0)) ?? -1),
                           tokenValue181(cancelled["tokens"] ?? "", tab: Int(rootTabID181(route.0)) ?? -1), rootMotion.valueDescription)
            XCTAssertEqual(rootHeader.frame, headerFrame)
            from.press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                       withVelocity: XCUIGestureVelocity(rawValue: 180), thenHoldForDuration: 0.1)
            waitUntil("Accepted root edge selects target exactly once") { self.mainTabButton(route.1).isSelected }
            idle()
            XCTAssertTrue(body.valueDescription.contains("kind=tab-edge"), body.valueDescription)
            XCTAssertTrue(body.valueDescription.contains("phase=completed"), body.valueDescription)
            let motion = rootMotionFields181(rootMotion.valueDescription)
            XCTAssertEqual(motion["source"], rootTabID181(route.0), rootMotion.valueDescription)
            XCTAssertEqual(motion["destination"], rootTabID181(route.1), rootMotion.valueDescription)
            XCTAssertEqual(motion["outcome"], "completed", rootMotion.valueDescription)
            XCTAssertEqual(motion["selected"], rootTabID181(route.1), rootMotion.valueDescription)
            XCTAssertEqual(motion["visibleSlots"], rootTabID181(route.1), rootMotion.valueDescription)
            XCTAssertGreaterThan(Int(motion["slotCount"] ?? "0") ?? 0, 0, rootMotion.valueDescription)
            XCTAssertLessThanOrEqual(Int(motion["slotCount"] ?? "99") ?? 99, 4, rootMotion.valueDescription)
            XCTAssertEqual(motion["sourceHidden"], "1", rootMotion.valueDescription)
            XCTAssertEqual(motion["targetHidden"], "0", rootMotion.valueDescription)
            XCTAssertGreaterThan(Int(motion["moveSamples"] ?? "0") ?? 0, 0, rootMotion.valueDescription)
            XCTAssertGreaterThan(Double(motion["maxMoveSourceX"] ?? "0") ?? 0, 0.5, rootMotion.valueDescription)
            XCTAssertGreaterThan(Double(motion["maxMoveTargetX"] ?? "0") ?? 0, 0.5, rootMotion.valueDescription)
            XCTAssertTrue(motion["lastEndpoint"]?.contains("selected=\(rootTabID181(route.1))") == true, rootMotion.valueDescription)
            XCTAssertEqual(tokenValue181(motion["tokens"] ?? "", tab: Int(rootTabID181(route.1)) ?? -1),
                           motion["destinationToken"], rootMotion.valueDescription)
            XCTAssertEqual(tokenValue181(tokensBeforeGesture, tab: Int(rootTabID181(route.0)) ?? -1),
                           tokenValue181(motion["tokens"] ?? "", tab: Int(rootTabID181(route.0)) ?? -1), rootMotion.valueDescription)
            XCTAssertEqual(mainTabBar().frame, bottom)
            XCTAssertEqual(heightValues(body.valueDescription)["top"] ?? -1, bodyGeometry["top"] ?? -2, accuracy: 1,
                           "The content viewport remains below the fixed header")
            XCTAssertEqual(heightValues(body.valueDescription)["bottom"] ?? -1, bodyGeometry["bottom"] ?? -2, accuracy: 1,
                           "The content viewport remains above the fixed footer")
            print("ROOT165 source=\(route.0);target=\(route.1);" + body.valueDescription)
            print("ROOT181 source=\(route.0);target=\(route.1);" + rootMotion.valueDescription)
            attachScreenshot(named: "root165-\(route.0)-\(route.1)")
        }
    }

    func testRootTabsAllHaveBodyTransitions164() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "--qa-theme-timeline",
                               "--qa-header-motion", "--qa-body-motion", "--qa-root-motion181", "-app.appearance", "light",
                               "-muted", "YES", "-autoplay", "NO", "-timeline.presentation", "stream"]
        app.launch()
        XCTAssertTrue(timelineTools().waitForExistence(timeout: 10))
        let bottom = mainTabBar().frame
        let rootMotion = app.staticTexts["root.motion181.qa"]
        XCTAssertTrue(rootMotion.waitForExistence(timeout: 5))
        let bodyQA = app.staticTexts["body.motion.qa"]
        let canvas = app.windows.firstMatch.frame
        var seenHostTokens: [String: String] = [:]
        func transition(to title: String) {
            let previous = rootMotionFields181(rootMotion.valueDescription)
            let sourceTitle = ["作者榜", "搜索", "收藏", "时间线"].first { mainTabButton($0).isSelected } ?? "时间线"
            mainTabButton(title).tap()
            waitUntil("The real root host pair completes the selected tab handoff") {
                let fields = self.rootMotionFields181(rootMotion.valueDescription)
                return self.mainTabButton(title).isSelected && fields["pair"] != previous["pair"] && fields["outcome"] == "completed"
            }
            let fields = rootMotionFields181(rootMotion.valueDescription)
            XCTAssertEqual(fields["source"], rootTabID181(sourceTitle), rootMotion.valueDescription)
            XCTAssertEqual(fields["destination"], rootTabID181(title), rootMotion.valueDescription)
            XCTAssertEqual(fields["selected"], rootTabID181(title), rootMotion.valueDescription)
            XCTAssertEqual(fields["visibleSlots"], rootTabID181(title), rootMotion.valueDescription)
            XCTAssertGreaterThan(Int(fields["slotCount"] ?? "0") ?? 0, 0, rootMotion.valueDescription)
            XCTAssertLessThanOrEqual(Int(fields["slotCount"] ?? "99") ?? 99, 4, rootMotion.valueDescription)
            XCTAssertEqual(fields["sourceHidden"], "1", rootMotion.valueDescription)
            XCTAssertEqual(fields["targetHidden"], "0", rootMotion.valueDescription)
            XCTAssertGreaterThan(Int(fields["moveSamples"] ?? "0") ?? 0, 0, rootMotion.valueDescription)
            XCTAssertGreaterThan(Double(fields["maxMoveSourceX"] ?? "0") ?? 0, 0.5, rootMotion.valueDescription)
            XCTAssertGreaterThan(Double(fields["maxMoveTargetX"] ?? "0") ?? 0, 0.5, rootMotion.valueDescription)
            XCTAssertTrue(fields["lastEndpoint"]?.contains("selected=\(rootTabID181(title))") == true, rootMotion.valueDescription)
            let destinationTab = Int(rootTabID181(title)) ?? -1
            let destinationToken = tokenValue181(fields["tokens"] ?? "", tab: destinationTab)
            XCTAssertEqual(destinationToken, fields["destinationToken"], rootMotion.valueDescription)
            if let priorToken = seenHostTokens[rootTabID181(title)] {
                XCTAssertEqual(destinationToken, priorToken, "The retained root host token must survive later routes")
            }
            if let destinationToken { seenHostTokens[rootTabID181(title)] = destinationToken }
            waitUntil("The tab handoff releases input") {
                self.app.descendants(matching: .any)["page.interaction-lock"].valueDescription.contains("locks=0")
            }
            XCTAssertEqual(mainTabBar().frame, bottom)
            for prefix in ["source", "target"] {
                XCTAssertEqual(Double(fields[prefix + "Width"] ?? "-1") ?? -1, canvas.width, accuracy: 1)
                XCTAssertEqual(Double(fields[prefix + "Height"] ?? "-1") ?? -1, canvas.height, accuracy: 1,
                               "The actual canvas extends behind both floating bars")
                XCTAssertEqual(Double(fields[prefix + "Y"] ?? "999") ?? 999, 0, accuracy: 1,
                               "Header clearance changes do not translate the whole page vertically")
            }
            print("TAB181 source=\(sourceTitle);destination=\(title);" + rootMotion.valueDescription)
        }
        for title in ["作者榜", "搜索", "收藏", "时间线", "收藏", "搜索", "作者榜", "时间线"] {
            transition(to: title)
            let qa = app.staticTexts["body.motion.qa"]
            print("TAB164_CURRENT title=\(title);" + qa.valueDescription)
            waitUntil("Every root tab has a completed body handoff") {
                qa.valueDescription.contains("kind=tab") && qa.valueDescription.contains("phase=completed")
            }
            let values = heightValues(qa.valueDescription)
            XCTAssertEqual(values["snapshotAvailable"], 0, "The root pair uses retained host views: " + qa.valueDescription)
            XCTAssertEqual(values["targetSnapshotAvailable"], 0, "The root pair has no target page snapshot: " + qa.valueDescription)
            XCTAssertEqual(mainTabBar().frame, bottom)
            print("TAB164_BODY_METADATA title=\(title);" + qa.valueDescription)
        }
        for _ in 0..<3 { transition(to: "作者榜"); transition(to: "时间线") }
        print("ROOT181_PIXEL_REVIEW intermediate host-pair texture continuity requires external silent screen recording; UIView transform readback is not GPU frame evidence")
    }

    func testEdgeReturnIdentityClearsHoldingAndHandoff165() {
        for hold in [true, false] {
            visualLaunch(width: 0, large: false, landscape: false,
                         extra: ["--qa-body-motion", "--qa-header-motion", "--qa-page-return", "--qa-body-identity164"] + (hold ? ["--qa-body-identity-hold164"] : []))
            let identity = app.staticTexts["body.identity.qa"]
            let initial = identity.label
            visualButton("media.author.28037100").tap()
            XCTAssertTrue(app.descendants(matching: .any)["creator.top-bar"].waitForExistence(timeout: 5))
            let window = app.windows.firstMatch
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.48))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.48)))
            waitUntil("Identity actually changes during the edge body phase") { identity.label != initial }
            let body = app.staticTexts["body.motion.qa"]
            waitUntil("Identity invalidation cancels the old body pixels") { body.valueDescription.contains("phase=cancelled") }
            waitUntil("The old account's leases are released") {
                self.app.descendants(matching: .any)["page.interaction-lock"].valueDescription.contains("locks=0")
            }
            print("BODY164_IDENTITY hold=\(hold);" + body.valueDescription)
            app.terminate()
        }
    }

    func testFloatingChromeRootCanvas173() { runFloatingChromeRootCanvas173(dark: false) }
    func testFloatingChromeDarkRootCanvas173() { runFloatingChromeRootCanvas173(dark: true) }
    private func runFloatingChromeRootCanvas173(dark: Bool) {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-author-activity58", "--qa-floating173", "--qa-header-motion", "-app.appearance", dark ? "dark" : "light", "-muted", "YES", "-autoplay", "NO"]
        XCUIDevice.shared.orientation = .portrait; app.launch()
        for tab in [2, 4, 3, 0] {
            let tabButton = app.buttons[tab == 0 ? "main.tab.timeline" : "main.tab.\(tab)"]
            tabButton.tap()
            let qa = app.staticTexts["page.canvas173"]
            waitUntil("The selected root publishes its full canvas after releasing transition input") {
                tabButton.isSelected && qa.exists && qa.valueDescription.contains("canvasY=") &&
                self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0")
            }
            let values = heightValues(qa.valueDescription)
            print("FLOAT173_ROOT tab=\(tab);" + qa.valueDescription)
            XCTAssertEqual(values["canvasY"] ?? -999, 0, accuracy: 1)
            XCTAssertEqual(values["canvasBottom"] ?? -999, app.windows.firstMatch.frame.height, accuracy: 1)
            XCTAssertLessThan(mainTabBar().frame.maxY, app.windows.firstMatch.frame.height - 1)
            if tab == 2 {
                let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "leaderboard.author.")).firstMatch
                XCTAssertTrue(first.waitForExistence(timeout: 10))
                let firstID = first.identifier, firstY = first.frame.minY
                XCTAssertGreaterThanOrEqual(firstY, (values["readingY"] ?? 0) - 1)
                XCTAssertLessThanOrEqual(firstY, (values["readingY"] ?? 0) + 20)
                app.swipeUp()
                let original = app.buttons[firstID]
                waitUntil("The real long ranking scrolls under its fixed chrome") { !original.exists || original.frame.minY < firstY - 60 }
                attachScreenshot(named: "floating173-authors-scrolled-under-bars-" + (dark ? "dark" : "light"))
                print("FLOAT173_SCROLLED " + qa.valueDescription)
            }
        }
    }

    func testReturnPromotionFailureRestoresSource172() {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-page-return", "--qa-header-motion", "--qa-return-promotion-fails172", "-autoplay", "NO", "-muted", "YES"])
        visualButton("media.author.28037100").tap()
        let header = app.descendants(matching: .any)["creator.top-bar"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.48))
            .press(forDuration: 0.05,
                   thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.48)),
                   withVelocity: XCUIGestureVelocity(rawValue: 180), thenHoldForDuration: 0.1)
        let qa = app.descendants(matching: .any)["page.return-motion.qa"]
        waitUntil("A failed promotion cancels before navigation and releases input") {
            qa.valueDescription.contains("return-promotion-capture-failed") &&
            self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0")
        }
        XCTAssertTrue(header.exists)
        XCTAssertTrue(header.buttons["navigation.back"].isHittable)
        header.buttons["navigation.back"].tap()
        XCTAssertTrue(header.waitForNonExistence(timeout: 5))
        XCTAssertTrue(timelineTools().isHittable)
    }

    func testAuthor183ReturnsAfterForegroundFromTimelineAndLeaderboard() {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-page-return", "--qa-header-motion", "-autoplay", "NO", "-muted", "YES"])
        let authorBar = app.otherElements["creator.top-bar"]
        let locks = app.staticTexts["page.interaction-lock"]
        func reactivate() {
            XCUIDevice.shared.press(.home)
            waitUntil("The app must leave the foreground", timeout: 5) {
                self.app.state == .runningBackground || self.app.state == .runningBackgroundSuspended
            }
            app.activate()
        }
        reactivate()
        for fromLeaderboard in [false, true] {
            if fromLeaderboard {
                mainTabButton("作者榜").tap()
                let row = app.buttons["leaderboard.author.28037001"]
                XCTAssertTrue(row.waitForExistence(timeout: 8))
                row.tap()
            } else {
                visualButton("media.author.28037100").tap()
            }
            XCTAssertTrue(authorBar.waitForExistence(timeout: 5))
            XCTAssertTrue(locks.waitForValueToContain("locks=0", timeout: 3))
            let back = authorBar.buttons["navigation.back"]
            XCTAssertTrue(back.isHittable, "The author's Back button is reachable before reactivation")
            reactivate()
            print("AUTHOR183_RESUME fromLeaderboard=\(fromLeaderboard);application=\(app.state.rawValue);back=\(back.isHittable);" + locks.valueDescription)
            XCTAssertTrue(locks.waitForValueToContain("locks=0", timeout: 3))
            let window = app.windows.firstMatch
            let right = fromLeaderboard
            window.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.98 : 0.02, dy: 0.48))
                .press(forDuration: 0.05,
                       thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.45 : 0.55, dy: 0.48)),
                       withVelocity: XCUIGestureVelocity(rawValue: 180), thenHoldForDuration: 0.1)
            XCTAssertTrue(authorBar.waitForNonExistence(timeout: 5),
                          app.staticTexts["page.return-motion.qa"].valueDescription)
            if fromLeaderboard { XCTAssertTrue(app.otherElements["leaderboard.top-bar"].exists) }
            else { XCTAssertTrue(timelineTools().isHittable) }
            XCTAssertTrue(locks.waitForValueToContain("locks=0", timeout: 3))
            print("AUTHOR183_FOREGROUND source=\(fromLeaderboard ? "leaderboard" : "timeline");edge=\(right ? "right" : "left");" + locks.valueDescription)
        }
    }

    func testLeaderboardAuthorAcceptsInputWhileFirstPageIsPending() {
        assertLeaderboardAuthorAcceptsInputWhileLoading(dropPushCompletion: false)
    }

    func testLeaderboardAuthorAcceptsInputAfterMissingPushCompletion() {
        assertLeaderboardAuthorAcceptsInputWhileLoading(dropPushCompletion: true)
    }

    private func assertLeaderboardAuthorAcceptsInputWhileLoading(dropPushCompletion: Bool) {
        let fault = dropPushCompletion ? ["--qa-drop-native-push-completion"] : []
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-author-activity58", "--qa-author-paging176", "--qa-hold-author-first-page",
                             "--qa-header-motion", "--qa-drag-performance167", "-muted", "YES", "-autoplay", "NO"] + fault)
        mainTabButton("作者榜").tap()
        let row = app.buttons["leaderboard.author.59001"]
        let state = app.staticTexts["author176.state"]
        let locks = app.staticTexts["page.interaction-lock"]
        let header = app.otherElements["creator.top-bar"]
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        XCTAssertTrue(locks.waitForValueToContain("locks=0", timeout: 3))
        let beforeOpening = heightValues(locks.valueDescription)["acquired"]
        row.tap()
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        XCTAssertTrue(state.waitForValueToContain("requests=1", timeout: 5), state.valueDescription)
        XCTAssertTrue(locks.waitForValueToContain("locks=0", timeout: 3), locks.valueDescription)
        let afterOpening = heightValues(locks.valueDescription)["acquired"]
        XCTAssertNotNil(beforeOpening)
        XCTAssertEqual(afterOpening, beforeOpening, "A native push never installs an extra window-wide input shield")
        print("AUTHOR_NATIVE_PUSH_INPUT fault=\(dropPushCompletion);before=\(beforeOpening ?? -1);after=\(afterOpening ?? -1)")
        XCTAssertTrue(state.valueDescription.contains("committed=0"))
        let cadence = app.staticTexts["performance.cadence172"].valueDescription
        print("AUTHOR_ENTRY_CADENCE_186 fault=\(dropPushCompletion);cadence=" + cadence)
        if dropPushCompletion {
            let sample = try? JSONSerialization.jsonObject(with: Data(cadence.utf8)) as? [String: Any]
            let cost = sample?["cost174"] as? [String: Any]
            let totals = cost?["totals"] as? [String: [Double]]
            XCTAssertEqual(totals?["nativeHeader.pushCompletionDropped"]?.first, 1)
            XCTAssertEqual(totals?["nativeHeader.deadline"]?.first, 1)
        }
        let video = header.buttons["视频"]
        XCTAssertTrue(video.isHittable)
        video.tap()
        XCTAssertTrue(state.waitForValueToContain("requests=2", timeout: 5), state.valueDescription)
        XCTAssertTrue(video.isSelected)
        XCTAssertTrue(locks.waitForValueToContain("locks=0", timeout: 3), locks.valueDescription)
        XCTAssertTrue(state.valueDescription.contains("committed=0"))
        let back = header.buttons["navigation.back"]
        XCTAssertTrue(back.isHittable)
        print("AUTHOR_LOADING_CAN_INTERACT fault=\(dropPushCompletion);" + state.valueDescription + ";" + locks.valueDescription)
        back.tap()
        XCTAssertTrue(header.waitForNonExistence(timeout: 5))
        XCTAssertTrue(locks.waitForValueToContain("locks=0", timeout: 3))
        XCTAssertTrue(state.valueDescription.contains("committed=0"))
        XCTAssertTrue(row.isHittable)
        app.buttons["leaderboard.author.59002"].tap()
        XCTAssertTrue(header.waitForExistence(timeout: 5), "The board accepts a second author while the first request was held")
    }

    func testLeaderboardAuthorReturnRestoresTheActualList() {
        assertLeaderboardAuthorReturn(restoringAfterDroppedCompletion: false)
    }

    func testLeaderboardAuthorReturnSurvivesMissingNativeCompletion() {
        assertLeaderboardAuthorReturn(restoringAfterDroppedCompletion: true)
    }

    private func assertLeaderboardAuthorReturn(restoringAfterDroppedCompletion: Bool) {
        let injected = restoringAfterDroppedCompletion ? ["--qa-drop-native-pop-completion"] : []
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-author-activity58", "--qa-page-return", "--qa-header-motion",
                             "--qa-drag-performance167", "-muted", "YES", "-autoplay", "NO"] + injected)
        mainTabButton("作者榜").tap()
        let first = app.buttons["leaderboard.author.59001"]
        let second = app.buttons["leaderboard.author.59002"]
        let author = app.otherElements["creator.top-bar"]
        let locks = app.staticTexts["page.interaction-lock"]
        let cadence = app.staticTexts["performance.cadence172"]
        guard first.waitForExistence(timeout: 8), locks.waitForValueToContain("locks=0", timeout: 3) else {
            XCTFail("The 1,000-row author board needs to accept input before return testing")
            return
        }
        let initialY = first.frame.minY
        func edge(_ right: Bool, cancelling: Bool = false) {
            let window = app.windows.firstMatch
            let from = window.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.98 : 0.02, dy: 0.48))
            let to = cancelling
                ? from.withOffset(CGVector(dx: right ? -34 : 34, dy: 0))
                : window.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.43 : 0.57, dy: 0.48))
            from.press(forDuration: 0.05, thenDragTo: to,
                       withVelocity: XCUIGestureVelocity(rawValue: cancelling ? 75 : 200), thenHoldForDuration: 0.12)
        }
        func nativeEventCount(_ name: String) -> Double {
            guard let sample = try? JSONSerialization.jsonObject(with: Data(cadence.valueDescription.utf8)) as? [String: Any],
                  let cost = sample["cost174"] as? [String: Any], let totals = cost["totals"] as? [String: [Double]] else { return 0 }
            return totals[name]?.first ?? 0
        }
        for (index, method) in (restoringAfterDroppedCompletion ? ["button", "button"] : ["button", "left", "right"]).enumerated() {
            first.tap()
            XCTAssertTrue(author.waitForExistence(timeout: 5))
            XCTAssertTrue(locks.waitForValueToContain("locks=0", timeout: 3))
            if method == "left" {
                let acquired = heightValues(locks.valueDescription)["acquired"]
                XCTAssertNotNil(acquired)
                edge(true, cancelling: true)
                let motion = app.staticTexts["page.return-motion.qa"]
                XCTAssertTrue(motion.waitForValueToContain("phase=cancelled", timeout: 3), motion.valueDescription)
                XCTAssertTrue(locks.waitForValueToContain("locks=0", timeout: 3))
                XCTAssertEqual(heightValues(locks.valueDescription)["acquired"], acquired)
                XCTAssertTrue(author.buttons["navigation.back"].isHittable, "Cancelled gesture leaves the author operable")
            }
            let before = heightValues(locks.valueDescription)["acquired"]
            XCTAssertNotNil(before)
            if method == "button" { author.buttons["navigation.back"].tap() }
            else { edge(method == "right") }
            XCTAssertTrue(author.waitForNonExistence(timeout: 5), app.staticTexts["page.return-motion.qa"].valueDescription)
            XCTAssertTrue(locks.waitForValueToContain("locks=0", timeout: 3), locks.valueDescription)
            let after = heightValues(locks.valueDescription)["acquired"]
            XCTAssertEqual(after, before, "Back and edge return both leave window input unshielded")
            XCTAssertTrue(first.isHittable)
            XCTAssertEqual(first.frame.minY, initialY, accuracy: 2)
            if restoringAfterDroppedCompletion {
                XCTAssertEqual(nativeEventCount("nativeHeader.popCompletionDropped"), Double(index + 1))
                XCTAssertEqual(nativeEventCount("nativeHeader.deadline"), Double(index + 1))
            }
            print("LEADERBOARD_AUTHOR_RETURN method=\(method);fault=\(restoringAfterDroppedCompletion);" + locks.valueDescription + ";" + cadence.valueDescription)
        }
        second.tap()
        XCTAssertTrue(author.waitForExistence(timeout: 5), "The returned ranking accepts a new row action")
    }

    func testAuthor183MissingLiveAcknowledgementDoesNotBlockInput() {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-page-return", "--qa-header-motion", "--qa-drop-author-live-ack183",
                             "-autoplay", "NO", "-muted", "YES"])
        visualButton("media.author.28037100").tap()
        let authorBar = app.otherElements["creator.top-bar"]
        XCTAssertTrue(authorBar.waitForExistence(timeout: 5))
        let locks = app.staticTexts["page.interaction-lock"]
        guard locks.waitForValueToContain("locks=0", timeout: 3) else {
            XCTFail("A lost visual acknowledgement must not leave a window-wide input shield: " + locks.valueDescription)
            return
        }
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.48))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.48)),
                   withVelocity: XCUIGestureVelocity(rawValue: 180), thenHoldForDuration: 0.1)
        XCTAssertTrue(authorBar.waitForNonExistence(timeout: 5))
        XCTAssertTrue(timelineTools().isHittable)
        XCTAssertTrue(locks.waitForValueToContain("locks=0", timeout: 3))
    }

    func testEdgeReturnWithoutPlatformReceiptRestoresSourceInput() {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-page-return", "--qa-header-motion", "--qa-drop-edge-return-action",
                             "-autoplay", "NO", "-muted", "YES"])
        visualButton("media.author.28037100").tap()
        let authorBar = app.otherElements["creator.top-bar"]
        XCTAssertTrue(authorBar.waitForExistence(timeout: 5))
        let locks = app.staticTexts["page.interaction-lock"]
        XCTAssertTrue(locks.waitForValueToContain("locks=0", timeout: 3))
        let window = app.windows.firstMatch
        func dragBack() {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.48))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.48)),
                       withVelocity: XCUIGestureVelocity(rawValue: 180), thenHoldForDuration: 0.1)
        }
        dragBack()
        let motion = app.staticTexts["page.return-motion.qa"]
        XCTAssertTrue(motion.waitForValueToContain("return-navigation-receipt-timeout", timeout: 6),
                      motion.valueDescription)
        XCTAssertTrue(motion.valueDescription.contains("navigationOutcome=pending"))
        XCTAssertTrue(locks.waitForValueToContain("locks=0", timeout: 3), locks.valueDescription)
        XCTAssertTrue(authorBar.buttons["navigation.back"].isHittable)
        dragBack()
        XCTAssertTrue(authorBar.waitForNonExistence(timeout: 5), motion.valueDescription)
        XCTAssertTrue(timelineTools().isHittable)
        XCTAssertTrue(locks.waitForValueToContain("locks=0", timeout: 3))
    }

    func testEdgeReturnAwaitingPlatformReceiptYieldsToFirstBottomTabTap() throws {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-page-return", "--qa-header-motion", "--qa-drop-edge-return-action",
                             "--qa-hold-edge-navigation-receipt", "-autoplay", "NO", "-muted", "YES"])
        visualButton("media.author.28037100").tap()
        let back = app.otherElements["creator.top-bar"].buttons["navigation.back"]
        let locks = app.staticTexts["page.interaction-lock"]
        let search = mainTabButton("搜索")
        waitUntil("The author and bottom tab are actionable before the edge gesture") {
            back.isHittable && search.isHittable && locks.valueDescription.contains("locks=0")
        }
        let target = search.frame
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.48))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.48)),
                   withVelocity: XCUIGestureVelocity(rawValue: 180), thenHoldForDuration: 0.1)
        let motion = app.staticTexts["page.return-motion.qa"]
        XCTAssertTrue(motion.waitForValueToContain("event=return-action-dropped", timeout: 3), motion.valueDescription)
        let pending = rootMotionFields181(motion.valueDescription)
        XCTAssertEqual(pending["phase"], "awaitingDisappearance")
        XCTAssertEqual(pending["navigationOutcome"], "pending")
        XCTAssertEqual(pending["globalBlocked"], "false")
        let receipt = try XCTUnwrap(pending["receipt"])

        tapScreenFrame(target)
        let field = app.textFields["search-title-input"]
        waitUntil("The first tab tap switches to Search before the pending return deadline", timeout: 4) {
            search.isSelected && field.isHittable && locks.valueDescription.contains("locks=0")
        }
        let superseded = rootMotionFields181(motion.valueDescription)
        XCTAssertEqual(superseded["receipt"], receipt)
        XCTAssertEqual(superseded["reason"], "return-visual-superseded")
        XCTAssertEqual(superseded["navigationOutcome"], "pending")

        let elapsed = expectation(description: "The six-second return receipt deadline passes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.2) { elapsed.fulfill() }
        wait(for: [elapsed], timeout: 8)
        XCTAssertTrue(search.isSelected)
        XCTAssertTrue(field.isHittable)
        XCTAssertEqual(rootMotionFields181(motion.valueDescription)["reason"], "return-visual-superseded")
        field.tap()
        field.typeText("new tab")
        XCTAssertEqual(field.value as? String, "new tab")
    }

    func testCommittedEdgeReturnHandoffYieldsFirstBackToDestination() throws {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-page-return", "--qa-header-motion", "--qa-hold-committed-edge-handoff",
                             "-autoplay", "NO", "-muted", "YES"])
        openAccountSettings()
        let settings = floatingPageTitle("账号与设置")
        let targetBack = settings.buttons["navigation.back"]
        let downloads = app.buttons["settings.downloads"]
        waitUntil("Account settings is ready before opening download settings") {
            targetBack.isHittable && downloads.isHittable
        }
        let targetFrame = targetBack.frame
        tapAboveMainBar(downloads)
        let source = floatingPageTitle("下载设置")
        waitUntil("Download settings is the current page") {
            source.buttons["navigation.back"].isHittable && self.app.switches["downloads.wifi-only"].isHittable
        }

        let window = app.windows.firstMatch
        let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.52))
        edge.press(forDuration: 0.05,
                   thenDragTo: edge.withOffset(CGVector(dx: window.frame.width * 0.45, dy: 0)),
                   withVelocity: XCUIGestureVelocity(rawValue: 180), thenHoldForDuration: 0.1)
        let motion = app.staticTexts["page.return-motion.qa"]
        XCTAssertTrue(motion.waitForValueToContain("event=committed-handoff-held", timeout: 5), motion.valueDescription)
        let committed = rootMotionFields181(motion.valueDescription)
        XCTAssertEqual(committed["phase"], "revealing")
        XCTAssertEqual(committed["navigationOutcome"], "committed")
        XCTAssertEqual(committed["visualOutcome"], "pending")
        XCTAssertEqual(committed["globalBlocked"], "false")
        XCTAssertFalse(source.exists)
        let receipt = try XCTUnwrap(committed["receipt"])

        tapScreenFrame(targetFrame)
        let account = app.buttons["timeline.account"]
        waitUntil("The first Back tap during handoff returns from account settings to the timeline", timeout: 4) {
            account.isHittable && !settings.exists
        }
        let superseded = rootMotionFields181(motion.valueDescription)
        XCTAssertEqual(superseded["receipt"], receipt)
        XCTAssertEqual(superseded["navigationOutcome"], "committed")
        XCTAssertEqual(superseded["reason"], "return-visual-superseded")

        account.tap()
        waitUntil("A fresh account settings route is live before the old handoff resumes", timeout: 4) {
            targetBack.isHittable && downloads.isHittable
        }
        XCTAssertFalse(motion.valueDescription.contains("lateCommittedHandoffRejected=true"))
        XCTAssertTrue(motion.waitForValueToContain("lateCommittedHandoffRejected=true", timeout: 9), motion.valueDescription)
        let late = rootMotionFields181(motion.valueDescription)
        XCTAssertEqual(late["receipt"], receipt)
        XCTAssertEqual(late["navigationOutcome"], "committed")
        XCTAssertEqual(late["reason"], "return-visual-superseded")
        XCTAssertTrue(targetBack.isHittable && downloads.isHittable)
    }

    func testAuthorDragAndButtonReturnHandoff164() {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-page-return", "--qa-header-motion", "-autoplay", "NO", "-muted", "YES"])
        let bottom = mainTabBar().frame
        let window = app.windows.firstMatch
        let timeline = timelineTools()
        let header = app.otherElements.matching(identifier: "creator.top-bar").firstMatch
        let back = header.buttons.matching(identifier: "navigation.back").firstMatch
        let motion = app.staticTexts.matching(identifier: "page.return-motion.qa").firstMatch
        let locks = app.staticTexts["page.interaction-lock"]
        for video in [false, true] {
            app.otherElements["timeline.media-kind"].buttons[video ? "视频" : "图片"].tap()
            let id = video ? 28_037_102 : 28_037_100
            waitUntil("The requested work is visible") { self.watchFocus() == id }
            for edge in [0, 1, 2] {
                visualButton("media.author.\(id)").tap()
                let label = "AUTHOR164 video=\(video);edge=\(edge)"
                waitUntil("The active author page accepts input before returning", timeout: 5,
                          onTimeout: { _ = self.logAuthorReturnMotion(label + ";entry-timeout", motion) }) {
                    back.isHittable && locks.valueDescription.contains("locks=0")
                }
                if edge > 0 {
                    window.coordinate(withNormalizedOffset: CGVector(dx: edge == 1 ? 0.98 : 0.02, dy: 0.48))
                        .press(forDuration: 0.05,
                               thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: edge == 1 ? 0.45 : 0.55, dy: 0.48)),
                               withVelocity: XCUIGestureVelocity(rawValue: 180), thenHoldForDuration: 0.1)
                    _ = logAuthorReturnMotion(label + ";post-drag", motion)
                } else { back.tap() }
                waitUntil("Return restores input to the real timeline", timeout: 5, onTimeout: {
                    _ = self.logAuthorReturnMotion(label + ";return-timeout", motion)
                    print("\(label);authorHeaderExists=\(header.exists);authorBackHittable=\(back.isHittable);timelineHittable=\(timeline.isHittable);\(locks.valueDescription)")
                }) {
                    timeline.isHittable && !back.isHittable && locks.valueDescription.contains("locks=0")
                }
                if edge > 0 {
                    let state = logAuthorReturnMotion(label + ";returned", motion)
                    XCTAssertTrue(state.contains("navigationOutcome=committed") && state.contains("phase=completed"), state)
                    XCTAssertTrue(state.contains("sharedHeader=true"), "Same-geometry author return must actually use the shared chrome progress: " + state)
                    XCTAssertTrue(state.contains("footerProtected=true"), "The accepted return must own its fixed footer until the live handoff: " + state)
                    if video {
                        XCTAssertTrue(state.contains("mediaCanvasProtected=true"), "Media return must own captured playback pixels across the complete window: " + state)
                    }
                }
                XCTAssertEqual(mainTabBar().frame, bottom)
                XCTAssertEqual(watchFocus(), id)
                attachScreenshot(named: "author164-return-\(video ? "video" : "image")-\(edge == 0 ? "button" : edge == 1 ? "right" : "left")")
            }
        }
    }

    func testTimelinePortraitVideoMovesBehindFixedHeader163() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "--qa-theme-timeline",
                               "--qa-pager-touch-trace", "-app.appearance", "dark", "-muted", "YES",
                               "-autoplay", "YES", "-timeline.presentation", "stream"]
        XCUIDevice.shared.orientation = .portrait; app.launch()
        XCTAssertTrue(timelineTools().waitForExistence(timeout: 10))
        heightCloseNotices()
        let picker = app.otherElements["timeline.media-kind"]
        picker.buttons["视频"].tap()
        waitUntil("Portrait video is the live timeline") { self.watchFocus() == 28_037_102 }
        let header = timelineTools()
        let headerFrame = header.frame, footerFrame = mainTabBar().frame
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.72))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -30, dy: 0)),
                    withVelocity: XCUIGestureVelocity(rawValue: 90), thenHoldForDuration: 0.3)
        let qa = app.descendants(matching: .any)["timeline.page-motion.qa"]
        waitUntil("The under-header video returns after a short drag") { qa.valueDescription.contains("phase=cancelled") }
        let values = heightValues(qa.valueDescription)
        print("TIMELINE163_CANVAS " + qa.valueDescription)
        XCTAssertLessThanOrEqual(values["canvasTop"] ?? 9999, headerFrame.minY)
        XCTAssertGreaterThanOrEqual(values["canvasBottom"] ?? 0, footerFrame.minY)
        XCTAssertTrue(qa.valueDescription.contains("windowHosted=false"))
        XCTAssertGreaterThan(values["settleFrames"] ?? 0, 1)
        XCTAssertEqual(header.frame, headerFrame); XCTAssertEqual(mainTabBar().frame, footerFrame)
        start.press(forDuration: 0.05,
                    thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.72)),
                    withVelocity: XCUIGestureVelocity(rawValue: 180), thenHoldForDuration: 0.1)
        waitUntil("The lower edge completes a media switch") { picker.buttons["图片"].isSelected }
        XCTAssertEqual(header.frame, headerFrame); XCTAssertEqual(mainTabBar().frame, footerFrame)
        attachScreenshot(named: "timeline163-fixed-header-after-video-swipe")
    }

    func testTimelineEdgeSwipeUsesStartingHalf() {
        visualLaunch(width: 0, large: false, landscape: false, extra: ["--qa-pager-touch-trace", "-muted", "YES", "-autoplay", "YES"])
        let source = app.otherElements["timeline.source"], media = app.otherElements["timeline.media-kind"]
        let window = app.windows.firstMatch
        func drag(from x: CGFloat, _ y: CGFloat, to endX: CGFloat, _ endY: CGFloat) {
            window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: endX, dy: endY)))
        }
        XCTAssertTrue(source.buttons["推荐"].isSelected && media.buttons["图片"].isSelected)
        let initialX = heightDeck().frame.minX
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.34))
            .press(forDuration: 0.05,
                   thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.02 + 40 / window.frame.width, dy: 0.34)),
                   withVelocity: XCUIGestureVelocity(rawValue: 90), thenHoldForDuration: 0.35)
        let motion = app.descendants(matching: .any)["timeline.page-motion.qa"]
        XCTAssertTrue(motion.waitForExistence(timeout: 5))
        waitUntil("The cancelled body preview finishes its spring back") { motion.valueDescription.contains("phase=cancelled") }
        let rendered = heightValues(motion.valueDescription)
        print("TIMELINE_RENDERED_MOTION " + motion.valueDescription)
        XCTAssertGreaterThan(rendered["peak"] ?? 0, 8, "The rendered source copy must follow before release")
        XCTAssertGreaterThan(rendered["settleFrames"] ?? 0, 1, "Release must render intermediate positions")
        XCTAssertGreaterThan(rendered["settleTravel"] ?? 0, 5)
        XCTAssertGreaterThan(rendered["blocked"] ?? 0, 0)
        XCTAssertEqual(heightDeck().frame.minX, initialX, accuracy: 1, "Only the visual body copy moves; the player and fixed bars keep their geometry")
        waitUntil("A short drag must settle back on the same timeline") {
            source.buttons["推荐"].isSelected && abs(self.heightDeck().frame.minX - initialX) < 1
        }
        drag(from: 1 - 36 / window.frame.width, 0.41, to: 0.22, 0.55)
        XCTAssertTrue(source.buttons["推荐"].isSelected, "A drag outside the edge band must not switch timelines")
        drag(from: 1 - 28 / window.frame.width, 0.41, to: 0.22, 0.55)
        waitUntil("Dragging left from recommendation wraps to following even across the midpoint") {
            source.buttons["关注"].isSelected && self.watchFocus() == 28_037_100
        }
        XCTAssertTrue(media.buttons["图片"].isSelected)
        drag(from: 0.98, 0.34, to: 0.28, 0.34)
        waitUntil("Repeating the same swipe cycles back to recommendation") {
            source.buttons["推荐"].isSelected && self.watchFocus() == 28_037_100
        }
        drag(from: 0.02, 0.34, to: 0.72, 0.34)
        waitUntil("Swiping right can also enter following") {
            source.buttons["关注"].isSelected && self.watchFocus() == 28_037_100
        }

        drag(from: 0.02, 0.56, to: 0.78, 0.42)
        waitUntil("Dragging right from images wraps to video even across the midpoint") { media.buttons["视频"].isSelected }
        XCTAssertTrue(source.buttons["关注"].isSelected)
        waitPlayingFixture()
        drag(from: 0.98, 0.57, to: 0.22, 0.57)
        waitUntil("Dragging left from video wraps to the first image") {
            media.buttons["图片"].isSelected && self.watchFocus() == 28_037_100
        }
        drag(from: 0.98, 0.57, to: 0.22, 0.57)
        waitUntil("Repeating the same swipe cycles back to video") { media.buttons["视频"].isSelected }
        XCTAssertTrue(source.buttons["关注"].isSelected)
        waitPlayingFixture()
        drag(from: 0.02, 0.34, to: 0.72, 0.34)
        attachEdgeTrace("upper-video-wrap")
        waitUntil("Dragging right from following wraps to recommendation") { source.buttons["推荐"].isSelected }
        XCTAssertTrue(media.buttons["图片"].isSelected, "Each source keeps its media selection")
    }

    func testTimelineKeepsWarmCoverUntilOriginalArrives() throws {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-timeline-cover-handoff", "--qa-pager-touch-trace",
                             "-wifiVideoPrefetch", "NO", "-muted", "YES", "-autoplay", "NO"])
        let picker = app.otherElements["timeline.media-kind"]
        picker.buttons["视频"].tap()
        waitUntil("Video is active before dragging to the neighboring image") {
            picker.buttons["视频"].isSelected && self.watchFocus() == 28_037_102
        }

        let window = app.windows.firstMatch
        let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.69))
        edge.press(forDuration: 0.05,
                   thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.23, dy: 0.69)),
                   withVelocity: XCUIGestureVelocity(rawValue: 230), thenHoldForDuration: 0.12)
        let motion = app.staticTexts["timeline.page-motion.qa"]
        waitUntil("The edge preview has been removed and the real image is focused") {
            picker.buttons["图片"].isSelected && self.watchFocus() == 28_037_100
                && motion.valueDescription.contains("phase=completed")
        }

        let center = CGRect(x: window.frame.midX - 8, y: window.frame.midY - 8, width: 16, height: 16)
        let pending = try XCTUnwrap(floating45MeanRGB(captureChromePixels(named: "timeline-cover-handoff-original-held"), in: center))
        XCTAssertGreaterThan(pending[0], pending[1] + 40, "The real page should show the warmed purple image while the blue original waits. RGB \(pending)")
        XCTAssertGreaterThan(pending[2], pending[1] + 80, "The purple cover should be visible past the animation. RGB \(pending)")
        XCTAssertTrue(app.staticTexts["media.qa.parent-ready"].valueDescription.contains("ready=false"))

        let page = app.descendants(matching: .any)["media-page-28037100"].firstMatch
        page.swipeUp()
        waitUntil("The next image takes focus while the previous original is still held") {
            self.watchFocus() == 28_037_101 && self.app.staticTexts["media.qa.parent-ready"].valueDescription.contains("ready=true")
        }
        let advanced = try XCTUnwrap(floating45MeanRGB(captureChromePixels(named: "timeline-cover-handoff-next-work"), in: center))
        XCTAssertGreaterThan(advanced[1], advanced[0] + 70, "The next work must show its own green original. RGB \(advanced)")
        app.descendants(matching: .any)["media-page-28037101"].firstMatch.swipeDown()
        waitUntil("The prior image is still waiting for its original") {
            self.watchFocus() == 28_037_100 && self.app.staticTexts["media.qa.parent-ready"].valueDescription.contains("ready=false")
        }

        app.buttons["timeline-cover.qa.release"].tap()
        waitUntil("The original now qualifies as ready") {
            self.watchFocus() == 28_037_100 && self.app.staticTexts["media.qa.parent-ready"].valueDescription.contains("ready=true")
        }
        let original = try XCTUnwrap(floating45MeanRGB(captureChromePixels(named: "timeline-cover-handoff-original-ready"), in: center))
        XCTAssertGreaterThan(original[2], original[0] + 120, "The loaded blue original should replace the purple cover. RGB \(original)")
        print("TIMELINE_COVER_HANDOFF held=\(pending) next=\(advanced) original=\(original)")
    }

    func testTimelineMissingSettlementReleasesInputForNextSwitch() {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-drop-timeline-settlement", "--qa-pager-touch-trace",
                             "--qa-header-motion", "-muted", "YES", "-autoplay", "NO"])
        let source = app.otherElements["timeline.source"]
        let media = app.otherElements["timeline.media-kind"]
        let motion = app.staticTexts["timeline.page-motion.qa"]
        let locks = app.staticTexts["page.interaction-lock"]
        var previousFlight: String?
        func verifyRecovered() {
            func flightID() -> String? {
                motion.valueDescription.split(separator: ";").first(where: { $0.hasPrefix("flight=") }).map(String.init)
            }
            waitUntil("This timeline action recovers from its own missing callback", timeout: 4) {
                motion.valueDescription.contains("reason=settlement-timeout") && flightID() != nil && flightID() != previousFlight
            }
            previousFlight = flightID()
            XCTAssertTrue(motion.valueDescription.contains("phase=completed"), motion.valueDescription)
            XCTAssertTrue(locks.waitForValueToContain("locks=0", timeout: 3), locks.valueDescription)
            print("TIMELINE_SETTLEMENT_RECOVERY " + motion.valueDescription + ";" + locks.valueDescription)
        }
        media.buttons["视频"].tap()
        verifyRecovered()
        XCTAssertTrue(media.buttons["视频"].isSelected)

        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.34))
            .press(forDuration: 0.05,
                   thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.44, dy: 0.34)),
                   withVelocity: XCUIGestureVelocity(rawValue: 180), thenHoldForDuration: 0.15)
        verifyRecovered()
        XCTAssertTrue(source.buttons["关注"].isSelected)
        mainTabButton("作者榜").tap()
        XCTAssertTrue(app.otherElements["leaderboard.top-bar"].waitForExistence(timeout: 5))
        XCTAssertTrue(locks.waitForValueToContain("locks=0", timeout: 3))
        mainTabButton("时间线").tap()
        waitUntil("The live timeline can still be entered") { source.buttons["关注"].isHittable }
    }

    func testTimelineFirstPageStopsAtTheBeginning() {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-pager-touch-trace", "-muted", "YES", "-autoplay", "NO"])
        let probe = app.staticTexts["pager.qa.trace"]
        guard let before = try? JSONSerialization.jsonObject(with: Data(probe.valueDescription.utf8)) as? [String: Any],
              let marker = before["lastSequence"] as? Int,
              let offset = ((before["current"] as? [String: Any])?["offset"] as? [String: Double])?["y"] else {
            XCTFail("Missing initial native pager frame"); return
        }
        let frame = heightDeck().frame
        let top = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.minY + frame.height * 0.3))
        let bottom = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.minY + frame.height * 0.7))
        top.press(forDuration: 0.05, thenDragTo: bottom,
                  withVelocity: XCUIGestureVelocity(rawValue: 240), thenHoldForDuration: 0.35)
        guard let after = try? JSONSerialization.jsonObject(with: Data(probe.valueDescription.utf8)) as? [String: Any],
              let events = after["events"] as? [[String: Any]] else {
            XCTFail("Missing first-page drag samples"); return
        }
        let held = events.filter {
            ($0["sequence"] as? Int ?? 0) > marker && $0["event"] as? String == "native.leadingBoundaryGate" && $0["state"] as? Int == 2
        }
        XCTAssertFalse(held.isEmpty, "The test must hold a real drag against the first page")
        for event in held {
            guard let native = event["native"] as? [String: Any],
                  let pageY = (native["displayedRelativeFrame"] as? [String: Double])?["y"],
                  let scrollY = (native["offset"] as? [String: Double])?["y"] else {
                XCTFail("Missing actual held page position"); continue
            }
            XCTAssertEqual(pageY, 0, accuracy: 1)
            XCTAssertEqual(scrollY, offset, accuracy: 1)
        }
        XCTAssertEqual(watchFocus(), 28_037_100)
        heightDeck().swipeUp()
        waitUntil("The first page can still advance") { self.watchFocus() == 28_037_101 }
        heightDeck().swipeDown()
        waitUntil("The second page can still go back") { self.watchFocus() == 28_037_100 }
    }

    private func floating44BlueFraction(_ screenshot: UIImage?, in frame: CGRect) -> Double? {
        guard let image = screenshot?.cgImage, app.frame.width > 0, app.frame.height > 0 else { return nil }
        let sx = CGFloat(image.width) / app.frame.width, sy = CGFloat(image.height) / app.frame.height
        let crop = CGRect(x: (frame.minX - app.frame.minX) * sx, y: (frame.minY - app.frame.minY) * sy, width: frame.width * sx, height: frame.height * sy).integral
        guard let region = image.cropping(to: crop), region.width > 0, region.height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: region.width * region.height * 4)
        guard let context = CGContext(data: &bytes, width: region.width, height: region.height, bitsPerComponent: 8, bytesPerRow: region.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(region, in: CGRect(x: 0, y: 0, width: region.width, height: region.height))
        let blue = stride(from: 0, to: bytes.count, by: 4).filter { Int(bytes[$0 + 2]) > Int(bytes[$0]) + 20 && bytes[$0 + 2] > 120 }.count
        return Double(blue) / Double(region.width * region.height)
    }

    private func floating45MeanRGB(_ screenshot: UIImage?, in frame: CGRect) -> [Double]? {
        guard let image = screenshot?.cgImage, app.frame.width > 0, app.frame.height > 0 else { return nil }
        let sx = CGFloat(image.width) / app.frame.width, sy = CGFloat(image.height) / app.frame.height
        let crop = CGRect(x: (frame.minX - app.frame.minX) * sx, y: (frame.minY - app.frame.minY) * sy, width: frame.width * sx, height: frame.height * sy).integral
        guard let region = image.cropping(to: crop), region.width > 0, region.height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: region.width * region.height * 4)
        guard let context = CGContext(data: &bytes, width: region.width, height: region.height, bitsPerComponent: 8, bytesPerRow: region.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(region, in: CGRect(x: 0, y: 0, width: region.width, height: region.height))
        return (0..<3).map { channel in Double(stride(from: channel, to: bytes.count, by: 4).reduce(0) { $0 + Int(bytes[$1]) }) / Double(region.width * region.height) }
    }

    func testSettingsHeaderIsCompactOnEntryAndAfterTabReturn() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-style49", "--qa-header-motion", "-app.appearance", "dark", "-muted", "YES"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        openAccountSettings()
        assertCompactSettingsHeader(phase: "initial-dark")
        mainTabButton("收藏").tap()
        waitUntil("Collection tab settles before switching back") {
            self.mainTabButton("收藏").isSelected && (!self.app.staticTexts["page.interaction-lock"].exists || self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0"))
        }
        mainTabButton("时间线").tap()
        waitUntil("Settings route returns with root transition complete") {
            self.mainTabButton("时间线").isSelected && self.floatingPageTitle("账号与设置").isHittable && self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0")
        }
        assertCompactSettingsHeader(phase: "return-from-timeline-dark")
        app.swipeDown()
        assertCompactSettingsHeader(phase: "after-pull-down-dark")
        app.terminate()
    }

    func testSegmentedCenterSwipesWrapBothDirectionsWithoutMovingChrome() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-segment-edge", "-app.appearance", "light", "-muted", "YES", "-autoplay", "NO"]
        XCUIDevice.shared.orientation = .portrait; app.launch()
        mainTabButton("作者榜").tap()
        let board = app.otherElements["leaderboard.board"]
        XCTAssertTrue(board.waitForExistence(timeout: 5))
        board.buttons["Seasonal"].tap()
        let header = app.otherElements["leaderboard.top-bar"].frame, bottom = mainTabBar().frame
        for (index, right) in [true, true, false, false].enumerated() {
            swipeSegmentCenter(right: right)
            XCTAssertTrue(board.buttons[index % 2 == 0 ? "Legacy" : "Seasonal"].isSelected)
            XCTAssertEqual(app.otherElements["leaderboard.top-bar"].frame, header)
            XCTAssertEqual(mainTabBar().frame, bottom)
        }
        mainTabButton("收藏").tap()
        let media = app.otherElements["collection.media-kind"]
        XCTAssertTrue(media.waitForExistence(timeout: 5)); media.buttons["图片"].tap()
        let collectionHeader = app.otherElements["collections.top-bar"].frame
        for (index, right) in [true, true, false, false].enumerated() {
            swipeSegmentCenter(right: right)
            XCTAssertTrue(media.buttons[index % 2 == 0 ? "视频" : "图片"].isSelected)
            XCTAssertEqual(app.otherElements["collections.top-bar"].frame, collectionHeader)
            XCTAssertEqual(mainTabBar().frame, bottom)
        }
        app.terminate()
    }

    func testUnifiedMenuCommandsContextAndConfirmation() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "-app.appearance", "light", "-muted", "YES", "-autoplay", "NO", "-timeline.presentation", "stream"]
        XCUIDevice.shared.orientation = .portrait; app.launch()
        let timeline = mainTabButton("时间线")
        XCTAssertTrue(timeline.waitForExistence(timeout: 8)); timeline.tap()
        XCTAssertTrue(timelineTools().waitForExistence(timeout: 8))
        timelineTools().tap()
        let recent = app.buttons["最近浏览"]
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(recent.frame.height, 44 - 0.01)
        XCTAssertLessThanOrEqual(recent.frame.width, 240)
        XCTAssertEqual(app.menus.count, 0)
        attachScreenshot(named: "unified-menu-commands")
        recent.tap()
        let history = floatingPageTitle("最近浏览")
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        let record = app.buttons["history.item.28037100"]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        record.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["history-batch.delete"].waitForExistence(timeout: 5))
        XCTAssertTrue(history.isHittable, "Long press must not open the work")
        XCTAssertTrue(record.exists)
        app.buttons["history-batch.delete"].tap()
        XCTAssertTrue(app.staticTexts["删除 1 条记录？"].waitForExistence(timeout: 5))
        app.scrollViews["app-menu.options"].buttons["取消"].tap()
        XCTAssertTrue(record.exists)
        app.buttons["history-batch.delete"].tap()
        app.buttons["删除"].tap()
        XCTAssertTrue(record.waitForNonExistence(timeout: 5))
        let survivor = app.buttons["history.item.28037101"]
        XCTAssertTrue(survivor.exists, "Deleting selected records preserves unselected history")
        history.buttons["history.actions"].tap()
        app.buttons["清空浏览历史"].tap()
        let clear = app.buttons["清空"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(clear.frame.height, 44 - 0.01)
        XCTAssertEqual(app.alerts.count, 0)
        attachScreenshot(named: "unified-menu-confirmation")
        app.scrollViews["app-menu.options"].buttons["取消"].tap()
        XCTAssertTrue(survivor.waitForExistence(timeout: 5))
        history.buttons["history.actions"].tap()
        app.buttons["清空浏览历史"].tap()
        XCTAssertTrue(clear.waitForExistence(timeout: 5)); clear.tap()
        XCTAssertTrue(survivor.waitForNonExistence(timeout: 5))
        app.terminate()
        visualLaunch(width: 0, large: false, landscape: false, extra: ["-muted", "YES", "-autoplay", "NO"])
        let favorite = visualButton("favorite-28037100")
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        let label = favorite.label
        favorite.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["favorite.manage"].waitForExistence(timeout: 5))
        attachScreenshot(named: "unified-menu-context")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.45)).tap()
        XCTAssertEqual(favorite.label, label, "Long press must not toggle the favorite")
        openFavoriteFolders(favorite)
        let editor = floatingPageTitle("收藏图片")
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.buttons["取消"].tap()
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        XCTAssertEqual(favorite.label, label)
        favorite.tap()
        waitUntil("Ordinary favorite tap still works") { favorite.label != label }
        app.terminate()
    }

    func testUnifiedContextTagsAndOfflineKeepPrimaryAction() {
        visualLaunch(width: 0, large: false, landscape: false, extra: ["--qa-details-tags", "-muted", "YES", "-autoplay", "NO"])
        visualButton("media.details.28037100").tap()
        let tag = app.buttons["details.tag.portrait"]
        XCTAssertTrue(tag.waitForExistence(timeout: 5))
        let before = tag.valueDescription
        tag.press(forDuration: 0.7)
        let block = app.buttons.matching(NSPredicate(format: "label IN %@", ["屏蔽此标签", "撤销屏蔽"])).firstMatch
        XCTAssertTrue(block.waitForExistence(timeout: 5))
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.8)).tap()
        XCTAssertEqual(tag.valueDescription, before, "Long press must not select a tag")
        tag.tap()
        waitUntil("A normal tag tap still changes selection") { tag.valueDescription != before }
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "-app.appearance", "dark", "-muted", "YES", "-autoplay", "NO"]
        app.launch()
        XCTAssertTrue(mainTabButton("时间线").waitForExistence(timeout: 8))
        openAccountSettings()
        heightTap(app.buttons["settings.offline-library"])
        let header = floatingPageTitle("离线收藏与空间")
        let row = app.buttons["offline.item.28037100"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["删除此本地副本"].waitForExistence(timeout: 5))
        attachScreenshot(named: "unified-menu-offline-context")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.8)).tap()
        XCTAssertTrue(header.isHittable, "Long press must not open offline playback")
        row.tap()
        XCTAssertTrue(app.buttons["offline.playback.close"].waitForExistence(timeout: 5))
        app.terminate()
    }

    func testUnifiedMenuKeyboardAndSharePresentation() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-tag-availability55", "--qa-theme-ui", "-app.appearance", "light", "-muted", "YES", "-autoplay", "NO"]
        XCUIDevice.shared.orientation = .portrait; app.launch()
        mainTabButton("搜索").tap()
        let tagPicker = app.buttons["search-tag-picker"]
        waitUntil("Search header has handed input back to its real controls") { tagPicker.isHittable }
        tagPicker.tap()
        let input = app.textFields["tag-search-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let prefix = app.buttons["tag-directory.prefix"]
        XCTAssertTrue(prefix.waitForExistence(timeout: 5)); prefix.tap()
        let letter = app.buttons["B"]
        XCTAssertTrue(letter.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(letter.frame.maxY, app.keyboards.firstMatch.frame.minY)
        attachScreenshot(named: "unified-menu-keyboard")
        letter.tap()
        XCTAssertEqual(input.value as? String, "b")
        floatingPageTitle("选择标签").buttons["navigation.back"].tap()
        mainTabButton("作者榜").tap()
        heightTap(app.buttons["leaderboard.author.28037001"])
        let authorActions = app.buttons["creator.actions"]
        waitUntil("Author header has handed input back to its real controls") { authorActions.isHittable }
        authorActions.tap()
        let share = app.buttons["creator.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 5)); share.tap()
        let copy = app.cells.matching(NSPredicate(format: "label == %@ OR label == %@ OR label == %@", "Copy", "拷贝", "复制")).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 8), "Sharing must survive closing the temporary menu")
        attachScreenshot(named: "unified-menu-share")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.9)).tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["creator.actions"].isHittable)
        app.buttons["creator.actions"].tap()
        let external = app.buttons["creator.open-site"]
        XCTAssertTrue(external.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(external.frame.height, 44 - 0.01)
        external.tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 8))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))
        let returned = app.buttons["creator.actions"]
        let restored = returned.waitForExistence(timeout: 8)
        if !restored { print("MENU_LINK_RETURN " + app.debugDescription) }
        attachScreenshot(named: "unified-menu-browser-return")
        XCTAssertTrue(restored && returned.isHittable)
        app.terminate()
    }

    func testAppValueSelectorCommitsAndCancelsInBothOrientations() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-style49", "-app.appearance", "light", "-muted", "YES", "-civitviewer.automaticRotation", "YES"]
        app.launch()
        mainTabButton("作者榜").tap()
        let trigger = app.buttons["leaderboard.recent-filter"]
        XCTAssertTrue(trigger.waitForExistence(timeout: 5))
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let landscape = orientation == .landscapeLeft
            let direction = NSPredicate { _, _ in
                let frame = self.app.windows.firstMatch.frame
                return (frame.width > frame.height) == landscape
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: direction, object: nil)], timeout: 5), .completed)
            XCTAssertGreaterThanOrEqual(trigger.frame.height, 44 - 0.01)
            trigger.tap()
            let option = app.buttons["value-selector.option.month"]
            XCTAssertTrue(option.waitForExistence(timeout: 5))
            XCTAssertGreaterThanOrEqual(option.frame.height, 44 - 0.01)
            XCTAssertEqual(app.pickers.count, 0, "Value choices use app rows, not a system picker")
            attachScreenshot(named: "app-selector-\(orientation.rawValue)")
            option.tap()
            XCTAssertTrue(trigger.waitForValueToContain("近 30 天", timeout: 5))
            trigger.tap()
            let selected = app.buttons["value-selector.option.month"]
            XCTAssertTrue(selected.waitForExistence(timeout: 5))
            attachScreenshot(named: "app-selector-reopened-\(orientation.rawValue)")
            XCTAssertTrue(selected.isSelected)
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.8)).tap()
            XCTAssertTrue(selected.waitForNonExistence(timeout: 5))
            XCTAssertTrue(trigger.waitForValueToContain("近 30 天", timeout: 5))
        }
        app.terminate()
    }

    func testSettingsHeaderRemainsVisibleAfterChildAndAppearanceChanges() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-style49", "-app.appearance", "light", "-muted", "YES"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        openAccountSettings()
        assertCompactSettingsHeader(phase: "initial-light")
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "账号内容偏好")).firstMatch.tap()
        XCTAssertTrue(floatingPageTitle("账号内容偏好").waitForExistence(timeout: 5))
        let back = app.buttons["navigation.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5)); back.tap()
        assertCompactSettingsHeader(phase: "return-from-account-preferences")
        let favoritesLink = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "我的收藏")).firstMatch
        XCTAssertTrue(favoritesLink.isHittable)
        favoritesLink.tap()
        let favorites = app.otherElements["collections.top-bar"]
        XCTAssertTrue(favorites.waitForExistence(timeout: 5))
        let favoritesBack = favorites.buttons["navigation.back"]
        XCTAssertTrue(favoritesBack.waitForExistence(timeout: 5))
        favoritesBack.tap()
        XCTAssertTrue(floatingPageTitle("账号与设置").waitForExistence(timeout: 5))

        // A launch-argument preference remains authoritative for that process.
        // Relaunch without the fixed light override before changing the real picker.
        app.terminate()
        app.launchArguments = ["--qa-collection-paging", "--qa-style49", "-muted", "YES"]
        app.launch()
        chooseAppearance("浅色")
        chooseAppearance("深色")
        assertCompactSettingsHeader(phase: "after-appearance-change")
        app.terminate()
    }

    private func assertCompactSettingsHeader(phase: String, file: StaticString = #filePath, line: UInt = #line) {
        let bar = floatingPageTitle("账号与设置")
        let title = bar.staticTexts["账号与设置"]
        let header = app.staticTexts["Civitai 账号"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(header.waitForExistence(timeout: 5), file: file, line: line)
        attachScreenshot(named: "settings54-\(phase)")
        print("SETTINGS54_LAYOUT phase=\(phase);bar=\(bar.frame);title=\(title.frame);header=\(header.frame);titleHittable=\(title.isHittable)")
        XCTAssertTrue(title.exists && title.isHittable, "Title must be visible before any pull-down", file: file, line: line)
        XCTAssertLessThanOrEqual(bar.frame.height, 60, "Settings must use a compact navigation title rather than reserve a large-title region", file: file, line: line)
        XCTAssertGreaterThanOrEqual(header.frame.minY, bar.frame.maxY - 1, "First section must be below the navigation bar", file: file, line: line)
        XCTAssertLessThanOrEqual(header.frame.minY - bar.frame.maxY, 56, "First section must not have another empty top reservation", file: file, line: line)
    }

    func testSettingsTagsAndPresetLayoutInBothOrientations() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-theme-ui", "--qa-style48",
                               "-app.appearance", "dark", "-civitviewer.automaticRotation", "YES", "-muted", "YES"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        func waitForWindow(landscape: Bool) {
            waitUntil("The ordinary page has the requested window orientation") {
                let frame = self.app.windows.firstMatch.frame
                return frame.width > 0 && frame.height > 0 && (frame.width > frame.height) == landscape
            }
        }

        openAccountSettings()
        let settings = floatingPageTitle("账号与设置")
        let refresh = settings.buttons["settings.account.refresh"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 5))
        XCTAssertFalse(settings.buttons["settings.rotation.toggle"].exists)
        attachScreenshot(named: "settings-font-and-refresh-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForWindow(landscape: true)
        XCTAssertTrue(refresh.isHittable)
        XCTAssertEqual(refresh.frame.midY, settings.buttons["navigation.back"].frame.midY, accuracy: 1)
        attachScreenshot(named: "settings-font-and-refresh-landscape")

        mainTabButton("搜索").tap()
        let tags = app.buttons["search-tag-picker"]
        XCTAssertTrue(tags.waitForExistence(timeout: 5)); tags.tap()
        let picker = floatingPageTitle("选择标签")
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(picker.buttons["navigation.back"].isHittable && picker.buttons["完成"].isHittable)
        attachScreenshot(named: "tag-picker-landscape")
        XCUIDevice.shared.orientation = .portrait
        waitForWindow(landscape: false)
        XCTAssertTrue(picker.buttons["navigation.back"].isHittable)
        attachScreenshot(named: "tag-picker-portrait")
        picker.buttons["navigation.back"].tap()

        let field = app.textFields["search-title-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("City")
        app.buttons["search.presets"].tap()
        let saveCurrent = app.buttons["preset.library.save"]
        waitUntil("The preset library completes its header handoff") { saveCurrent.isHittable }
        saveCurrent.tap()
        let editor = floatingPageTitle("保存条件")
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["preset.name.range"].exists)
        attachScreenshot(named: "save-conditions-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForWindow(landscape: true)
        XCTAssertTrue(editor.buttons["preset.name.save"].isHittable)
        attachScreenshot(named: "save-conditions-landscape")
        editor.buttons["navigation.back"].tap()
        XCTAssertTrue(floatingPageTitle("已存条件 · 搜索").waitForExistence(timeout: 5))
    }

    func testBlockedCreatorProfilePreview() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "--qa-body-motion", "-app.appearance", "light", "-muted", "YES"]
        app.launch()
        mainTabButton("作者榜").tap()
        let row = app.buttons["leaderboard.author.28037001"]
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
        let actions = app.buttons["creator.actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        waitUntil("Author actions are ready") { actions.isHittable }
        actions.tap()
        app.buttons["在本机屏蔽作者"].tap()
        XCTAssertTrue(app.staticTexts["已屏蔽此作者"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["取消本机屏蔽"].exists)
        attachScreenshot(named: "blocked-creator-profile-redesign")
        actions.tap()
        XCTAssertFalse(app.buttons["取消本机屏蔽"].exists)
    }

    func testBlockedAuthorsOrdinalPreview() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "-app.appearance", "light", "-muted", "YES"]
        app.launch()
        openAccountSettings()
        tapAboveMainBar(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "屏蔽的作者")).firstMatch)
        let header = floatingPageTitle("屏蔽作者")
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        header.buttons["添加屏蔽作者"].tap()
        let field = app.textFields["author-picker.input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("PagingFixture")
        let result = app.buttons["author-picker.author.28037001"]
        XCTAssertTrue(result.waitForExistence(timeout: 6))
        result.tap()
        app.buttons["author-picker.done"].tap()
        let remove = app.buttons["取消屏蔽作者 PagingFixture"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "作者 ID")).firstMatch.exists)
        attachScreenshot(named: "blocked-authors-ordinal-redesign")
        remove.tap()
    }

    func testBlocklistTopBarActionsAndSingleLineHistorySetting() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "-app.appearance", "light", "-muted", "YES"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        openAccountSettings()

        func openSettingsChild(_ entry: String) {
            tapAboveMainBar(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", entry)).firstMatch)
        }

        openSettingsChild("最近浏览与接着看")
        let history = floatingPageTitle("最近浏览")
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["记录浏览历史"].exists)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "保留 30 天")).firstMatch.exists)
        attachScreenshot(named: "history-single-line")
        history.buttons["navigation.back"].tap()

        openSettingsChild("屏蔽标签")
        let tags = floatingPageTitle("屏蔽标签")
        let addTag = tags.buttons["添加屏蔽标签"]
        XCTAssertTrue(addTag.waitForExistence(timeout: 5))
        XCTAssertFalse(addTag.isEnabled)
        let tag = app.textFields["输入站点标签名"]
        tag.tap()
        tag.typeText("qa121tag")
        XCTAssertTrue(addTag.isEnabled)
        addTag.tap()
        let removeTag = app.buttons["删除屏蔽标签 qa121tag"]
        XCTAssertTrue(removeTag.waitForExistence(timeout: 5))
        attachScreenshot(named: "blocked-tags-top-add")
        removeTag.tap()
        tags.buttons["navigation.back"].tap()

        openSettingsChild("屏蔽的作者")
        let authors = floatingPageTitle("屏蔽作者")
        let addAuthor = authors.buttons["添加屏蔽作者"]
        XCTAssertTrue(addAuthor.waitForExistence(timeout: 5))
        addAuthor.tap()
        XCTAssertTrue(floatingPageTitle("添加屏蔽作者").waitForExistence(timeout: 5))
        let authorField = app.textFields["author-picker.input"]
        authorField.tap()
        authorField.typeText("PagingFixture")
        let result = app.buttons["author-picker.author.28037001"]
        let found = result.waitForExistence(timeout: 6)
        if !found { attachScreenshot(named: "blocked-author-lookup-missing"); print(app.debugDescription) }
        XCTAssertTrue(found)
        result.tap()
        XCTAssertTrue(result.isSelected)
        app.buttons["author-picker.done"].tap()
        let removeAuthor = app.buttons["取消屏蔽作者 PagingFixture"]
        XCTAssertTrue(removeAuthor.waitForExistence(timeout: 5))
        attachScreenshot(named: "blocked-authors-top-add")
        removeAuthor.tap()
    }

    func testSettingsChildrenUseTheSameFloatingHeader() {
        visualLaunch(width: 0, large: false, landscape: false, extra: ["--qa-floating173"])
        openAccountSettings()
        let settings = floatingPageTitle("账号与设置")
        let reference = settings.frame

        for (entry, title) in [
            ("账号内容偏好", "账号内容偏好"),
            ("关注的作者", "我的关注"),
            ("下载设置", "下载设置"),
            ("播放侧栏", "播放侧栏"),
            ("最近浏览与接着看", "最近浏览"),
            ("本机错误与诊断记录", "本机诊断记录"),
            ("屏蔽标签", "屏蔽标签"),
            ("屏蔽的作者", "屏蔽作者"),
            ("本地标签库与同步", "本地标签库"),
            ("开源组件", "开源组件")
        ] {
            let link = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", entry)).firstMatch
            tapAboveMainBar(link)
            let header = floatingPageTitle(title)
            guard header.waitForExistence(timeout: 5) else { XCTFail("Missing header for \(entry)"); return }
            XCTAssertEqual(header.frame.minX, reference.minX, accuracy: 1, entry)
            XCTAssertEqual(header.frame.maxX, reference.maxX, accuracy: 1, entry)
            XCTAssertEqual(header.frame.height, reference.height, accuracy: 1, entry)
            XCTAssertEqual(header.frame.midY, reference.midY, accuracy: 1, entry)
            if title == "最近浏览" {
                let selector = header.descendants(matching: .any).matching(identifier: "history.media-kind").firstMatch
                XCTAssertTrue(selector.exists)
            } else {
                let titleGroup = header.descendants(matching: .any).matching(identifier: "page-header.title").firstMatch
                XCTAssertTrue(titleGroup.exists, entry)
                XCTAssertEqual(titleGroup.frame.midX, header.frame.midX, accuracy: 1, entry)
            }
            if title == "我的关注" { XCTAssertTrue(header.buttons["following.order"].exists) }
            let cardListIDs = ["本机诊断记录": "diagnostics.card-list"]
            if let id = cardListIDs[title] {
                let list = app.descendants(matching: .any).matching(identifier: id).firstMatch
                XCTAssertTrue(list.waitForExistence(timeout: 5), title)
                XCTAssertEqual(list.frame.maxY, app.windows.firstMatch.frame.maxY, accuracy: 1, title)
            }
            let canvas = heightValues(app.staticTexts["page.canvas173"].valueDescription)
            XCTAssertEqual(canvas["canvasY"] ?? -999, 0, accuracy: 1, title)
            XCTAssertEqual(canvas["canvasBottom"] ?? -999, app.windows.firstMatch.frame.height, accuracy: 1, title)
            attachScreenshot(named: "settings-child-" + title)
            let back = header.buttons["navigation.back"]
            XCTAssertTrue(back.waitForExistence(timeout: 5), entry)
            back.tap()
            XCTAssertTrue(settings.waitForExistence(timeout: 5), entry)
        }
    }

    func testConfigurationBothEdgesReturnAndCommitOnlyOnCompletion() {
        visualLaunch(width: 0, large: false, landscape: false, extra: ["--qa-page-return", "--qa-segment-edge", "--qa-header-motion"])
        openAccountSettings()
        let settings = floatingPageTitle("账号与设置")
        let bottom = mainTabBar().frame
        for right in [false, true] {
            let entry = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "推荐时间线默认筛选")).firstMatch
            tapAboveMainBar(entry)
            let header = floatingPageTitle("浏览条件")
            XCTAssertTrue(header.waitForExistence(timeout: 5))
            let toggle = app.switches["filter.only-pg"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            let fixedHeader = header.frame
            let before = toggle.valueDescription
            toggle.tap()
            let changed = toggle.valueDescription
            XCTAssertNotEqual(before, changed)
            let window = app.windows.firstMatch
            let frame = window.frame
            let start = window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: right ? frame.width - 12 : 12, dy: frame.height * 0.55))
            // A small, slow drag must cancel without leaving or committing.
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: right ? -18 : 18, dy: 0)),
                        withVelocity: XCUIGestureVelocity(rawValue: 60), thenHoldForDuration: 0.1)
            XCTAssertTrue(header.isHittable)
            let readback = app.descendants(matching: .any)["page.return-motion.qa"]
            waitUntil("Cancelled return restores its source mask") { readback.valueDescription.contains("phase=cancelled") }
            let geometry = heightValues(readback.valueDescription)
            XCTAssertGreaterThanOrEqual(geometry["minY"] ?? 0, fixedHeader.maxY - 1)
            XCTAssertLessThanOrEqual(geometry["maxY"] ?? 9999, bottom.minY + 1)
            XCTAssertTrue(readback.valueDescription.contains("sourceMasked=false"))
            XCTAssertEqual(toggle.valueDescription, changed)
            XCTAssertEqual(mainTabBar().frame, bottom)
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: right ? -160 : 160, dy: 0)),
                        withVelocity: XCUIGestureVelocity(rawValue: 180), thenHoldForDuration: 0.1)
            XCTAssertTrue(header.waitForNonExistence(timeout: 5))
            print("RETURN_COMPLETION_QA " + readback.valueDescription)
            print("RETURN_LOCK_QA " + app.descendants(matching: .any)["page.interaction-lock"].valueDescription)
            attachScreenshot(named: "config-return-destination")
            let ready = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                settings.buttons["navigation.back"].isHittable
            }, object: nil)], timeout: 5)
            if ready != .completed {
                attachScreenshot(named: "config-return-not-interactive")
                let tree = XCTAttachment(string: app.debugDescription)
                tree.name = "config-return-final-hierarchy"; tree.lifetime = .keepAlways; add(tree)
                print("CONFIG_BACK_EXISTS \(settings.buttons["navigation.back"].exists);FILTER_REAPPEARED=\(header.exists)")
            }
            if ready != .completed {
                // A List can overlap the header in the AX frame tree. Verify
                // actual touch delivery before diagnosing a broken header.
                let back = settings.buttons["navigation.back"]
                let rotation = app.switches["自动旋转"]
                let oldRotation = rotation.valueDescription
                app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: back.frame.midX, dy: back.frame.midY)).tap()
                print("CONFIG_COORDINATE_BACK rotationBefore=\(oldRotation);rotationAfter=\(rotation.exists ? rotation.valueDescription : "absent")")
                XCTAssertTrue(settings.waitForNonExistence(timeout: 5), "Actual Back must return to the timeline")
                XCTAssertTrue(app.buttons["timeline.account"].waitForExistence(timeout: 5))
                openAccountSettings()
                XCTAssertTrue(settings.waitForExistence(timeout: 5))
            }
            waitUntil("Completed return releases its source mask") { readback.valueDescription.contains("phase=completed") }
            XCTAssertTrue(readback.valueDescription.contains("sourceMasked=false"))
            XCTAssertEqual(mainTabBar().frame, bottom)
            tapAboveMainBar(entry)
            XCTAssertTrue(header.waitForExistence(timeout: 5))
            XCTAssertEqual(toggle.valueDescription, changed, "Successful return commits local configuration")
            header.buttons["navigation.back"].tap()
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
        }
        app.terminate()
    }

    func testDetailsBothEdgesReturnKeepSharedChrome() {
        visualLaunch(width: 0, large: false, landscape: false, extra: ["--qa-page-return", "--qa-segment-edge", "--qa-header-motion", "--qa-details-tags"])
        for right in [false, true] {
            visualButton("media.details.28037100").tap()
            let header = floatingPageTitle("作品详情")
            XCTAssertTrue(header.waitForExistence(timeout: 5))
            let top = header.frame, bottom = mainTabBar().frame
            let window = app.windows.firstMatch
            let start = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: right ? window.frame.width - 12 : 12, dy: window.frame.height * 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: right ? -18 : 18, dy: 0)),
                        withVelocity: XCUIGestureVelocity(rawValue: 60), thenHoldForDuration: 0.1)
            let qa = app.descendants(matching: .any)["page.return-motion.qa"]
            print("MODAL_RETURN_EXISTS \(qa.exists)")
            if qa.exists { print("MODAL_RETURN_QA " + qa.valueDescription) }
            waitUntil("Modal return cancels cleanly") { qa.valueDescription.contains("phase=cancelled") }
            let rect = heightValues(qa.valueDescription)
            XCTAssertGreaterThanOrEqual(rect["minY"] ?? 0, top.maxY - 1)
            XCTAssertLessThanOrEqual(rect["maxY"] ?? 9999, bottom.minY + 1)
            XCTAssertTrue(qa.valueDescription.contains("sourceMasked=false"))
            XCTAssertEqual(header.frame, top)
            XCTAssertEqual(mainTabBar().frame, bottom)
            attachScreenshot(named: right ? "details-right-return-cancel" : "details-left-return-cancel")
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: right ? -170 : 170, dy: 0)),
                        withVelocity: XCUIGestureVelocity(rawValue: 180), thenHoldForDuration: 0.1)
            XCTAssertTrue(header.waitForNonExistence(timeout: 5))
            waitUntil("Modal source leaves its window and releases the mask") { qa.valueDescription.contains("phase=completed") }
            XCTAssertTrue(qa.valueDescription.contains("sourceMasked=false"))
            XCTAssertTrue(visualButton("media.details.28037100").isHittable)
        }
        app.terminate()
    }

    func testRepeatedTagPickerTransitionsKeepSharedChrome() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-header-motion", "-app.appearance", "light", "-muted", "YES"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        mainTabButton("搜索").tap()
        let mode = app.buttons["search.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        if mode.valueDescription.contains("作者") { mode.tap() }
        let searchHeader = app.otherElements["search.top-bar"]
        let titleInput = app.textFields["search-title-input"]
        let tags = app.buttons["search-tag-picker"]
        waitUntil("Works search exposes its real input and second-row tag action") {
            mode.valueDescription.contains("作品") && titleInput.isHittable && tags.isHittable
        }
        let worksFrame = searchHeader.frame
        let bottom = mainTabBar().frame
        attachScreenshot(named: "repeated-tag-picker-search-baseline")

        for round in 1...3 {
            waitUntil("Round \(round): the real tag action can open the picker") { tags.isHittable }
            tags.tap()
            let picker = floatingPageTitle("选择标签")
            let back = picker.buttons["navigation.back"]
            let done = picker.buttons["完成"]
            let tagInput = app.textFields["tag-search-input"]
            XCTAssertTrue(picker.waitForExistence(timeout: 5))
            waitUntil("Round \(round): the single-row picker hands input back to its real controls") {
                back.isHittable && done.isHittable && tagInput.isHittable && self.app.keyboards.count == 0
            }
            // The single-row AX parent includes its 44pt hit region above
            // the 36pt surface. Compare the actual rendered panel instead.
            let motion = app.descendants(matching: .any)["header.layout-motion.qa"]
            waitUntil("Round \(round): the actual header handoff finishes") { motion.valueDescription.contains("phase=finished") }
            let geometry = heightValues(motion.valueDescription)
            print("TAG_HEADER_MOTION \(round) " + motion.valueDescription)
            XCTAssertEqual(geometry["topMin"] ?? -1, worksFrame.minY, accuracy: 1)
            XCTAssertEqual(geometry["topMax"] ?? -1, worksFrame.minY, accuracy: 1)
            XCTAssertGreaterThan(geometry["source"] ?? 0, geometry["target"] ?? 0)
            XCTAssertLessThan(picker.frame.height, worksFrame.height - 1)
            XCTAssertEqual(mainTabBar().frame, bottom)
            attachScreenshot(named: "repeated-tag-picker-\(round)-single-row")

            let tagQuery = "city"
            tagInput.tap()
            tagInput.typeText(tagQuery)
            waitUntil("Round \(round): picker text entry reaches the real field") {
                tagInput.value as? String == tagQuery
            }
            let clearTag = app.buttons["tag-search.clear"]
            waitUntil("Round \(round): the picker clear action is usable") { clearTag.isHittable }
            clearTag.tap()
            waitUntil("Round \(round): picker text is cleared") {
                ["", tagInput.placeholderValue ?? "搜索标签名称"].contains(tagInput.value as? String ?? "") && !clearTag.isHittable
            }
            waitUntil("Round \(round): the picker return action is usable") { back.isHittable }
            back.tap()
            XCTAssertTrue(picker.waitForNonExistence(timeout: 5))
            waitUntil("Round \(round): the restored two-row search can receive input") {
                titleInput.isHittable && tags.isHittable && self.app.keyboards.count == 0
                    && abs(searchHeader.frame.height - worksFrame.height) < 1
            }
            XCTAssertEqual(searchHeader.frame.minY, worksFrame.minY, accuracy: 1)
            XCTAssertEqual(searchHeader.frame.height, worksFrame.height, accuracy: 1)
            XCTAssertEqual(mainTabBar().frame, bottom)
            attachScreenshot(named: "repeated-tag-picker-\(round)-two-rows-restored")

            let titleQuery = "Chrome\(round)"
            titleInput.tap()
            titleInput.typeText(titleQuery)
            waitUntil("Round \(round): returned search accepts new title text") {
                titleInput.value as? String == titleQuery
            }
            let clearSearch = app.buttons["search.clear"]
            waitUntil("Round \(round): returned search clear action is usable") { clearSearch.isHittable }
            clearSearch.tap()
            waitUntil("Round \(round): returned search conditions are cleared") {
                ["", titleInput.placeholderValue ?? "搜标题"].contains(titleInput.value as? String ?? "") && !clearSearch.isEnabled
            }
            XCTAssertFalse(app.buttons["search-submit"].isEnabled)
        }
        app.terminate()
    }

    func testDetailsBodyHandoffKeepsLandscapeChromeAligned() {
        visualLaunch(width: 0, large: false, landscape: true,
                     extra: ["--qa-body-motion", "--qa-details-tags", "-muted", "YES", "-autoplay", "NO"])
        let before = mainTabBar().frame
        let details = visualButton("media.details.28037100")
        waitUntil("Landscape details action is available") { details.isHittable }
        details.tap()
        let header = floatingPageTitle("作品详情")
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        let qa = app.staticTexts["body.motion.qa"]
        waitUntil("Landscape body entry has settled") {
            qa.valueDescription.contains("kind=entry;phase=completed") && self.app.buttons["details.back"].isHittable
        }
        XCTAssertEqual(mainTabBar().frame, before)
        XCTAssertGreaterThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height)
        print("LANDSCAPE_BODY_ENTRY \(qa.valueDescription)")
        attachScreenshot(named: "body-landscape-details")
        app.buttons["details.back"].tap()
        waitUntil("Landscape return settles without moving fixed chrome") {
            qa.valueDescription.contains("kind=return;phase=completed") && details.isHittable
        }
        XCTAssertEqual(mainTabBar().frame, before)
        print("LANDSCAPE_BODY_RETURN \(qa.valueDescription)")
        app.terminate()
    }

    func testDetailsBodyHandoffForImagesAndVideoInBothThemes() {
        for appearance in ["light", "dark"] {
            app = XCUIApplication()
            app.launchArguments = ["--qa-collection-paging", "--qa-visual-controls", "--qa-details-tags", "--qa-body-motion", "-app.appearance", appearance, "-muted", "YES", "-autoplay", "YES"]
            XCUIDevice.shared.orientation = .portrait
            app.launch()
            XCTAssertTrue(timelineTools().waitForExistence(timeout: 10))
            if timelineTools().valueDescription.contains("双列网格") { toggleTimelinePresentation() }
            heightCloseNotices()
            for (kind, id) in [("图片", 28_037_100), ("视频", 28_037_102)] {
                app.otherElements["timeline.media-kind"].buttons[kind].tap()
                let action = visualButton("media.details.\(id)")
                waitUntil("Details action is ready") { action.isHittable }
                if kind == "视频" { waitPlayingFixture() }
                attachScreenshot(named: "body-\(appearance)-\(kind)-source")
                action.tap()
                let title = floatingPageTitle("作品详情")
                XCTAssertTrue(title.waitForExistence(timeout: 5))
                let qa = app.staticTexts["body.motion.qa"]
                waitUntil("Entry body reaches its terminal frame and releases input") {
                    qa.valueDescription.contains("kind=entry;phase=completed") && self.app.buttons["details.back"].isHittable
                }
                let entry = heightValues(qa.valueDescription)
                XCTAssertEqual(entry["snapshotAvailable"], 1)
                XCTAssertGreaterThan(entry["frames"] ?? 0, 2)
                print("BODY_ENTRY appearance=\(appearance);kind=\(kind);\(qa.valueDescription)")
                attachScreenshot(named: "body-\(appearance)-\(kind)-destination")
                app.buttons["details.back"].tap()
                XCTAssertTrue(title.waitForNonExistence(timeout: 5))
                waitUntil("Button return has its own body handoff, not an instant replacement") {
                    qa.valueDescription.contains("kind=return;phase=completed") && action.isHittable
                }
                let returned = heightValues(qa.valueDescription)
                XCTAssertEqual(returned["snapshotAvailable"], 1)
                XCTAssertGreaterThan(returned["frames"] ?? 0, 2)
                print("BODY_RETURN appearance=\(appearance);kind=\(kind);\(qa.valueDescription)")
            }
            app.terminate()
        }
    }

    func testPresentationLifecycleHandlesReplacementAndSourceRemoval() {
        for scenario in ["begin-remove", "end-remove", "replace"] {
            app = XCUIApplication()
            app.launchArguments = ["--qa-presentation-lifecycle", "--qa-lifecycle-case=" + scenario]
            app.launch()
            let status = app.staticTexts["qa.lifecycle.state"]
            XCTAssertTrue(app.buttons["qa.lifecycle.open"].waitForExistence(timeout: 5))
            app.buttons["qa.lifecycle.open"].tap()
            if scenario == "begin-remove" {
                waitUntil("Removed preparation ends without a platform dismissal callback") {
                    status.valueDescription.contains("ends=1") && status.valueDescription.contains("mounts=0")
                }
                XCTAssertFalse(app.staticTexts["qa.lifecycle.presented.1"].exists)
            } else {
                XCTAssertTrue(app.staticTexts["qa.lifecycle.presented.1"].waitForExistence(timeout: 5))
                if scenario == "end-remove" {
                    app.buttons["qa.lifecycle.close"].tap()
                    waitUntil("Source removal completes every prepared request without mounting B") {
                        let values = self.heightValues(status.valueDescription)
                        return values["source"] == 0 && values["ends"] == values["begins"]
                    }
                    print("PRESENTATION_TEARDOWN \(status.valueDescription)")
                    XCTAssertEqual(heightValues(status.valueDescription)["mounts"], 1)
                    XCTAssertFalse(app.staticTexts["qa.lifecycle.presented.2"].exists)
                } else {
                    app.buttons["qa.lifecycle.replace"].tap()
                    XCTAssertTrue(app.staticTexts["qa.lifecycle.presented.2"].waitForExistence(timeout: 5))
                    app.buttons["qa.lifecycle.close"].tap()
                    waitUntil("Same work replacement finishes and rejects the old close predicate") {
                        status.valueDescription.contains("ends=2") && status.valueDescription.contains("mounts=2")
                            && status.valueDescription.contains("staleRejected=1")
                    }
                }
            }
            print("PRESENTATION_LIFECYCLE scenario=\(scenario);\(status.valueDescription)")
            app.terminate()
        }
    }

    func testPerformance175OwnedProfilerWindow() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-author-activity58", "--qa-drag-performance167",
                               "-app.appearance", "light", "-muted", "YES", "-autoplay", "NO"]
        app.launch()
        mainTabButton("作者榜").tap()
        waitUntil("Ranking is loaded before the diagnostic recording") {
            self.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "leaderboard.author."))
                .allElementsBoundByIndex.prefix(48).contains { $0.isHittable }
        }
        print("PERF175_PROFILE_READY epoch=\(Date().timeIntervalSince1970)")
        // Diagnostic attachment and symbol-loading window, not app latency.
        Thread.sleep(forTimeInterval: 30)
        Thread.sleep(forTimeInterval: 30)
        runSustainedDragProfilerRound167(round: 1, window: app.windows.firstMatch,
                                        picker: app.otherElements["leaderboard.board"])
        print("PERF175_PROFILE_ACTIONS_END epoch=\(Date().timeIntervalSince1970)")
        // Keep the exact app process alive until recorder finalisation.
        for _ in 0..<3 { Thread.sleep(forTimeInterval: 30) }
        app.terminate()
    }

    func testContinuousDragPerformanceWorkload167() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-author-activity58", "--qa-drag-performance167", "-app.appearance", "light",
                               "-muted", "YES", "-autoplay", "NO"]
        app.launch()
        mainTabButton("作者榜").tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "leaderboard.author."))
        waitUntil("The representative ranking receives input before profiling") {
            rows.allElementsBoundByIndex.prefix(48).contains { $0.isHittable }
        }
        let window = app.windows.firstMatch
        let verticalTop = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.30))
        let verticalBottom = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
        let horizontalLeft = window.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.50))
        let horizontalRight = window.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.50))
        let edgeLeft = window.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.50))
        let edgeRight = window.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.50))
        print("PERF167_READY time=\(Date().timeIntervalSince1970)")
        // Deliberate profiler-attachment window; this is not product timing.
        Thread.sleep(forTimeInterval: 15)
        print("PERF167_VERTICAL time=\(Date().timeIntervalSince1970)")
        for _ in 0..<3 {
            verticalBottom.press(forDuration: 0.02, thenDragTo: verticalTop,
                                 withVelocity: XCUIGestureVelocity(rawValue: 400), thenHoldForDuration: 0.05)
            verticalTop.press(forDuration: 0.02, thenDragTo: verticalBottom,
                              withVelocity: XCUIGestureVelocity(rawValue: 400), thenHoldForDuration: 0.05)
        }
        print("PERF167_CENTRAL time=\(Date().timeIntervalSince1970)")
        let picker = app.otherElements["leaderboard.board"]
        for _ in 0..<2 {
            horizontalRight.press(forDuration: 0.02, thenDragTo: horizontalLeft,
                                  withVelocity: XCUIGestureVelocity(rawValue: 250), thenHoldForDuration: 0.05)
            Thread.sleep(forTimeInterval: 0.75)
            XCTAssertTrue(picker.buttons["Legacy"].isSelected, "The profiled central drag switches the real pane")
            horizontalLeft.press(forDuration: 0.02, thenDragTo: horizontalRight,
                                 withVelocity: XCUIGestureVelocity(rawValue: 250), thenHoldForDuration: 0.05)
            Thread.sleep(forTimeInterval: 0.75)
            XCTAssertTrue(picker.buttons["Seasonal"].isSelected)
        }
        print("PERF167_EDGE time=\(Date().timeIntervalSince1970)")
        for _ in 0..<2 {
            edgeRight.press(forDuration: 0.02, thenDragTo: horizontalLeft,
                            withVelocity: XCUIGestureVelocity(rawValue: 250), thenHoldForDuration: 0.05)
            waitUntil("The profiled edge drag switches and reveals the real search root") {
                self.mainTabButton("搜索").isSelected && self.app.otherElements["search.top-bar"].isHittable
            }
            edgeLeft.press(forDuration: 0.02, thenDragTo: horizontalRight,
                           withVelocity: XCUIGestureVelocity(rawValue: 250), thenHoldForDuration: 0.05)
            waitUntil("The reverse edge restores the real ranking root") {
                self.mainTabButton("作者榜").isSelected && self.app.otherElements["leaderboard.top-bar"].isHittable
            }
        }
        print("PERF167_END time=\(Date().timeIntervalSince1970)")
    }

    func testSustainedDragProfilerWindow167() { runSustainedDragWorkload172(eagerAuthors: false) }
    func testSustainedDragIdleMountControl178() { runSustainedDragWorkload172(eagerAuthors: false, controlIdleMount: true) }
    func testSustainedDragEagerAuthors172() { runSustainedDragWorkload172(eagerAuthors: true) }

    func testSustainedDragLiveToneControl175() { runSustainedDragWorkload172(eagerAuthors: false, controlLiveTone: true) }

    func testSustainedDragLayoutPlanControl175() { runSustainedDragWorkload172(eagerAuthors: false, controlLayoutPlan: true) }

    private func runSustainedDragWorkload172(eagerAuthors: Bool, controlLiveTone: Bool = false, controlLayoutPlan: Bool = false, controlIdleMount: Bool = false) {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-author-activity58", "--qa-drag-performance167", "-app.appearance", "light",
                               "-muted", "YES", "-autoplay", "NO"]
        if eagerAuthors { app.launchArguments.append("--qa-eager-authors172") }
        if controlLiveTone { app.launchArguments.append("--qa-root-live-tone-control175") }
        if controlLayoutPlan { app.launchArguments.append("--qa-root-layout-plan-control175") }
        if controlIdleMount { app.launchArguments.append("--qa-root-idle-control178") }
        print("CADENCE172_MODE eager=\(eagerAuthors)")
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        mainTabButton("作者榜").tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "leaderboard.author."))
        waitUntil("The representative ranking is loaded before the profiler window") {
            rows.allElementsBoundByIndex.prefix(48).contains { $0.isHittable }
        }
        let window = app.windows.firstMatch
        let picker = app.otherElements["leaderboard.board"]
        print("PERF167_READY time=\(Date().timeIntervalSince1970)")
        for round in 1...3 {
            runSustainedDragProfilerRound167(round: round, window: window, picker: picker)
        }
        print("PERF167_END time=\(Date().timeIntervalSince1970)")
        app.terminate()
    }

    private func runSustainedDragProfilerRound167(round: Int, window: XCUIElement, picker: XCUIElement) {
        let verticalTop = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.30))
        let verticalBottom = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
        let horizontalLeft = window.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.50))
        let horizontalRight = window.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.50))
        let edgeLeft = window.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.50))
        let edgeRight = window.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.50))

        print("PERF167 phase=vertical epoch=\(Date().timeIntervalSince1970) round=\(round)")
        for _ in 0..<3 {
            verticalBottom.press(forDuration: 0.02, thenDragTo: verticalTop,
                                 withVelocity: XCUIGestureVelocity(rawValue: 400), thenHoldForDuration: 0.05)
            verticalTop.press(forDuration: 0.02, thenDragTo: verticalBottom,
                              withVelocity: XCUIGestureVelocity(rawValue: 400), thenHoldForDuration: 0.05)
        }

        print("PERF167 phase=central epoch=\(Date().timeIntervalSince1970) round=\(round)")
        for _ in 0..<2 {
            horizontalRight.press(forDuration: 0.02, thenDragTo: horizontalLeft,
                                  withVelocity: XCUIGestureVelocity(rawValue: 250), thenHoldForDuration: 0.05)
            waitUntil("The profiled center drag switches to the real Legacy pane") { picker.buttons["Legacy"].isSelected }
            horizontalLeft.press(forDuration: 0.02, thenDragTo: horizontalRight,
                                 withVelocity: XCUIGestureVelocity(rawValue: 250), thenHoldForDuration: 0.05)
            waitUntil("The profiled reverse center drag restores the real Seasonal pane") { picker.buttons["Seasonal"].isSelected }
        }

        print("PERF167 phase=root-edge epoch=\(Date().timeIntervalSince1970) round=\(round)")
        for _ in 0..<2 {
            edgeRight.press(forDuration: 0.02, thenDragTo: horizontalLeft,
                            withVelocity: XCUIGestureVelocity(rawValue: 250), thenHoldForDuration: 0.05)
            waitUntil("The profiled root edge selects and reveals search") {
                self.mainTabButton("搜索").isSelected && self.app.otherElements["search.top-bar"].isHittable
            }
            XCTAssertTrue(mainTabButton("搜索").isSelected)
            edgeLeft.press(forDuration: 0.02, thenDragTo: horizontalRight,
                           withVelocity: XCUIGestureVelocity(rawValue: 250), thenHoldForDuration: 0.05)
            waitUntil("The reverse profiled root edge restores the ranking") {
                self.mainTabButton("作者榜").isSelected && self.app.otherElements["leaderboard.top-bar"].isHittable
            }
            XCTAssertTrue(mainTabButton("作者榜").isSelected)
        }
        print("PERF167 phase=round-end epoch=\(Date().timeIntervalSince1970) round=\(round) time=\(Date().timeIntervalSince1970)")
        let cadence = app.staticTexts["performance.cadence172"]
        if cadence.exists { print("CADENCE172 round=\(round);sample=\(cadence.valueDescription)") }
    }

    func testLoadedLeaderboardToSearchRemainsResponsive() { assertLoadedLeaderboardToSearch175() }
    func testWarmLayout175MismatchReplansWithoutChangingState() { assertLoadedLeaderboardToSearch175(injectStaleLayout: true) }
    private func assertLoadedLeaderboardToSearch175(injectStaleLayout: Bool = false) {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-author-activity58", "--qa-transition-performance", "--qa-header-motion", "-app.appearance", "light", "-muted", "YES"]
        if injectStaleLayout { app.launchArguments += ["--qa-root-layout-mismatch175", "--qa-drag-performance167"] }
        app.launch()
        let authors = mainTabButton("作者榜"), search = mainTabButton("搜索")
        for round in 1...3 {
            authors.tap()
            let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "leaderboard.author."))
            // Three swipes retain the list position. Check a visible row rather
            // than demanding the original first row return to the screen.
            waitUntil("Loaded ranking receives input at its preserved position") {
                rows.allElementsBoundByIndex.prefix(48).contains { $0.isHittable }
                    && self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0")
            }
            app.swipeUp()
            let start = Date()
            search.tap()
            let field = app.textFields["search-title-input"]
            attachScreenshot(named: "leaderboard-search-\(round)-after-tap")
            print("LEADERBOARD_SEARCH_HIERARCHY \(app.debugDescription.prefix(24000))")
            waitUntil("Search receives input after leaving a loaded ranking") {
                field.isHittable && self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0")
            }
            print("LEADERBOARD_MOTION_STATE \(app.staticTexts["header.layout-motion.qa"].valueDescription);lock=\(app.staticTexts["page.interaction-lock"].valueDescription)")
            print("LEADERBOARD_SEARCH_PERF round=\(round);seconds=\(Date().timeIntervalSince(start))")
            field.tap(); field.typeText("test")
            XCTAssertEqual(field.value as? String, "test")
            app.buttons["search.clear"].tap()
            let collection = mainTabButton("收藏")
            // The synthesized-event archive showed XCTest reusing the prior
            // ranking snapshot (y=816) after the live footer moved above the
            // keyboard. Resolve the live scoped element and validate its
            // visible hit rectangle before sending a physical touch.
            waitUntil("The live search footer is above the keyboard and unlocked") {
                let keyboard = self.app.keyboards.firstMatch
                let frame = collection.frame
                return self.mainTabButton("搜索").isSelected && collection.isHittable
                    && frame.width >= 44 && frame.height >= 44
                    && (!keyboard.exists || frame.maxY <= keyboard.frame.minY + 1)
                    && self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0")
            }
            let hit = collection.frame
            print("LEADERBOARD_COLLECTION_HIT round=\(round);frame=\(hit);keyboard=\(app.keyboards.firstMatch.frame)")
            app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: hit.midX, dy: hit.midY)).tap()
            waitUntil("Collection navigation settles before another root action") {
                self.mainTabButton("收藏").isSelected
                    && self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0")
            }
            XCTAssertFalse(app.keyboards.firstMatch.exists, "A hidden search page cannot retain its keyboard")
        }
        if injectStaleLayout {
            let raw = app.staticTexts["performance.cadence172"].valueDescription.data(using: .utf8) ?? Data()
            let value = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
            let costs = value?["cost174"] as? [String: Any]
            let totals = costs?["totals"] as? [String: Any]
            let rejected = (totals?["warmLayoutRejected175"] as? [NSNumber])?.first?.intValue ?? 0
            print("WARM175_STALE_REPLAN_COUNT \(rejected)")
            XCTAssertGreaterThan(rejected, 0, "Stale metadata must take the guarded replan path before staging")
        }
        app.terminate()
    }

    func testDetails175TagRevealHasVisibleIntermediateFrames() { assertDetailsReveal175(late: false) }
    func testDetails175LateTagsRevealAfterEntry() { assertDetailsReveal175(late: true) }
    private func assertDetailsReveal175(late: Bool) {
        var options = ["--qa-details-tags", "--qa-details-reveal175", "--qa-body-motion", "-muted", "YES", "-autoplay", "NO"]
        if late { options += ["--qa-details-reveal175-late", "--qa-details-input-tags-unknown175"] }
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: options)
        visualButton("media.details.28037100").tap()
        let probe = app.staticTexts["details.reveal175.28037100"]
        XCTAssertTrue(probe.waitForExistence(timeout: 8))
        let value = probe.valueDescription
        print("DETAILS175_VISIBLE_REVEAL " + value)
        attachScreenshot(named: "details175-reveal-settled")
        XCTAssertGreaterThan(heightValues(value)["visible"] ?? 0, 0, "Tag expansion must have visible intermediate frames after entry pixels release")
        XCTAssertEqual(heightValues(value)["covered"] ?? 0, 0, "The expansion cannot finish behind a frozen entry snapshot")
        app.terminate()
    }

    func testVideoDetailsReturnUsesCachedPreviewAndKeepsChrome() { assertVideoDetailsReturn175(primeOtherRoots: false) }
    func testVideo175ReturnUsesActiveRootPreview() { assertVideoDetailsReturn175(primeOtherRoots: true) }
    private func assertVideoDetailsReturn175(primeOtherRoots: Bool) {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-page-return", "--qa-details-tags", "--qa-drag-performance167", "--qa-header-motion", "-muted", "YES", "-autoplay", "YES"])
        if primeOtherRoots {
            func idle() {
                waitUntil("The root and its return pixels release input") {
                    self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0")
                }
            }
            mainTabButton("收藏").tap(); idle()
            let downloads = app.buttons["collections.downloads"].firstMatch
            waitUntil("The collection exposes its download page") { downloads.isHittable }
            downloads.tap()
            let back = floatingPageTitle("下载管理").buttons["navigation.back"]
            XCTAssertTrue(back.waitForExistence(timeout: 5)); idle()
            back.tap(); idle()
            mainTabButton("搜索").tap(); idle()
            let picker = app.buttons["search-author-picker"]
            waitUntil("Search exposes its author picker") { picker.isHittable }
            picker.tap()
            let field = app.textFields["author-picker.input"]
            XCTAssertTrue(field.waitForExistence(timeout: 5)); idle()
            let window = app.windows.firstMatch
            let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
            edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(CGVector(dx: 200, dy: 0)),
                       withVelocity: XCUIGestureVelocity(rawValue: 180), thenHoldForDuration: 0.1)
            XCTAssertTrue(field.waitForNonExistence(timeout: 5)); idle()
            mainTabButton("时间线").tap(); idle()
        }
        app.otherElements["timeline.media-kind"].buttons["视频"].tap()
        let details = visualButton("media.details.28037102")
        waitUntil("Video details are ready on the active video") { details.isHittable }
        waitPlayingFixture()
        attachScreenshot(named: "video-return-before-details")
        details.tap()
        let header = floatingPageTitle("作品详情")
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        let top = header.frame, bottom = mainTabBar().frame
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 12, dy: window.frame.height * 0.55))
        print("VIDEO_RETURN_CAPTURE_READY")
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 170, dy: 0)),
                    withVelocity: XCUIGestureVelocity(rawValue: 180), thenHoldForDuration: 1.5)
        XCTAssertTrue(header.waitForNonExistence(timeout: 5))
        let qa = app.descendants(matching: .any)["page.return-motion.qa"]
        waitUntil("Video return completes and clears the source mask") {
            let value = qa.valueDescription
            print("VIDEO175_RETURN_STATE " + value)
            print("VIDEO175_RETURN_COST " + self.app.staticTexts["performance.cadence172"].valueDescription)
            return value.contains("phase=completed")
        }
        XCTAssertTrue(qa.valueDescription.contains("previewKind=cached"), qa.valueDescription)
        XCTAssertTrue(qa.valueDescription.contains("sharedHeader=true"), "The completed return uses the coordinated shared header")
        XCTAssertTrue(qa.valueDescription.contains("sourceMasked=false"))
        XCTAssertGreaterThanOrEqual(heightValues(qa.valueDescription)["minY"] ?? 0, top.maxY - 1)
        XCTAssertLessThanOrEqual(heightValues(qa.valueDescription)["maxY"] ?? 9999, bottom.minY + 1)
        XCTAssertEqual(mainTabBar().frame, bottom)
        waitUntil("Playback details become usable after the return") { details.isHittable }
        attachScreenshot(named: "video-return-after-details")
        print("EDGE175_COST " + app.staticTexts["performance.cadence172"].valueDescription)
        app.terminate()
    }

    func testOpenSource181SeparatesComponentAndFullLicense() {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-header-motion", "--qa-body-motion", "-muted", "YES", "-autoplay", "NO"])
        openAccountSettings()
        tapAboveMainBar(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "开源组件")).firstMatch)
        let component = floatingPageTitle("开源组件")
        XCTAssertTrue(component.waitForExistence(timeout: 5))
        let bottom = mainTabBar().frame
        let website = app.descendants(matching: .any)["opensource.ffmpeg-website"]
        XCTAssertTrue(website.isHittable)
        let fullText = app.staticTexts["opensource.ffmpeg-license-text"]
        XCTAssertFalse(fullText.exists, "The component page does not lay out the long license body")
        app.buttons["opensource.ffmpeg-license"].tap()
        XCTAssertTrue(floatingPageTitle("FFmpeg 许可证").waitForExistence(timeout: 5))
        XCTAssertTrue(fullText.waitForExistence(timeout: 5))
        let text = fullText.label
        XCTAssertGreaterThan(text.utf8.count, 25000, "The bundled license is available without truncation")
        XCTAssertTrue(text.contains("END OF TERMS AND CONDITIONS"))
        XCTAssertEqual(mainTabBar().frame, bottom)
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.5)),
                   withVelocity: XCUIGestureVelocity(rawValue: 180), thenHoldForDuration: 0.1)
        waitUntil("The license returns to its original component page") {
            component.isHittable && website.isHittable
        }
        XCTAssertEqual(mainTabBar().frame, bottom)
        attachScreenshot(named: "opensource181-component-directory")
        app.terminate()
    }

    func testSettingsEmptyCacheUsesNumericZero() {
        visualLaunch(width: 0, large: false, landscape: false)
        openAccountSettings()
        XCTAssertTrue(floatingPageTitle("账号与设置").waitForExistence(timeout: 5))
        let clear = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "清理媒体缓存")).firstMatch
        for _ in 0..<8 { if clear.exists && clear.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(clear.isHittable); clear.tap()
        let row = app.descendants(matching: .any).matching(identifier: "settings.media-cache-size").firstMatch
        waitUntil("A successfully cleared cache must display the exact numeric zero, excluding 10/100 KB") {
            (row.label + " " + row.valueDescription).range(of: "(?<![0-9.,])0 KB(?![A-Za-z0-9])", options: .regularExpression) != nil
        }
        print("CACHE44_EXACT_ZERO label=\(row.label);value=\(row.valueDescription)")
        attachScreenshot(named: "floating44-settings-numeric-zero")
        app.terminate()
    }

    private func launchPlayback43(_ mode: String, automatic: Bool? = nil) {
        app = XCUIApplication(); XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--qa-collection-paging", "--qa-playback-diagnostics43=\(mode)",
                               "-automaticVideoRepair", (automatic ?? mode.hasPrefix("repair-")) ? "YES" : "NO", "-muted", "YES"]
        app.launch()
        let node = app.descendants(matching: .any).matching(identifier: "qa.playback-diagnostics43").firstMatch
        let appeared = node.waitForExistence(timeout: 10)
        if !appeared { print("PLAYBACK43_MISSING_READBACK mode=\(mode)\n\(app.debugDescription)"); attachScreenshot(named: "playback43-missing-readback-\(mode)") }
        XCTAssertTrue(appeared)
        print("PLAYBACK43_READBACK_NODE \(node.debugDescription)")
    }
    private func playback43Entries() -> [[String: Any]] {
        let raw = app.descendants(matching: .any).matching(identifier: "qa.playback-diagnostics43").firstMatch.valueDescription
        return ((try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [[String: Any]]) ?? []
    }
    private func attachPlayback43(_ mode: String) {
        let raw = app.descendants(matching: .any).matching(identifier: "qa.playback-diagnostics43").firstMatch.valueDescription
        print("PLAYBACK43_FIXTURE mode=\(mode);synthetic=true;json=\(raw)")
        let attachment = XCTAttachment(string: raw); attachment.name = "playback43-\(mode)-synthetic-only"; attachment.lifetime = .keepAlways; add(attachment)
        attachScreenshot(named: "playback43-\(mode)")
    }
    func testPlaybackDiagnostics43ValidVideoDoesNotRecordFailure() {
        launchPlayback43("valid"); waitPlayingFixture()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(playback43Entries().isEmpty)
        XCTAssertEqual(playerFields()["created"], "1")
        attachPlayback43("valid")
    }
    func testPoster49CapturesCurrentDecodedFrameWithoutRepair() {
        launchPlayback43("poster-stream49")
        let video = app.otherElements["timeline.media-kind"].buttons["视频"]
        XCTAssertTrue(video.waitForExistence(timeout: 5))
        if !video.isSelected { video.tap() }
        waitUntil("A failed declared JPEG should be replaced by the existing native player's current frame", timeout: 20) {
            self.playback43Entries().contains { $0["code"] as? String == "posterCaptured" }
        }
        let events = playback43Entries()
        let failure = events.first { $0["code"] as? String == "posterFailed" }?["playback"] as? [String: Any]
        XCTAssertEqual(failure?["posterStage"] as? String, "declaredImage")
        XCTAssertEqual(failure?["posterFailure"] as? String, "decode")
        XCTAssertFalse(events.contains { $0["code"] as? String == "repairStarted" }, "Capturing a displayed frame must not invoke conversion")
        XCTAssertEqual(playerFields()["created"], "1", "The existing native player supplies the frame")
        XCTAssertEqual(playerFields()["muted"], "true")
        let poster = app.descendants(matching: .any)["poster.qa.146087479"]
        XCTAssertTrue(poster.waitForValueToContain("state=ready", timeout: 5))
        attachPlayback43("poster-stream49-current-frame")
        app.buttons.matching(NSPredicate(format: "label == %@", "作品详情")).firstMatch.tap()
        XCTAssertTrue(floatingPageTitle("作品详情").waitForExistence(timeout: 5))
        let preview = app.descendants(matching: .any)["details.preview"]
        XCTAssertTrue(preview.exists)
        let detailPoster = preview.descendants(matching: .any)["poster.qa.146087479"]
        print("POSTER49_DETAIL \(detailPoster.debugDescription)")
        attachScreenshot(named: "poster49-details-visible-before-readback")
        XCTAssertTrue(detailPoster.waitForValueToContain("state=ready", timeout: 5))
        XCTAssertFalse(app.buttons["details.poster.retry"].exists)
        attachScreenshot(named: "poster49-details-reuses-captured-frame")
    }

    private func launchPosterDetails50(missing: Bool = false) {
        app = XCUIApplication(); XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--qa-collection-paging", "--qa-playback-diagnostics43=poster-stream49",
                               "--qa-poster-details50", "-muted", "YES"] + (missing ? ["--qa-poster-missing50"] : [])
        app.launch()
        XCTAssertTrue(floatingPageTitle("作品详情").waitForExistence(timeout: 10))
    }
    func testPoster50LocalVideoRepairsBrokenDeclaredCover() {
        launchPosterDetails50()
        let preview = app.descendants(matching: .any)["details.preview"]
        let poster = preview.descendants(matching: .any)["poster.qa.146087479"]
        XCTAssertTrue(poster.waitForValueToContain("state=ready", timeout: 12))
        waitUntil("The local recovery and route must persist their finite diagnostic stages") {
            let events = self.playback43Entries()
            return events.contains { $0["code"] as? String == "posterOpened" && ($0["playback"] as? [String: Any])?["posterStage"] as? String == "detailsVideo" } &&
                events.contains { $0["code"] as? String == "posterLoaded" && ($0["playback"] as? [String: Any])?["posterStage"] as? String == "cacheWrite" }
        }
        let events = playback43Entries()
        XCTAssertFalse(events.contains { ["repairStarted", "posterCaptured", "posterCaptureStarted"].contains($0["code"] as? String ?? "") })
        XCTAssertFalse(app.descendants(matching: .any)["media.qa.player"].exists, "The detail preview must not create a player")
        XCTAssertFalse(app.buttons["details.poster.retry"].exists)
        attachPlayback43("poster50-local-recovery")
    }
    func testPoster50UnavailableRouteIsRecordedWithoutRequest() {
        launchPosterDetails50(missing: true)
        XCTAssertTrue(app.descendants(matching: .any)["details.preview"].staticTexts["暂无可用封面"].exists)
        waitUntil("A rejected source is recorded without inventing a URL or request") {
            self.playback43Entries().contains {
                let context = $0["playback"] as? [String: Any]
                return $0["code"] as? String == "posterOpened" && context?["posterStage"] as? String == "detailsUnavailable" && context?["source"] as? String == "unavailable"
            }
        }
        XCTAssertFalse(playback43Entries().contains { $0["code"] as? String == "posterStarted" })
        XCTAssertFalse(app.buttons["details.poster.retry"].exists)
        attachPlayback43("poster50-unavailable-route")
    }

    func testPoster67NeutralPlaceholderRefreshesWhenAnotherProducerCachesFrame() {
        app = XCUIApplication(); XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--qa-collection-paging", "--qa-playback-diagnostics43=poster-stream49",
                               "--qa-poster-details50", "--qa-poster-late51", "-muted", "YES"]
        app.launch()
        XCTAssertTrue(floatingPageTitle("作品详情").waitForExistence(timeout: 10))
        let preview = app.descendants(matching: .any)["details.preview"]
        let poster = preview.descendants(matching: .any)["poster.qa.146087479"]
        XCTAssertTrue(poster.waitForValueToContain("state=failed", timeout: 12))
        let unavailable = preview.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "暂无可用封面")).firstMatch
        XCTAssertTrue(unavailable.exists)
        XCTAssertEqual(preview.activityIndicators.count, 0)
        XCTAssertFalse(app.buttons["details.poster.retry"].exists)
        attachScreenshot(named: "poster67-neutral-before-frame")
        let producer = app.buttons["poster.qa.generate51"]
        producer.tap()
        XCTAssertTrue(producer.waitForValueToContain("written", timeout: 3), "The real cache writer must commit a valid frame first")
        XCTAssertTrue(poster.waitForValueToContain("state=ready", timeout: 5), "The existing failed detail must refresh without tapping retry or reopening")
        XCTAssertFalse(unavailable.exists)
        XCTAssertFalse(app.buttons["details.poster.retry"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["media.qa.player"].exists, "Cache invalidation does not create a second player")
        attachPlayback43("poster51-late-cache-write")
    }

    func testToolbar49VideoCancelAndNativeBack() {
        visualLaunch(width: 0, large: false, landscape: false, extra: ["--qa-style49"])
        let account = app.buttons["timeline.account"]
        let tools = app.buttons["timeline.tools"]
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        XCTAssertEqual(account.frame.size, tools.frame.size)
        XCTAssertEqual(account.frame.midY, tools.frame.midY, accuracy: 1)
        app.otherElements["timeline.media-kind"].buttons["视频"].tap()
        let favorite = visualButton("favorite-28037102")
        waitUntil("The timeline has switched to the video before opening its favorite editor") {
            self.watchFocus() == 28_037_102 && favorite.isHittable
        }
        openFavoriteFolders(favorite)
        let favoriteEditor = floatingPageTitle("收藏视频")
        XCTAssertTrue(favoriteEditor.waitForExistence(timeout: 5))
        let cancel = favoriteEditor.buttons["取消"]
        let save = favoriteEditor.buttons["保存"]
        let folder = app.buttons["favorite.folder.28037002"]
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        XCTAssertEqual(cancel.frame.width, save.frame.width, accuracy: 1)
        XCTAssertLessThan(cancel.frame.midX, favoriteEditor.frame.midX)
        XCTAssertGreaterThan(save.frame.midX, favoriteEditor.frame.midX)
        XCTAssertGreaterThanOrEqual(folder.frame.minY, favoriteEditor.frame.minY)
        XCTAssertEqual(folder.frame.minX - favoriteEditor.frame.minX, 12, accuracy: 1)
        XCTAssertEqual(favoriteEditor.frame.maxX - folder.frame.maxX, 12, accuracy: 1)
        XCTAssertFalse(app.staticTexts["公开收藏夹中的作品可被他人看到。"].exists)
        attachScreenshot(named: "toolbar49-cancel-before-hit-check")
        waitUntil("The favorite editor cancel button is hittable") { cancel.isHittable }
        XCTAssertGreaterThanOrEqual(cancel.frame.width, 42, "The scaled detent keeps the two icon targets full-sized")
        XCTAssertLessThanOrEqual(cancel.frame.height, 50, "Two Chinese glyphs must stay horizontal in the compact toolbar")
        attachScreenshot(named: "toolbar49-video-favorite-horizontal-cancel")
        cancel.tap()
        XCTAssertTrue(floatingPageTitle("收藏视频").waitForNonExistence(timeout: 5))
        mainTabButton("作者榜").tap()
        XCTAssertFalse(app.buttons["navigation.back"].exists, "Root pages must not acquire a return action")
        let creator = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Pattern Creator 1")).firstMatch
        XCTAssertTrue(creator.waitForExistence(timeout: 5)); creator.tap()
        XCTAssertTrue(app.descendants(matching: .any)["creator.top-bar"].waitForExistence(timeout: 5))
        let state = app.descendants(matching: .any)["navigation.qa49"]
        XCTAssertTrue(state.waitForValueToContain("nativeBackHidden=true", timeout: 5))
        XCTAssertTrue(state.valueDescription.contains("edgeSwipe=true"))
        let back = app.descendants(matching: .any)["creator.top-bar"].buttons["navigation.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        waitUntil("The single visible return action is hittable") { back.isHittable }
        XCTAssertEqual(app.descendants(matching: .any)["creator.top-bar"].buttons.matching(identifier: "navigation.back").count, 1)
        XCTAssertGreaterThanOrEqual(back.frame.width, 44)
        XCTAssertLessThanOrEqual(back.frame.height, 50)
        let more = app.buttons["creator.actions"]
        XCTAssertEqual(back.frame.size, more.frame.size)
        XCTAssertEqual(back.frame.midY, more.frame.midY, accuracy: 1)
        let media = app.otherElements["creator.media-kind"]
        XCTAssertEqual(media.frame.minX - back.frame.maxX, 4, accuracy: 1)
        XCTAssertEqual(more.frame.minX - media.frame.maxX, 4, accuracy: 1)
        more.tap()
        app.buttons["creator.filter"].tap()
        let browseHeader = floatingPageTitle("浏览条件")
        XCTAssertTrue(browseHeader.waitForExistence(timeout: 5))
        attachScreenshot(named: "creator-browse-filter")
        browseHeader.buttons["navigation.back"].tap()
        XCTAssertTrue(browseHeader.waitForNonExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.6))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.015, dy: 0.35)))
        waitUntil("A predominantly vertical edge scroll retains the current page and usable return control") {
            back.isHittable && state.valueDescription.contains("depth=2") && state.valueDescription.contains("transition=false")
        }
        print("BACK49_AFTER_VERTICAL_EDGE \(state.valueDescription)")
        attachScreenshot(named: "toolbar49-flat-back-no-shared-glass")
        print("BACK49_BEFORE_SWIPE \(state.valueDescription)")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        let returned = app.descendants(matching: .any)["leaderboard.top-bar"].waitForExistence(timeout: 5)
        print("BACK49_AFTER_SWIPE \(state.valueDescription)")
        XCTAssertTrue(returned, "System interactive back swipe remains usable")
        XCTAssertFalse(app.buttons["navigation.back"].exists)
        creator.tap()
        XCTAssertTrue(back.waitForExistence(timeout: 5)); back.tap()
        XCTAssertTrue(app.descendants(matching: .any)["leaderboard.top-bar"].waitForExistence(timeout: 5), "The flat return control dismisses through SwiftUI")
    }
    func testFlatBack49NestedCollectionsAndNoAccess() {
        func openCollections() {
            mainTabButton("收藏").tap()
            XCTAssertTrue(app.descendants(matching: .any)["collections.top-bar"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.descendants(matching: .any)["collections.top-bar"].buttons.matching(identifier: "navigation.back").count, 0)
        }
        visualLaunch(width: 0, large: false, landscape: false, extra: ["--qa-style49"])
        openCollections()
        let downloads = app.descendants(matching: .any)["collections.top-bar"].buttons["collections.downloads"]
        XCTAssertTrue(downloads.waitForExistence(timeout: 5)); downloads.tap()
        let bar = floatingPageTitle("下载管理")
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        XCTAssertEqual(bar.buttons.matching(identifier: "navigation.back").count, 1)
        waitUntil("Nested collection return is hittable") { bar.buttons["navigation.back"].isHittable }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 1)
        print("BACK49_AFTER_SHORT_SWIPE \(app.descendants(matching: .any)["navigation.qa49"].valueDescription)")
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "A short interactive pop cancels and retains download management")
        waitUntil("Cancelled transition keeps the return action usable") { bar.buttons["navigation.back"].isHittable }
        attachScreenshot(named: "toolbar49-depth3-cancelled-pop")
        bar.buttons["navigation.back"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["collections.top-bar"].waitForExistence(timeout: 5))
        downloads.tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        XCTAssertTrue(app.descendants(matching: .any)["collections.top-bar"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["navigation.back"].exists)
        app.terminate()
        visualLaunch(width: 0, large: false, landscape: false, extra: ["--qa-style49", "--qa-no-collection-access49"])
        openCollections()
        XCTAssertTrue(app.staticTexts["启用账号收藏"].exists)
        attachScreenshot(named: "toolbar49-no-collection-access-one-back")
        app.buttons["补充收藏授权"].tap()
        let login = floatingPageTitle("启用账号收藏")
        XCTAssertTrue(login.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["前往 Civitai 授权"].isHittable)
        login.buttons["关闭"].tap()
        XCTAssertTrue(app.staticTexts["启用账号收藏"].isHittable)
        XCTAssertTrue(downloads.isHittable)
        XCTAssertEqual(downloads.frame.width, 44, accuracy: 1, "The icon link must not inherit a whole-row hit frame")
        downloads.tap()
        XCTAssertTrue(floatingPageTitle("下载管理").waitForExistence(timeout: 5))
        app.terminate()
        visualLaunch(width: 0, large: false, landscape: false, extra: ["--qa-style49", "--qa-no-collections"])
        openCollections()
        XCTAssertTrue(app.staticTexts["暂无收藏作品"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["新建私密收藏夹"].exists)
    }
    func testRepair47VP9AutomaticallyEscalatesToH264AndDisplaysFrame() {
        assertAutomaticRepair47("repair-vp9", codec: 3)
    }
    func testRepair47VP8AutomaticallyTranscodesAndDisplaysFrame() {
        assertAutomaticRepair47("repair-vp8", codec: 4)
    }
    func testRepair47BrokenBrowserCacheStillRetriesOriginal() {
        launchPlayback43("bad-cache", automatic: true)
        waitPlayingFixture()
        let failures = playback43Entries().filter { $0["code"] as? String == "playbackFailed" }
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual((failures.first?["playback"] as? [String: Any])?["source"] as? String, "cache")
        XCTAssertEqual(playerFields()["created"], "2")
        XCTAssertEqual(playerFields()["muted"], "true")
        attachPlayback43("broken-cache-auto")
    }
    func testPreparation62OrdinaryWaitingIsSilentAndRepairRemainsCancelable() {
        app = XCUIApplication(); app.launchArguments = ["--qa-preparation48", "-muted", "YES"]; app.launch()
        let panel = app.descendants(matching: .any).matching(identifier: "media.preparation").firstMatch
        let waiting = app.descendants(matching: .any).matching(identifier: "media.waiting").firstMatch
        let qa = app.descendants(matching: .any).matching(identifier: "media.qa.preparation48").firstMatch
        XCTAssertTrue(qa.waitForExistence(timeout: 5)); XCTAssertTrue(waiting.waitForExistence(timeout: 5))
        func state() -> String { qa.value as? String ?? qa.label }
        XCTAssertFalse(panel.exists, "Ordinary loading must have no text strip")
        XCTAssertTrue(state().contains("panel=0,0,0,0"))
        XCTAssertLessThanOrEqual(waiting.frame.width, 24); XCTAssertLessThanOrEqual(waiting.frame.height, 24)
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.65)
        waitUntil("The spinner cannot intercept a center hold") { state().contains("chromeHoldCount=1") }
        XCTAssertTrue(state().contains("tapCount=0"))
        attachScreenshot(named: "loading62-current-only-center-spinner")
        app.buttons["修复 65%"].tap()
        XCTAssertTrue(panel.waitForExistence(timeout: 5)); XCTAssertTrue(panel.valueDescription.contains("progress=0.65"))
        XCTAssertTrue(app.staticTexts["media.preparation.progress"].exists)
        for text in ["正在转换视频格式", "正在加载原生播放器", "正在准备兼容播放器", "缓存视频", "首次播放，正在适配格式"] {
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists)
        }
        let band = app.descendants(matching: .any)["media.progress-band"].firstMatch
        XCTAssertEqual(band.frame.height, 44, accuracy: 1)
        XCTAssertTrue(band.frame.insetBy(dx: -1, dy: -1).contains(panel.frame))
        let cancel = app.buttons["media.preparation.cancel"]
        XCTAssertTrue(cancel.exists); XCTAssertEqual(cancel.frame.height, 44, accuracy: 1)
        attachScreenshot(named: "loading62-repair-progress-and-cancel")
        tapScreenFrame(cancel.frame)
        waitUntil("Cancel clears the repair strip and its gesture exclusion") {
            state().contains("stage=hidden;visible=0;presented=0;cancelCount=1") && state().contains("panel=0,0,0,0")
        }
        XCTAssertTrue(waiting.waitForNonExistence(timeout: 2))
        app.buttons["新播放器"].tap()
        XCTAssertTrue(waiting.waitForExistence(timeout: 3)); XCTAssertFalse(panel.exists)
        XCTAssertFalse(app.buttons["media.preparation.cancel"].exists)
        app.buttons["修复 65%"].tap()
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        XCTAssertTrue(panel.valueDescription.contains("progress=0.65"))
    }
    func testEmpty63FilteredCurrentShowsLoadingFailureAndRetry() {
        app = XCUIApplication(); app.launchArguments = ["--qa-collection-paging", "--qa-empty-deck63", "-muted", "YES", "-autoplay", "YES"]; app.launch()
        let state = app.descendants(matching: .any)["empty.qa.state"].firstMatch
        let empty = app.descendants(matching: .any)["media.empty.state"].firstMatch
        let loading = app.descendants(matching: .any)["feed.continuation.loading"].firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 10)); XCTAssertTrue(state.valueDescription.contains("raw=1"))
        XCTAssertTrue(empty.waitForExistence(timeout: 5)); XCTAssertTrue(loading.waitForExistence(timeout: 5), "A filtered current viewport must never be silent black while scanning")
        XCTAssertFalse(app.descendants(matching: .any)["media-page-900000063"].firstMatch.exists, "The source work stays blocked; do not weaken visibility to fill the page")
        attachScreenshot(named: "empty63-filtered-current-loading")
        app.buttons["empty.qa.ready"].tap()
        XCTAssertTrue(app.staticTexts["media.empty.message"].waitForExistence(timeout: 3))
        app.buttons["media.empty.continue"].tap()
        XCTAssertTrue(state.waitForValueToContain("requests=1", timeout: 3)); XCTAssertTrue(loading.exists)
        app.buttons["empty.qa.fail"].tap()
        XCTAssertTrue(app.staticTexts["app.toast"].waitForExistence(timeout: 3))
        let retry = app.buttons["feed.continuation.retry"]
        XCTAssertTrue(retry.exists && retry.isHittable)
        attachScreenshot(named: "empty63-current-failure-retry")
        retry.tap()
        XCTAssertTrue(state.waitForValueToContain("requests=2", timeout: 3)); XCTAssertTrue(loading.exists)
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        XCTAssertTrue(state.valueDescription.contains("requests=2"), "No new timer-driven request loop may be introduced")
        app.buttons["empty.qa.recover"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["media-page-900000063"].firstMatch.waitForExistence(timeout: 5))
        waitPlayingFixture()
        XCTAssertTrue(empty.waitForNonExistence(timeout: 3))
        XCTAssertFalse(loading.exists)
        attachScreenshot(named: "empty63-recovered-real-video")
        app.terminate()
    }
    func testEmpty63ClearThenFilteredEndCanExitRealViewer() {
        app = XCUIApplication(); app.launchArguments = ["--qa-collection-paging", "--qa-empty-deck63", "-muted", "YES", "-autoplay", "YES"]; app.launch()
        XCTAssertTrue(app.buttons["empty.qa.recover"].waitForExistence(timeout: 10)); app.buttons["empty.qa.recover"].tap()
        waitPlayingFixture()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.65)
        XCTAssertTrue(chromeState().waitForValueToContain("hidden=true", timeout: 4))
        app.buttons["empty.qa.block"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["media.empty.state"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(chromeState().waitForValueToContain("hidden=false", timeout: 4))
        XCTAssertTrue(app.descendants(matching: .any)["feed.continuation.ended"].firstMatch.exists)
        let close = app.buttons["关闭作品"]
        XCTAssertTrue(close.exists && close.isHittable); close.tap()
        XCTAssertTrue(app.staticTexts["empty.qa.closed"].waitForExistence(timeout: 4))
        attachScreenshot(named: "empty63-clear-filter-end-real-exit")
        app.terminate()
    }
    func testEmpty63ClearThenInvalidSourceRevealsDetailsAndExit() {
        app = XCUIApplication(); app.launchArguments = ["--qa-collection-paging", "--qa-empty-deck63", "-muted", "YES", "-autoplay", "YES"]; app.launch()
        XCTAssertTrue(app.buttons["empty.qa.recover"].waitForExistence(timeout: 10)); app.buttons["empty.qa.recover"].tap()
        waitPlayingFixture()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.65)
        XCTAssertTrue(chromeState().waitForValueToContain("hidden=true", timeout: 4))
        app.buttons["empty.qa.invalid"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["media.source.unavailable"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(chromeState().waitForValueToContain("hidden=false", timeout: 4))
        let details = app.buttons.matching(NSPredicate(format: "label == %@", "作品详情")).firstMatch
        XCTAssertTrue(details.exists && details.isHittable)
        let close = app.buttons["关闭作品"]
        XCTAssertTrue(close.exists && close.isHittable); close.tap()
        XCTAssertTrue(app.staticTexts["empty.qa.closed"].waitForExistence(timeout: 4))
        attachScreenshot(named: "empty63-clear-invalid-real-exit")
        app.terminate()
    }
    func testEmpty63InvalidVideoSourceKeepsAuthorAndDetails() {
        app = XCUIApplication(); app.launchArguments = ["--qa-collection-paging", "--qa-empty-deck63", "-muted", "YES"]; app.launch()
        XCTAssertTrue(app.buttons["empty.qa.invalid"].waitForExistence(timeout: 10))
        app.buttons["empty.qa.invalid"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["media.source.unavailable"].firstMatch.waitForExistence(timeout: 5))
        let details = app.buttons.matching(NSPredicate(format: "label == %@", "作品详情")).firstMatch
        XCTAssertTrue(details.exists && details.isHittable)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Synthetic_Blank_Page")).firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["media.empty.state"].firstMatch.exists)
        attachScreenshot(named: "empty63-invalid-source-actionable-page")
        app.terminate()
    }
    func testBuffer62CurrentWaitPauseClearAndRecoveryKeepCanvas() {
        visualLaunch(width: 320, large: false, landscape: false,
                     extra: ["--qa-buffering62", "--qa-chrome-geometry", "-autoplay", "YES", "-muted", "YES"])
        app.otherElements["timeline.media-kind"].buttons["视频"].tap()
        waitPlayingFixture()
        let waiting = app.descendants(matching: .any).matching(identifier: "media.waiting").firstMatch
        XCTAssertTrue(waiting.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(waiting.frame.height, 24)
        XCTAssertFalse(app.descendants(matching: .any)["media.preparation"].firstMatch.exists)
        for text in ["正在加载视频", "正在缓冲画面", "正在加载原生播放器"] { XCTAssertFalse(app.staticTexts[text].exists) }
        let initial = playerFields()
        XCTAssertEqual(initial["posterMode"], "hidden", "Buffering after a native frame is ready must keep the video instead of its cover")
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        center.tap()
        waitUntil("A user pause removes the wait indicator") { self.playerFields()["intent"] == "false" }
        XCTAssertTrue(waiting.waitForNonExistence(timeout: 3))
        let rail = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "播放进度")).firstMatch
        XCTAssertTrue(rail.valueDescription.contains("segments=0.0:0.2,0.4:0.6"), "Native track preserves the injected unloaded gap")
        attachScreenshot(named: "buffer62-native-track-with-loaded-gap")
        center.tap()
        waitUntil("A second tap preserves the existing play command") { self.playerFields()["intent"] == "true" }
        XCTAssertEqual(playerFields()["posterMode"], "hidden")
        XCTAssertTrue(waiting.waitForExistence(timeout: 3))
        center.press(forDuration: 0.65)
        XCTAssertTrue(chromeState().waitForValueToContain("hidden=true", timeout: 4))
        XCTAssertTrue(waiting.waitForNonExistence(timeout: 3))
        center.press(forDuration: 0.65)
        XCTAssertTrue(chromeState().waitForValueToContain("hidden=false", timeout: 4))
        XCTAssertTrue(waiting.waitForExistence(timeout: 3))
        waitUntil("Video geometry is available before recovery") { self.videoGeometryReadback() != nil }
        let before = videoGeometryReadback()!
        app.buttons["media.qa.buffering-toggle"].tap()
        XCTAssertTrue(waiting.waitForNonExistence(timeout: 2), "Ready playback must clear the spinner without a minimum display hold")
        let after = videoGeometryReadback()!
        for field in ["surfaceBounds", "surfaceWindow", "videoRect", "videoWindow", "sourceScale", "transform"] {
            XCTAssertEqual((before.fields[field] as? NSDictionary), (after.fields[field] as? NSDictionary), "Recovery cannot move the canvas: \(field)")
        }
        let final = playerFields()
        XCTAssertEqual(final["player"], initial["player"]); XCTAssertEqual(final["created"], initial["created"])
        XCTAssertEqual(final["muted"], "true")
        XCTAssertFalse(app.descendants(matching: .any)["media.preparation"].firstMatch.exists)
        attachScreenshot(named: "buffer62-recovered-without-loading-copy")
    }
    func testBuffer62AutoplayOffHasNoWaitIndicator() {
        visualLaunch(width: 320, large: true, landscape: false,
                     extra: ["--qa-buffering62", "-autoplay", "NO", "-muted", "YES"])
        app.otherElements["timeline.media-kind"].buttons["视频"].tap()
        waitUntil("The local player is ready while autoplay is off") { self.playerFields()["ready"] == "true" }
        XCTAssertEqual(playerFields()["intent"], "false")
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertFalse(app.descendants(matching: .any)["media.waiting"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["media.preparation"].firstMatch.exists)
        attachScreenshot(named: "buffer62-paused-large-type-without-spinner")
        app.terminate()
    }
    func testStartup177AutoplayDoesNotPresentPausedWhilePreparing() {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-startup-held177", "-autoplay", "YES", "-muted", "YES"])
        app.otherElements["timeline.media-kind"].buttons["视频"].tap()
        waitUntil("The actual player preparation is held before it can bind a player") { self.playerFields()["startupHeld177"] == "true" }
        let held = playerFields()
        print("STARTUP177 held=\(held)")
        attachScreenshot(named: "startup177-before-preparation-finishes")
        XCTAssertEqual(held["pausedHUD"], "false", "Autoplay preparation must never impersonate a user pause")
        app.buttons["media.qa.finish-prepare177"].tap()
        waitPlayingFixture()
        XCTAssertEqual(playerFields()["pausedHUD"], "false")
    }

    func testStartup177PauseDuringPreparationChangesIntent() {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-startup-held177", "-autoplay", "YES", "-muted", "YES"])
        app.otherElements["timeline.media-kind"].buttons["视频"].tap()
        waitUntil("Preparation is held while autoplay is requested") { self.playerFields()["startupHeld177"] == "true" }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        waitUntil("A tap reverses autoplay intent even before the native player exists") {
            self.playerFields()["wantsPlayback"] == "false"
        }
        app.buttons["media.qa.finish-prepare177"].tap()
        waitUntil("The paused native player has a drawable frame") { self.playerFields()["nativeVisible"] == "true" }
        let paused = playerFields()
        XCTAssertEqual(paused["intent"], "false"); XCTAssertEqual(paused["pausedHUD"], "true")
        XCTAssertEqual(paused["rate"], "0.0"); XCTAssertEqual(paused["muted"], "true")
        print("STARTUP177 explicit-pause=\(paused)")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        waitPlayingFixture()
        XCTAssertEqual(playerFields()["pausedHUD"], "false")
    }

    func testStartup177NativePrerollDoesNotRevealPausedFrame() {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-native-start-held177", "-autoplay", "YES", "-muted", "YES"])
        app.otherElements["timeline.media-kind"].buttons["视频"].tap()
        waitUntil("The actual native layer is ready but its transport remains paused") {
            let state = self.playerFields()
            return state["ready"] == "true" && state["layerReady"] == "true" && state["timeStatus"] == "0"
        }
        let before = playerFields()
        XCTAssertEqual(before["nativeVisible"], "false")
        XCTAssertEqual(before["pausedHUD"], "false")
        XCTAssertEqual(before["preview177"], "poster")
        print("STARTUP177 native-held=\(before)")
        attachScreenshot(named: "startup177-native-preroll-keeps-cover")
        app.buttons["media.qa.native-start177"].tap()
        waitPlayingFixture()
        waitUntil("Native playback replaces the cover after it really starts") { self.playerFields()["nativeVisible"] == "true" }
        XCTAssertEqual(playerFields()["posterMode"], "hidden")
        XCTAssertEqual(playerFields()["player"], before["player"])
        XCTAssertEqual(playerFields()["created"], before["created"])
    }

    func testStartup177LateWarmFrameKeepsAlreadyVisibleCover() {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-buffering62", "--qa-neighbor-first-frame", "--qa-late-transition177", "-autoplay", "YES", "-muted", "YES"])
        app.otherElements["timeline.media-kind"].buttons["视频"].tap()
        waitPlayingFixture()
        XCTAssertTrue(app.staticTexts["media.qa.transition-frames"].waitForValueToContain("frames=1", timeout: 8))
        heightDeck().swipeUp()
        waitUntil("The next work displays its cover while a warm image is held back") {
            let state = self.playerFields()
            return self.watchFocus() == 28_037_104 && state["preview177"] == "poster" && state["lateTransition177"] == "false"
        }
        let before = playerFields()
        app.buttons["media.qa.release-warm177"].tap()
        waitUntil("The decoded neighbor frame arrives after the existing cover") { self.playerFields()["lateTransition177"] == "true" }
        let after = playerFields()
        XCTAssertEqual(after["preview177"], "poster", "An already visible valid cover must not swap to a late warm frame")
        XCTAssertEqual(after["transitionFrame"], "false"); XCTAssertEqual(after["nativeVisible"], "false")
        XCTAssertEqual(after["pausedHUD"], "false"); XCTAssertEqual(after["player"], before["player"])
        print("STARTUP177 late-warm before=\(before);after=\(after)")
        attachScreenshot(named: "startup177-late-warm-keeps-existing-cover")
        app.buttons["media.qa.buffering-toggle"].tap()
        waitPlayingFixture()
        waitUntil("The same native player replaces the retained cover") { self.playerFields()["nativeVisible"] == "true" }
        XCTAssertEqual(playerFields()["posterMode"], "hidden")
    }

    func testPoster177SameSourceRefreshKeepsExistingImage() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-playback-diagnostics43=poster-stream49",
                               "--qa-poster-details50", "--qa-cover-refresh177", "-muted", "YES"]
        app.launch()
        let poster = app.descendants(matching: .any)["details.preview"].descendants(matching: .any)["poster.qa.146087479"]
        XCTAssertTrue(poster.waitForValueToContain("state=ready", timeout: 15))
        let producer = app.buttons["poster.qa.generate51"]
        producer.tap()
        waitUntil("The real cache producer confirms a completed write", timeout: 10) { producer.valueDescription == "written" }
        print("POSTER177 producer=\(producer.valueDescription)")
        XCTAssertTrue(poster.waitForValueToContain("refreshing177=true", timeout: 5))
        print("POSTER177 refreshing=\(poster.valueDescription)")
        attachScreenshot(named: "poster177-during-same-source-refresh")
        XCTAssertTrue(poster.valueDescription.contains("state=ready"), "A same-source refresh must keep the already decoded frame visible")
        app.buttons["poster.qa.release177.146087479"].tap()
        XCTAssertTrue(poster.waitForValueToContain("refreshing177=false", timeout: 5))
        XCTAssertTrue(poster.valueDescription.contains("state=ready"))
    }

    func testAutoplayUsesCoverOnlyWhileFirstFrameIsLate() {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-buffering62", "--qa-first-frame-poster", "-autoplay", "YES", "-muted", "YES"])
        app.otherElements["timeline.media-kind"].buttons["视频"].tap()
        waitUntil("Delayed first frame can use a real local cover") {
            let state = self.playerFields()
            return state["posterMode"] == "imageOnly" && state["coverReady"] == "true"
        }
        XCTAssertFalse(app.descendants(matching: .any)["media.waiting"].firstMatch.exists)
        app.buttons["media.qa.buffering-toggle"].tap()
        waitPlayingFixture()
        XCTAssertEqual(playerFields()["posterMode"], "hidden", "The native frame immediately replaces the cover")
        XCTAssertFalse(app.descendants(matching: .any)["media.waiting"].firstMatch.exists)
    }
    func testCachedNeighborShowsDecodedFrameWhileNativePlaybackStarts() {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-buffering62", "--qa-neighbor-first-frame", "-autoplay", "YES", "-muted", "YES"])
        app.otherElements["timeline.media-kind"].buttons["视频"].tap()
        waitPlayingFixture()
        let warm = app.staticTexts["media.qa.transition-frames"]
        XCTAssertTrue(warm.waitForValueToContain("frames=1", timeout: 8), "Decode the cached next video while its page is still offscreen")
        XCTAssertEqual(watchFocus(), 28_037_102)
        heightDeck().swipeUp()
        waitUntil("The next work becomes current") { self.watchFocus() == 28_037_104 }
        waitUntil("The prepared frame bridges the next work's native first-frame wait") {
            let fields = self.playerFields()
            return fields["transitionFrame"] == "true" && fields["posterMode"] == "hidden"
        }
        XCTAssertFalse(app.descendants(matching: .any)["media.waiting"].firstMatch.exists)
        attachScreenshot(named: "neighbor-cached-first-frame")
        app.buttons["media.qa.buffering-toggle"].tap()
        waitPlayingFixture()
        XCTAssertEqual(playerFields()["transitionFrame"], "false")
        XCTAssertEqual(playerFields()["posterMode"], "hidden")
    }
    func testPlaybackSessionsRetainCoveredAndPromoteNext172() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-visual-controls", "--qa-playback-sessions172",
                               "--qa-header-motion", "--qa-page-return", "--qa-continuous59", "--qa-native-layout64",
                               "-autoplay", "YES", "-muted", "YES"]
        app.launch()
        XCTAssertTrue(timelineTools().waitForExistence(timeout: 10))
        app.otherElements["timeline.media-kind"].buttons["视频"].tap()
        waitPlayingFixture()
        waitUntil("The current video advances before covering it") { (Double(self.playerFields()["position"] ?? "0") ?? 0) > 0.7 }
        let deck = heightDeck().frame
        let center = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: deck.midX, dy: deck.minY + 130))
        center.tap()
        waitUntil("Manual pause is recorded") { self.playerFields()["intent"] == "false" && self.playerFields()["rate"] == "0.0" }
        let before = playerFields()
        visualButton("media.author.28172000").tap()
        let creator = app.otherElements["creator.top-bar"]
        XCTAssertTrue(creator.waitForExistence(timeout: 5))
        creator.buttons["navigation.back"].tap()
        XCTAssertTrue(creator.waitForNonExistence(timeout: 5))
        waitUntil("The preserved paused player has a drawable layer and parent readiness again") {
            self.playerFields()["ready"] == "true" && self.app.staticTexts["media.qa.parent-ready"].valueDescription.contains("ready=true")
        }
        let returned = playerFields()
        XCTAssertEqual(returned["player"], before["player"])
        XCTAssertEqual(returned["created"], before["created"])
        XCTAssertEqual(returned["seekCallbacks"], before["seekCallbacks"])
        XCTAssertEqual(returned["intent"], "false"); XCTAssertEqual(returned["rate"], "0.0")
        XCTAssertEqual(Double(returned["nativePosition"] ?? "-1") ?? -1,
                       Double(before["nativePosition"] ?? "-10") ?? -10, accuracy: 0.12)
        print("PLAYBACK172_RETURN before=\(before);after=\(returned)")
        for edge in [0.02, 0.98] {
            visualButton("media.author.28172000").tap()
            XCTAssertTrue(creator.waitForExistence(timeout: 5))
            let window = app.windows.firstMatch
            window.coordinate(withNormalizedOffset: CGVector(dx: edge, dy: 0.48))
                .press(forDuration: 0.05,
                       thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: edge < 0.5 ? 0.55 : 0.45, dy: 0.48)),
                       withVelocity: XCUIGestureVelocity(rawValue: 180), thenHoldForDuration: 0.1)
            XCTAssertTrue(creator.waitForNonExistence(timeout: 5))
            waitUntil("Edge return restores the same paused native player") {
                self.playerFields()["player"] == before["player"] && self.playerFields()["ready"] == "true"
                    && self.app.staticTexts["media.qa.parent-ready"].valueDescription.contains("ready=true")
            }
            let edgeReturned = playerFields()
            XCTAssertEqual(edgeReturned["created"], before["created"])
            XCTAssertEqual(edgeReturned["seekCallbacks"], before["seekCallbacks"])
            XCTAssertEqual(edgeReturned["intent"], "false")
            XCTAssertEqual(Double(edgeReturned["nativePosition"] ?? "-1") ?? -1,
                           Double(before["nativePosition"] ?? "-10") ?? -10, accuracy: 0.12)
        }
        center.tap(); waitPlayingFixture()
        for next in 28_172_001...28_172_003 {
            waitUntil("Exactly the next local candidate completes preroll", timeout: 10) {
                let candidate = self.playerFields()["candidate"] ?? ""
                return candidate.hasPrefix("\(next):") && candidate.hasSuffix(":true")
            }
            let candidate = (playerFields()["candidate"] ?? "").split(separator: ":").map(String.init)
            XCTAssertEqual(candidate.count, 3)
            XCTAssertLessThanOrEqual(Int(playerFields()["poolCount"] ?? "99") ?? 99, 3)
            XCTAssertEqual(Int(playerFields()["poolPlaying"] ?? "99"), 1)
            heightDeck().swipeUp()
            waitUntil("Focus commits the warmed next video") { self.watchFocus() == next }
            waitPlayingFixture()
            let promoted = playerFields()
            XCTAssertEqual(promoted["player"], candidate[1], "Promotion reuses the exact warmed AVPlayer")
            XCTAssertEqual(promoted["created"], "0", "A warmed page does not create a second player on activation")
            XCTAssertLessThanOrEqual(Int(promoted["poolCount"] ?? "99") ?? 99, 3)
            XCTAssertEqual(promoted["poolPlaying"], "1")
            print("PLAYBACK172_PROMOTION work=\(next);state=\(promoted)")
        }
    }

    func testFastSwipeNetworkPlaybackReachesFinalVisibleFrame() async throws {
        app = XCUIApplication()
        let run = UUID().uuidString
        app.launchArguments = ["--qa-collection-paging", "--qa-visual-controls", "--qa-continuous59",
                               "--qa-native-layout64", "--qa-fast-swipe-network=\(run)",
                               "-autoplay", "YES", "-muted", "YES", "-wifiVideoPrefetch", "NO"]
        let control = URL(string: "http://localhost:49371/\(run)/")!
        func command(_ name: String) async throws {
            let (_, response) = try await URLSession.shared.data(from: control.appendingPathComponent(name))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        }
        try await command("ready")
        app.launch()
        XCTAssertTrue(timelineTools().waitForExistence(timeout: 10))
        app.otherElements["timeline.media-kind"].buttons["视频"].tap()
        waitPlayingFixture()
        for id in 28_193_401...28_193_403 {
            heightDeck().swipeUp()
            waitUntil("The next video becomes active while the server is still holding its bytes") {
                self.watchFocus() == id && self.playerFields()["player"] != "none" &&
                    self.playerFields()["source"] == "network"
            }
            XCTAssertEqual(playerFields()["nativeCommitted"], "false")
            XCTAssertEqual(playerFields()["muted"], "true")
        }
        let finalPlayer = try XCTUnwrap(playerFields()["player"])
        let start = ProcessInfo.processInfo.systemUptime
        try await command("release-final")
        waitUntil("The final video draws a real frame and plays", timeout: 8) {
            let fields = self.playerFields()
            return self.watchFocus() == 28_193_403 && fields["nativeCommitted"] == "true" &&
                fields["rate"] == "1.0" && (Double(fields["position"] ?? "") ?? -1) > 0.2
        }
        let timeToPlaying = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
        let playing = playerFields()
        try await command("release-skipped")
        waitUntil("Late responses for skipped works leave playback on the final video") {
            self.playerFields()["player"] == finalPlayer &&
                (Double(self.playerFields()["position"] ?? "") ?? -1) > (Double(playing["position"] ?? "") ?? 0) + 0.3
        }
        let final = playerFields()
        XCTAssertEqual(watchFocus(), 28_193_403)
        XCTAssertEqual(final["player"], finalPlayer)
        XCTAssertEqual(final["nativeCommitted"], "true")
        XCTAssertEqual(final["poolPlaying"], "1")
        XCTAssertEqual(final["muted"], "true")
        print("FAST_SWIPE_NETWORK run=\(run) work=28193403 releaseToPlayingMS=\(timeToPlaying) nativeFirstFrameMS=\(final["firstFrameMS"] ?? "missing")")
    }

    func testTimelineReusesLocalPlayersOnImmediateReverseSwipe() throws {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-visual-controls", "--qa-playback-sessions172",
                               "--qa-continuous59", "--qa-native-layout64", "-autoplay", "YES", "-muted", "YES"]
        app.launch()
        XCTAssertTrue(timelineTools().waitForExistence(timeout: 10))
        app.otherElements["timeline.media-kind"].buttons["视频"].tap()
        waitPlayingFixture()
        let firstID = 28_172_000
        let firstPlayer = try XCTUnwrap(playerFields()["player"])
        func waitForNext(_ id: Int) {
            waitUntil("The next local video has completed preroll") {
                let candidate = self.playerFields()["candidate"] ?? ""
                return candidate.hasPrefix("\(id):") && candidate.hasSuffix(":true")
            }
        }
        func checkPlaying(_ id: Int) -> [String: String] {
            waitUntil("The requested timeline work has focus and a visible native frame") {
                self.watchFocus() == id && self.playerFields()["layerReady"] == "true"
            }
            self.waitPlayingFixture()
            let fields = self.playerFields()
            print("TIMELINE_BUFFER work=\(id) player=\(fields["player"] ?? "-") pool=\(fields["poolCount"] ?? "-") firstFrameMS=\(fields["firstFrameMS"] ?? "-")")
            XCTAssertEqual(fields["poolPlaying"], "1")
            XCTAssertLessThanOrEqual(Int(fields["poolCount"] ?? "99") ?? 99, 3)
            return fields
        }
        waitForNext(firstID + 1)
        heightDeck().swipeUp()
        let secondPlayer = try XCTUnwrap(checkPlaying(firstID + 1)["player"])
        waitForNext(firstID + 2)
        let middle = playerFields()
        XCTAssertEqual(middle["retainedNeighbor"], "\(firstID):\(firstPlayer)")
        XCTAssertEqual(middle["poolCount"], "3")
        heightDeck().swipeDown()
        XCTAssertEqual(checkPlaying(firstID)["player"], firstPlayer, "Reversing must reuse the original AVPlayer")
        heightDeck().swipeUp()
        XCTAssertEqual(checkPlaying(firstID + 1)["player"], secondPlayer, "The second visit must reuse its AVPlayer too")
    }

    func testPlayingTimelineResumesAfterViewingLeaderboard() {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-header-motion", "--qa-body-motion", "-autoplay", "YES", "-muted", "YES"])
        app.otherElements["timeline.media-kind"].buttons["视频"].tap()
        waitPlayingFixture()
        let work = watchFocus()
        mainTabButton("作者榜").tap()
        waitUntil("The leaderboard is active") {
            self.mainTabButton("作者榜").isSelected && self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0")
        }
        mainTabButton("时间线").tap()
        waitUntil("The same timeline work is active again") {
            self.mainTabButton("时间线").isSelected && self.watchFocus() == work
        }
        waitPlayingFixture()
        let initial = Double(playerFields()["position"] ?? "") ?? -1
        XCTAssertGreaterThanOrEqual(initial, 0)
        waitUntil("Playback advances after returning to the timeline") {
            (Double(self.playerFields()["position"] ?? "") ?? -1) > initial + 0.15
        }
    }

    func testRootReturnRetainsWarmFramesPausedPositionAndIntent170() {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-header-motion", "--qa-body-motion", "-autoplay", "YES", "-muted", "YES"])
        app.otherElements["timeline.media-kind"].buttons["视频"].tap()
        waitPlayingFixture()
        waitUntil("The ordinary current video has advanced") { (Double(self.playerFields()["position"] ?? "0") ?? 0) > 0.7 }
        let deck = heightDeck().frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: deck.midX, dy: deck.minY + 130)).tap()
        waitUntil("Manual pause is accepted") { self.playerFields()["rate"] == "0.0" || self.playerFields()["rate"] == "0" }
        let paused = playerFields()
        let warm = app.staticTexts["media.qa.transition-frames"]
        waitUntil("The local next frame is ready before departure") { (self.heightValues(warm.valueDescription)["frames"] ?? 0) >= 1 }
        let decodes = heightValues(warm.valueDescription)["decodes"] ?? -1
        let focus = watchFocus()
        mainTabButton("作者榜").tap()
        waitUntil("Authors owns the root after departure") {
            self.mainTabButton("作者榜").isSelected && self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0")
        }
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                   withVelocity: XCUIGestureVelocity(rawValue: 180), thenHoldForDuration: 0.1)
        waitUntil("Edge return restores the current work without a tab reselect") {
            self.mainTabButton("时间线").isSelected && self.playerFields()["ready"] == "true"
        }
        XCTAssertEqual(watchFocus(), focus)
        XCTAssertEqual(Double(playerFields()["position"] ?? "-1") ?? -1,
                       Double(paused["position"] ?? "-10") ?? -10, accuracy: 0.5)
        XCTAssertEqual(Double(playerFields()["rate"] ?? "-1"), 0)
        XCTAssertEqual(playerFields()["player"], paused["player"], "A short root departure preserves the exact playback session")
        XCTAssertEqual(playerFields()["created"], paused["created"], "Root reattachment does not recreate the decoder")
        waitUntil("A returned layer has its actual frame before exposing the retained native surface") { self.playerFields()["nativeVisible"] == "true" }
        XCTAssertEqual(playerFields()["entryNative177"], "true", "The stable entry retains presentation across a leaf reattachment")
        XCTAssertEqual(playerFields()["seekCallbacks"], paused["seekCallbacks"], "The retained item needs no duplicate restore seek")
        XCTAssertEqual(Double(playerFields()["prepare"] ?? "0") ?? 0,
                       (Double(paused["prepare"] ?? "0") ?? 0) + 1,
                       "Only reactivation prepares a player; prepared roots must stay static")
        XCTAssertEqual(heightValues(warm.valueDescription)["decodes"], decodes,
                       "The same bounded frame window survives root inactivity without decoding again")
        attachScreenshot(named: "root170-paused-position-and-warm-frame-return")
    }

    func testPreparation62RealPageKeepsCanvasAndActionsUnchanged() {
        for (large, landscape) in [(false, false), (true, true)] {
            visualLaunch(width: 320, large: large, landscape: false, extra: ["--qa-preparation58", "--qa-chrome-geometry", "-autoplay", "YES", "-muted", "YES"])
            app.otherElements["timeline.media-kind"].buttons["视频"].tap()
            waitPlayingFixture()
            if landscape && app.windows.firstMatch.frame.width < app.windows.firstMatch.frame.height { app.buttons["手动切换横竖屏"].tap() }
            heightWaitOrientation(landscape: landscape)
            let cancel = app.buttons["media.preparation.cancel"]
            XCTAssertTrue(cancel.waitForExistence(timeout: 8))
            XCTAssertGreaterThanOrEqual(cancel.frame.height, 44)
            let panel = app.descendants(matching: .any).matching(identifier: "media.preparation").firstMatch
            waitUntil("Actual video geometry is available with inline preparation") { self.videoGeometryReadback() != nil }
            let before = videoGeometryReadback()!
            let details = app.buttons.matching(NSPredicate(format: "label == %@", "作品详情")).firstMatch
            let mute = app.buttons.matching(NSPredicate(format: "label == %@", "取消静音")).firstMatch
            XCTAssertTrue(details.exists && mute.exists)
            XCTAssertFalse(panel.frame.intersects(details.frame), "The entire status must avoid the details target")
            XCTAssertFalse(panel.frame.intersects(mute.frame), "The status must avoid the mute target")
            let band = app.descendants(matching: .any)["media.progress-band"].firstMatch
            print("PREPARATION61_BAND large=\(large);landscape=\(landscape);band=\(band.frame);panel=\(panel.frame);cancel=\(cancel.frame);video=\(before.raw)")
            if abs(band.frame.height - 44) > 1 {
                print("PREPARATION61_BAND_AX \(app.debugDescription)")
                attachScreenshot(named: "loading61-band-height-investigation")
            }
            XCTAssertEqual(band.frame.height, 44, accuracy: 1)
            XCTAssertTrue(band.frame.insetBy(dx: -1, dy: -1).contains(panel.frame))
            let rail = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "播放进度")).firstMatch
            XCTAssertTrue(rail.exists); XCTAssertEqual(band.frame.midY, rail.frame.midY, accuracy: 1)
            attachScreenshot(named: "loading61-real-page-inline-large-\(large)-landscape-\(landscape)")
            tapScreenFrame(cancel.frame)
            let canceled = cancel.waitForNonExistence(timeout: 5)
            if !canceled { print("PREPARATION61_REAL_AX \(app.debugDescription)"); attachScreenshot(named: "loading61-cancel-point-inspection") }
            XCTAssertTrue(canceled)
            XCTAssertFalse(floatingPageTitle("作品详情").exists, "Cancel must not open the overlapping sibling details action")
            XCTAssertTrue(details.isHittable)
            XCTAssertEqual(playerFields()["muted"], "true")
            waitUntil("Actual video geometry remains available after status ends") { self.videoGeometryReadback() != nil }
            let after = videoGeometryReadback()!
            for field in ["surfaceBounds", "surfaceWindow", "videoRect", "videoWindow", "sourceScale", "transform"] {
                XCTAssertEqual((before.fields[field] as? NSDictionary), (after.fields[field] as? NSDictionary), "Preparation does not move or resize the video: \(field)")
            }
            app.terminate(); XCUIDevice.shared.orientation = .portrait
        }
    }

    private func assertAutomaticRepair47(_ mode: String, codec: Int) {
        launchPlayback43(mode)
        waitUntil("A repaired native player must display a frame and advance", timeout: 35) {
            self.playback43Entries().contains { $0["code"] as? String == "repairedVideoPlaying" }
        }
        let entries = playback43Entries()
        let begun = entries.first { $0["code"] as? String == "repairStarted" }?["playback"] as? [String: Any]
        let completed = entries.first { $0["code"] as? String == "repairCompleted" }?["playback"] as? [String: Any]
        XCTAssertEqual(begun?["videoCodec"] as? Int, codec)
        XCTAssertEqual(begun?["containerHint"] as? String, "ebml")
        XCTAssertEqual(completed?["repairMode"] as? String, "transcode")
        XCTAssertEqual(completed?["videoCodec"] as? Int, 1)
        XCTAssertEqual(completed?["containerHint"] as? String, "isoBmff")
        XCTAssertEqual(completed?["source"] as? String, "cache")
        XCTAssertEqual(playerFields()["muted"], "true")
        XCTAssertFalse(app.buttons["media.compatibility.open"].exists)
        attachPlayback43(mode)
    }
    func testCompatibilityPlayerFromNativeHostUsesSharedTabs() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "--qa-compatibility-template", "--qa-header-motion", "--qa-collection-batch-manage", "-muted", "YES", "-autoplay", "NO"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(mainTabButton("收藏").waitForExistence(timeout: 8))
        mainTabButton("收藏").tap()
        waitUntil("Collection root transition releases interaction") {
            self.mainTabButton("收藏").isSelected && (!self.app.staticTexts["page.interaction-lock"].exists || self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0"))
        }
        let video = app.otherElements["collection.media-kind"].buttons["视频"]
        XCTAssertTrue(video.waitForExistence(timeout: 5)); video.tap()
        let cell = app.buttons["media.grid.cell.28037102"].firstMatch
        waitUntil("Video grid is settled and tappable") {
            cell.isHittable && (!self.app.staticTexts["page.interaction-lock"].exists || self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0"))
        }
        print("FLOAT173_COMPAT_ENTRY frame=\(cell.frame);locks=\(app.staticTexts["page.interaction-lock"].exists ? app.staticTexts["page.interaction-lock"].valueDescription : "never-acquired")")
        cell.tap()
        let fallback = app.buttons["media.qa.compatibility-open"]
        XCTAssertTrue(fallback.waitForExistence(timeout: 8)); fallback.tap()
        let header = floatingPageTitle("兼容播放")
        XCTAssertTrue(header.waitForExistence(timeout: 8))
        XCTAssertTrue(header.buttons["playback.share"].isHittable)
        let tabs = app.descendants(matching: .any)["compatibility.tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        XCTAssertTrue(tabs.buttons["main.tab.3"].isSelected)
        let state = app.descendants(matching: .any)["compatibility.qa.state"]
        XCTAssertTrue(state.waitForValueToContain("\"ready\":true", timeout: 8))
        header.buttons["compatibility.close"].tap()
        XCTAssertTrue(header.waitForNonExistence(timeout: 5))
        XCTAssertTrue(fallback.waitForExistence(timeout: 5))
        fallback.tap()
        XCTAssertTrue(state.waitForValueToContain("\"ready\":true", timeout: 8))
        attachScreenshot(named: "compatibility-shared-tabs")
        print("COMPAT144_TAB_EXIT \(Date().timeIntervalSince1970)")
        tabs.buttons["main.tab.4"].tap()
        XCTAssertTrue(app.textFields["search-title-input"].waitForExistence(timeout: 8))
        XCTAssertFalse(header.isHittable)
    }

    func testPlaybackDiagnostics43TruncatedOfflineRetainsNativeErrorAndRetry() {
        launchPlayback43("invalid-offline")
        waitUntil("Both native offline failure attempts should persist", timeout: 15) {
            self.playback43Entries().compactMap { $0["playback"] as? [String: Any] }.count == 2
        }
        let contexts = playback43Entries().compactMap { $0["playback"] as? [String: Any] }
        XCTAssertEqual(Set(contexts.compactMap { $0["attempt"] as? Int }), [0, 1])
        for context in contexts {
            XCTAssertEqual(context["workID"] as? Int, 146_853_866)
            XCTAssertEqual(context["source"] as? String, "offline")
            XCTAssertEqual(context["localBytes"] as? Int, 1_024)
            guard let errors = context["nativeErrors"] as? [[String: Any]], !errors.isEmpty else { XCTFail("Actual native failure chain is required"); return }
            XCTAssertEqual(errors[0]["domain"] as? String, "AVFoundationErrorDomain")
            XCTAssertTrue([-11828, -11829].contains(errors[0]["code"] as? Int ?? 0))
        }
        attachPlayback43("invalid-offline")
        openAccountSettings()
        XCTAssertTrue(floatingPageTitle("账号与设置").waitForExistence(timeout: 5))
        let diagnosticsLink = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "本机错误与诊断记录")).firstMatch
        for _ in 0..<6 {
            if diagnosticsLink.exists && diagnosticsLink.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(diagnosticsLink.exists && diagnosticsLink.isHittable)
        diagnosticsLink.tap()
        XCTAssertTrue(floatingPageTitle("本机诊断记录").waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "作品 #146853866")).firstMatch.exists)
        attachScreenshot(named: "playback43-diagnostics-native-codes")
    }
    func testPlaybackDiagnostics46CurrentTargetRetainsNativeFailure() {
        launchPlayback43("invalid-current-target")
        waitUntil("Both native failure attempts for the newly confirmed work must persist", timeout: 15) {
            self.playback43Entries().compactMap { $0["playback"] as? [String: Any] }.count == 2
        }
        let contexts = playback43Entries().compactMap { $0["playback"] as? [String: Any] }
        XCTAssertEqual(Set(contexts.compactMap { $0["attempt"] as? Int }), [0, 1])
        for context in contexts {
            XCTAssertEqual(context["workID"] as? Int, 146_853_737)
            XCTAssertEqual(context["source"] as? String, "offline")
            XCTAssertEqual(context["localBytes"] as? Int, 1_024)
            guard let errors = context["nativeErrors"] as? [[String: Any]], !errors.isEmpty else {
                XCTFail("Actual native failure chain is required for the new target"); return
            }
            XCTAssertEqual(errors[0]["domain"] as? String, "AVFoundationErrorDomain")
            XCTAssertTrue([-11828, -11829].contains(errors[0]["code"] as? Int ?? 0))
        }
        attachPlayback43("invalid-current-target")
    }

    func testPlaybackDiagnostics43BadCacheRecordsActualSourceThenRecovers() {
        launchPlayback43("bad-cache")
        waitUntil("Actual corrupt cache failure must be recorded", timeout: 12) { !self.playback43Entries().isEmpty }
        waitPlayingFixture()
        let contexts = playback43Entries().compactMap { $0["playback"] as? [String: Any] }
        XCTAssertEqual(contexts.count, 1)
        XCTAssertEqual(contexts[0]["source"] as? String, "cache")
        XCTAssertEqual(contexts[0]["localBytes"] as? Int, 1_024)
        XCTAssertEqual(contexts[0]["attempt"] as? Int, 0)
        XCTAssertEqual(playerFields()["created"], "2")
        XCTAssertEqual(playerFields()["muted"], "true")
        attachPlayback43("bad-cache")
    }
    func testPlaybackDiagnostics43UntargetedFailureKeepsNoWorkID() {
        launchPlayback43("invalid-untargeted")
        waitUntil("An ordinary generic failure should still be recorded", timeout: 12) { !self.playback43Entries().isEmpty }
        XCTAssertTrue(playback43Entries().allSatisfy { $0["playback"] == nil })
        attachPlayback43("invalid-untargeted")
    }

    func testVideoFooterAndCompactTabsStayStable() {
        visualLaunch(width: 0, large: false, landscape: false)
        app.otherElements["timeline.media-kind"].buttons["视频"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let favorite = visualButton("favorite-28037102")
        XCTAssertTrue(favorite.waitForExistence(timeout: 8))
        let seek = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "播放进度")).firstMatch
        XCTAssertTrue(seek.waitForExistence(timeout: 10)); XCTAssertTrue(seek.isHittable)
        let before = seek.frame
        let rotate = app.buttons["手动切换横竖屏"]
        XCTAssertEqual(rotate.frame.midX, timelineTools().frame.midX, accuracy: 1,
                       "The rail and timeline tools share a vertical centerline")
        let rotateBaseline = rotate.frame.maxY
        visualAssertCaptionAndActions(itemID: 28_037_102, caseName: "video-portrait")
        XCTAssertEqual(seek.frame.height, 44, accuracy: 1)
        XCTAssertEqual(mainTabBar().frame.minY - rotateBaseline, 96, accuracy: 1)
        XCTAssertTrue(app.buttons["取消静音"].isHittable)
        let deck = heightDeck().frame
        let tap = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: deck.midX, dy: deck.minY + 130))
        // One raw read per stage; no extra readiness waits or diagnostic UI
        // queries are inserted into the original seek-to-resume sequence.
        let initialPlayerRaw = app.staticTexts.matching(identifier: "media.qa.player").firstMatch.valueDescription
        tap.tap(); RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let paused = seekSeconds(seek.valueDescription)!
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        XCTAssertEqual(seekSeconds(seek.valueDescription)!, paused, accuracy: 0.5, "The media tap must actually pause playback")
        XCTAssertEqual(seek.frame.minY, before.minY, accuracy: 1)
        XCTAssertEqual(rotate.frame.maxY, rotateBaseline, accuracy: 1)
        attachScreenshot(named: "controls39-video-paused")
        let pausedPlayerRaw = app.staticTexts.matching(identifier: "media.qa.player").firstMatch.valueDescription
        seek.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let nearHalf = NSPredicate { _, _ in abs((self.seekSeconds(seek.valueDescription) ?? -100) - 15) < 2 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: nearHalf, object: nil)], timeout: 5), .completed)
        let soughtPlayerRaw = app.staticTexts.matching(identifier: "media.qa.player").firstMatch.valueDescription
        tap.tap()
        let playing = NSPredicate { _, _ in (self.seekSeconds(seek.valueDescription) ?? 0) >= 16 }
        let growthResult = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: playing, object: nil)], timeout: 4)
        let finalPlayerRaw = app.staticTexts.matching(identifier: "media.qa.player").firstMatch.valueDescription
        // Detailed UI queries and the new screenshot occur only after the
        // unchanged four-second observation window has finished.
        for (phase, raw) in [("before-pause", initialPlayerRaw), ("paused-before-seek", pausedPlayerRaw),
                             ("seek-before-resume", soughtPlayerRaw), ("after-original-growth-window", finalPlayerRaw)] {
            print("FOOTER40_FAST phase=\(phase);\(raw)")
        }
        let currentPage = app.descendants(matching: .any).matching(identifier: "media-page-28037102").firstMatch
        let scopedSeek = currentPage.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "播放进度")).firstMatch
        let scopedReceipt = scopedSeek.exists ? "value=\(scopedSeek.valueDescription),frame=\(scopedSeek.frame),hittable=\(scopedSeek.isHittable)" : "not-exposed"
        let finalFocus = watchFocus()
        print("FOOTER40_FAST_UI result=\(growthResult);globalSeek={value=\(seek.valueDescription),frame=\(seek.frame),hittable=\(seek.isHittable)};scopedSeek={\(scopedReceipt)};focus=\(finalFocus);capturedDeck=\(deck);tap=(\(deck.midX),\(deck.minY + 130))")
        attachScreenshot(named: "footer40-fast-after-original-growth-window")
        XCTAssertEqual(growthResult, .completed, "The original progress label must reach 16 seconds within its original four-second window")
        XCTAssertEqual(seek.frame.minY, before.minY, accuracy: 1)
        let snapshots = [initialPlayerRaw, pausedPlayerRaw, soughtPlayerRaw, finalPlayerRaw].map { qaFields($0) }
        var parsed: [(taps: Int, seeks: Int, position: Double, rate: Double)] = []
        for (index, fields) in snapshots.enumerated() {
            guard let playerID = fields["player"], playerID != "none", !playerID.isEmpty,
                  let taps = fields["taps"].flatMap(Int.init), let seeks = fields["seekStarts"].flatMap(Int.init),
                  let position = fields["position"].flatMap(Double.init), position.isFinite,
                  let rate = fields["rate"].flatMap(Double.init), rate.isFinite,
                  fields["created"] != nil, fields["prepare"] != nil, fields["muted"] != nil, fields["rateHolds"] != nil else {
                XCTFail("Missing or invalid actual player QA fields at stage \(index): \(fields)"); return
            }
            parsed.append((taps, seeks, position, rate))
        }
        XCTAssertEqual(parsed[0].rate, 1, "Observe whether the original setup was actually playing before the pause tap")
        XCTAssertEqual(parsed[1].taps, parsed[0].taps + 1, "One actual pause tap must execute exactly one accepted playback callback")
        XCTAssertEqual(parsed[1].rate, 0)
        XCTAssertEqual(parsed[2].taps, parsed[1].taps, "The progress-bar tap must not toggle playback")
        XCTAssertEqual(parsed[2].seeks, parsed[1].seeks + 1, "The actual bar tap must begin exactly one seek")
        XCTAssertEqual(parsed[2].rate, 0, "Seeking while paused must keep actual playback paused")
        XCTAssertLessThan(abs(parsed[2].position - 15), 2, "Compare completed actual seek position with the original label check")
        XCTAssertEqual(parsed[3].taps, parsed[2].taps + 1, "One actual resume tap must execute exactly one accepted playback callback")
        XCTAssertEqual(parsed[3].rate, 1)
        XCTAssertEqual(parsed[3].seeks, parsed[2].seeks, "The resume tap must not begin a seek")
        XCTAssertGreaterThanOrEqual(parsed[3].position, parsed[2].position + 1, "Actual playback must advance during the original progress observation")
        for fields in snapshots.dropFirst() {
            for key in ["player", "created", "prepare", "muted", "rateHolds"] {
                XCTAssertEqual(fields[key], snapshots[0][key], "Footer actions must preserve actual \(key)")
            }
        }
        XCTAssertEqual(snapshots[3]["muted"], "true")
        XCTAssertEqual(finalFocus, 28_037_102)
        let tabs = mainTabBar()
        XCTAssertTrue(tabs.exists); XCTAssertEqual(["main.tab.timeline", "main.tab.2", "main.tab.4", "main.tab.3"].filter { tabs.buttons.matching(identifier: $0).count > 0 }.count, 4)
        XCTAssertLessThanOrEqual(tabs.frame.height, 54)
        for title in ["作者榜", "搜索", "收藏", "时间线"] {
            let button = mainTabButton(title); XCTAssertTrue(button.isHittable); XCTAssertGreaterThanOrEqual(button.frame.height + 0.01, 44); button.tap()
            switch title {
            case "作者榜": XCTAssertTrue(app.descendants(matching: .any)["leaderboard.top-bar"].waitForExistence(timeout: 5))
            case "搜索": XCTAssertTrue(app.descendants(matching: .any)["search.top-bar"].waitForExistence(timeout: 5))
            case "收藏": XCTAssertTrue(app.descendants(matching: .any)["collections.top-bar"].waitForExistence(timeout: 5))
            default: XCTAssertTrue(app.otherElements["timeline.media-kind"].waitForExistence(timeout: 5))
            }
        }
        heightAssert("recommendation", phase: "controls39-video-after-tabs", expected: 28_037_102)
        attachScreenshot(named: "controls39-video-playing-compact-tabs")
        print("CONTROLS39_FOOTER seek44, no-gap slot, stable paused/playing geometry, actual seek and4tab clicks passed")
        app.terminate()
    }

    func testVideoLargeLandscapeControlsStayInsideViewport() {
        visualLaunch(width: 0, large: true, landscape: false)
        app.otherElements["timeline.media-kind"].buttons["视频"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        visualEnsureLandscape()
        let favorite = visualButton("favorite-28037102"), details = visualButton("media.details.28037102")
        let seek = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "播放进度")).firstMatch
        XCTAssertTrue(seek.waitForExistence(timeout: 10)); XCTAssertTrue(seek.isHittable)
        let deck = heightDeck().frame
        XCTAssertGreaterThan(deck.width, deck.height)
        XCTAssertGreaterThanOrEqual(favorite.frame.minY, deck.minY + 92 - 1,
                                    "Compact landscape controls must use the 92pt chrome reservation")
        for button in [favorite, details] {
            XCTAssertTrue(button.isHittable); XCTAssertGreaterThanOrEqual(button.frame.height + 0.01, 44)
            XCTAssertGreaterThanOrEqual(button.frame.minY, deck.minY); XCTAssertLessThanOrEqual(button.frame.maxY, seek.frame.minY + 1)
        }
        visualAssertCaptionAndActions(itemID: 28_037_102, caseName: "video-large-landscape")
        XCTAssertEqual(seek.frame.height, 44, accuracy: 1)
        XCTAssertLessThanOrEqual(seek.frame.maxY, deck.maxY + 1)
        XCTAssertTrue(app.buttons["取消静音"].isHittable)
        heightAssert("recommendation", phase: "controls39-large-video-landscape", expected: 28_037_102)
        let slots = ["时间线", "作者榜", "搜索", "收藏"].map { mainTabButton($0).frame }
        for index in 0..<slots.count {
            XCTAssertEqual(slots[index].width, slots[0].width, accuracy: 1)
            if index > 0 { XCTAssertLessThanOrEqual(slots[index - 1].maxX, slots[index].minX + 1) }
        }
        attachScreenshot(named: "controls39-video-large-landscape")
        print("CONTROLS39_LARGE_VIDEO actualViewport=\(deck);seek=\(seek.frame);favorite=\(favorite.frame);details=\(details.frame);muted=true")
        app.terminate(); XCUIDevice.shared.orientation = .portrait
    }

    private func visualLaunch(width: Int, large: Bool, landscape: Bool, state: String? = nil, extra: [String] = [], expectsDetails: Bool = true) {
        app = XCUIApplication(); app.launchArguments = ["--qa-collection-paging", "--qa-visual-controls"]
        app.launchArguments += extra
        if let state { app.launchArguments += ["--qa-control-state=\(state)"] }
        if width > 0 { app.launchArguments += ["--qa-control-width=\(width)"] }
        if large { app.launchArguments += ["--qa-control-large-type", "--qa-control-long-author"] }
        app.launchArguments += ["-app.appearance", width == 375 ? "dark" : "light"]
        XCUIDevice.shared.orientation = .portrait; app.launch()
        let mode = timelineTools(); XCTAssertTrue(mode.waitForExistence(timeout: 10))
        if mode.valueDescription.contains("双列网格") { toggleTimelinePresentation() }
        heightCloseNotices()
        app.otherElements["timeline.media-kind"].buttons["图片"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let favoriteReady = visualButton("favorite-28037100").waitForExistence(timeout: 10)
        if !favoriteReady { attachScreenshot(named: "controls39-missing-favorite"); print(String(app.debugDescription.prefix(18000))) }
        XCTAssertTrue(favoriteReady)
        if expectsDetails { XCTAssertTrue(visualButton("media.details.28037100").waitForExistence(timeout: 10)) }
        if landscape { visualEnsureLandscape() }
    }

    private func visualEnsureLandscape() {
        // Orientation belongs to the window; a media-kind change can replace
        // the deck while leaving the window and header available.
        let frame = app.windows.firstMatch.frame
        if frame.width <= frame.height {
            let active = app.buttons.matching(NSPredicate(format: "label == %@", "手动切换横竖屏")).allElementsBoundByIndex.filter { $0.isHittable }
            XCTAssertEqual(active.count, 1, "Only the currently visible lane may supply the rotation action")
            guard let rotate = active.first else { return }
            rotate.tap()
        }
        let stable = NSPredicate { _, _ in let frame = self.app.windows.firstMatch.frame; return frame.width > frame.height && frame.height > 0 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: stable, object: nil)], timeout: 5), .completed)
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    private func visualTypeControls(caseName: String) {
        let picker = app.otherElements["timeline.media-kind"]
        let tools = timelineTools()
        let source = app.otherElements["timeline.source"]
        let row = app.staticTexts["qa.controls.row"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let original = app.staticTexts["qa.controls.filter"].valueDescription.components(separatedBy: ";").dropFirst().joined(separator: ";")
        for (title, raw) in [("图片", "image"), ("视频", "video")] {
            picker.buttons[title].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(picker.buttons[title].isSelected)
            if caseName.hasPrefix("landscape") { visualEnsureLandscape() }
            let values = heightValues(row.valueDescription)
            guard let rowX = values["x"], let rowWidth = values["w"] else { XCTFail("Unparseable actual control frame: \(row.valueDescription)"); return }
            let center = rowX + rowWidth / 2
            XCTAssertEqual(source.frame.union(picker.frame).midX, center, accuracy: 0.75)
            XCTAssertGreaterThanOrEqual(picker.frame.minX, values["x"]! - 1)
            XCTAssertGreaterThanOrEqual(tools.frame.minX - picker.frame.maxX, 3)
            XCTAssertLessThanOrEqual(tools.frame.maxX, values["x"]! + values["w"]! + 1)
            let segments = ["图片", "视频"].map { picker.buttons[$0] }
            print("CONTROLS39_SEGMENTS selected=\(raw);" + segments.map { "\($0.label):\($0.frame):hit=\($0.isHittable)" }.joined(separator: ";"))
            XCTAssertEqual(segments[0].frame.width, segments[1].frame.width, accuracy: 1.5)
            for segment in segments {
                XCTAssertEqual(segment.frame.midY, picker.frame.midY, accuracy: 1)
            }
            let state = app.staticTexts["qa.controls.filter"].valueDescription
            XCTAssertTrue(state.hasPrefix("kind=\(raw);")); XCTAssertEqual(state.components(separatedBy: ";").dropFirst().joined(separator: ";"), original)
            print("CONTROLS39_TYPE case=\(caseName);selected=\(raw);picker=\(picker.frame);contentCenter=\(center);tools=\(tools.frame)")
            attachScreenshot(named: "controls39-\(caseName)-type-\(raw)")
        }
        openTimelineTool("浏览条件"); XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 5)); app.buttons["完成"].tap()
        if caseName.hasPrefix("landscape") { visualEnsureLandscape() }
        XCTAssertTrue(picker.buttons["视频"].isSelected)
        XCTAssertFalse(picker.buttons["全部"].exists)
    }

    private func visualSocialStates(caseName: String) {
        let images = app.otherElements["timeline.media-kind"].buttons["图片"]
        if !images.isSelected { images.tap() }
        visualAssertSocial(caseName: caseName, saved: false, followed: false)
        visualToggleFollow(); visualAssertSocial(caseName: caseName, saved: false, followed: true)
        visualSaveFavorite(remove: false); visualAssertSocial(caseName: caseName, saved: true, followed: true)
        visualToggleFollow(); visualAssertSocial(caseName: caseName, saved: true, followed: false)
        visualSaveFavorite(remove: true); visualAssertSocial(caseName: caseName, saved: false, followed: false)
    }
    private func visualToggleFollow() {
        visualButton("media.follow.28037100").tap()
    }
    private func visualOpenDetails(itemID: Int) {
        let details = visualButton("media.details.\(itemID)")
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        details.tap()
        XCTAssertTrue(floatingPageTitle("作品详情").waitForExistence(timeout: 5))
    }
    private func visualCloseDetails() {
        app.buttons["details.back"].tap()
        XCTAssertTrue(floatingPageTitle("作品详情").waitForNonExistence(timeout: 5))
    }
    private func visualSaveFavorite(remove: Bool) {
        openFavoriteFolders(visualButton("favorite-28037100"))
        XCTAssertTrue(floatingPageTitle("收藏图片").waitForExistence(timeout: 5))
        let folder = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "分页测试收藏")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        if remove { folder.tap() }
        let save = app.buttons["保存"]; XCTAssertTrue(save.isEnabled)
        attachScreenshot(named: "controls39-favorite-editor")
        save.tap()
        XCTAssertTrue(floatingPageTitle("收藏图片").waitForNonExistence(timeout: 5))
    }
    private func visualAssertSocial(caseName: String, saved: Bool, followed: Bool) {
        if caseName.hasPrefix("landscape") { visualEnsureLandscape() }
        let favorite = visualButton("favorite-28037100"), follow = visualButton("media.follow.28037100")
        let savedTitle = saved ? "已收藏" : "收藏", followTitle = followed ? "已关注" : "关注"
        waitUntil("The favorite operation must update its button") { favorite.label.contains(savedTitle) }
        XCTAssertEqual(favorite.label.contains("已收藏"), saved)
        visualAssertCaptionAndActions(itemID: 28_037_100, caseName: caseName)
        waitUntil("The author relation must be visible next to the author") { follow.isHittable && follow.label == followTitle }
        XCTAssertEqual(follow.label.contains("已关注"), followed)
        attachScreenshot(named: "controls39-\(caseName)-saved\(saved)-followed\(followed)")
        visualOpenDetails(itemID: 28_037_100)
        let detailsFollow = visualButton("follow-28037901")
        waitUntil("Details must show the same author relation") { detailsFollow.isHittable && detailsFollow.label == followTitle }
        visualCloseDetails()
    }
    private func visualAssertCaptionAndActions(itemID: Int, caseName: String) {
        let favorite = visualButton("favorite-\(itemID)")
        let details = visualButton("media.details.\(itemID)"), author = visualButton("media.author.\(itemID)")
        let follow = visualButton("media.follow.\(itemID)")
        let deck = heightDeck().frame
        for button in [favorite, details, author, follow] {
            XCTAssertTrue(button.isHittable)
            XCTAssertGreaterThanOrEqual(button.frame.width + 0.01, 44); XCTAssertGreaterThanOrEqual(button.frame.height + 0.01, 44)
            XCTAssertGreaterThanOrEqual(button.frame.minY, deck.minY); XCTAssertLessThanOrEqual(button.frame.maxY, deck.maxY + 1)
        }
        XCTAssertEqual(favorite.frame.width, 44, accuracy: 1)
        XCTAssertGreaterThan(favorite.frame.midX, deck.midX)
        XCTAssertEqual(details.frame.midX, favorite.frame.midX, accuracy: 1)
        XCTAssertEqual(details.frame.minY - favorite.frame.maxY, 4, accuracy: 1)
        XCTAssertFalse(details.frame.intersects(author.frame))
        XCTAssertEqual(follow.frame.midY, author.frame.midY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(follow.frame.minX, author.frame.maxX - 1)
        XCTAssertLessThanOrEqual(follow.frame.maxX, favorite.frame.minX + 1)
        XCTAssertFalse(app.staticTexts["VIDEO"].exists); XCTAssertFalse(app.staticTexts["IMAGE"].exists)
        if itemID == 28_037_100 {
            XCTAssertEqual(mainTabBar().frame.minY - author.frame.maxY, 8, accuracy: 1,
                           "The image author row should sit 8pt above the tabs")
        }
        print("PLAYER73_CAPTION case=\(caseName);favorite=\(favorite.frame);details=\(details.frame);author=\(author.frame)")
        attachScreenshot(named: "player73-\(caseName)")
    }

    func testVisualControlsBusyAndUnknownStates() {
        for state in ["busy", "unknown"] {
            visualLaunch(width: 320, large: true, landscape: false, state: state)
            visualAssertCaptionAndActions(itemID: 28_037_100, caseName: state)
            let playbackFollow = visualButton("media.follow.28037100")
            if state == "busy" { XCTAssertFalse(playbackFollow.isEnabled) }
            else { XCTAssertEqual(playbackFollow.label, "关注结果待确认") }
            visualOpenDetails(itemID: 28_037_100)
            let follow = visualButton("follow-28037901")
            if state == "busy" { XCTAssertFalse(follow.isEnabled) }
            else { XCTAssertTrue(follow.label.contains("待确认")) }
            attachScreenshot(named: "controls40-\(state)-long-author-A2")
            app.terminate()
        }
    }

    func testCentralLongPressPreservesVideoAndRestoresImageChrome() {
        visualLaunch(width: 0, large: false, landscape: false)
        app.otherElements["timeline.media-kind"].buttons["视频"].tap()
        waitPlayingFixture()
        let before = playerFields(), focus = watchFocus(), toggles = metric("toggles", in: chromeState().valueDescription)
        let seek = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "播放进度")).firstMatch
        guard let videoDetails = app.buttons.matching(NSPredicate(format: "label == %@", "作品详情")).allElementsBoundByIndex.first(where: { $0.isHittable }) else { XCTFail("A visible video details control must exist before hiding"); return }
        attachScreenshot(named: "chrome40-video-before-hold")
        centralPress()
        XCTAssertTrue(chromeState().waitForValueToContain("hidden=true", timeout: 5))
        attachScreenshot(named: "chrome40-video-hidden")
        recordChromeAX61([mainTabBar(), mainTabButton("收藏"), app.buttons["timeline.account"], app.otherElements["timeline.media-kind"],
                          visualButton("favorite-28037102"), videoDetails, seek], phase: "video-hidden")
        let hidden = playerFields(); assertUnchangedPlayer(before, hidden)
        XCTAssertEqual(watchFocus(), focus)
        waitUntil("Playback must advance while the actual chrome is hidden") { Double(self.playerFields()["position"] ?? "0")! > Double(before["position"] ?? "0")! + 0.5 }
        XCTAssertEqual(metric("toggles", in: chromeState().valueDescription), toggles + 1)
        centralPress(); XCTAssertTrue(chromeState().waitForValueToContain("hidden=false", timeout: 5))
        assertUnchangedPlayer(before, playerFields()); XCTAssertEqual(watchFocus(), focus)
        XCTAssertEqual(metric("toggles", in: chromeState().valueDescription), toggles + 2)
        XCTAssertTrue(mainTabButton("收藏").isHittable); XCTAssertTrue(visualButton("favorite-28037102").isHittable)
        app.otherElements["timeline.media-kind"].buttons["图片"].tap()
        XCTAssertTrue(visualButton("favorite-28037100").waitForExistence(timeout: 8))
        let imageFocus = watchFocus()
        let favorite = visualButton("favorite-28037100")
        guard let details = app.buttons.matching(NSPredicate(format: "label == %@", "作品详情")).allElementsBoundByIndex.first(where: { $0.isHittable }) else { XCTFail("A visible image details control must exist before hiding"); return }
        let collections = mainTabButton("收藏"), account = app.buttons["timeline.account"], picker = app.otherElements["timeline.media-kind"]
        let regions = ["favorite": favorite.frame.insetBy(dx: 8, dy: 8), "details": details.frame.insetBy(dx: 8, dy: 8),
                       "header": picker.frame.insetBy(dx: 4, dy: 4), "bottom-tabs": collections.frame.insetBy(dx: 4, dy: 4)]
        let originalFrames = [favorite.frame, details.frame, collections.frame, account.frame]
        let imageBefore = captureChromePixels(named: "chrome40-image-before-hold")
        centralPress(); XCTAssertTrue(chromeState().waitForValueToContain("hidden=true", timeout: 5))
        let imageHidden = captureChromePixels(named: "chrome40-image-hidden")
        recordChromeAX61([favorite, details, collections, account, mainTabBar(), picker], phase: "image-hidden")
        assertChromePixelsDisappear(before: imageBefore, hidden: imageHidden, regions: regions)
        XCTAssertEqual(watchFocus(), imageFocus)
        // Static image taps isolate hidden controls from a video's intentional
        // single-tap pause. These are real taps at the formerly visible targets.
        for frame in originalFrames {
            tapScreenFrame(frame)
            XCTAssertFalse(floatingPageTitle("收藏图片").exists)
            XCTAssertFalse(floatingPageTitle("作品详情").exists)
            XCTAssertFalse(floatingPageTitle("账号与设置").exists)
            XCTAssertFalse(app.descendants(matching: .any)["collections.top-bar"].exists)
            XCTAssertTrue(chromeState().valueDescription.contains("hidden=true"))
            XCTAssertEqual(watchFocus(), imageFocus)
        }
        centralPress(); XCTAssertTrue(chromeState().waitForValueToContain("hidden=false", timeout: 5))
        XCTAssertTrue(favorite.isHittable); XCTAssertEqual(watchFocus(), imageFocus)
        attachScreenshot(named: "chrome40-image-restored")
        openAccountSettings()
        XCTAssertTrue(mainTabBar().isHittable)
    }

    func testCentralPressPreservesActualVideoGeometryAcrossLayouts() {
        let cases: [(name: String, width: Int, large: Bool, landscape: Bool, extra: [String])] = [
            ("normal-portrait", 0, false, false, []),
            ("narrow320-A2", 320, true, false, []),
            ("landscape", 0, false, true, []),
            ("landscape-A2", 0, true, true, []),
            ("wide-video", 0, false, false, ["--qa-wide-video"])
        ]

        for item in cases {
            visualLaunch(width: item.width, large: item.large, landscape: item.landscape,
                         extra: ["--qa-chrome-geometry"] + item.extra)
            app.otherElements["timeline.media-kind"].buttons["视频"].tap()
            waitPlayingFixture()
            if item.landscape { visualEnsureLandscape(); waitPlayingFixture() }
            let beforePlayer = playerFields()
            waitUntil("Actual player surface must be ready and expose nonempty video geometry") {
                self.videoGeometryReadback() != nil
            }
            guard let before = videoGeometryReadback() else {
                XCTFail("Missing valid video geometry before hold in \(item.name)")
                app.terminate(); XCUIDevice.shared.orientation = .portrait
                continue
            }
            layout41LogGeometry(item.name, phase: "visible", readback: before.raw)
            assertVideoGeometryOrientation(before.fields, landscape: item.landscape)
            attachScreenshot(named: "layout41-\(item.name)-chrome-visible")

            centralPress()
            XCTAssertTrue(chromeState().waitForValueToContain("hidden=true", timeout: 5))
            waitUntil("Muted local video must keep advancing with chrome hidden") {
                guard let start = beforePlayer["position"].flatMap(Double.init),
                      let current = self.playerFields()["position"].flatMap(Double.init) else { return false }
                return current > start
            }
            waitUntil("Hidden chrome must retain a ready actual player surface") { self.videoGeometryReadback() != nil }
            guard let hidden = videoGeometryReadback() else {
                XCTFail("Missing valid video geometry while hidden in \(item.name)")
                app.terminate(); XCUIDevice.shared.orientation = .portrait
                continue
            }
            layout41LogGeometry(item.name, phase: "hidden", readback: hidden.raw)
            assertVideoGeometryOrientation(hidden.fields, landscape: item.landscape)
            attachScreenshot(named: "layout41-\(item.name)-chrome-hidden")
            assertVideoGeometryUnchanged(before.fields, hidden.fields, phase: "hidden/\(item.name)")
            let hiddenPlayer = playerFields()
            assertChromePlayerIdentityUnchanged(beforePlayer, hiddenPlayer, phase: "hidden/\(item.name)")
            guard let start = beforePlayer["position"].flatMap(Double.init),
                  let hiddenPosition = hiddenPlayer["position"].flatMap(Double.init) else {
                XCTFail("Missing actual player positions before/hidden: \(beforePlayer), \(hiddenPlayer)")
                app.terminate(); XCUIDevice.shared.orientation = .portrait
                continue
            }
            XCTAssertGreaterThan(hiddenPosition, start, "Hidden chrome must not reset actual video progress")

            centralPress()
            XCTAssertTrue(chromeState().waitForValueToContain("hidden=false", timeout: 5))
            waitUntil("Restored chrome must retain a ready actual player surface") { self.videoGeometryReadback() != nil }
            guard let restored = videoGeometryReadback() else {
                XCTFail("Missing valid video geometry after restore in \(item.name)")
                app.terminate(); XCUIDevice.shared.orientation = .portrait
                continue
            }
            layout41LogGeometry(item.name, phase: "restored", readback: restored.raw)
            assertVideoGeometryOrientation(restored.fields, landscape: item.landscape)
            attachScreenshot(named: "layout41-\(item.name)-chrome-restored")
            assertVideoGeometryUnchanged(before.fields, restored.fields, phase: "restored/\(item.name)")
            let restoredPlayer = playerFields()
            assertChromePlayerIdentityUnchanged(beforePlayer, restoredPlayer, phase: "restored/\(item.name)")
            guard let restoredPosition = restoredPlayer["position"].flatMap(Double.init) else {
                XCTFail("Missing actual restored player position: \(restoredPlayer)")
                app.terminate(); XCUIDevice.shared.orientation = .portrait
                continue
            }
            XCTAssertGreaterThanOrEqual(restoredPosition, hiddenPosition,
                                        "Restoring chrome must not rewind actual playback")
            app.terminate(); XCUIDevice.shared.orientation = .portrait
        }
    }

    func testPlaybackRailOrderPersistsAndAppliesToImagesAndVideos() {
        // This test restores its own persisted sidebar state through Settings.
        visualLaunch(width: 0, large: false, landscape: false, expectsDetails: false)
        openAccountSettings()
        heightTap(app.buttons["settings.media-rail"])
        let settings = floatingPageTitle("播放侧栏")
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["settings.media-rail.cleanImage"].exists)
        let reset = app.buttons["settings.media-rail.reset"]
        if reset.exists && reset.isEnabled {
            waitUntil("The reset action is ready after header handoff") { reset.isHittable }; reset.tap()
        }
        let detailsVisibility = app.switches["settings.media-rail.details"]
        XCTAssertTrue(detailsVisibility.isHittable)
        XCTAssertEqual(detailsVisibility.frame.width, 44, accuracy: 1)
        XCTAssertEqual(detailsVisibility.frame.height, 44, accuracy: 1)
        detailsVisibility.tap()
        waitUntil("The details switch turns off") { detailsVisibility.value as? String == "0" }
        let reorder = app.descendants(matching: .any)["settings.media-rail.drag.rotate"].firstMatch
        guard reorder.waitForExistence(timeout: 5) else {
            XCTFail("The reorder handle for rotation is missing")
            return
        }
        let firstRow = app.switches["settings.media-rail.favorite"]
        XCTAssertTrue(firstRow.exists)
        let destination = firstRow.frame.midY - reorder.frame.midY
        reorder.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.65, thenDragTo: reorder.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .withOffset(CGVector(dx: 0, dy: destination - 12)), withVelocity: .slow, thenHoldForDuration: 0.5)
        let rotationVisibility = app.switches["settings.media-rail.rotate"]
        waitUntil("Dragging the last row to the top must save a custom order") {
            rotationVisibility.frame.minY < firstRow.frame.minY
        }
        attachScreenshot(named: "playback-rail-card-settings")
        settings.buttons["navigation.back"].tap()
        closeAccountSettings()

        func assertRotationIsFirst(id: Int) {
            let rotate = app.buttons["手动切换横竖屏"]
            let favorite = visualButton("favorite-\(id)")
            XCTAssertTrue(favorite.waitForExistence(timeout: 8))
            XCTAssertTrue(rotate.isHittable)
            XCTAssertLessThan(rotate.frame.minY, favorite.frame.minY)
            XCTAssertFalse(app.buttons["media.details.\(id)"].exists)
        }

        assertRotationIsFirst(id: 28_037_100)
        app.terminate()
        app.launch()
        app.otherElements["timeline.media-kind"].buttons["视频"].tap()
        assertRotationIsFirst(id: 28_037_102)
        openAccountSettings()
        heightTap(app.buttons["settings.media-rail"])
        waitUntil("Restored sidebar settings hand input to reset") { reset.isHittable }
        XCTAssertEqual(detailsVisibility.value as? String, "0")
        reset.tap()
        waitUntil("Reset restores both visibility and order") {
            detailsVisibility.value as? String == "1" && !reset.isEnabled
        }
    }

    func testVideoActionRailSocialFooterAndSeekRemainUsable() {
        // CollectionPagingQA.prepare() validates its bundled test video has no audio track.
        visualLaunch(width: 0, large: false, landscape: false, extra: ["--qa-playback-follow-fallback"])
        let imageRotate = app.buttons["手动切换横竖屏"]
        let cleanImage = app.buttons["media.clean-image.28037100"]
        XCTAssertTrue(cleanImage.waitForExistence(timeout: 5))
        XCTAssertTrue(cleanImage.isHittable)
        let imageRailAnchor = imageRotate.frame
        let imageFavoriteFrame = visualButton("favorite-28037100").frame
        attachScreenshot(named: "rail112-image")
        app.otherElements["timeline.media-kind"].buttons["视频"].tap()
        waitPlayingFixture()

        let favorite = visualButton("favorite-28037102")
        let details = visualButton("media.details.28037102")
        let mute = app.buttons["取消静音"]
        let rotate = app.buttons["手动切换横竖屏"]
        let seek = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "播放进度")).firstMatch
        let follow = visualButton("media.follow.28037102")
        let author = app.buttons["media.author.28037102"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 8)); XCTAssertTrue(details.exists)
        XCTAssertTrue(mute.isHittable); XCTAssertTrue(rotate.isHittable)
        XCTAssertTrue(follow.waitForExistence(timeout: 8), "The visible work with no creator ID should resolve its author")
        XCTAssertTrue(app.staticTexts["media.title.28037102"].exists, "A post title must coexist with its author row")
        XCTAssertEqual(follow.label, "关注")
        XCTAssertTrue(author.isHittable); XCTAssertTrue(seek.isHittable)

        XCTAssertFalse(cleanImage.isHittable)
        XCTAssertEqual(rotate.frame.midX, imageRailAnchor.midX, accuracy: 1)
        XCTAssertEqual(rotate.frame.maxY, imageRailAnchor.maxY, accuracy: 1)
        XCTAssertEqual(favorite.frame.minY, imageFavoriteFrame.minY, accuracy: 1)
        let rail = [favorite, details, mute, rotate]
        for (index, button) in rail.enumerated() {
            XCTAssertEqual(button.frame.width, 44, accuracy: 1, "Action \(index) should expose a 44pt target")
            XCTAssertEqual(button.frame.height, 44, accuracy: 1, "Action \(index) should expose a 44pt target")
            XCTAssertEqual(button.frame.midX, rail[0].frame.midX, accuracy: 1,
                           "All four actions must share one right edge column")
            if index > 0 {
                XCTAssertEqual(button.frame.minY - rail[index - 1].frame.maxY, 4, accuracy: 1,
                               "The right rail must keep a compact, consistent spacing")
            }
        }
        XCTAssertEqual(follow.frame.midY, author.frame.midY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(follow.frame.minX, author.frame.maxX - 1)
        XCTAssertLessThanOrEqual(follow.frame.maxX, favorite.frame.minX + 1)
        XCTAssertEqual(mainTabBar().frame.minY - rotate.frame.maxY, 96, accuracy: 1,
                       "The right rail must sit above the caption and progress line")
        XCTAssertEqual(author.frame.minX, seek.frame.minX, accuracy: 1)
        XCTAssertEqual(seek.frame.minY, author.frame.maxY, accuracy: 1,
                       "The author row should sit directly above the seek target")
        XCTAssertEqual(mainTabBar().frame.minY, seek.frame.maxY, accuracy: 1,
                       "The seek target must finish at the tabs without another bottom gap")
        for control in rail + [author, follow, seek] {
            XCTAssertTrue(control.isHittable, "Control must not overlap or be covered: \(control.identifier) \(control.frame)")
        }
        follow.tap()
        waitUntil("Follow from the playing video updates its author row") { follow.label == "已关注" }
        waitPlayingFixture()
        attachScreenshot(named: "player89-follow-beside-author")

        // CollectionPagingQA.prepare validates its bundled fixture has no audio track.
        mute.tap()
        XCTAssertTrue(app.buttons["静音"].waitForExistence(timeout: 4))
        XCTAssertEqual(playerFields()["muted"], "false")
        app.buttons["静音"].tap()
        XCTAssertTrue(app.buttons["取消静音"].waitForExistence(timeout: 4))
        XCTAssertEqual(playerFields()["muted"], "true")

        rotate.tap(); heightWaitOrientation(landscape: true)
        app.buttons["手动切换横竖屏"].tap(); heightWaitOrientation(landscape: false)

        openFavoriteFolders(favorite)
        XCTAssertTrue(floatingPageTitle("收藏视频").waitForExistence(timeout: 5), "Open the local QA favorite editor")
        let cancelFavorite = app.buttons["取消"]
        XCTAssertTrue(cancelFavorite.waitForExistence(timeout: 5)); cancelFavorite.tap()
        XCTAssertTrue(floatingPageTitle("收藏视频").waitForNonExistence(timeout: 5))

        visualOpenDetails(itemID: 28_037_102)
        XCTAssertTrue(app.staticTexts.matching(identifier: "details.summary").firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(visualButton("details.author").isHittable)
        let detailsFollow = visualButton("follow-28037901")
        XCTAssertTrue(detailsFollow.isHittable)
        XCTAssertEqual(detailsFollow.label, "已关注")
        detailsFollow.tap()
        waitUntil("Unfollowing from details updates the shared relation") { detailsFollow.label == "关注" }
        attachScreenshot(named: "player73-details")
        visualCloseDetails()
        waitUntil("The playback row must reflect the change made in details") { follow.isHittable && follow.label == "关注" }

        // Confirm the player has resumed after the sheet. Pause before reading the
        // seek result so XCTest's observation delay cannot move playback past it.
        waitPlayingFixture()
        let viewport = heightDeck().frame
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: viewport.midX, dy: viewport.midY)).tap()
        waitUntil("The viewer can pause after closing details") { self.playerFields()["rate"].flatMap(Double.init) == 0 }
        let durationLabel = seek.valueDescription.components(separatedBy: " / ").last ?? ""
        guard let seekStarts = playerFields()["seekStarts"].flatMap(Int.init),
              let duration = seekSeconds(durationLabel), duration > 0 else {
            XCTFail("Missing seek count or clip duration: \(seek.valueDescription)"); return
        }
        func expectPosition(fraction: Double, seekCount: Int) {
            waitUntil("The paused player should land near \(fraction * duration)s") {
                let fields = self.playerFields()
                guard let position = fields["position"].flatMap(Double.init) else { return false }
                return abs(position - fraction * duration) < 0.20 &&
                    fields["seekStarts"].flatMap(Int.init) == seekCount && fields["rate"].flatMap(Double.init) == 0
            }
        }
        seek.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        expectPosition(fraction: 0.5, seekCount: seekStarts + 1)
        attachScreenshot(named: "player73-paused-at-midpoint")
        seek.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.05, thenDragTo:
            seek.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)))
        expectPosition(fraction: 0.75, seekCount: seekStarts + 2)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let center = origin.withOffset(CGVector(dx: viewport.midX, dy: viewport.midY))
        // A body swipe moves about six seconds per 60 points. Start close
        // enough to each endpoint to exercise real clamping.
        for (start, delta, endpoint, count) in [(0.10, -60.0, 0.0, 3), (0.90, 60.0, 1.0, 5)] {
            seek.coordinate(withNormalizedOffset: CGVector(dx: start, dy: 0.5)).tap()
            expectPosition(fraction: start, seekCount: seekStarts + count)
            center.press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: viewport.midX + delta, dy: viewport.midY)))
            expectPosition(fraction: endpoint, seekCount: seekStarts + count + 1)
        }
    }

    func testAuthorActivity70SmallLoadingAndProgressiveChecks() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-theme-ui", "--qa-author-activity58", "-muted", "YES"]
        app.launch()
        mainTabButton("作者榜").tap()
        app.buttons["leaderboard.recent-filter"].tap()
        let day = app.scrollViews["value-selector.options"].buttons.matching(identifier: "value-selector.option.day").firstMatch
        XCTAssertTrue(day.waitForExistence(timeout: 5))
        day.tap()
        let first = app.buttons["leaderboard.author.59004"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(first.isHittable)
        XCTAssertFalse(app.staticTexts["符合更新范围"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["leaderboard.activity.loading"].exists)
        XCTAssertLessThan(first.frame.minY, app.frame.height * 0.45)
        let next = app.buttons["leaderboard.activity.next"]
        heightTap(next)
        // The next batch appends matches below the current results.
        for _ in 0..<8 {
            if next.exists && next.valueDescription.contains("80/1,000") { break }
            app.swipeUp()
        }
        XCTAssertTrue(next.valueDescription.contains("符合 20 位") && next.valueDescription.contains("80/1,000"))
        attachScreenshot(named: "author70-explicit-second-batch")
    }

    func testStyle48SearchTagsAndAuthorFilterInBothAppearances() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-theme-ui", "--qa-style48", "-muted", "YES"]
        app.launch()
        for appearance in ["深色", "浅色"] {
            chooseAppearance(appearance)
            mainTabButton("搜索").tap()
            let field = app.textFields["search-title-input"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            XCTAssertFalse(app.navigationBars["组合搜索"].exists)
            attachScreenshot(named: "style48-\(appearance)-combined-search")
            let author = app.buttons["search-author-picker"]
            XCTAssertTrue(author.isHittable)
            XCTAssertEqual(author.frame.width, app.buttons["search-tag-picker"].frame.width, accuracy: 1)
            let range = app.buttons["search.range"]
            XCTAssertEqual(author.frame.width, range.frame.width, accuracy: 1)
            XCTAssertEqual(app.buttons["search-submit"].frame.maxX, app.buttons["search.presets"].frame.maxX, accuracy: 1)
            XCTAssertEqual(app.buttons["search.presets"].frame.midY, range.frame.midY, accuracy: 1)
            XCTAssertLessThan(range.frame.minX, app.buttons["search.presets"].frame.minX)
            author.tap()
            let authorHeader = floatingPageTitle("选择作者")
            XCTAssertTrue(authorHeader.waitForExistence(timeout: 5))
            XCTAssertTrue(app.textFields["author-picker.input"].exists)
            let authorField = app.descendants(matching: .any).matching(identifier: "author-picker.field").firstMatch
            XCTAssertEqual(authorField.frame.minX, authorHeader.frame.minX, accuracy: 1)
            XCTAssertEqual(authorField.frame.maxX, authorHeader.frame.maxX, accuracy: 1)
            XCTAssertTrue(mainTabButton("搜索").isHittable)
            XCTAssertTrue(authorHeader.buttons["navigation.back"].isHittable)
            attachScreenshot(named: "style48-\(appearance)-author-picker")
            authorHeader.buttons["navigation.back"].tap()
            let picker = app.buttons["search-tag-picker"]
            waitUntil("The search toolbar must become interactive after returning from the author picker") {
                picker.isHittable
            }
            picker.tap()
            XCTAssertTrue(app.textFields["tag-search-input"].waitForExistence(timeout: 5))
            let portrait = app.buttons["tag-directory.tag.42001"]
            let night = app.buttons["tag-directory.tag.42002"]
            XCTAssertTrue(portrait.waitForExistence(timeout: 5)); XCTAssertTrue(night.exists)
            XCTAssertGreaterThanOrEqual(portrait.frame.height, 44)
            let portraitFrame = portrait.frame, nightFrame = night.frame
            if !portrait.valueDescription.contains("已选择") { portrait.tap() }
            if !night.valueDescription.contains("已选择") { night.tap() }
            XCTAssertTrue(portrait.valueDescription.contains("已选择"))
            XCTAssertTrue(night.valueDescription.contains("已选择"))
            XCTAssertEqual(portrait.frame, portraitFrame, "Color-only tag selection keeps the directory cell geometry")
            XCTAssertEqual(night.frame, nightFrame)
            portrait.tap()
            waitUntil("Tapping a selected chip cancels the draft selection") {
                !portrait.valueDescription.contains("已选择")
            }
            XCTAssertEqual(portrait.frame, portraitFrame)
            portrait.tap()
            attachScreenshot(named: "style48-\(appearance)-tag-selection")
            app.buttons["完成"].tap()
            XCTAssertTrue(app.buttons["search-tag-picker"].waitForValueToContain("已选择 2 个标签", timeout: 5))
            XCTAssertTrue(app.buttons["search-submit"].isEnabled)
            attachScreenshot(named: "style48-\(appearance)-combined-selected")

            mainTabButton("作者榜").tap()
            XCTAssertTrue(app.otherElements["leaderboard.board"].buttons["Seasonal"].waitForExistence(timeout: 5))
            let recent = app.buttons["leaderboard.recent-filter"]
            XCTAssertTrue(recent.isHittable); XCTAssertGreaterThanOrEqual(recent.frame.height, 44)
            attachScreenshot(named: "style48-\(appearance)-author-board")
            recent.tap()
            XCTAssertTrue(app.buttons["近 7 天"].waitForExistence(timeout: 5))
            attachScreenshot(named: "style48-\(appearance)-author-time-menu")
            app.buttons["不限时间"].tap()
        }
    }

    private func openFavoriteFolders(_ favorite: XCUIElement) {
        favorite.press(forDuration: 0.7)
        let manage = app.buttons["favorite.manage"]
        XCTAssertTrue(manage.waitForExistence(timeout: 5))
        manage.tap()
    }

    func testSignedOutPlaybackCanOpenAndExitSharedLoginPage() {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-anonymous-navigation", "--qa-body-motion", "-muted", "YES", "-autoplay", "NO"])
        let follow = visualButton("media.follow.28037100")
        XCTAssertTrue(follow.waitForExistence(timeout: 8)); follow.tap()
        let login = floatingPageTitle("账号登录")
        XCTAssertTrue(login.waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["business.tabs"].exists)
        let body = app.staticTexts["body.motion.qa"]
        waitUntil("Root login has a real measured body handoff") { body.valueDescription.contains("kind=entry;phase=completed") }
        print("ROOT_LOGIN_BODY \(body.valueDescription)")
        login.buttons["关闭"].tap()
        XCTAssertTrue(follow.waitForExistence(timeout: 5))

        visualButton("media.author.28037100").tap()
        let authorBar = app.otherElements["creator.top-bar"]
        XCTAssertTrue(authorBar.waitForExistence(timeout: 5))
        authorBar.buttons["creator.actions"].tap()
        app.buttons["creator.search"].tap()
        XCTAssertTrue(app.textFields["search-title-input"].waitForExistence(timeout: 5))
        chooseSearchMedia("图片")
        app.buttons["search-submit"].tap()
        let cell = app.buttons["media.grid.cell.28037100"]
        XCTAssertTrue(cell.waitForExistence(timeout: 8))
        cell.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.15)).tap()
        XCTAssertTrue(app.buttons["关闭作品"].waitForExistence(timeout: 5))
        visualButton("media.follow.28037100").tap()
        XCTAssertTrue(login.waitForExistence(timeout: 5))
        let tabs = app.otherElements["business.tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        attachScreenshot(named: "dimensions-signed-out-login-over-playback")
        tabs.buttons["main.tab.3"].tap()
        XCTAssertTrue(app.otherElements["collections.top-bar"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["关闭作品"].isHittable)
        XCTAssertFalse(login.exists)
    }

    func testBusinessFavoritePageHasOneTabBarAndUnwindsNestedPlayback() {
        for nested in [false, true] {
            visualLaunch(width: 0, large: false, landscape: false,
                         extra: ["-muted", "YES", "-autoplay", "NO"])
            if nested {
                visualButton("media.author.28037100").tap()
                XCTAssertTrue(app.otherElements["creator.top-bar"].waitForExistence(timeout: 5))
                visualButton("media.grid.cell.28037100").tap()
                XCTAssertTrue(app.buttons["关闭作品"].waitForExistence(timeout: 5))
            }
            openFavoriteFolders(visualButton("favorite-28037100"))
            let editor = floatingPageTitle("收藏图片")
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            let tabs = app.otherElements["business.tabs"]
            XCTAssertTrue(tabs.waitForExistence(timeout: 5))
            var buttonsFrame = CGRect.null
            for id in ["main.tab.timeline", "main.tab.2", "main.tab.4", "main.tab.3"] {
                let buttons = app.buttons.matching(identifier: id).allElementsBoundByIndex.filter(\.isHittable)
                guard buttons.count == 1, let button = buttons.first else {
                    XCTFail("Business page must own exactly one usable tab action: " + id)
                    return
                }
                buttonsFrame = buttonsFrame.union(button.frame)
            }
            // The tab accessibility container also includes the transparent page margins.
            // Its visible panel surrounds the four hit targets with 4 pt of inner padding.
            let panel = buttonsFrame.insetBy(dx: -4, dy: 0)
            XCTAssertEqual(editor.frame.minX, panel.minX, accuracy: 1)
            XCTAssertEqual(editor.frame.maxX, panel.maxX, accuracy: 1)
            attachScreenshot(named: "dimensions-business-favorite-nested-\(nested)")
            tabs.buttons["main.tab.4"].tap()
            XCTAssertTrue(app.otherElements["search.top-bar"].waitForExistence(timeout: 5))
            XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
            XCTAssertFalse(app.buttons["关闭作品"].isHittable)
            XCTAssertFalse(app.buttons["details.back"].isHittable)
            XCTAssertTrue(mainTabButton("搜索").isHittable)
            app.terminate()
        }
    }

    func testVideoBookmarkTogglesWithoutOpeningFolderPicker() {
        visualLaunch(width: 0, large: false, landscape: false, extra: ["-muted", "YES", "-autoplay", "NO"])
        app.otherElements["timeline.media-kind"].buttons["视频"].tap()
        let favorite = visualButton("favorite-28037102")
        XCTAssertTrue(favorite.waitForExistence(timeout: 8))
        favorite.tap()
        waitUntil("A single tap saves the video") { favorite.label == "已收藏" }
        XCTAssertFalse(floatingPageTitle("收藏视频").exists)
        waitUntil("The first background save finishes") { favorite.isEnabled }
        favorite.tap()
        waitUntil("A second tap removes the bookmark") { favorite.label == "收藏" }
        XCTAssertFalse(floatingPageTitle("收藏视频").exists)
        visualOpenDetails(itemID: 28_037_102)
        visualCloseDetails()
        let restored = app.buttons["favorite-28037102"]
        if !restored.waitForExistence(timeout: 5) {
            attachScreenshot(named: "details-return-missing-rail")
            print(app.debugDescription)
        }
        waitUntil("The player restores its bookmark after closing details") { restored.isHittable }
    }

    func testVideoBookmarkShowsPendingIntentBeforeServerConfirms() {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-favorite-save69-delay", "-muted", "YES", "-autoplay", "NO"])
        app.otherElements["timeline.media-kind"].buttons["视频"].tap()
        let favorite = visualButton("favorite-28037102")
        XCTAssertTrue(favorite.waitForExistence(timeout: 8))
        favorite.tap()
        XCTAssertEqual(favorite.label, "已收藏")
        XCTAssertFalse(favorite.isEnabled, "The server request is still pending")
        XCTAssertFalse(app.descendants(matching: .any)["favorite-saving-28037102"].exists)
        waitUntil("The background save finishes", timeout: 10) { favorite.isEnabled }
        XCTAssertEqual(favorite.label, "已收藏")

        favorite.tap()
        XCTAssertEqual(favorite.label, "收藏")
        XCTAssertFalse(favorite.isEnabled, "Removal is also pending in the background")
        waitUntil("The background removal finishes", timeout: 10) { favorite.isEnabled }
        XCTAssertEqual(favorite.label, "收藏")
    }

    func testBookmarkRestoresConfirmedStateAfterFailedRemoval() {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-favorite-save69-delay", "--qa-favorite-save69-start-saved",
                             "--qa-favorite-save69-failure", "-muted", "YES", "-autoplay", "NO"])
        let favorite = visualButton("favorite-28037100")
        XCTAssertTrue(favorite.waitForExistence(timeout: 8))
        XCTAssertEqual(favorite.label, "已收藏")
        favorite.tap()
        XCTAssertEqual(favorite.label, "收藏")
        XCTAssertFalse(favorite.isEnabled)
        let alert = app.alerts["Civit Viewer"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        alert.buttons["好"].tap()
        XCTAssertEqual(favorite.label, "已收藏")
        XCTAssertTrue(favorite.isEnabled)
    }

    func testAuthorSelectionCommitsOnSuccessfulReturn() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "--qa-header-motion", "--qa-body-motion",
                               "-app.appearance", "light", "-muted", "YES", "-autoplay", "NO"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        mainTabButton("搜索").tap()
        let picker = app.buttons["search-author-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let field = app.textFields["author-picker.input"]
        let result = app.buttons["author-picker.author.28037001"]
        let done = app.buttons["author-picker.done"]

        func chooseDraft() {
            let hasSelection = picker.valueDescription.contains("@PagingFixture")
            picker.tap()
            let header = floatingPageTitle("选择作者")
            let locks = app.staticTexts["page.interaction-lock"]
            waitUntil("The author picker header is settled and all input locks are released") {
                header.exists && header.isHittable && locks.valueDescription.contains("locks=0")
            }
            XCTAssertTrue(done.waitForExistence(timeout: 5))
            XCTAssertEqual(done.isEnabled, hasSelection)
            field.tap()
            field.typeText("@Pagi")
            XCTAssertTrue(result.waitForExistence(timeout: 6))
            result.tap()
            XCTAssertTrue(done.isEnabled)
        }

        chooseDraft()
        floatingPageTitle("选择作者").buttons["navigation.back"].tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertEqual(picker.value as? String, "@PagingFixture")
        chooseDraft()
        done.tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertEqual(picker.value as? String, "@PagingFixture")

        let submit = app.buttons["search-submit"]
        let creatorHeader = app.otherElements["creator.top-bar"]
        chooseSearchMedia("视频")
        XCTAssertEqual(submit.label, "搜索作品")
        submit.tap()
        let results = app.descendants(matching: .any)["search.results"]
        XCTAssertTrue(results.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["@PagingFixture"].waitForExistence(timeout: 5))
        XCTAssertFalse(creatorHeader.exists)
        XCTAssertTrue(picker.isHittable)
        let sort = app.buttons["search.results.sort"]
        XCTAssertTrue(sort.waitForValueToContain("最新", timeout: 5))
        XCTAssertLessThan(sort.frame.midX, app.frame.midX)
        sort.tap()
        app.buttons["value-selector.option.Most Reactions"].tap()
        XCTAssertTrue(sort.waitForValueToContain("热度", timeout: 5))
        XCTAssertTrue(app.buttons["search.range"].label.contains("视频"))
        XCTAssertTrue(results.exists)
        attachScreenshot(named: "search-author-only-inline")

        let title = app.textFields["search-title-input"]
        title.tap()
        title.typeText("Paging")
        XCTAssertEqual(submit.label, "搜索作品")
        submit.tap()
        XCTAssertTrue(app.descendants(matching: .any)["search.results"].waitForExistence(timeout: 5))
        XCTAssertFalse(creatorHeader.exists)
        XCTAssertFalse(app.buttons["作者主页"].exists)
        XCTAssertFalse(app.buttons["不限作者"].exists)
        attachScreenshot(named: "search-author-and-title-inline")

        let clear = app.buttons["author-picker.clear"]
        picker.tap()
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        XCTAssertEqual(clear.frame.midY, field.frame.midY, accuracy: 2)
        XCTAssertGreaterThan(clear.frame.minX, field.frame.minX)
        attachScreenshot(named: "search-author-clear-row")
        clear.tap()
        floatingPageTitle("选择作者").buttons["navigation.back"].tap()
        XCTAssertTrue(picker.waitForValueToContain("未选择", timeout: 5))
        chooseDraft()
        done.tap()
        picker.tap()
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        done.tap()
        XCTAssertTrue(picker.waitForValueToContain("未选择", timeout: 5))
        XCTAssertEqual(title.value as? String, "Paging")
        XCTAssertFalse(app.descendants(matching: .any)["search.results"].exists)
    }

    func testCovered181FooterWaitsForNestedDismissalsAndSlidesRoot() {
        for appearance in ["light", "dark"] {
            app = XCUIApplication()
            app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "--qa-header-motion",
                                   "--qa-body-motion", "--qa-page-return", "-app.appearance", appearance,
                                   "-muted", "YES", "-autoplay", "NO", "-civitviewer.automaticRotation", "NO"]
            XCUIDevice.shared.orientation = .portrait
            app.launch()
            let rootTabs = mainTabBar()
            let ready = rootTabs.waitForExistence(timeout: 10)
            if !ready { print("COVER181_ROOT_AX " + app.debugDescription) }
            XCTAssertTrue(ready)
            mainTabButton("收藏").tap()
            let video = app.otherElements["collection.media-kind"].buttons["视频"]
            XCTAssertTrue(video.waitForExistence(timeout: 8)); video.tap()
            let cell = app.buttons["media.grid.cell.28037102"].firstMatch
            waitUntil("The retained video card is ready for input") { cell.isHittable }
            cell.tap()
            let detailsAction = visualButton("media.details.28037102")
            waitUntil("The real player entry releases input") {
                detailsAction.isHittable && self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0")
            }
            detailsAction.tap()
            let details = floatingPageTitle("作品详情")
            XCTAssertTrue(details.waitForExistence(timeout: 8))
            let tabs = app.descendants(matching: .any)["details.tabs"]
            let search = tabs.buttons["main.tab.4"]
            waitUntil("The nested details footer is ready for input") {
                search.isHittable && self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0")
            }
            let footerFrame = tabs.frame
            search.tap()
            let body = app.staticTexts["body.motion.qa"]
            waitUntil("Nested platform dismissals end in the one root canvas transition", timeout: 10) {
                body.valueDescription.contains("kind=cover-tab;phase=completed")
                    && self.app.textFields["search-title-input"].isHittable
                    && self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0")
            }
            XCTAssertTrue(mainTabButton("搜索").isSelected)
            XCTAssertFalse(details.isHittable)
            XCTAssertFalse(app.buttons["playback.close"].isHittable)
            XCTAssertEqual(mainTabBar().frame, footerFrame)
            print("COVER181_ROOT appearance=\(appearance);" + body.valueDescription)
            attachScreenshot(named: "covered181-nested-to-search-\(appearance)")
            mainTabButton("收藏").tap()
            waitUntil("Returning to the root retains the video selection and card") { video.isSelected && cell.isHittable }
            app.terminate()
        }
    }

    func testCovered181ManualRotationRestoresAfterRootExitAndBackground() {
        for background in [false, true] {
            app = XCUIApplication()
            app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "--qa-header-motion",
                                   "--qa-body-motion", "-app.appearance", "light", "-muted", "YES", "-autoplay", "NO",
                                   "-civitviewer.automaticRotation", "NO"]
            if background { app.launchArguments.append("--qa-cover-root-hold181") }
            XCUIDevice.shared.orientation = .portrait
            app.launch()
            XCTAssertTrue(mainTabBar().waitForExistence(timeout: 10))
            mainTabButton("收藏").tap()
            let video = app.otherElements["collection.media-kind"].buttons["视频"]
            XCTAssertTrue(video.waitForExistence(timeout: 6)); video.tap()
            let cell = app.buttons["media.grid.cell.28037102"].firstMatch
            waitUntil("The offline card can open its real player") { cell.isHittable }
            cell.tap()
            waitUntil("Player entry is complete before rotating") {
                self.app.buttons["playback.close"].isHittable
                    && self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0")
            }
            visualEnsureLandscape()
            XCTAssertGreaterThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height)
            let footer = app.descendants(matching: .any)["playback.tabs"]
            let search = footer.buttons["main.tab.4"]
            waitUntil("The rotated player footer is ready") { search.isHittable }
            search.tap()
            if background {
                // Interrupt the explicit held handoff after the actual cover
                // dismissal; the restore intent must survive the same scene.
                XCUIDevice.shared.press(.home)
                app.activate()
            }
            waitUntil("Root choice and original orientation both survive cover teardown", timeout: 12) {
                self.mainTabButton("搜索").isSelected && self.app.textFields["search-title-input"].isHittable
                    && self.app.windows.firstMatch.frame.height > self.app.windows.firstMatch.frame.width
                    && self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0")
            }
            XCTAssertFalse(app.buttons["playback.close"].exists)
            attachScreenshot(named: "covered181-rotation-root-background-\(background)")
            app.terminate()
        }
        XCUIDevice.shared.orientation = .portrait
    }

    func testNative181SearchFilterHeaderMovesDuringNavigationAndBack() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "--qa-header-motion",
                               "--qa-body-motion", "-muted", "YES", "-autoplay", "NO", "-app.appearance", "light"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(mainTabBar().waitForExistence(timeout: 10))
        mainTabButton("搜索").tap()
        let field = app.textFields["search-title-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 6))
        let bottom = mainTabBar().frame
        let top = app.otherElements["search.top-bar"].frame.minY
        let motion = app.descendants(matching: .any)["header.layout-motion.qa"]
        func assertConcurrentHeightChange(_ opening: Bool) {
            let value = motion.valueDescription
            print("NATIVE181_HEADER opening=\(opening);" + value)
            let numbers = numericReadback(value)
            XCTAssertGreaterThan(numbers["nativeSamples"] ?? 0, 0, value)
            XCTAssertGreaterThan(numbers["nativeHeightOverlap"] ?? 0, 0, value)
            XCTAssertGreaterThan(abs((numbers["source"] ?? 0) - (numbers["target"] ?? 0)), 20, value)
            XCTAssertLessThanOrEqual(abs((numbers["topMax"] ?? -100) - (numbers["topMin"] ?? 100)), 1, value)
            XCTAssertEqual(mainTabBar().frame, bottom)
        }
        for _ in 0..<2 {
            heightTap(app.buttons["search.range"])
            let filter = floatingPageTitle("浏览条件")
            XCTAssertTrue(filter.waitForExistence(timeout: 6))
            waitUntil("Native push hands the fixed header to real filter controls") {
                filter.buttons["完成"].isHittable
                    && self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0")
            }
            assertConcurrentHeightChange(true)
            filter.buttons["完成"].tap()
            waitUntil("Button return restores the original search header") {
                field.isHittable && self.app.buttons["search.range"].isHittable
                    && self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0")
            }
            assertConcurrentHeightChange(false)
            XCTAssertEqual(app.otherElements["search.top-bar"].frame.minY, top, accuracy: 1)
        }
        app.terminate()
    }

    func testGlobalAuthorSearchDoesNotChangeWorkCriteria() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "-app.appearance", "light", "-muted", "YES"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        mainTabButton("搜索").tap()
        let mode = app.buttons["search.mode"]
        XCTAssertTrue(mode.waitForValueToContain("作品", timeout: 5))
        let title = app.textFields["search-title-input"]
        title.tap()
        title.typeText("Paging")
        app.buttons["search-submit"].tap()
        let results = app.descendants(matching: .any)["search.results"]
        XCTAssertTrue(results.waitForExistence(timeout: 5))
        attachScreenshot(named: "search-preview-works")

        let workToggle = mode.frame
        mode.tap()
        XCTAssertTrue(mode.waitForValueToContain("作者", timeout: 5))
        XCTAssertEqual(mode.frame, workToggle)
        XCTAssertTrue(mainTabButton("搜索").isHittable)
        let username = app.textFields["search-author-input"]
        XCTAssertTrue(username.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["search-author-picker"].exists)
        XCTAssertFalse(app.buttons["search-tag-picker"].exists)
        XCTAssertFalse(app.buttons["search.presets"].exists)
        username.tap()
        username.typeText("@Pagi")
        app.buttons["search-authors-submit"].tap()
        let candidate = app.buttons["search.author.28037001"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 5))
        XCTAssertEqual(candidate.label, "@PagingFixture")
        attachScreenshot(named: "search-preview-authors")
        candidate.tap()
        let creatorBar = app.otherElements["creator.top-bar"]
        XCTAssertTrue(creatorBar.waitForExistence(timeout: 5))
        let back = creatorBar.buttons["navigation.back"]
        XCTAssertEqual(workToggle.width, back.frame.width, accuracy: 1)
        heightTap(back)
        XCTAssertTrue(candidate.waitForExistence(timeout: 5))
        mode.tap()
        XCTAssertTrue(mode.waitForValueToContain("作品", timeout: 5))
        XCTAssertTrue(results.waitForExistence(timeout: 5))
        XCTAssertTrue(mainTabButton("搜索").isHittable)
        XCTAssertEqual(title.value as? String, "Paging")
        XCTAssertEqual(app.buttons["search-author-picker"].valueDescription, "未选择")
    }

    func testScrolledSettingsRetainsViewportAcrossRootTabs166() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "--qa-header-motion", "--qa-body-motion",
                               "-app.appearance", "light", "-muted", "YES", "-autoplay", "NO"]
        app.launch()
        func idle() {
            waitUntil("The visible page releases its transition input lease") {
                self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0")
            }
        }
        mainTabButton("时间线").tap(); idle()
        openAccountSettings()
        let header = floatingPageTitle("账号与设置")
        XCTAssertTrue(header.waitForExistence(timeout: 5)); idle()
        app.swipeUp()
        let candidates = ["播放侧栏", "自动播放视频", "视频默认静音", "自动修复不兼容视频", "自动旋转",
                          "最近浏览与接着看", "本机错误与诊断记录", "推荐时间线默认筛选", "关注时间线默认筛选",
                          "屏蔽标签", "屏蔽的作者", "本地标签库与同步", "合并相同媒体", "媒体缓存", "磁盘缓存上限"]
        guard let row = candidates.map({ app.staticTexts[$0] }).first(where: {
            $0.isHittable && $0.frame.minY > header.frame.maxY + 20 && $0.frame.maxY < self.mainTabBar().frame.minY - 20
        }) else { XCTFail("A middle settings row is fully visible after a real scroll"); return }
        let y = row.frame.minY
        let bottom = mainTabBar().frame
        mainTabButton("搜索").tap()
        XCTAssertTrue(app.otherElements["search.top-bar"].waitForExistence(timeout: 5)); idle()
        mainTabButton("时间线").tap()
        XCTAssertTrue(header.waitForExistence(timeout: 5)); idle()
        XCTAssertEqual(row.frame.minY, y, accuracy: 2)
        XCTAssertTrue(app.staticTexts["body.motion.qa"].valueDescription.contains("liveBody=0"))
        XCTAssertGreaterThan(heightValues(app.staticTexts["header.layout-motion.qa"].valueDescription)["intermediate"] ?? 0, 1)
        XCTAssertEqual(mainTabBar().frame, bottom)
        attachScreenshot(named: "settings166-preserved-child-viewport")
    }

    func testRootClearanceTopAndMiddleViewports166() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "--qa-search-viewport166",
                               "--qa-author-activity58", "--qa-header-motion", "--qa-body-motion",
                               "-deduplicateMedia", "NO", "-app.appearance", "light", "-muted", "YES"]
        app.launch()
        func route(_ title: String) {
            print("CLEARANCE166 route=\(title);time=\(Date().timeIntervalSince1970)")
            mainTabButton(title).tap()
            waitUntil("Root selection and visual session finish") {
                self.mainTabButton(title).isSelected
                    && self.app.staticTexts["body.motion.qa"].valueDescription.contains("phase=completed")
                    && self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0")
            }
        }
        route("作者榜")
        let bottom = mainTabBar().frame
        route("搜索")
        XCTAssertTrue(app.staticTexts["body.motion.qa"].valueDescription.contains("liveBody=0"), "Root170 keeps visual ownership until the final layout is ready")
        let field = app.textFields["search-title-input"]
        field.tap(); field.typeText("Paging")
        app.buttons["search-submit"].tap()
        let first = app.buttons["media.grid.cell.28039000"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let firstY = first.frame.minY
        route("作者榜")
        XCTAssertTrue(app.staticTexts["body.motion.qa"].valueDescription.contains("liveBody=0"), "Root170 keeps visual ownership until the final layout is ready")
        route("搜索")
        XCTAssertEqual(first.frame.minY, firstY, accuracy: 2)
        app.swipeUp(); app.swipeUp()
        let gridRows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "media.grid.cell."))
        guard let grid = gridRows.allElementsBoundByIndex.first(where: { $0.isHittable && $0.frame.minY > 180 && $0.frame.maxY < bottom.minY }) else {
            XCTFail("A complete middle search row is visible"); return
        }
        let gridID = grid.identifier, gridY = grid.frame.minY
        route("作者榜")
        app.swipeUp(); app.swipeUp()
        let authorRows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "leaderboard.author."))
        guard let author = authorRows.allElementsBoundByIndex.first(where: { $0.isHittable && $0.frame.minY > 180 && $0.frame.maxY < bottom.minY }) else {
            XCTFail("A complete middle author row is visible"); return
        }
        let authorID = author.identifier, authorY = author.frame.minY
        route("搜索")
        XCTAssertEqual(app.buttons[gridID].frame.minY, gridY, accuracy: 2)
        XCTAssertTrue(app.staticTexts["body.motion.qa"].valueDescription.contains("liveBody=0"))
        XCTAssertGreaterThan(heightValues(app.staticTexts["header.layout-motion.qa"].valueDescription)["intermediate"] ?? 0, 1)
        route("作者榜")
        XCTAssertEqual(app.buttons[authorID].frame.minY, authorY, accuracy: 2)
        XCTAssertTrue(app.staticTexts["body.motion.qa"].valueDescription.contains("liveBody=0"))
        XCTAssertGreaterThan(heightValues(app.staticTexts["header.layout-motion.qa"].valueDescription)["intermediate"] ?? 0, 1)
        XCTAssertEqual(mainTabBar().frame, bottom)
        attachScreenshot(named: "clearance166-preserved-middle-viewport")
    }

    func testSearchResourcesAreLazyAndRetained172() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-drag-performance167", "--qa-search-resources172", "--qa-header-motion",
                               "-app.appearance", "light", "-muted", "YES", "-autoplay", "NO"]
        app.launch()
        func idle() {
            waitUntil("Search navigation settles") {
                self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0")
            }
        }
        func state() -> [String: String] { self.qaFields(self.app.staticTexts["search.resources172"].valueDescription) }
        print("SEARCH172_ENTRY epoch=\(Date().timeIntervalSince1970)")
        mainTabButton("搜索").tap(); idle()
        XCTAssertTrue(app.staticTexts["search.resources172"].waitForExistence(timeout: 5))
        let initial = state()
        XCTAssertEqual(initial["authors"], "false"); XCTAssertEqual(initial["feed"], "false"); XCTAssertEqual(initial["directory"], "false")
        print("SEARCH172_AUTHORS_FIRST epoch=\(Date().timeIntervalSince1970)")
        app.buttons["search.mode"].tap(); idle()
        XCTAssertTrue(app.textFields["search-author-input"].exists)
        XCTAssertEqual(state()["authors"], "true"); XCTAssertEqual(state()["directory"], "false")
        app.buttons["search.mode"].tap(); idle()
        print("SEARCH172_TAGS_FIRST epoch=\(Date().timeIntervalSince1970)")
        app.buttons["search-tag-picker"].tap()
        XCTAssertTrue(floatingPageTitle("选择标签").waitForExistence(timeout: 5)); idle()
        floatingPageTitle("选择标签").buttons["navigation.back"].tap(); idle()
        XCTAssertEqual(state()["directory"], "true")
        let retained = state()
        XCTAssertEqual(initial["owner"], retained["owner"])
        app.buttons["search.mode"].tap(); idle()
        XCTAssertEqual(state()["owner"], initial["owner"])
        print("SEARCH172_END epoch=\(Date().timeIntervalSince1970);state=\(app.staticTexts["search.resources172"].valueDescription)")
        let cadence = app.staticTexts["performance.cadence172"]
        if cadence.exists { print("SEARCH172_CADENCE \(cadence.valueDescription)") }
    }

    func testSearchModesKeepIndependentViewports166() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "--qa-header-motion",
                               "-app.appearance", "light", "-muted", "YES"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        func idle() {
            waitUntil("Page motion releases input") {
                self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0")
            }
        }
        mainTabButton("搜索").tap(); idle()
        let mode = app.buttons["search.mode"]
        mode.tap(); idle()
        let username = app.textFields["search-author-input"]
        XCTAssertTrue(username.waitForExistence(timeout: 5))
        username.tap(); username.typeText("pagedfixture")
        app.buttons["search-authors-submit"].tap()
        let authors = app.scrollViews["author-lookup.results"]
        let row = app.buttons["search.author.29000024"]
        for _ in 0..<6 where !row.isHittable { authors.swipeUp() }
        XCTAssertTrue(row.isHittable)
        let originalY = row.frame.minY
        mode.tap(); idle()
        let title = app.textFields["search-title-input"]
        title.tap(); title.typeText("Paging")
        app.buttons["search-submit"].tap()
        XCTAssertTrue(app.otherElements["search.results"].waitForExistence(timeout: 5))
        mode.tap(); idle()
        XCTAssertTrue(row.isHittable, "Returning to author mode keeps its loaded page")
        XCTAssertEqual(row.frame.minY, originalY, accuracy: 2)
        XCTAssertFalse(app.descendants(matching: .any)["author-lookup.initial-progress"].exists)
        row.tap()
        let creator = app.otherElements["creator.top-bar"]
        XCTAssertTrue(creator.waitForExistence(timeout: 5)); idle()
        creator.buttons["navigation.back"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5)); idle()
        XCTAssertEqual(row.frame.minY, originalY, accuracy: 2)
        mainTabButton("收藏").tap(); idle()
        mainTabButton("搜索").tap(); idle()
        XCTAssertEqual(row.frame.minY, originalY, accuracy: 2)
        XCTAssertEqual(username.value as? String, "pagedfixture")
        mode.tap(); idle()
        XCTAssertEqual(title.value as? String, "Paging")
        XCTAssertTrue(app.otherElements["search.results"].exists)
        attachScreenshot(named: "search166-retained-author-and-work-state")
    }

    func testAuthorSearchCentersInitialProgressAndLoadsMoreAtTheEnd() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "-muted", "YES"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        mainTabButton("搜索").tap()
        app.buttons["search.mode"].tap()
        let username = app.textFields["search-author-input"]
        XCTAssertTrue(username.waitForExistence(timeout: 5))
        username.tap()
        username.typeText("pagedfixture")
        app.buttons["search-authors-submit"].tap()

        let results = app.scrollViews["author-lookup.results"]
        let progress = app.descendants(matching: .any)["author-lookup.initial-progress"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 3))
        XCTAssertEqual(progress.frame.midX, app.frame.midX, accuracy: 2)
        XCTAssertEqual(progress.frame.midY, app.frame.midY, accuracy: 12)

        XCTAssertTrue(app.buttons["search.author.29000001"].waitForExistence(timeout: 6))
        let lastAuthor = app.buttons["search.author.29000025"]
        for _ in 0..<6 where !lastAuthor.isHittable { results.swipeUp() }
        XCTAssertTrue(lastAuthor.waitForExistence(timeout: 5))
        XCTAssertTrue(lastAuthor.isHittable)
    }

    func testAuthorPageSearchUsesTheSameInlineResults() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "-app.appearance", "light", "-muted", "YES"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        mainTabButton("作者榜").tap()
        heightTap(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Pattern Creator 1")).firstMatch)
        let authorBar = app.otherElements["creator.top-bar"]
        XCTAssertTrue(authorBar.waitForExistence(timeout: 5))
        heightTap(app.otherElements["creator.media-kind"].buttons["视频"])
        heightTap(authorBar.buttons["creator.actions"])
        heightTap(app.buttons["creator.search"])
        let searchBar = app.otherElements["search.top-bar"]
        XCTAssertTrue(searchBar.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["search-author-picker"].valueDescription.contains("@Pattern Creator 1"))
        XCTAssertTrue(app.buttons["search.range"].label.contains("视频"))
        XCTAssertFalse(app.buttons["search.mode"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["search.results"].exists)
        attachScreenshot(named: "search-preview-from-author")
        let field = app.textFields["search-title-input"]
        field.tap()
        field.typeText("Paging")
        app.buttons["search-submit"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["search.results"].waitForExistence(timeout: 5))
        XCTAssertTrue(searchBar.isHittable)
        attachScreenshot(named: "search-works-from-author")
    }

    func testDownloadManagementTaskAndSpaceSections() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "--qa-download-tasks", "-app.appearance", "light",
                               "-muted", "YES", "-autoplay", "NO"]
        app.launch()
        let downloads = app.buttons["collections.downloads"]
        XCTAssertTrue(downloads.waitForExistence(timeout: 8))
        downloads.tap()
        let header = app.otherElements["page-title.下载管理"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        let sections = header.otherElements["downloads.section"]
        XCTAssertTrue(header.buttons["downloads.menu"].exists)
        XCTAssertFalse(app.buttons["downloads.storage"].exists)
        attachScreenshot(named: "downloads-tasks-redesign")
        sections.buttons["空间"].tap()
        let cleanup = app.buttons["offline.storage.clean-unfavorited"]
        XCTAssertTrue(cleanup.waitForExistence(timeout: 5))
        attachScreenshot(named: "downloads-space-redesign")
        sections.buttons["任务"].tap()
        XCTAssertTrue(app.buttons["downloads.task-action.28037601"].waitForExistence(timeout: 5))
        header.buttons["downloads.menu"].tap()
        XCTAssertTrue(app.buttons["检查待下载收藏"].waitForExistence(timeout: 3))
        attachScreenshot(named: "downloads-menu-redesign")
        app.buttons["下载设置"].tap()
        let settings = floatingPageTitle("下载设置")
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertTrue(settings.buttons["downloads.reset"].exists)
        settings.buttons["navigation.back"].tap()
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        header.buttons["navigation.back"].tap()
        XCTAssertTrue(downloads.waitForExistence(timeout: 5))
    }

    func testDownloadsBackAndTabSwitchKeepTheirNavigationContexts() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-download-tasks", "--qa-height-audit", "--qa-header-motion", "--qa-body-motion", "-app.appearance", "light",
                               "-muted", "YES", "-autoplay", "NO"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let collection = app.otherElements["collections.top-bar"]
        let downloads = collection.buttons["collections.downloads"]
        let header = floatingPageTitle("下载管理")
        func unlocked(_ message: String) {
            waitUntil(message) {
                self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0")
            }
        }
        XCTAssertTrue(downloads.waitForExistence(timeout: 8))
        downloads.tap()
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        unlocked("Download page finishes its header and body transition")
        header.buttons["navigation.back"].tap()
        XCTAssertTrue(downloads.waitForExistence(timeout: 5))
        unlocked("Collection root is ready for the next action")
        mainTabButton("时间线").tap()
        XCTAssertTrue(timelineTools().waitForExistence(timeout: 5))
        unlocked("Timeline root finishes navigation")
        mainTabButton("收藏").tap()
        XCTAssertTrue(downloads.waitForExistence(timeout: 5))
        unlocked("Collection root is ready for the next action")
        downloads.tap()
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        unlocked("Download page finishes its header and body transition")
        mainTabButton("搜索").tap()
        print("DOWNLOADS_ROOT_BEGIN " + app.staticTexts["header.motion.begin.qa"].valueDescription)
        XCTAssertTrue(app.otherElements["search.top-bar"].waitForExistence(timeout: 5))
        unlocked("Search root finishes navigation")
        XCTAssertFalse(header.isHittable)
        mainTabButton("收藏").tap()
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        unlocked("Download page finishes its header and body transition")
        let back = header.buttons["navigation.back"]
        XCTAssertTrue(back.isHittable)
        back.tap()
        let video = app.otherElements["collection.media-kind"].buttons["视频"]
        XCTAssertTrue(video.waitForExistence(timeout: 5))
        video.tap()
        unlocked("Collection media selection settles before opening a work")
        let work = app.buttons["media.grid.cell.28037102"]
        XCTAssertTrue(work.waitForExistence(timeout: 5))
        waitUntil("The downloaded local work is interactive") { work.isHittable }
        work.tap()
        let playerTabs = app.descendants(matching: .any)["playback.tabs"]
        let search = playerTabs.buttons["main.tab.4"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        print("DOWNLOADS_ROOT_BEGIN " + app.staticTexts["header.motion.begin.qa"].valueDescription)
        XCTAssertTrue(app.otherElements["search.top-bar"].waitForExistence(timeout: 5))
        unlocked("Search root finishes navigation")
        XCTAssertFalse(playerTabs.isHittable)
        mainTabButton("收藏").tap()
        XCTAssertTrue(downloads.waitForExistence(timeout: 5))
        unlocked("Collection root is ready for the next action")
        downloads.tap()
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        unlocked("Download page finishes its header and body transition")
    }

    private func favorite69Submit(extra: [String] = [], remove: Bool = false, nested: Bool = false) {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-favorite-save69-delay", "-muted", "YES", "-autoplay", "NO"] + extra)
        if nested {
            visualButton("media.author.28037100").tap()
            XCTAssertTrue(app.descendants(matching: .any)["creator.top-bar"].waitForExistence(timeout: 5))
            let cell = visualButton("media.grid.cell.28037100")
            XCTAssertTrue(cell.waitForExistence(timeout: 5)); cell.tap()
            XCTAssertTrue(app.buttons["关闭作品"].waitForExistence(timeout: 5))
        }
        openFavoriteFolders(visualButton("favorite-28037100"))
        XCTAssertTrue(floatingPageTitle("收藏图片").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["新建私密收藏夹"].exists)
        let folder = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "分页测试收藏")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        if remove { folder.tap() }
        let save = app.buttons["保存"]
        XCTAssertTrue(save.isEnabled); save.tap()
        XCTAssertTrue(floatingPageTitle("收藏图片").waitForNonExistence(timeout: 2), "Saving must dismiss without waiting for the controlled six-second server operation")
        let state = app.staticTexts["favorite69.qa.state"]
        XCTAssertTrue(state.waitForExistence(timeout: 2))
        XCTAssertTrue(state.valueDescription.contains("pending=28037100"))
        XCTAssertFalse(app.staticTexts["正在保存并核对…"].exists)
        attachScreenshot(named: "favorite69-background-save")
    }

    func testFavorite69SaveContinuesAfterPickerDismissalAndPagingAway() {
        favorite69Submit()
        heightDeck().swipeUp()
        XCTAssertTrue(visualButton("favorite-28037101").waitForExistence(timeout: 4), "The user can continue browsing while the save is pending")
        let state = app.staticTexts["favorite69.qa.state"]
        waitUntil("A session-owned save completes after its picker and original page stop being visible", timeout: 10) {
            state.valueDescription.contains("pending=-1;saved=true;message=false")
        }
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    func testFavorite69FailureRemainsVisibleAfterPickerDismissal() {
        favorite69Submit(extra: ["--qa-favorite-save69-failure"])
        let toast = app.staticTexts["app.toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 10))
        XCTAssertTrue(toast.label.contains("收藏结果尚未确认"))
        waitUntil("The existing global message is acknowledged once") {
            self.app.staticTexts["favorite69.qa.state"].valueDescription.contains("pending=-1;saved=false;message=false")
        }
        XCTAssertFalse(app.alerts.firstMatch.exists)
        attachScreenshot(named: "favorite169-error-central-toast")
    }

    func testFavorite69AccountInvalidationDiscardsLateSaveAndError() {
        favorite69Submit(extra: ["--qa-favorite-save69-account-change"])
        let state = app.staticTexts["favorite69.qa.state"]
        waitUntil("Invalidating the account context clears saving and rejects a late completion", timeout: 10) {
            state.valueDescription.contains("pending=-1;saved=false;message=false")
        }
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    func testFavorite69FailureIsPresentedOverAuthorWorkViewer() {
        favorite69Submit(extra: ["--qa-favorite-save69-failure"], nested: true)
        let toast = app.staticTexts["app.toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 10), "The existing failure remains visible above the full-screen work")
        XCTAssertTrue(toast.label.contains("收藏结果尚未确认"))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        attachScreenshot(named: "favorite169-error-above-player")
    }

    func testFavorite69RemovalAlsoCompletesOutsidePicker() {
        favorite69Submit(extra: ["--qa-favorite-save69-start-saved"], remove: true)
        let state = app.staticTexts["favorite69.qa.state"]
        XCTAssertTrue(state.valueDescription.contains("saved=true"), "The previous confirmed state stays visible until the removal finishes")
        waitUntil("Removal completes through the same session-owned save", timeout: 10) {
            state.valueDescription.contains("pending=-1;saved=false;message=false")
        }
        XCTAssertEqual(visualButton("favorite-28037100").label, "收藏")
    }

    func testCover69WaitingAndFailedPreviewsKeepWorkIdentifiers() {
        app = XCUIApplication(); app.launchArguments = ["--qa-grid-retry55", "--qa-cover69-wait", "-muted", "YES"]; app.launch()
        for name in ["图片 · #55001", "视频 · #55002"] {
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch.waitForExistence(timeout: 3))
        }
        XCTAssertEqual(app.progressIndicators.count, 0, "A cover wait must show a stable placeholder, not only a spinner")
        attachScreenshot(named: "cover69-waiting-image-and-video-placeholders")
        XCTAssertTrue(app.buttons["media.grid.retry.55001"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["media.grid.retry.55002"].exists)
        XCTAssertEqual(app.progressIndicators.count, 0)
        attachScreenshot(named: "cover69-failed-image-and-video-identifiers")
    }

    func testCover69UnderlyingCancellationFinishesActivePreview() {
        app = XCUIApplication(); app.launchArguments = ["--qa-grid-retry55", "--qa-cover69-cancel", "-muted", "YES"]; app.launch()
        let retry = app.buttons["media.grid.retry.55002"]
        XCTAssertTrue(retry.waitForExistence(timeout: 8), "A live consumer receiving underlying cancellation must enter its existing failure state")
        let attempts = app.staticTexts["grid.preview.attempts.55002"]
        XCTAssertTrue(attempts.waitForExistence(timeout: 3)); XCTAssertTrue(attempts.valueDescription.contains("attempts=1"))
        XCTAssertEqual(app.progressIndicators.count, 0)
        XCTAssertTrue(retry.isHittable); retry.tap()
        XCTAssertTrue(attempts.waitForValueToContain("attempts=2", timeout: 8), "Retry must start a second real preview task, rather than only leave the old error visible")
        XCTAssertTrue(retry.waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts["grid.retry.qa.opens"].label, "opened=0")
        attachScreenshot(named: "cover69-underlying-cancellation-has-retry")
    }

    func testGestures68CoveredEnabledPageCannotReceiveAuthorsEdgeSwipe() {
        app = XCUIApplication(); app.launchArguments = ["--qa-gesture-scope68", "--qa-collection-paging", "-muted", "YES", "-autoplay", "NO"]
        XCUIDevice.shared.orientation = .portrait; app.launch()
        let cover = app.staticTexts["gesture68.cover.state"]
        XCTAssertTrue(cover.waitForExistence(timeout: 8)); XCTAssertEqual(cover.label, "backgroundSwitches=0")
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.985, dy: 0.45))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.45)))
        attachScreenshot(named: "gestures68-covered-owner-must-ignore-authors-touch")
        XCTAssertEqual(cover.label, "backgroundSwitches=0", "An enabled retained page cannot observe touches in another controller's author page")
        app.buttons["返回播放页"].tap()
        let page = app.staticTexts["gesture68.page.state"]
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.985, dy: 0.45))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.45)))
        waitUntil("The same recognizer still handles its own page after returning") { page.label == "backgroundSwitches=1" }
    }

    func testAuthorPageCenterAndBothEdgesChangeMedia() {
        visualLaunch(width: 0, large: false, landscape: false, extra: ["-muted", "YES", "-autoplay", "NO"])
        let author = visualButton("media.author.28037100")
        XCTAssertTrue(author.isHittable)
        author.tap()
        let authorBar = app.descendants(matching: .any)["creator.top-bar"]
        XCTAssertTrue(authorBar.waitForExistence(timeout: 8))
        XCTAssertFalse(app.navigationBars["作者作品"].exists)
        let picker = app.otherElements["creator.media-kind"]
        let image = visualButton("media.grid.cell.28037100")
        let video = visualButton("media.grid.cell.28037102")
        let window = app.windows.firstMatch

        func swipe(from startX: CGFloat, _ startY: CGFloat, to endX: CGFloat, _ endY: CGFloat) {
            window.coordinate(withNormalizedOffset: CGVector(dx: startX, dy: startY))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: endX, dy: endY)))
        }

        waitUntil("The author page starts with a visible image grid") {
            picker.buttons["图片"].isSelected && image.isHittable
        }
        XCTAssertGreaterThan(image.frame.minY, authorBar.frame.maxY)
        XCTAssertEqual(image.frame.minX, authorBar.frame.minX, accuracy: 2)
        attachScreenshot(named: "floating-topbar-creator")
        XCTAssertFalse(app.buttons["creator.biography.toggle"].exists)
        swipe(from: 0.75, 0.71, to: 0.45, 0.34)
        XCTAssertTrue(picker.buttons["图片"].isSelected, "A vertical scroll keeps the selected media")

        let imageY = (image.frame.midY - window.frame.minY) / window.frame.height
        swipe(from: 0.76, imageY, to: 0.24, imageY)
        waitUntil("Swiping left in the grid loads the author's videos") {
            picker.buttons["视频"].isSelected && video.isHittable && !image.isHittable
        }
        XCTAssertTrue(authorBar.isHittable)

        let videoY = (video.frame.midY - window.frame.minY) / window.frame.height
        swipe(from: 36 / window.frame.width, videoY, to: 0.76, videoY)
        waitUntil("Swiping right in the grid restores the author's images") {
            picker.buttons["图片"].isSelected && image.isHittable && !video.isHittable
        }
        image.tap()
        let close = app.buttons["关闭作品"]
        XCTAssertTrue(close.waitForExistence(timeout: 8), "A normal tap still opens a work")
        close.tap()
        waitUntil("The author page is visible after closing the work") {
            authorBar.buttons["navigation.back"].isHittable && image.isHittable
        }

        let beforeCancel = authorBar.frame
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.52))
            .press(forDuration: 0.1,
                   thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.52)),
                   withVelocity: .slow, thenHoldForDuration: 0.7)
        waitUntil("Cancelling the tab preview restores the author header") {
            authorBar.buttons["navigation.back"].isHittable
        }
        XCTAssertEqual(authorBar.frame.minX, beforeCancel.minX, accuracy: 1)
        XCTAssertEqual(authorBar.frame.minY, beforeCancel.minY, accuracy: 1)

        swipe(from: 28 / window.frame.width, 0.52, to: 0.84, 0.52)
        waitUntil("The left edge switches the browsing tab") { picker.buttons["视频"].isSelected }
        XCTAssertTrue(authorBar.exists)
        authorBar.buttons["navigation.back"].tap()
        XCTAssertTrue(authorBar.waitForNonExistence(timeout: 5))
        waitUntil("The same timeline item is visible after the return") {
            self.visualButton("media.author.28037100").isHittable && self.watchFocus() == 28_037_100
        }
        XCTAssertTrue(app.otherElements["timeline.media-kind"].buttons["图片"].isSelected)
    }

    func testTabSwitchAfterOpeningAuthorKeepsSearchHeaderHittable() {
        visualLaunch(width: 0, large: false, landscape: false, extra: ["--qa-header-motion", "--qa-body-motion", "-muted", "YES", "-autoplay", "NO"])
        let window = app.windows.firstMatch
        let searchTab = mainTabButton("搜索")
        let searchPosition = searchTab.frame
        let searchCoordinate = window.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: searchPosition.midX - window.frame.minX, dy: searchPosition.midY - window.frame.minY)
        )

        visualButton("media.author.28037100").tap()
        XCTAssertTrue(app.descendants(matching: .any)["creator.top-bar"].waitForExistence(timeout: 5))
        waitUntil("Author entry finishes before a new tab click") {
            self.app.descendants(matching: .any)["page.interaction-lock"].valueDescription.contains("locks=0")
        }
        searchCoordinate.tap()

        let searchHeader = app.otherElements["search.top-bar"]
        if !searchHeader.waitForExistence(timeout: 8) {
            attachScreenshot(named: "tabs164-after-author-missing-search")
            print("TAB164_LOCK " + app.descendants(matching: .any)["page.interaction-lock"].valueDescription)
            print("TAB164_SEARCH_SELECTED \(searchTab.isSelected)")
            XCTFail("The search tab must become visible"); return
        }
        XCTAssertTrue(searchTab.isSelected)
        let searchField = app.textFields["search-title-input"]
        waitUntil("Search must accept input after the tab switch") { searchField.isHittable }
        searchField.tap()
        searchField.typeText("test")
        XCTAssertEqual(searchField.value as? String, "test")
        let creatorBack = app.descendants(matching: .any)["creator.top-bar"].buttons["navigation.back"]
        XCTAssertFalse(creatorBack.isHittable)
        mainTabButton("时间线").tap()
        waitUntil("The author push must have succeeded and its header must still work") {
            creatorBack.isHittable
        }
    }

    func testGestures68AuthorGridDoesNotChangeStreamBehindIt() {
        auditAuthorGestureScope68(fromGrid: false, openWork: false)
    }

    func testGestures68AuthorWorkDoesNotChangeStreamBehindIt() {
        auditAuthorGestureScope68(fromGrid: false, openWork: true)
    }

    func testGestures68AuthorGridDoesNotChangeGridViewerBehindIt() {
        auditAuthorGestureScope68(fromGrid: true, openWork: false)
    }

    func testGestures68AuthorWorkDoesNotChangeGridViewerBehindIt() {
        auditAuthorGestureScope68(fromGrid: true, openWork: true)
    }

    func testGestures68AuthorVideoDoesNotChangeStreamBehindIt() {
        auditAuthorGestureScope68(fromGrid: false, openWork: true, video: true)
    }

    func testGestures68AuthorVideoDoesNotChangeGridViewerBehindIt() {
        auditAuthorGestureScope68(fromGrid: true, openWork: true, video: true)
    }

    private func auditAuthorGestureScope68(fromGrid: Bool, openWork: Bool, video: Bool = false) {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["-autoplay", "YES", "-muted", "YES"] + (fromGrid ? ["--qa-pager-touch-trace"] : []))
        let picker = app.otherElements["timeline.media-kind"]
        if video { picker.buttons["视频"].tap() }
        let initialKind = video ? "视频" : "图片", nextKind = video ? "图片" : "视频"
        let initialRaw = video ? "video" : "image", itemID = video ? 28_037_102 : 28_037_100
        XCTAssertTrue(picker.buttons[initialKind].isSelected)
        if fromGrid {
            toggleTimelinePresentation()
            let cell = visualButton("media.grid.cell.\(itemID)")
            XCTAssertTrue(cell.waitForExistence(timeout: 8)); cell.tap()
        }
        if video { waitPlayingFixture() }
        let author = visualButton("media.author.\(itemID)")
        XCTAssertTrue(author.waitForExistence(timeout: 8)); author.tap()
        XCTAssertTrue(app.descendants(matching: .any)["creator.top-bar"].waitForExistence(timeout: 8))
        if openWork {
            let cell = visualButton("media.grid.cell.\(itemID)")
            XCTAssertTrue(cell.waitForExistence(timeout: 8)); cell.tap()
            XCTAssertTrue(visualButton("media.author.\(itemID)").waitForExistence(timeout: 8))
            if video { waitPlayingFixture() }
            if !fromGrid {
                heightDeck().swipeUp()
                let nextID = video ? 28_037_104 : 28_037_101
                waitUntil("The author viewer can advance to the next work") { self.watchFocus() == nextID }
                heightDeck().swipeDown()
                waitUntil("The author viewer can return to the previous work") { self.watchFocus() == itemID }
            }
        }
        let route = "\(fromGrid ? "grid-viewer" : "stream")-author-\(video ? "video" : (openWork ? "image" : "grid"))"
        let window = app.windows.firstMatch
        let edgeY = openWork ? 0.45 : 0.23
        let startX = video ? 0.015 : 0.985, endX = video ? 0.45 : 0.55
        window.coordinate(withNormalizedOffset: CGVector(dx: startX, dy: edgeY))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: endX, dy: edgeY)))
        attachScreenshot(named: "gestures68-after-child-edge-\(route)")
        let back = visualButton("navigation.back")
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        waitUntil("Return must target the actually visible author page") { back.isHittable }
        back.tap()
        if fromGrid {
            waitUntil("Returning from the author reveals the same grid work") {
                self.visualButton("media.author.\(itemID)").isHittable && self.watchFocus() == itemID
            }
            closeVisibleWork68()
        }
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(picker.buttons[initialKind].isSelected,
                      "\(route): an edge swipe in a child page must not change the retained timeline's media filter")
        XCTAssertTrue(app.staticTexts["qa.controls.filter"].valueDescription.hasPrefix("kind=\(initialRaw);"))
        if fromGrid {
            toggleTimelinePresentation()
            waitUntil("The timeline stream is visible after closing the grid viewer") {
                self.heightDeck().identifier == "timeline.media.deck" && self.heightDeck().isHittable &&
                self.visualButton("media.author.\(itemID)").isHittable
            }
        }
        if video { waitPlayingFixture() }
        window.coordinate(withNormalizedOffset: CGVector(dx: startX, dy: 0.57))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: endX, dy: 0.57)))
        if fromGrid { attachEdgeTrace(route) }
        attachScreenshot(named: "gestures68-parent-edge-restored-\(route)")
        waitUntil("The original timeline still applies its own edge filter change") { picker.buttons[nextKind].isSelected }
        if !video {
            waitUntil("Returning to the actual timeline restores its own edge type switch") { self.watchFocus() == 28_037_102 }
            waitPlayingFixture()
        }
    }

    private func attachEdgeTrace(_ name: String) {
        for probe in app.staticTexts.matching(identifier: "pager.qa.trace").allElementsBoundByIndex {
            let attachment = XCTAttachment(string: probe.valueDescription)
            attachment.name = "edge79-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func closeVisibleWork68() {
        guard let close = app.buttons.matching(NSPredicate(format: "label == %@", "关闭作品"))
            .allElementsBoundByIndex.first(where: \.isHittable) else {
            XCTFail("Expected the current full-screen viewer's visible close action"); return
        }
        close.tap()
    }

    func testLayout73SameCaptionPositionsAcrossRealEntries() {
        visualLaunch(width: 0, large: false, landscape: false, extra: ["-autoplay", "YES", "-muted", "YES"])
        app.otherElements["timeline.media-kind"].buttons["视频"].tap()
        waitPlayingFixture()
        var metrics: [String: [String: Double]] = [:]
        func sample(_ route: String) {
            let author = visualButton("media.author.28037102"), details = visualButton("media.details.28037102")
            let follow = visualButton("media.follow.28037102")
            XCTAssertTrue(author.waitForExistence(timeout: 8)); XCTAssertTrue(details.waitForExistence(timeout: 8))
            waitUntil("The same work and caption must be visible before comparing entry layouts") {
                author.isHittable && details.isHittable && follow.isHittable && self.watchFocus() == 28_037_102
            }
            let seek = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "播放进度")).allElementsBoundByIndex.first(where: \.isHittable)
            guard let seek else { XCTFail("Missing actual current seek control"); return }
            let viewport = heightDeck().frame
            metrics[route] = ["authorX":author.frame.minX,"authorY":author.frame.minY,"authorW":author.frame.width,"authorH":author.frame.height,
                              "detailsX":details.frame.minX,"detailsY":details.frame.minY,"detailsW":details.frame.width,"detailsH":details.frame.height,
                              "seekY":seek.frame.minY,"seekMaxY":seek.frame.maxY,"viewportY":viewport.minY,"viewportH":viewport.height,
                              "windowW":app.windows.firstMatch.frame.width,"windowH":app.windows.firstMatch.frame.height]
            print("PLAYER73_ENTRY \(route) \(metrics[route]!)")
            attachScreenshot(named: "player73-aligned-\(route)")
        }
        sample("timeline")
        mainTabButton("收藏").tap()
        let video = app.otherElements["collection.media-kind"].buttons["视频"]
        XCTAssertTrue(video.waitForExistence(timeout: 5))
        if !video.isSelected { video.tap() }
        let cell = app.buttons["media.grid.cell.28037102"]
        XCTAssertTrue(cell.waitForExistence(timeout: 8)); if !cell.isHittable { app.swipeUp() }; cell.tap()
        waitPlayingFixture(); sample("collection")
        visualOpenDetails(itemID: 28_037_102)
        visualButton("details.author").tap()
        XCTAssertTrue(app.descendants(matching: .any)["creator.top-bar"].waitForExistence(timeout: 8))
        let creatorCell = visualButton("media.grid.cell.28037102")
        XCTAssertTrue(creatorCell.waitForExistence(timeout: 8)); if !creatorCell.isHittable { app.swipeUp() }; creatorCell.tap()
        waitPlayingFixture(); sample("creator")
        visualButton("media.author.28037102").tap()
        XCTAssertTrue(visualButton("media.grid.cell.28037102").waitForExistence(timeout: 5), "Author tap in that author's viewer should still close back to its grid")
        guard let timeline = metrics["timeline"] else { XCTFail("Missing timeline reference"); return }
        for route in ["collection", "creator"] {
            guard let value = metrics[route] else { XCTFail("Missing entry \(route)"); continue }
            for key in ["authorX", "authorY", "detailsX", "detailsY", "seekY", "seekMaxY"] {
                XCTAssertEqual(value[key]!, timeline[key]!, accuracy: 0.5, "\(route) \(key) must share the measured timeline overlay baseline")
            }
            XCTAssertEqual(value["viewportH"]!, timeline["viewportH"]!, accuracy: 0.5, "Floating controls must not shrink the media canvas")
        }
        let attachment = XCTAttachment(string: String(data: try! JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys]), encoding: .utf8)!)
        attachment.name = "player73-three-real-entries"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testTags67DetailsSelectionKeepsVisibleChipLayout() {
        visualLaunch(width: 0, large: false, landscape: false, extra: ["--qa-details-tags", "--qa-header-motion", "-muted", "YES"])
        app.otherElements["timeline.media-kind"].buttons["视频"].tap()
        let details = app.buttons["media.details.28037102"].firstMatch
        waitUntil("Video content transition settles before opening details") {
            details.isHittable && self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0")
        }
        print("FLOAT173_DETAILS_ENTRY frame=\(details.frame);locks=\(app.staticTexts["page.interaction-lock"].valueDescription)")
        details.tap()
        XCTAssertTrue(floatingPageTitle("作品详情").waitForExistence(timeout: 5))
        let matches = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "details.tag."))
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 5))
        let chips = Array(matches.allElementsBoundByIndex.filter(\.isHittable).prefix(6))
        guard chips.count == 6 else { XCTFail("Expected six visible fixture tags"); return }
        let before = chips.map(\.frame)
        chips[0].tap()
        waitUntil("The color-only tag must retain its selected accessibility state") {
            chips[0].valueDescription.contains("已选入组合搜索")
        }
        for (chip, frame) in zip(chips, before) {
            XCTAssertEqual(chip.frame.width, frame.width, accuracy: 0.5)
            XCTAssertEqual(chip.frame.height, frame.height, accuracy: 0.5)
            XCTAssertEqual(chip.frame.minX, frame.minX, accuracy: 0.5)
            XCTAssertEqual(chip.frame.minY, frame.minY, accuracy: 0.5)
        }
        attachScreenshot(named: "tags67-highlight-without-layout-shift")
        chips[0].tap()
        waitUntil("Deselecting retains the original label geometry") { chips[0].valueDescription == "未选择" }
        XCTAssertEqual(chips[0].frame, before[0])
    }

    func testWorkDetailsImageAndVideoPreviews() {
        visualLaunch(width: 0, large: false, landscape: false, extra: ["--qa-details-tags", "--qa-details-preview"])
        for (kind, workID, name) in [("图片", 28_037_100, "image"), ("视频", 28_037_102, "video")] {
            if kind == "视频" { app.otherElements["timeline.media-kind"].buttons[kind].tap() }
            let playerFollow = app.buttons["media.follow.\(workID)"]
            XCTAssertTrue(playerFollow.waitForExistence(timeout: 8))
            let followSize = playerFollow.frame.size
            let followState = playerFollow.label
            let details = app.buttons["media.details.\(workID)"]
            XCTAssertTrue(details.waitForExistence(timeout: 8))
            details.tap()
            let publication = app.staticTexts["details.publication"]
            XCTAssertTrue(publication.waitForExistence(timeout: 5))
            let preview = app.descendants(matching: .any)["details.preview"].firstMatch
            XCTAssertEqual(preview.frame.width, 60, accuracy: 1)
            XCTAssertEqual(preview.frame.height, 80, accuracy: 1)
            let title = app.staticTexts["details.summary"]
            XCTAssertTrue(title.label.contains(kind == "图片" ? "城市风景" : "街景短片"))
            XCTAssertTrue(app.staticTexts["details.metadata"].exists)
            let detailFollow = app.buttons["follow-28037901"]
            XCTAssertTrue(detailFollow.waitForExistence(timeout: 5))
            XCTAssertEqual(detailFollow.label, followState)
            XCTAssertEqual(detailFollow.frame.width, followSize.width, accuracy: 1)
            XCTAssertEqual(detailFollow.frame.height, followSize.height, accuracy: 1)
            XCTAssertTrue(app.buttons["details.tag.warm window light"].waitForExistence(timeout: 5))
            attachScreenshot(named: "work-details-\(name)-preview")
            print("DETAIL_PREVIEW_\(name.uppercased())_AT=\(Date().timeIntervalSince1970)")
            RunLoop.main.run(until: Date().addingTimeInterval(2))
            if kind == "图片" {
                app.buttons["details.back"].tap()
                XCTAssertTrue(publication.waitForNonExistence(timeout: 5))
            } else {
                app.buttons["details.author"].tap()
                XCTAssertTrue(app.otherElements["creator.top-bar"].waitForExistence(timeout: 5))
                let authorFollow = app.buttons["follow-28037901"]
                XCTAssertTrue(authorFollow.isHittable)
                XCTAssertEqual(authorFollow.label, followState)
                XCTAssertEqual(authorFollow.frame.width, followSize.width, accuracy: 1)
                XCTAssertEqual(authorFollow.frame.height, followSize.height, accuracy: 1)
                attachScreenshot(named: "author-profile-shared-follow")
                authorFollow.tap()
                waitUntil("Following in the author profile updates the shared relation") {
                    authorFollow.label == (followState == "关注" ? "已关注" : "关注")
                }
                XCTAssertEqual(authorFollow.frame.width, followSize.width, accuracy: 1)
                XCTAssertEqual(authorFollow.frame.height, followSize.height, accuracy: 1)
            }
        }
    }

    func testDetailsTagsShowAllAndSupportSelectionAndSearch() {
        visualLaunch(width: 0, large: false, landscape: false, extra: ["--qa-details-tags"])
        app.otherElements["timeline.media-kind"].buttons["视频"].tap()
        let details = app.buttons.matching(NSPredicate(format: "label == %@", "作品详情")).firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 8)); details.tap()
        let header = floatingPageTitle("作品详情")
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        XCTAssertEqual(header.staticTexts["作品详情"].frame.midX, header.frame.midX, accuracy: 1)
        let summary = app.staticTexts.matching(identifier: "details.summary").firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 5), "Use the source Text accessibility identifier for the compact summary")
        XCTAssertEqual(summary.label, "视频作品")
        let metadata = app.staticTexts["details.metadata"]
        XCTAssertTrue(metadata.exists)
        XCTAssertTrue(metadata.label.contains("01:59"))
        let publication = app.staticTexts["details.publication"]
        XCTAssertTrue(publication.exists)
        XCTAssertTrue(publication.label.contains("28037102") && publication.label.contains("28037500") && publication.label.contains("2026"))
        let tabs = app.descendants(matching: .any)["details.tabs"]
        let authors = tabs.buttons["main.tab.2"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        XCTAssertTrue(tabs.buttons["main.tab.timeline"].isSelected)
        XCTAssertTrue(authors.isHittable)
        let more = app.buttons["details.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5)); XCTAssertTrue(more.label.contains("更多作者操作"))

        let search = app.buttons["details.search"]
        XCTAssertFalse(search.exists, "No disabled footer occupies space before any tag is selected")
        XCTAssertTrue(app.descendants(matching: .any)["details.preview"].exists, "Details should include a static work preview")
        XCTAssertFalse(app.buttons["清空"].exists, "Clear appears only once selection exists")
        let count = app.descendants(matching: .any).matching(identifier: "details.tags").firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertTrue(count.valueDescription.contains("0 / 8"))
        XCTAssertFalse(app.buttons["details.tags.expand"].exists)
        XCTAssertFalse(app.buttons["details.refresh"].exists)
        attachScreenshot(named: "details-tags-all-visible")

        let expectedTags = ["portrait", "night", "city", "street fashion", "soft lighting", "cinematic",
                            "rain", "architecture", "neon signs", "reflection", "evening", "long coat",
                            "urban landscape", "depth of field", "warm window light", "35mm photo", "blue hour", "city walk"]
        let detailsScroll = app.scrollViews.firstMatch
        for tag in expectedTags {
            XCTAssertTrue(app.buttons["details.tag.\(tag)"].exists, "Missing fixture tag: \(tag)")
        }

        let farTagName = "warm window light"
        let farTag = app.buttons["details.tag.\(farTagName)"]
        XCTAssertTrue(layout41ScrollToHittable(farTag, in: detailsScroll, towardBottom: true),
                      "The last tag is reachable by scrolling alone")
        print("DETAILS41_TAG id=\(farTag.identifier);label=\(farTag.label);value=\(farTag.valueDescription);frame=\(farTag.frame)")
        farTag.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        print("DETAILS41_SELECTION count=\(count.valueDescription);tag=\(farTag.valueDescription)")
        waitUntil("The first visible chip must update both its selection and the count label") {
            count.valueDescription.contains("1 / 8") && farTag.valueDescription.contains("已选入组合搜索")
        }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(search.frame.height, 44)
        XCTAssertLessThanOrEqual(search.frame.maxY, authors.frame.minY + 1)
        XCTAssertLessThanOrEqual(search.frame.height, 56, "Search affordance should remain compact")
        XCTAssertLessThanOrEqual(search.label.count, 15, "The compact footer should use short copy")

        let secondTag = app.buttons["details.tag.\(expectedTags[0])"]
        XCTAssertTrue(layout41ScrollToHittable(secondTag, in: detailsScroll, towardBottom: false),
                      "Another tag must remain reachable after selection")
        secondTag.tap()
        waitUntil("Both visible tag selections must update the count label") { count.valueDescription.contains("2 / 8") }
        XCTAssertTrue(app.buttons["清空"].exists)
        attachScreenshot(named: "layout41-details-two-tags-selected")
        search.tap()
        XCTAssertTrue(app.descendants(matching: .any)["search.top-bar"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["search-tag-picker"].waitForValueToContain("已选择 2 个标签", timeout: 5),
                      "Both selected real tags should navigate as initial AND criteria")
        XCTAssertTrue(app.buttons["search-submit"].exists)
        attachScreenshot(named: "layout41-details-combined-search")
        authors.tap()
        XCTAssertTrue(app.otherElements["leaderboard.top-bar"].waitForExistence(timeout: 5))
        XCTAssertFalse(tabs.isHittable)
        XCTAssertTrue(mainTabButton("作者榜").isSelected)
    }

    func testDetails175FailedRefreshKeepsKnownTags() {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["--qa-details-tags", "--qa-details-tags-failure", "-muted", "YES"])
        visualButton("media.details.28037100").tap()
        XCTAssertTrue(app.buttons["details.tag.portrait"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["details.publication"].exists)
        XCTAssertFalse(app.buttons["details.refresh"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "标签读取失败")).firstMatch.exists)
    }

    func testDetailsTagRefreshFailureLeavesWorkCardWithoutTagControls() {
        visualLaunch(width: 0, large: false, landscape: false, extra: ["--qa-details-tags", "--qa-details-tags-failure", "--qa-details-input-tags-unknown175"])
        app.buttons["media.details.28037100"].tap()
        XCTAssertTrue(app.staticTexts["details.publication"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["details.tags"].exists)
        XCTAssertFalse(app.buttons["details.tag.portrait"].exists)
        XCTAssertFalse(app.buttons["details.refresh"].exists)
        XCTAssertFalse(app.buttons["details.tags.expand"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "标签读取失败")).firstMatch.exists)
    }

    func testAuthorAndSearchUseTheSharedPlaybackControls() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "-muted", "YES", "-autoplay", "NO"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()

        for (route, title, selectedID, targetID, destination) in [
            ("author-video", "作者作品", "main.tab.2", "main.tab.4", "search.top-bar"),
            ("search", "作品", "main.tab.4", "main.tab.3", "collections.top-bar")
        ] {
            heightOpen(route, expected: 28_037_102)
            let header = floatingPageTitle(title)
            XCTAssertTrue(header.waitForExistence(timeout: 5))
            let share = header.buttons["playback.share"]
            XCTAssertTrue(share.isHittable)
            XCTAssertEqual(share.frame.size, header.buttons["playback.close"].frame.size)
            let tabs = app.descendants(matching: .any)["playback.tabs"]
            XCTAssertTrue(tabs.waitForExistence(timeout: 5))
            XCTAssertTrue(tabs.buttons[selectedID].isSelected)
            XCTAssertTrue(app.buttons["手动切换横竖屏"].isHittable)
            attachScreenshot(named: "shared-player-" + route)
            tabs.buttons[targetID].tap()
            XCTAssertTrue(app.otherElements[destination].waitForExistence(timeout: 8))
            XCTAssertFalse(tabs.isHittable)
        }
    }

    func testNestedAuthorSelectionUsesOneBottomBarAndCanExitFromDetails() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "-muted", "YES", "-autoplay", "NO"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(mainTabButton("收藏").waitForExistence(timeout: 8))
        heightOpen("collections", expected: 28_037_102)
        let author = visualButton("media.author.28037102")
        XCTAssertTrue(author.waitForExistence(timeout: 5)); author.tap()
        let authorBar = app.otherElements["creator.top-bar"]
        XCTAssertTrue(authorBar.waitForExistence(timeout: 5))
        let tabs = app.descendants(matching: .any)["playback.tabs"]
        XCTAssertTrue(tabs.buttons["main.tab.3"].isSelected)
        let before = tabs.frame
        let cover = visualButton("media.grid.cell.28037102")
        XCTAssertTrue(cover.waitForExistence(timeout: 5))
        authorBar.buttons["creator.actions"].tap()
        let select = app.buttons["favorite-batch.select"]
        XCTAssertTrue(select.waitForExistence(timeout: 5)); select.tap()
        let cancel = tabs.buttons["favorite-batch.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertTrue(cancel.isHittable)
        XCTAssertFalse(tabs.buttons["main.tab.4"].isHittable)
        XCTAssertEqual(tabs.frame, before)
        attachScreenshot(named: "nested-author-shared-batch-bar")
        cancel.tap()
        XCTAssertTrue(tabs.buttons["main.tab.4"].isHittable)

        cover.tap()
        XCTAssertTrue(floatingPageTitle("作者作品").waitForExistence(timeout: 5))
        visualOpenDetails(itemID: 28_037_102)
        app.descendants(matching: .any)["details.tabs"].buttons["main.tab.4"].tap()
        XCTAssertTrue(app.textFields["search-title-input"].waitForExistence(timeout: 8))
        XCTAssertFalse(tabs.isHittable)
    }

    func testOfflineTagBlockKeepsExitAndClearsShare() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "--qa-details-tags", "--qa-header-motion", "-muted", "YES", "-autoplay", "NO"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        // Recover only this synthetic test tag after an interrupted prior run.
        openAccountSettings()
        tapAboveMainBar(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "屏蔽标签")).firstMatch)
        let previousBlock = app.buttons["删除屏蔽标签 portrait"]
        if previousBlock.exists {
            waitUntil("The blocked-tag row becomes interactive after navigation") { previousBlock.isHittable }
            previousBlock.tap()
            XCTAssertTrue(previousBlock.waitForNonExistence(timeout: 5))
        }
        let blockedBack = floatingPageTitle("屏蔽标签").buttons["navigation.back"]
        waitUntil("The blocked-tag return button is live") { blockedBack.isHittable }
        blockedBack.tap()
        let settingsHeader = floatingPageTitle("账号与设置")
        waitUntil("The actual Settings header and transition ownership have settled") {
            settingsHeader.isHittable &&
                (!self.app.staticTexts["page.interaction-lock"].exists || self.app.staticTexts["page.interaction-lock"].valueDescription.contains("locks=0"))
        }
        let backs = app.descendants(matching: .any).matching(identifier: "navigation.back")
        // XCTest reports this floating button as non-hittable after a pop.
        // Tap its validated on-screen hit rectangle, then verify the actual route.
        let settingsBack = backs.allElementsBoundByIndex.first { $0.isEnabled && $0.frame.minY >= 0 && $0.frame.midY < 120 }!
        XCTAssertEqual(settingsBack.frame.width, 44, accuracy: 1)
        XCTAssertEqual(settingsBack.frame.height, 44, accuracy: 1)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: settingsBack.frame.midX, dy: settingsBack.frame.midY)).tap()
        waitUntil("The physical back button returns to the actual timeline") { self.app.buttons["timeline.account"].isHittable }
        heightOpen("offline", expected: 28_037_102)
        let playback = floatingPageTitle("作品")
        let share = playback.buttons["playback.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        visualOpenDetails(itemID: 28_037_102)
        let tag = app.buttons["details.tag.portrait"]
        XCTAssertTrue(tag.waitForExistence(timeout: 5))
        tag.press(forDuration: 0.8)
        app.buttons["屏蔽此标签"].tap()
        app.buttons["details.back"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["media.empty.state"].waitForExistence(timeout: 5))
        XCTAssertFalse(share.isHittable)
        let close = playback.buttons["playback.close"]
        XCTAssertTrue(close.isHittable); close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))

        openAccountSettings()
        tapAboveMainBar(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "屏蔽标签")).firstMatch)
        let remove = app.buttons["删除屏蔽标签 portrait"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
    }

    func testHistoryUnavailableCardClearsHeaderInBothOrientations() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "--qa-details-tags", "-muted", "YES", "-autoplay", "NO", "-civitviewer.automaticRotation", "YES"]
        app.launch()
        // A previous interrupted run may have persisted this synthetic tag.
        openAccountSettings()
        tapAboveMainBar(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "屏蔽标签")).firstMatch)
        let previousBlock = app.buttons["删除屏蔽标签 portrait"]
        if previousBlock.exists { previousBlock.tap() }
        floatingPageTitle("屏蔽标签").buttons["navigation.back"].tap()
        heightOpen("history", expected: 28_037_102)
        visualOpenDetails(itemID: 28_037_102)
        let tag = app.buttons["details.tag.portrait"]
        XCTAssertTrue(tag.waitForExistence(timeout: 5))
        tag.press(forDuration: 0.8)
        app.buttons["屏蔽此标签"].tap()
        if app.buttons["details.back"].isHittable { app.buttons["details.back"].tap() }
        let card = app.descendants(matching: .any)["history.playback.unavailable"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let landscape = orientation == .landscapeLeft
            let direction = NSPredicate { _, _ in
                let frame = self.app.windows.firstMatch.frame
                return (frame.width > frame.height) == landscape
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: direction, object: nil)], timeout: 5), .completed)
            let headers = app.otherElements.matching(identifier: "page-title.最近浏览").allElementsBoundByIndex
            guard let header = headers.first(where: { $0.isHittable && $0.buttons["playback.close"].exists }) else {
                XCTFail("Missing active history playback header"); return
            }
            XCTAssertGreaterThanOrEqual(card.frame.minY, header.frame.maxY - 1)
            XCTAssertTrue(app.buttons["history.playback.retry"].isHittable)
            XCTAssertTrue(app.buttons["playback.close"].isHittable)
            attachScreenshot(named: "history-unavailable-\(orientation.rawValue)")
        }
        app.buttons["playback.close"].tap()
        app.buttons["navigation.back"].tap()
        tapAboveMainBar(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "屏蔽标签")).firstMatch)
        let remove = app.buttons["删除屏蔽标签 portrait"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5)); remove.tap()
        app.terminate()
    }

    func testOfflineAndHistoryUseSharedPlaybackAndDetailTabs() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "-muted", "YES", "-autoplay", "NO"]
        for (route, title) in [("offline", "作品"), ("history", "最近浏览")] {
            XCUIDevice.shared.orientation = .portrait
            app.launch()
            heightOpen(route, expected: 28_037_102)
            let tabs = app.descendants(matching: .any)["playback.tabs"]
            XCTAssertTrue(tabs.waitForExistence(timeout: 8), route)
            XCTAssertTrue(tabs.buttons[route == "offline" ? "main.tab.3" : "main.tab.timeline"].isSelected)
            let share = floatingPageTitle(title).buttons["playback.share"]
            XCTAssertTrue(share.waitForExistence(timeout: 5), route)
            XCTAssertTrue(share.isHittable)
            visualOpenDetails(itemID: 28_037_102)
            let detailTabs = app.descendants(matching: .any)["details.tabs"]
            XCTAssertTrue(detailTabs.waitForExistence(timeout: 5), route)
            detailTabs.buttons["main.tab.4"].tap()
            XCTAssertTrue(app.textFields["search-title-input"].waitForExistence(timeout: 8), route)
            XCTAssertFalse(tabs.isHittable)
            app.terminate()
        }
    }

    func testDetailsTabsDismissCollectionPlaybackAndSelectSearch() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "-app.appearance", "dark", "-muted", "YES", "-civitviewer.automaticRotation", "NO"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let collections = mainTabButton("收藏")
        XCTAssertTrue(collections.waitForExistence(timeout: 8))
        if !collections.isSelected { collections.tap() }
        let video = app.otherElements["collection.media-kind"].buttons["视频"]
        XCTAssertTrue(video.waitForExistence(timeout: 5))
        video.tap()
        let cover = app.buttons["media.grid.cell.28037102"]
        XCTAssertTrue(cover.waitForExistence(timeout: 5)); cover.tap()
        let playbackHeader = floatingPageTitle("作品")
        XCTAssertTrue(playbackHeader.waitForExistence(timeout: 5))
        XCTAssertTrue(playbackHeader.buttons["playback.share"].isHittable)
        app.buttons["手动切换横竖屏"].tap()
        heightWaitOrientation(landscape: true)
        visualOpenDetails(itemID: 28_037_102)

        let tabs = app.descendants(matching: .any)["details.tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        XCTAssertTrue(tabs.buttons["main.tab.3"].isSelected)
        XCTAssertTrue(tabs.buttons["main.tab.4"].isHittable)
        attachScreenshot(named: "details-collection-landscape-tabs")
        tabs.buttons["main.tab.4"].tap()
        XCTAssertTrue(app.textFields["search-title-input"].waitForExistence(timeout: 8))
        XCTAssertTrue(mainTabButton("搜索").isSelected)
        waitUntil("Leaving landscape playback restores the root page to portrait") {
            let frame = self.app.windows.firstMatch.frame
            return frame.height > frame.width
        }
        XCTAssertFalse(playbackHeader.isHittable)
        XCTAssertFalse(tabs.isHittable)
        mainTabButton("收藏").tap()
        XCTAssertTrue(cover.waitForExistence(timeout: 5))
        XCTAssertTrue(video.isSelected)
    }

    func testCentralHoldGesturePrioritiesAndFullscreenExit() {
        visualLaunch(width: 0, large: false, landscape: false)
        app.otherElements["timeline.media-kind"].buttons["视频"].tap(); waitPlayingFixture()
        let before = playerFields(), initialToggles = metric("toggles", in: chromeState().valueDescription)
        let deck = heightDeck().frame
        let center = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: deck.midX, dy: deck.midY))
        center.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: deck.midX + 50, dy: deck.midY)))
        waitUntil("A short moved press must seek and cancel the central hold") { Int(self.playerFields()["seekStarts"] ?? "-1")! > Int(before["seekStarts"] ?? "-1")! }
        XCTAssertEqual(metric("toggles", in: chromeState().valueDescription), initialToggles)
        center.tap(); waitUntil("Normal center tap pauses") { self.playerFields()["rate"] == "0.0" }
        let paused = playerFields(); RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertEqual(Double(playerFields()["position"]!)!, Double(paused["position"]!)!, accuracy: 0.3)
        center.tap(); waitPlayingFixture()
        let beforeEdge = playerFields()
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: deck.minX + 15, dy: deck.midY)).press(forDuration: 0.7)
        waitUntil("The edge hold must reach the original 2x callback") { Int(self.playerFields()["rateHolds"] ?? "-1")! == Int(beforeEdge["rateHolds"] ?? "-1")! + 1 }
        XCTAssertEqual(metric("toggles", in: chromeState().valueDescription), initialToggles)
        XCTAssertEqual(playerFields()["taps"], beforeEdge["taps"]); XCTAssertEqual(playerFields()["rate"], "1.0")
        let seek = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "播放进度")).firstMatch
        seek.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitUntil("The real progress control must still seek near 15 seconds") { abs((Double(self.playerFields()["position"] ?? "0") ?? 0) - 15) < 2 }
        center.doubleTap(); XCTAssertTrue(app.descendants(matching: .any)["creator.top-bar"].waitForExistence(timeout: 8))
        XCTAssertTrue(mainTabBar().isHittable, "Author navigation must restore ordinary navigation")
        mainTabButton("收藏").tap()
        let card = app.buttons["media.grid.cell.28037100"]; XCTAssertTrue(card.waitForExistence(timeout: 8)); card.tap()
        let close = app.buttons["关闭作品"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        let closeFrame = close.frame, fullscreenFocus = watchFocus()
        let fullscreenBefore = captureChromePixels(named: "chrome40-fullscreen-before-hold")
        centralPress(); XCTAssertTrue(chromeState().waitForValueToContain("hidden=true", timeout: 5))
        let fullscreenHidden = captureChromePixels(named: "chrome40-fullscreen-hidden")
        assertChromeNotHittable([close], phase: "fullscreen-hidden")
        assertChromePixelsDisappear(before: fullscreenBefore, hidden: fullscreenHidden,
                                   regions: ["fullscreen-close": closeFrame.insetBy(dx: 8, dy: 8)])
        tapScreenFrame(closeFrame)
        XCTAssertTrue(chromeState().valueDescription.contains("hidden=true"))
        XCTAssertEqual(watchFocus(), fullscreenFocus, "A tap at the hidden close button must keep the viewer open")
        centralPress(); XCTAssertTrue(chromeState().waitForValueToContain("hidden=false", timeout: 5))
        XCTAssertTrue(close.isHittable)
        close.tap(); XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(mainTabBar().isHittable)
        attachScreenshot(named: "chrome40-fullscreen-exit-navigation-restored")
    }

    func testAutomaticAppearanceFillMaintainsSixUpcomingAcrossSparsePages() {
        launchContinuation("sparse-reserve")
        XCTAssertTrue(app.staticTexts["continuation.qa.state"].waitForExistence(timeout: 5))
        waitUntil("Visible first video should immediately request its first fill page") {
            self.continuationFields()["requests"] == "2" && self.continuationFields()["gate"] == "waiting"
        }
        XCTAssertEqual(watchFocus(), 28_037_102, "Appearance fill must not move focus from the first video")
        XCTAssertEqual(continuationFields()["first"], "1")
        XCTAssertEqual(continuationFields()["lastCursor"], "scan-0")
        waitPlayingFixture()
        let beforePlayer = playerFields()
        XCTAssertFalse(app.descendants(matching: .any)["media.waiting"].firstMatch.exists,
                       "Preparing future items cannot mark the playing current video as waiting")
        XCTAssertFalse(app.descendants(matching: .any)["media.preparation"].firstMatch.exists)
        let continuationIndicators = app.descendants(matching: .any)
            .matching(identifier: "feed.continuation.loading").allElementsBoundByIndex
        if !continuationIndicators.isEmpty {
            print("SPARSE_RESERVE_INDICATORS \(continuationIndicators.map { ($0.isHittable, $0.frame) })")
            attachScreenshot(named: "sparse-reserve-visible-playback-during-background-fill")
        }
        XCTAssertFalse(continuationIndicators.contains(where: \.isHittable),
                       "Background continuation must not present a loading indicator over the active player")

        releaseContinuationResponse()
        waitUntil("Appearance fill should cross sparse pages until six distinct upcoming works are available", timeout: 25) {
            self.continuationFields()["requests"] == "19" &&
                self.continuationFields()["returned"] == "28037306" &&
                self.continuationFields()["gate"] == "released"
        }
        XCTAssertEqual(watchFocus(), 28_037_102, "The focused initial video must stay selected during fill")
        XCTAssertEqual(continuationFields()["requests"], "19", "The reserve should stop after the exact eighteenth continuation")
        XCTAssertEqual(continuationFields()["returned"], "28037306")
        XCTAssertEqual(continuationFields()["lastCursor"], "scan-17", "The fixture observer exposes the nonempty final request cursor")
        assertUnchangedPlayer(beforePlayer, playerFields())
        guard let start = beforePlayer["position"].flatMap(Double.init),
              let finish = playerFields()["position"].flatMap(Double.init) else {
            XCTFail("Missing actual player progress around automatic fill")
            return
        }
        XCTAssertGreaterThan(finish, start, "Automatic fill must preserve active playback progress")
        assertNoFixtureRead(for: 1)
        attachScreenshot(named: "continuation41-appearance-fill-six-upcoming-sparse-pages")
    }

    func testNative66WaitingTailShowsStateAndAutomaticallyOpensNext() {
        auditWaitingTail65(compactLarge: false)
    }

    func testNative66BoundarySpinnerStaysSmallInCompactLargeLandscape() {
        auditWaitingTail65(compactLarge: true)
    }

    func testNative67WaitingForwardDragIsBoundedAndDoesNotRestartLoading() {
        launchContinuation("sparse-long64", extra: ["--qa-native-layout64", "--qa-pager-touch-trace", "-muted", "YES"])
        waitPlayingFixture()
        waitUntil("Sparse continuation remains gated") { self.continuationFields()["gate"] == "waiting" }
        heightDeck().swipeUp(); heightDeck().swipeUp(); heightDeck().swipeUp()
        XCTAssertTrue(app.descendants(matching: .any)["media.boundary.state"].waitForExistence(timeout: 5))
        let requests = continuationFields()["requests"]
        let probe = app.staticTexts["pager.qa.trace"], frame = heightDeck().frame
        guard let initial = try? JSONSerialization.jsonObject(with: Data(probe.valueDescription.utf8)) as? [String: Any],
              let marker = initial["lastSequence"] as? Int else { XCTFail("Missing waiting trace"); return }
        let bottom = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.minY + frame.height * 0.8))
        let top = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.minY + frame.height * 0.2))
        bottom.press(forDuration: 0.05, thenDragTo: top, withVelocity: XCUIGestureVelocity(rawValue: 220), thenHoldForDuration: 0.3)
        guard let trace = try? JSONSerialization.jsonObject(with: Data(probe.valueDescription.utf8)) as? [String: Any],
              let events = trace["events"] as? [[String: Any]] else { XCTFail("Missing resisted forward samples"); return }
        let held = events.filter { ($0["sequence"] as? Int ?? 0) > marker && ($0["native"] as? [String: Any])?["boundaryGateActive"] as? Bool == true }
        let distances = held.compactMap { ($0["native"] as? [String: Any])?["boundaryVisualOffset"] as? Double }.map { max(0, -$0) }
        XCTAssertGreaterThan(distances.max() ?? 0, 8, "The waiting canvas must give visible resistance feedback")
        XCTAssertLessThanOrEqual(distances.max() ?? .infinity, 50, "A full finger drag must not create another empty page")
        XCTAssertEqual(watchFocus(), 64_000_102)
        XCTAssertEqual(continuationFields()["requests"], requests, "Resistance is not another load or refresh request")
        XCTAssertTrue(app.descendants(matching: .any)["media.boundary.state"].exists)
        XCTAssertEqual(heightDeck().frame, frame, "The native input viewport remains fixed")
        attachScreenshot(named: "boundary67-forward-resistance-retains-loading-destination")
        heightDeck().swipeDown()
        XCTAssertTrue(app.descendants(matching: .any)["media.boundary.state"].waitForNonExistence(timeout: 5))
        waitPlayingFixture()
    }

    func testNative67WaitingTailKeepsTimelineEdgeSwitchInteractive() {
        launchContinuation("sparse-long64", extra: ["--qa-native-layout64", "--qa-pager-touch-trace", "-muted", "YES"])
        waitPlayingFixture()
        waitUntil("The real timeline continuation is held") { self.continuationFields()["gate"] == "waiting" }
        heightDeck().swipeUp(); heightDeck().swipeUp(); heightDeck().swipeUp()
        let waiting = app.descendants(matching: .any)["media.boundary.state"]
        XCTAssertTrue(waiting.waitForExistence(timeout: 5))
        XCTAssertEqual(watchFocus(), 64_000_102)
        let details = app.buttons["media.details.64000102"]
        XCTAssertFalse(details.exists && details.isHittable, "The outgoing work's details cannot be invoked from the waiting canvas")

        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.34))
        let requestCount = continuationFields()["requests"]
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 30, dy: 0)),
                    withVelocity: XCUIGestureVelocity(rawValue: 90), thenHoldForDuration: 0.15)
        let motion = app.descendants(matching: .any)["timeline.page-motion.qa"]
        waitUntil("The waiting viewport renders a cancelled edge gesture", timeout: 5) {
            motion.valueDescription.contains("phase=cancelled")
        }
        XCTAssertGreaterThan(heightValues(motion.valueDescription)["peak"] ?? 0, 8, "The waiting page must move before cancellation")
        XCTAssertTrue(waiting.exists, "Cancelling the edge drag preserves the waiting destination")
        XCTAssertEqual(continuationFields()["requests"], requestCount)

        start.press(forDuration: 0.05,
                    thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.68, dy: 0.34)),
                    withVelocity: XCUIGestureVelocity(rawValue: 210), thenHoldForDuration: 0.1)
        let following = app.otherElements["timeline.source"].buttons["关注"]
        waitUntil("A held response must not prevent switching to the following timeline", timeout: 8) {
            following.isSelected && !waiting.exists
        }
        XCTAssertEqual(continuationFields()["gate"], "waiting", "The original response is still deliberately unreleased")
    }

    func testNative67ReverseDragRevealsPreviousWithoutSkippingWork() {
        launchContinuation("sparse-long64", extra: ["--qa-native-layout64", "--qa-pager-touch-trace", "-muted", "YES"])
        waitPlayingFixture()
        waitUntil("Sparse continuation remains gated") { self.continuationFields()["gate"] == "waiting" }
        heightDeck().swipeUp(); heightAssert("recommendation", phase: "cancel66-second", expected: 64_000_101)
        heightDeck().swipeUp(); heightAssert("recommendation", phase: "cancel66-tail", expected: 64_000_102)
        let before = playerFields()
        heightDeck().swipeUp()
        XCTAssertTrue(app.descendants(matching: .any)["media.boundary.state"].waitForExistence(timeout: 5))
        let viewport = heightDeck().frame
        let probe = app.staticTexts["pager.qa.trace"]
        guard let initial = try? JSONSerialization.jsonObject(with: Data(probe.valueDescription.utf8)) as? [String: Any],
              let marker = initial["lastSequence"] as? Int else { XCTFail("Missing waiting gesture trace"); return }
        let upper = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: viewport.midX, dy: viewport.minY + viewport.height * 0.22))
        let lower = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: viewport.midX, dy: viewport.minY + viewport.height * 0.75))
        upper.press(forDuration: 0.05, thenDragTo: lower, withVelocity: XCUIGestureVelocity(rawValue: 220), thenHoldForDuration: 0.3)
        guard let trace = try? JSONSerialization.jsonObject(with: Data(probe.valueDescription.utf8)) as? [String: Any],
              let events = trace["events"] as? [[String: Any]] else { XCTFail("Missing reverse drag samples"); return }
        let held = events.filter { ($0["sequence"] as? Int ?? 0) > marker && ($0["native"] as? [String: Any])?["boundaryGateActive"] as? Bool == true }
        let offsets = held.compactMap { ($0["native"] as? [String: Any])?["boundaryVisualOffset"] as? Double }
        XCTAssertGreaterThan(offsets.max() ?? 0, 60, "The previous canvas must follow a real held reverse drag")
        let pageFrames = held.compactMap { ($0["native"] as? [String: Any])?["renderedPageWindowFrame"] as? [String: Double] }
        XCTAssertGreaterThan((pageFrames.compactMap { $0["y"] }.max() ?? 0) - (pageFrames.compactMap { $0["y"] }.min() ?? 0), 40,
                             "Real rendered page geometry must move; a callback number alone is insufficient")
        XCTAssertTrue(app.descendants(matching: .any)["media.boundary.state"].waitForNonExistence(timeout: 5))
        heightAssert("recommendation", phase: "cancel66-return-to-origin", expected: 64_000_102)
        waitPlayingFixture(); assertUnchangedPlayer(before, playerFields())
        releaseContinuationResponse()
        waitUntil("The canceled request's result can still fill the ordinary background queue", timeout: 12) {
            (Int(self.continuationFields()["requests"] ?? "0") ?? 0) >= 5
        }
        XCTAssertEqual(watchFocus(), 64_000_102, "Canceled forward intent must not be resurrected by a late response")
        assertUnchangedPlayer(before, playerFields())
        attachScreenshot(named: "boundary66-canceled-wait-late-response-no-jump")
    }

    func testNative66FailedDestinationStaysUntilExplicitRetryThenOpensNext() {
        launchContinuation("rate-limited", extra: ["-muted", "YES"])
        waitForAppearanceContinuation()
        heightDeck().swipeUp()
        XCTAssertTrue(app.descendants(matching: .any)["media.boundary.state"].waitForExistence(timeout: 5))
        releaseContinuationResponse()
        let retry = app.buttons["feed.continuation.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 8))
        XCTAssertFalse(retry.isEnabled)
        XCTAssertTrue(app.descendants(matching: .any)["media.boundary.state"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["feed.continuation.error"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["media.boundary.waiting"].exists)
        XCTAssertFalse(app.buttons["media.author.28037102"].exists, "A failed destination must not fall back to the previous work")
        XCTAssertEqual(continuationFields()["requests"], "2")
        assertNoFixtureRead(for: 0.8)
        waitUntil("Explicit retry is available after the actual cooldown") { retry.isEnabled }
        XCTAssertEqual(continuationFields()["requests"], "2")
        retry.tap()
        waitUntil("Retry completes the original forward request without a second swipe", timeout: 12) { self.watchFocus() == 28_037_104 }
        XCTAssertTrue(app.descendants(matching: .any)["media.boundary.state"].waitForNonExistence(timeout: 4))
        heightAssert("recommendation", phase: "failed66-retry-opens-requested-work", expected: 28_037_104)
        waitPlayingFixture()
        XCTAssertTrue(app.buttons["取消静音"].exists)
        attachScreenshot(named: "boundary66-retry-destination-without-backward-jump")
    }

    func testFailure66ActualMissingVideosAdvanceToPlayableFollowingWork() {
        launchFailures66(2)
        waitUntil("Actual missing-file player failures must reach the first playable following work", timeout: 20) {
            self.watchFocus() == 28_037_102 && self.playerFields()["ready"] == "true"
        }
        waitPlayingFixture()
        heightAssert("recommendation", phase: "failure66-two-missing-then-playable", expected: 28_037_102)
        XCTAssertFalse(app.descendants(matching: .any)["media.boundary.state"].exists)
        XCTAssertEqual(playerFields()["muted"], "true")
        attachScreenshot(named: "failure66-actual-avplayer-two-missing-then-playable")
    }

    func testFailure66ThreeFollowingAttemptsStopUntilManualNavigation() {
        launchFailures66(4)
        waitUntil("The current failure and three following attempts must stop on the fourth failed work", timeout: 20) {
            self.watchFocus() == 28_037_103 && self.app.buttons["重试"].exists
        }
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(watchFocus(), 28_037_103, "A known fifth playable work is outside the three-attempt recovery budget")
        XCTAssertFalse(app.descendants(matching: .any)["media.boundary.state"].exists)
        attachScreenshot(named: "failure66-budget-stops-on-fourth-current-failure")
        heightDeck().swipeUp()
        waitUntil("Manual navigation can still reach the known playable next work") { self.watchFocus() == 28_037_104 }
        waitPlayingFixture()
        XCTAssertEqual(playerFields()["muted"], "true")
    }

    private func launchFailures66(_ count: Int) {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-theme-timeline", "--qa-native-layout64", "--qa-failure-next66=\(count)", "-autoplay", "YES", "-muted", "YES"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(timelineTools().waitForExistence(timeout: 10))
        app.otherElements["timeline.media-kind"].buttons["视频"].tap()
    }

    func testNative66SecondHeldReverseKeepsWaitingUntilCancelDespiteArrival() {
        launchContinuation("sparse-long64", extra: ["--qa-native-layout64", "--qa-pager-touch-trace", "--qa-release-during-drag64", "-muted", "YES"])
        waitPlayingFixture()
        waitUntil("Initial sparse response remains gated") { self.continuationFields()["gate"] == "waiting" }
        heightDeck().swipeUp(); heightAssert("recommendation", phase: "held66-second", expected: 64_000_101)
        heightDeck().swipeUp(); heightAssert("recommendation", phase: "held66-tail", expected: 64_000_102)
        let before = playerFields()
        heightDeck().swipeUp()
        XCTAssertTrue(app.descendants(matching: .any)["media.boundary.state"].waitForExistence(timeout: 5))
        let viewport = heightDeck().frame
        let upper = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: viewport.midX, dy: viewport.minY + viewport.height * 0.2))
        let lower = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: viewport.midX, dy: viewport.minY + viewport.height * 0.8))
        app.buttons["continuation.qa.release"].tap()
        upper.press(forDuration: 0.05, thenDragTo: lower, withVelocity: XCUIGestureVelocity(rawValue: 110), thenHoldForDuration: 0.4)
        waitUntil("The response must really arrive during the second gesture", timeout: 12) { (Int(self.continuationFields()["requests"] ?? "0") ?? 0) >= 5 }
        let raw = app.staticTexts["pager.qa.trace"].valueDescription
        print("PAGER66_SECOND_HELD_TRACE \(raw)")
        guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let events = object["events"] as? [[String: Any]] else { XCTFail("Missing held-destination trace"); return }
        let overlapped = events.filter { event in
            let native = event["native"] as? [String: Any]
            return native?["boundaryGateActive"] as? Bool == true && native?["currentID"] as? Int == 64_000_102 &&
                (native?["pendingFocused"] as? Int == 64_000_103 || (event["incomingCount"] as? Int ?? 0) > 3)
        }
        XCTAssertFalse(overlapped.isEmpty, "Metadata must overlap an already-waiting second held gesture")
        XCTAssertTrue(overlapped.allSatisfy { ($0["native"] as? [String: Any])?["latestBoundaryWaiting"] as? Bool == true }, "Only actual native display can withdraw the loading destination")
        XCTAssertTrue(app.descendants(matching: .any)["media.boundary.state"].waitForNonExistence(timeout: 5))
        heightAssert("recommendation", phase: "held66-reverse-cancel-wins-over-arrival", expected: 64_000_102)
        waitPlayingFixture()
        assertUnchangedPlayer(before, playerFields())
        attachScreenshot(named: "boundary66-held-reverse-cancels-after-overlapping-arrival")
    }

    func testNative65DisabledGateShowsActualEmptySlotControl() {
        auditWaitingTail65(compactLarge: false, disabledControl: true)
    }

    private func auditWaitingTail65(compactLarge: Bool, disabledControl: Bool = false) {
        var extra = ["--qa-native-layout64", "--qa-pager-touch-trace", "-muted", "YES"]
        if disabledControl { extra += ["--qa-disable-boundary-gate65"] }
        if compactLarge { extra += ["--qa-visual-controls", "--qa-control-width=320", "--qa-control-large-type"] }
        launchContinuation("sparse-long64", extra: extra)
        waitPlayingFixture()
        waitUntil("The continuation must remain gated while native pages are browsable") { self.continuationFields()["gate"] == "waiting" }
        XCTAssertFalse(app.descendants(matching: .any)["media.boundary.waiting"].exists, "Background continuation stays silent")
        heightDeck().swipeUp(); heightAssert("recommendation", phase: "tail65-second", expected: 64_000_101)
        heightDeck().swipeUp(); heightAssert("recommendation", phase: "tail65-waiting", expected: 64_000_102)
        XCTAssertFalse(app.descendants(matching: .any)["media.boundary.waiting"].exists, "Landing on the last known video alone is still background preloading")
        if compactLarge {
            app.buttons["手动切换横竖屏"].tap(); heightWaitOrientation(landscape: true)
        }
        let viewport = heightDeck().frame
        let probe = app.staticTexts["pager.qa.trace"]
        guard let data = probe.valueDescription.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let current = object["current"] as? [String: Any],
              let offset = current["offset"] as? [String: Double], let baseY = offset["y"],
              let marker = object["lastSequence"] as? Int else { XCTFail("Missing settled native boundary geometry"); return }
        let lower = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: viewport.midX, dy: viewport.minY + viewport.height * (compactLarge ? 0.55 : 0.8)))
        let upper = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: viewport.midX, dy: viewport.minY + viewport.height * (compactLarge ? 0.15 : 0.2)))
        print("PAGER65_TAIL_DRAG_BEGIN baseY=\(baseY)")
        lower.press(forDuration: 0.05, thenDragTo: upper, withVelocity: XCUIGestureVelocity(rawValue: 160), thenHoldForDuration: 0.4)
        let raw = probe.valueDescription
        print("PAGER65_TAIL_TRACE \(raw)")
        guard let traceData = raw.data(using: .utf8),
              let trace = (try? JSONSerialization.jsonObject(with: traceData)) as? [String: Any],
              let events = trace["events"] as? [[String: Any]] else { XCTFail("Missing boundary gesture trace"); return }
        let gesture = events.filter { ($0["sequence"] as? Int ?? 0) > marker }
        let positions = gesture.compactMap { event -> Double? in
            guard let native = event["native"] as? [String: Any],
                  native["currentID"] as? Int == 64_000_102,
                  let value = native["displayedRelativeFrame"] as? [String: Double] else { return nil }
            return value["y"]
        }
        XCTAssertFalse(positions.isEmpty)
        let exposed = positions.map { max(0, -$0) }.max() ?? .infinity
        print("PAGER65_EXPOSED_EMPTY_HEIGHT=\(exposed)")
        if disabledControl {
            XCTAssertGreaterThan(exposed, 36, "With the gate disabled, this same binary must visibly move the real page away from the viewport")
            return
        }
        // Retain the observed first-candidate1pt failure. Allow at most2pt of
        // native residual motion, with whole settled geometry checked below.
        XCTAssertLessThanOrEqual(exposed, 2, "An unavailable next page must stay within2pt boundary motion, not expose a black page")
        XCTAssertEqual(watchFocus(), 64_000_102)
        XCTAssertTrue(heightDeck().isHittable, "The native hit-test viewport stays available behind the movable waiting canvas")
        XCTAssertTrue(app.descendants(matching: .any)["media.boundary.waiting"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["media.boundary.message"].exists)
        XCTAssertFalse(app.buttons["media.author.64000102"].exists, "The loading destination must not expose the previous work's actions")
        XCTAssertEqual(continuationFields()["gate"], "waiting")
        if compactLarge {
            XCTAssertGreaterThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height,
                                 "The landscape window can intentionally contain a narrower 320pt test viewport")
        }
        let spinner = app.descendants(matching: .any)["media.boundary.waiting"].firstMatch
        XCTAssertGreaterThan(spinner.frame.width, 0); XCTAssertGreaterThan(spinner.frame.height, 0)
        XCTAssertLessThanOrEqual(spinner.frame.width, 20.5); XCTAssertLessThanOrEqual(spinner.frame.height, 20.5)
        let loadingPage = app.descendants(matching: .any)["media.boundary.state"].firstMatch
        XCTAssertTrue(loadingPage.frame.contains(spinner.frame), "The wait indicator belongs to the loading destination, not a popup")
        attachScreenshot(named: compactLarge ? "tail65-compact-large-landscape-waiting" : "tail65-waiting-small-indicator")
        releaseContinuationResponse()
        waitUntil("A matching next work must arrive", timeout: 12) { (Int(self.continuationFields()["requests"] ?? "0") ?? 0) >= 5 }
        waitUntil("The original upward request must open the first matching new work without another swipe") { self.watchFocus() == 64_000_103 }
        heightAssert("recommendation", phase: "tail66-next-after-arrival", expected: 64_000_103)
        waitPlayingFixture()
        waitUntil("The automatically opened work must really advance in its native player") {
            self.playerFields()["timeStatus"] == "2" && (Double(self.playerFields()["nativePosition"] ?? "0") ?? 0) > 0.2
        }
        XCTAssertFalse(app.descendants(matching: .any)["media.boundary.state"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["media.boundary.waiting"].exists)
        heightDeck().swipeDown(); heightAssert("recommendation", phase: "tail65-return", expected: 64_000_102)
        XCTAssertTrue(app.buttons["取消静音"].exists)
    }

    func testNative66EndedTailStaysAtDestinationUntilUserReturns() {
        launchContinuation("filtered-empty", extra: ["--qa-native-layout64", "--qa-pager-touch-trace", "-muted", "YES"])
        waitForAppearanceContinuation(); releaseContinuationResponse()
        waitUntil("The real filtered route must reach its final page", timeout: 20) { self.continuationFields()["requests"] == "10" && self.continuationFields()["returned"] == "28037104" }
        heightDeck().swipeUp(); heightAssert("recommendation", phase: "tail65-ended-before-demand", expected: 28_037_104)
        func native() -> [String: Any] {
            let raw = app.staticTexts["pager.qa.trace"].valueDescription
            return ((try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any])?["current"] as? [String: Any] ?? [:]
        }
        guard let original = native()["bounces"] as? Bool else { XCTFail("Missing actual native bounce policy"); return }
        let viewport = heightDeck().frame
        let lower = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: viewport.midX, dy: viewport.minY + viewport.height * 0.8))
        let upper = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: viewport.midX, dy: viewport.minY + viewport.height * 0.2))
        lower.press(forDuration: 0.05, thenDragTo: upper, withVelocity: XCUIGestureVelocity(rawValue: 160), thenHoldForDuration: 0.4)
        waitUntil("The original policy must be restored while idle before any next touch") {
            let value = native()
            return value["bounces"] as? Bool == original && value["dragging"] as? Bool == false && value["decelerating"] as? Bool == false
        }
        XCTAssertFalse(app.descendants(matching: .any)["media.boundary.waiting"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["media.boundary.state"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["feed.continuation.ended"].exists)
        XCTAssertEqual(continuationFields()["requests"], "10")
        heightDeck().swipeDown(); heightAssert("recommendation", phase: "tail66-ended-user-return", expected: 28_037_104)
        XCTAssertFalse(app.descendants(matching: .any)["media.boundary.state"].exists)
        heightDeck().swipeDown(); heightAssert("recommendation", phase: "tail66-ended-normal-reverse", expected: 28_037_102)
    }

    func testNative64LongVideoSparseTailAppendKeepsWholePage() {
        launchContinuation("sparse-long64", extra: ["--qa-native-layout64", "-muted", "YES"])
        waitPlayingFixture()
        XCTAssertEqual(watchFocus(), 64_000_100)
        waitUntil("The next sparse page must wait while three real videos remain browsable") {
            self.continuationFields()["gate"] == "waiting"
        }
        heightAssert("recommendation", phase: "long64-initial", expected: 64_000_100)
        heightDeck().swipeUp(); heightAssert("recommendation", phase: "long64-before-tail", expected: 64_000_101)
        heightDeck().swipeUp(); heightAssert("recommendation", phase: "long64-tail-waiting", expected: 64_000_102)
        heightDeck().swipeUp(); heightAssert("recommendation", phase: "long64-tail-bounce", expected: 64_000_102)
        releaseContinuationResponse()
        waitUntil("A >120s match must arrive after rejecting short videos", timeout: 12) {
            (Int(self.continuationFields()["requests"] ?? "0") ?? 0) >= 5
        }
        for index in 3...11 {
            heightDeck().swipeUp()
            waitUntil("Real native paging must settle on long video \(index)", timeout: 12) { self.watchFocus() == 64_000_100 + index }
            guard watchFocus() == 64_000_100 + index else { return }
            heightAssert("recommendation", phase: "long64-rollover-\(index)", expected: 64_000_100 + index)
            XCTAssertFalse(app.descendants(matching: .any)["feed.continuation.loading"].exists)
            XCTAssertTrue(app.buttons["取消静音"].exists)
        }
        heightDeck().swipeDown(); heightAssert("recommendation", phase: "long64-back", expected: 64_000_110)
        heightDeck().swipeUp(); heightAssert("recommendation", phase: "long64-forward-again", expected: 64_000_111)
        attachScreenshot(named: "long64-sparse-rollover-whole-current-page")
    }

    func testHeaderStaging161RevokesRasterWhenTargetGeometryChanges() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-header-staging161"]
        app.launch()
        let qa = app.staticTexts["header.staging.qa"]
        waitUntil("The real header raster owner completes its geometry-change checks") { qa.valueDescription.contains("finished=1") }
        let values = heightValues(qa.valueDescription)
        for key in ["staged", "heightRevoked", "restaged", "rowRevoked", "finalRevoked", "finished"] {
            XCTAssertEqual(values[key], 1, "Actual staged owner invariant: \(key)")
        }
        XCTAssertEqual(values["height"], 68)
        print("HEADER_STAGING161 \(qa.valueDescription)")
    }

    func testNative161IdentityChangeInvalidatesHeldDragHosts() {
        launchContinuation("sparse-long64", extra: ["--qa-native-layout64", "--qa-pager-touch-trace", "--qa-identity-during-drag161", "-muted", "YES"])
        waitPlayingFixture()
        waitUntil("Identity test reaches a real gated native queue") { self.continuationFields()["gate"] == "waiting" }
        heightDeck().swipeUp(); heightDeck().swipeUp()
        waitUntil("The old queue reaches its tail") { self.watchFocus() == 64_000_102 }
        let qa = app.staticTexts["pager.identity.qa"]
        let before = heightValues(qa.valueDescription)["instances"] ?? 0
        let viewport = heightDeck().frame
        let lower = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: viewport.midX, dy: viewport.minY + viewport.height * 0.8))
        let upper = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: viewport.midX, dy: viewport.minY + viewport.height * 0.2))
        app.buttons["continuation.qa.release"].tap()
        lower.press(forDuration: 0.05, thenDragTo: upper, withVelocity: XCUIGestureVelocity(rawValue: 110), thenHoldForDuration: 0.4)
        waitUntil("Changing identity must dismantle the moving old queue and mount a fresh one", timeout: 12) {
            let values = self.heightValues(qa.valueDescription)
            return values["invalidated"] == 1 && (values["instances"] ?? 0) > before
                && (values["moving"] ?? 0) > 0 && (values["cleared"] ?? 0) > 0
        }
        print("NATIVE_IDENTITY161 \(qa.valueDescription)")
        waitUntil("Fresh identity displays only its new initial queue", timeout: 12) { self.watchFocus() == 64_000_100 }
        heightDeck().swipeUp()
        waitUntil("The new queue remains interactive") { self.watchFocus() == 64_000_101 }
        attachScreenshot(named: "native-identity-held-drag-new-queue")
    }

    func testNative66SparseAppendDuringTailDragOpensRequestedNext() {
        launchContinuation("sparse-long64", extra: ["--qa-native-layout64", "--qa-pager-touch-trace", "--qa-release-during-drag64", "-muted", "YES"])
        waitPlayingFixture()
        waitUntil("The sparse continuation must be gated") { self.continuationFields()["gate"] == "waiting" }
        heightDeck().swipeUp(); heightAssert("recommendation", phase: "long64-drag-first", expected: 64_000_101)
        heightDeck().swipeUp(); heightAssert("recommendation", phase: "long64-drag-tail", expected: 64_000_102)
        let viewport = heightDeck().frame
        let lower = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: viewport.midX, dy: viewport.minY + viewport.height * 0.8))
        let upper = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: viewport.midX, dy: viewport.minY + viewport.height * 0.2))
        app.buttons["continuation.qa.release"].tap()
        lower.press(forDuration: 0.05, thenDragTo: upper, withVelocity: XCUIGestureVelocity(rawValue: 110), thenHoldForDuration: 0.4)
        waitUntil("The scripted continuation must really return a long video", timeout: 12) {
            (Int(self.continuationFields()["requests"] ?? "0") ?? 0) >= 5
        }
        let trace = app.staticTexts["pager.qa.trace"].valueDescription
        print("PAGER64_TAIL_TRACE \(trace)")
        if let data = trace.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let events = object["events"] as? [[String: Any]] {
            let refreshes = events.filter { $0["event"] as? String == "native.beforeNeighborRefresh" }
            XCTAssertFalse(refreshes.isEmpty, "The queued append must eventually reach the native pager")
            XCTAssertTrue(events.contains { event in
                let native = event["native"] as? [String: Any]
                return event["event"] as? String == "native.deferQueue" &&
                    (native?["dragging"] as? Bool == true || native?["tracking"] as? Bool == true || native?["boundaryGateActive"] as? Bool == true) &&
                    native?["currentID"] as? Int == 64_000_102 && (event["incomingCount"] as? Int ?? 0) > 3
            }, "The response must overlap a real boundary drag, not just an idle append")
            XCTAssertFalse(refreshes.contains { event in
                let native = event["native"] as? [String: Any]
                return native?["boundaryGateActive"] as? Bool == true || native?["tracking"] as? Bool == true || native?["dragging"] as? Bool == true || native?["decelerating"] as? Bool == true
            }, "An append must not reset native neighbors while drag or bounce owns the offset")
        } else { XCTFail("Missing actual native trace") }
        waitUntil("Data arriving during the held tail gesture must honor its forward intent") { self.watchFocus() == 64_000_103 }
        let focus = watchFocus()
        XCTAssertEqual(focus, 64_000_103)
        guard focus == 64_000_103 else { return }
        heightAssert("recommendation", phase: "long64-append-during-tail-drag", expected: focus)
        let next = focus + 1
        heightDeck().swipeUp()
        waitUntil("The next real swipe must still settle") { self.watchFocus() == next }
        heightAssert("recommendation", phase: "long64-after-overlap-forward", expected: next)
        XCTAssertTrue(app.buttons["取消静音"].exists)
    }

    func testPrefetch52UpdatesWindowAndResumesAfterTabSwitch() {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["-mediaPrefetchCount", "6", "-wifiVideoPrefetch", "YES", "-muted", "YES"])
        let readback = app.descendants(matching: .any)["media.qa.prefetch"]
        XCTAssertTrue(readback.waitForValueToContain("ready=5", timeout: 8), "All five available future fixture media should be ready, including locally cached videos")
        XCTAssertTrue(readback.valueDescription.contains("desired=5"))
        heightDeck().swipeUp()
        waitUntil("Paging updates the prefetch window without changing its scope") { self.watchFocus() == 28_037_101 }
        XCTAssertTrue(readback.waitForValueToContain("desired=4", timeout: 5))
        XCTAssertTrue(readback.waitForValueToContain("ready=4", timeout: 5))
        mainTabButton("收藏").tap()
        XCTAssertTrue(mainTabButton("时间线").waitForExistence(timeout: 5))
        mainTabButton("时间线").tap()
        waitUntil("Returning through the timeline button keeps its single-tap return-to-top behavior") { self.watchFocus() == 28_037_100 }
        XCTAssertTrue(readback.waitForValueToContain("pagingAllowed=false", timeout: 5), "The actual tab callback gates feed pagination after returning to the top")
        XCTAssertTrue(readback.waitForValueToContain("desired=5", timeout: 5))
        XCTAssertTrue(readback.waitForValueToContain("ready=5", timeout: 8), "A retained viewer resumes media preloading at the requested top after hide")
        attachScreenshot(named: "prefetch53-window-resumed-at-top-after-tab-switch")
    }

    func testPrefetch53SingleTabTopKeepsKnownMediaWarmWithoutEnablingPaging() {
        visualLaunch(width: 0, large: false, landscape: false,
                     extra: ["-mediaPrefetchCount", "6", "-wifiVideoPrefetch", "YES", "-muted", "YES"])
        let readback = app.descendants(matching: .any)["media.qa.prefetch"]
        XCTAssertTrue(readback.waitForValueToContain("ready=5", timeout: 8))
        mainTabButton("时间线").tap()
        XCTAssertTrue(readback.waitForValueToContain("pagingAllowed=false", timeout: 5), "The programmatic-top gate still blocks automatic feed requests")
        XCTAssertTrue(readback.waitForValueToContain("ready=5", timeout: 5), "Known media preloading remains enabled while feed paging is gated")
        XCTAssertEqual(watchFocus(), 28_037_100)
        attachScreenshot(named: "prefetch53-top-gate-keeps-known-window")
    }

    func testAutomaticContinuationSkipsEightFilteredPagesWithoutJump() {
        launchContinuation("filtered-empty")
        waitForAppearanceContinuation()
        let loading = app.descendants(matching: .any).matching(identifier: "feed.continuation.loading").firstMatch
        if loading.exists {
            print("CONTINUATION40_UNEXPECTED_LOADING frame=\(loading.frame);hittable=\(loading.isHittable);deck=\(heightDeck().frame)")
            attachScreenshot(named: "continuation40-unexpected-loading")
        }
        XCTAssertFalse(loading.exists, "Background fill must not put a loading banner over an existing video")
        waitUntil("The current video must remain the active page while scanning") { self.watchFocus() == 28_037_102 }
        waitPlayingFixture()
        let before = playerFields()
        releaseContinuationResponse()
        waitUntil("Eight genuinely filtered pages must be crossed automatically", timeout: 20) { self.continuationFields()["requests"] == "10" && self.continuationFields()["returned"] == "28037104" }
        XCTAssertEqual(watchFocus(), 28_037_102, "Appending a matching video must not jump the current one")
        assertUnchangedPlayer(before, playerFields())
        XCTAssertFalse(app.buttons["继续加载"].exists); XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "media-page--1").firstMatch.exists)
        heightDeck().swipeUp(); heightAssert("recommendation", phase: "auto40-final-video", expected: 28_037_104)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "feed.continuation.ended").firstMatch.waitForExistence(timeout: 5))
        assertNoFixtureRead(for: 0.8)
        attachScreenshot(named: "continuation40-eight-filtered-pages-real-end")
    }

    func testInitialTimelineShowsLoadingBeforeActivation171() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-theme-timeline", "--qa-initial-loading171",
                               "-app.appearance", "light", "-muted", "YES", "-autoplay", "NO", "-timeline.presentation", "stream"]
        app.launch()
        let loading = app.descendants(matching: .any)["feed.continuation.loading"]
        XCTAssertTrue(loading.waitForExistence(timeout: 2), "Before activation the initial viewport must show loading, never a confirmed empty result")
        XCTAssertFalse(app.staticTexts["media.empty.message"].exists)
        XCTAssertFalse(app.buttons["media.empty.continue"].exists)
        attachScreenshot(named: "initial171-before-request-loading")
        waitUntil("A committed initial response replaces loading with a real work", timeout: 12) {
            self.app.buttons["media.details.28037100"].exists
        }
        XCTAssertFalse(app.staticTexts["media.empty.message"].exists)
    }

    func testAutomaticContinuationInitialEmptyReachesRealEnd() {
        launchContinuation("initial-empty")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "feed.continuation.loading").firstMatch.waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["正在查找作品…"].exists)
        XCTAssertEqual(continuationFields()["requests"], "2", "The actual initial scan must be waiting for its local response")
        attachScreenshot(named: "continuation40-initial-empty-loading-gated")
        releaseContinuationResponse()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "feed.continuation.ended").firstMatch.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["调整筛选"].exists)
        XCTAssertTrue(timelineTools().isHittable)
        XCTAssertEqual(continuationFields()["requests"], "10")
        XCTAssertEqual(continuationFields()["first"], "1")
        XCTAssertEqual(continuationFields()["continuations"], "9")
        print("CONTINUATION171 scoped-end=\(app.staticTexts["continuation.qa.state"].valueDescription)")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "media-page-28037102").firstMatch.exists)
        assertNoFixtureRead(for: 0.8)
        attachScreenshot(named: "continuation40-initial-empty-to-real-end")
    }

    func testAutomaticContinuationRateLimitNeedsExplicitRetry() {
        launchContinuation("rate-limited")
        waitForAppearanceContinuation()
        releaseContinuationResponse()
        let retry = app.buttons["feed.continuation.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 8)); XCTAssertFalse(retry.isEnabled, "429 must expose an actual cooldown")
        XCTAssertEqual(continuationFields()["requests"], "2"); XCTAssertEqual(continuationFields()["errors"], "1")
        assertNoFixtureRead(for: 0.8)
        waitUntil("Retry becomes enabled after the actual cooldown") { retry.isEnabled }
        XCTAssertEqual(continuationFields()["requests"], "2", "Cooldown expiry alone is not permission to retry")
        assertContinuationActionAccessible(retry)
        waitPlayingFixture()
        let before = playerFields(), focus = watchFocus()
        retry.tap()
        waitUntil("An explicit retry tap issues exactly one further page") { self.continuationFields()["requests"] == "3" && self.continuationFields()["returned"] == "28037104" }
        XCTAssertEqual(watchFocus(), focus)
        assertUnchangedPlayer(before, playerFields())
        waitUntil("Retry button tap must not pause the video") { (Double(self.playerFields()["position"] ?? "0") ?? 0) > (Double(before["position"] ?? "0") ?? 0) + 0.4 }
        attachScreenshot(named: "continuation40-explicit-retry-player-preserved")
    }

    func testAutomaticContinuationRepeatedCursorStaysStopped() {
        launchContinuation("repeated-cursor")
        waitPlayingFixture()
        XCTAssertEqual(watchFocus(), 28_037_102)
        waitUntil("Ordinary visible queue should automatically request continuation") {
            self.continuationFields()["requests"] == "2"
        }
        // Capture the production viewport before failure. Coordinate gestures
        // remain valid when a retained deck's XCTest role/hittability changes.
        let geometry = app.staticTexts.matching(identifier: "collection.qa.geometry").allElementsBoundByIndex.first {
            Int(heightValues($0.valueDescription)["focused"] ?? -1) == 28_037_102
        }
        let values = geometry.map { heightValues($0.valueDescription) } ?? [:]
        guard let x = values["viewportX"], let y = values["viewportY"],
              let width = values["viewportW"], let height = values["viewportH"], width > 0, height > 0 else {
            XCTFail("The actual initial media viewport must be measurable before the stalled response"); return
        }
        let viewport = CGRect(x: x, y: y, width: width, height: height)
        let upper = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: viewport.midX, dy: viewport.minY + viewport.height * 0.2))
        let lower = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: viewport.midX, dy: viewport.minY + viewport.height * 0.8))
        print("CONTINUATION40_STALL viewport=\(viewport)")
        lower.press(forDuration: 0.05, thenDragTo: upper)
        waitUntil("A real upward swipe must browse the second existing video") { self.watchFocus() == 28_037_104 }
        let restart = app.buttons["feed.continuation.restart"]
        XCTAssertTrue(restart.waitForExistence(timeout: 8)); XCTAssertTrue(restart.isHittable)
        assertContinuationActionAccessible(restart)
        XCTAssertEqual(continuationFields()["requests"], "2")
        let focus = watchFocus()
        XCTAssertEqual(focus, 28_037_104)
        XCTAssertFalse(app.buttons["feed.continuation.retry"].exists)
        attachScreenshot(named: "continuation40-repeat-cursor-stalled-at-last")

        upper.press(forDuration: 0.05, thenDragTo: lower)
        waitUntil("The stalled error layer must allow a real swipe back to the first saved video") { self.watchFocus() == 28_037_102 }
        XCTAssertTrue(restart.isHittable); XCTAssertEqual(continuationFields()["requests"], "2")
        XCTAssertFalse(app.buttons["feed.continuation.retry"].exists)
        assertNoFixtureRead(for: 0.5)
        lower.press(forDuration: 0.05, thenDragTo: upper)
        waitUntil("The old queue must still allow a real swipe forward to the last video") { self.watchFocus() == 28_037_104 }
        XCTAssertTrue(restart.isHittable); XCTAssertEqual(continuationFields()["requests"], "2")
        assertNoFixtureRead(for: 0.5)
        lower.press(forDuration: 0.05, thenDragTo: upper)
        assertNoFixtureRead(for: 1)
        XCTAssertEqual(continuationFields()["requests"], "2")
        XCTAssertEqual(watchFocus(), focus); XCTAssertTrue(restart.isHittable)
        XCTAssertFalse(app.buttons["feed.continuation.retry"].exists)
        attachScreenshot(named: "continuation40-repeat-cursor-old-queue-browsable-no-extra-read")
    }

    func testDiagnoseOriginalFortyFourPercentDrag() {
        let cases: [(Double, Bool)] = [(0.44, false), (0.60, false), (0.44, true), (0.48, true), (0.52, true), (0.60, true)]
        for (fraction, trace) in cases { auditPagingDrag(fraction: fraction, trace: trace, expectedFocus: nil) }
    }

    func testOriginalFortyFourPercentDragReboundsWithoutLosingPage() {
        // This exact short input starts an interactive UIKit transition but
        // does not commit it on the tested runtime. Keep the original distance
        // and API; a longer drag has a separate forward/back paging test.
        for trace in [false, true] {
            auditPagingDrag(fraction: 0.44, trace: trace, expectedFocus: 28_037_102)
        }
    }

    func testNative65OriginalShortDragWithGateDisabledControl() {
        for trace in [false, true] {
            auditPagingDrag(fraction: 0.44, trace: trace, expectedFocus: 28_037_102, disabledGate: true)
        }
    }

    private func auditPagingDrag(fraction: Double, trace: Bool, expectedFocus: Int?, disabledGate: Bool = false) {
        launchContinuation("repeated-cursor", extra: (trace ? ["--qa-pager-touch-trace"] : []) + ["--qa-chrome-geometry"] + (disabledGate ? ["--qa-disable-boundary-gate65"] : []))
        waitPlayingFixture()
        let restart = app.buttons["feed.continuation.restart"]
        XCTAssertTrue(restart.waitForExistence(timeout: 5))
        XCTAssertEqual(watchFocus(), 28_037_102)
        XCTAssertEqual(continuationFields()["requests"], "2")
        let beforePlayer = playerFields()
        let viewport = heightDeck().frame
        let lower = app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: viewport.midX, dy: viewport.minY + viewport.height * (1 + fraction) / 2))
        let upper = app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: viewport.midX, dy: viewport.minY + viewport.height * (1 - fraction) / 2))
        let traceNode = app.staticTexts["pager.qa.trace"]
        let beforeRaw = trace ? traceNode.valueDescription : "{}"
        let beforeTrace = (try? JSONSerialization.jsonObject(with: Data(beforeRaw.utf8))) as? [String: Any]
        let marker = (beforeTrace?["lastSequence"] as? Int) ?? 0
        let startTime = ProcessInfo.processInfo.systemUptime
        lower.press(forDuration: 0.05, thenDragTo: upper)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        let focus = watchFocus()
        XCTAssertTrue([28_037_102, 28_037_104].contains(focus), "A drag must settle on an actual member of the retained queue")
        heightAssert("recommendation", phase: "drag-\(fraction)-trace\(trace)", expected: focus)
        XCTAssertEqual(continuationFields()["requests"], "2")
        XCTAssertTrue(restart.isHittable)
        if focus == 28_037_102 { assertUnchangedPlayer(beforePlayer, playerFields()) }
        XCTAssertNotNil(videoGeometryReadback(), "A settled drag must retain an actual ready video surface, not a blank page")
        let raw = trace ? traceNode.valueDescription : "{}"
        if trace, expectedFocus == 28_037_102 {
            assertOriginalShortDragTrace(raw, after: marker, viewport: viewport)
        }
        let object: [String: Any] = ["fraction": fraction, "traceEnabled": trace, "eventMarker": marker,
            "pressDuration": 0.05, "gestureAPIVelocity": "default/unspecified",
            "viewport": ["x": viewport.minX, "y": viewport.minY, "width": viewport.width, "height": viewport.height],
            "plannedStart": ["x": viewport.midX, "y": viewport.minY + viewport.height * (1 + fraction) / 2],
            "plannedEnd": ["x": viewport.midX, "y": viewport.minY + viewport.height * (1 - fraction) / 2],
            "wallElapsed": ProcessInfo.processInfo.systemUptime - startTime,
            "finalFocus": focus, "trace": (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) ?? [:]]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        print("PAGER41_DRAG json=\(String(data: data, encoding: .utf8)!)")
        if let expectedFocus { XCTAssertEqual(focus, expectedFocus) }
        attachScreenshot(named: "pager41-drag-\(fraction)-trace\(trace)-final\(focus)")
        app.terminate()
    }

    private func assertOriginalShortDragTrace(_ raw: String, after marker: Int, viewport: CGRect) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
              let all = object["events"] as? [[String: Any]], let current = object["current"] as? [String: Any] else {
            XCTFail("The original short drag requires its real native touch/transition trace"); return
        }
        XCTAssertEqual(object["droppedEvents"] as? Int, 0)
        let events = all.filter { ($0["sequence"] as? Int ?? 0) > marker }
        let begins = events.filter { $0["event"] as? String == "touch.began" }
        let ends = events.filter { $0["event"] as? String == "touch.ended" }
        XCTAssertEqual(begins.count, 1); XCTAssertEqual(ends.count, 1)
        guard let begin = begins.first, let end = ends.first,
              let startPoint = begin["windowLocation"] as? [String: Double],
              let endPoint = end["windowLocation"] as? [String: Double],
              let hit = begin["touchView"] as? [String: Any] else { return }
        XCTAssertEqual(begin["touchID"] as? Int, end["touchID"] as? Int)
        XCTAssertEqual(startPoint["x"] ?? -1, Double(viewport.midX), accuracy: 2)
        XCTAssertEqual(startPoint["y"] ?? -1, Double(viewport.minY + viewport.height * 0.72), accuracy: 2)
        XCTAssertEqual(endPoint["x"] ?? -1, Double(viewport.midX), accuracy: 2)
        XCTAssertEqual(endPoint["y"] ?? -1, Double(viewport.minY + viewport.height * 0.28), accuracy: 2)
        XCTAssertEqual(hit["nativeScrollAncestor"] as? Bool, true)
        XCTAssertEqual(hit["controlAncestor"] as? Bool, false)
        XCTAssertTrue(events.contains { $0["event"] as? String == "native.pan" && $0["state"] as? Int == 1 })
        XCTAssertTrue(events.contains { $0["event"] as? String == "native.willTransition" })
        let completion = events.filter { $0["event"] as? String == "native.didFinish" }
        XCTAssertEqual(completion.count, 1)
        XCTAssertEqual(completion.first?["completed"] as? Bool, false)
        XCTAssertTrue(events.contains { $0["event"] as? String == "native.didSettle" && $0["redirected"] as? Bool == false })
        XCTAssertFalse(events.contains { $0["event"] as? String == "window.action" })
        XCTAssertEqual(current["focused"] as? Int, 28_037_102)
        XCTAssertEqual(current["displayedIDs"] as? [Int], [28_037_102])
        XCTAssertEqual(current["transitionActive"] as? Bool, false)
        XCTAssertEqual(current["dragging"] as? Bool, false)
        XCTAssertEqual(current["decelerating"] as? Bool, false)
    }

    private func launchContinuation(_ scenario: String, extra: [String] = []) {
        app = XCUIApplication(); app.launchArguments = ["--qa-collection-paging", "--qa-theme-timeline", "--qa-auto-continuation=\(scenario)", "-timeline.presentation", "stream", "-muted", "YES"]
        app.launchArguments += extra
        XCUIDevice.shared.orientation = .portrait; app.launch()
        XCTAssertTrue(app.staticTexts["continuation.qa.state"].waitForExistence(timeout: 10))
        waitUntil("The fixture must receive the real video filter") { self.continuationFields()["kind"] == "video" }
        printContinuationCounts("launch-ready")
    }
    private func waitForAppearanceContinuation() {
        waitPlayingFixture()
        XCTAssertEqual(watchFocus(), 28_037_102)
        waitUntil("The visible ordinary queue should automatically request a continuation on appearance") {
            (Int(self.continuationFields()["requests"] ?? "0") ?? 0) >= 2
        }
        printContinuationCounts("after-appearance-fill-demand")
    }
    private func releaseContinuationResponse() {
        let release = app.buttons["continuation.qa.release"]
        XCTAssertTrue(release.waitForExistence(timeout: 5))
        waitUntil("The fake response must wait while real loading is visible") { self.continuationFields()["gate"] == "waiting" && release.isEnabled }
        printContinuationCounts("before-local-response-release")
        release.tap()
        waitUntil("Only the local response gate must be released") { self.continuationFields()["gate"] == "released" }
        printContinuationCounts("after-local-response-release")
    }
    private func printContinuationCounts(_ phase: String) {
        print("CONTINUATION40 phase=\(phase);\(app.staticTexts["continuation.qa.state"].valueDescription)")
    }
    private func assertContinuationActionAccessible(_ action: XCUIElement) {
        let viewport = heightDeck().frame
        let window = app.windows.firstMatch.frame
        let headerHeight: CGFloat = window.width > window.height ? 92 : 104
        let frame = action.frame
        print("CONTINUATION41_ACTION id=\(action.identifier);frame=\(frame);viewport=\(viewport);headerBottom=\(viewport.minY + headerHeight);exists=\(action.exists);enabled=\(action.isEnabled);hittable=\(action.isHittable)")
        XCTAssertTrue(action.isHittable)
        XCTAssertGreaterThan(frame.width, 0); XCTAssertGreaterThanOrEqual(frame.height + 0.01, 44)
        XCTAssertGreaterThanOrEqual(frame.minY, viewport.minY + headerHeight)
        XCTAssertLessThanOrEqual(frame.maxY, viewport.maxY + 1)
        let seek = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "播放进度")).firstMatch
        if seek.exists { XCTAssertFalse(frame.intersects(seek.frame)) }
        for id in ["timeline.resume", "timeline.notice.text"] {
            let overlay = app.descendants(matching: .any).matching(identifier: id).firstMatch
            if overlay.exists && overlay.isHittable { XCTAssertFalse(frame.intersects(overlay.frame)) }
        }
    }
    private func continuationFields() -> [String: String] { qaFields(app.staticTexts["continuation.qa.state"].valueDescription) }
    private func assertNoFixtureRead(for interval: TimeInterval) {
        printContinuationCounts("before-no-read-window")
        let count = continuationFields()["requests"]
        let unexpected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.continuationFields()["requests"] != count }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [unexpected], timeout: interval), .timedOut)
        printContinuationCounts("after-no-read-window")
    }
    private func chromeState() -> XCUIElement { app.staticTexts.matching(identifier: "media.qa.chrome").firstMatch }
    private func playerFields() -> [String: String] { qaFields(app.staticTexts.matching(identifier: "media.qa.player").firstMatch.valueDescription) }
    private func videoGeometryReadback() -> (fields: [String: Any], raw: String)? {
        let probe = app.staticTexts.matching(identifier: "media.qa.video-geometry").firstMatch
        guard probe.exists else { return nil }
        let raw = probe.valueDescription
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any],
              let surface = fields["surface"] as? String, !surface.isEmpty,
              let ready = fields["ready"] as? Bool, ready,
              layout41HasPositiveRect(fields["videoRect"]),
              layout41HasPositiveRect(fields["videoWindow"]) else { return nil }
        return (fields, raw)
    }
    private func layout41HasPositiveRect(_ value: Any?) -> Bool {
        guard let rect = value as? [String: Any],
              let width = rect["width"] as? Double,
              let height = rect["height"] as? Double else { return false }
        return width > 0 && height > 0
    }
    private func assertVideoGeometryOrientation(_ fields: [String: Any], landscape: Bool) {
        guard let window = fields["window"] as? [String: Any],
              let width = window["width"] as? Double, let height = window["height"] as? Double else {
            XCTFail("Actual window dimensions are missing from geometry readback"); return
        }
        XCTAssertEqual(width > height, landscape, "Read back the actual orientation at every chrome phase")
    }
    private func layout41LogGeometry(_ scenario: String, phase: String,
                                     readback: String) {
        print("LAYOUT41_GEOMETRY case=\(scenario);phase=\(phase);json=\(readback)")
    }
    private func assertVideoGeometryUnchanged(_ before: [String: Any], _ after: [String: Any], phase: String) {
        guard let beforeSurface = before["surface"] as? String, !beforeSurface.isEmpty,
              let afterSurface = after["surface"] as? String, !afterSurface.isEmpty else {
            XCTFail("Missing actual surface UUID at \(phase): before=\(before), after=\(after)")
            return
        }
        XCTAssertEqual(afterSurface, beforeSurface, "Chrome transition must retain the same actual video surface")
        for key in ["surfaceWindow", "layerBounds", "layerFrame", "videoRect", "videoWindow", "windowSafeArea", "transform", "presentationSize", "sourceScale"] {
            guard let left = before[key], let right = after[key] else {
                XCTFail("Missing geometry field \(key) at \(phase); before=\(before), after=\(after)")
                continue
            }
            assertGeometryNumbersEqual(left, right, field: key, phase: phase)
        }
        guard let beforeScale = layout41VideoScale(before), let afterScale = layout41VideoScale(after) else {
            XCTFail("Cannot calculate actual video scale at \(phase); before=\(before), after=\(after)")
            return
        }
        XCTAssertEqual(afterScale.x, beforeScale.x, accuracy: 0.005, "Actual horizontal video scale changed at \(phase)")
        XCTAssertEqual(afterScale.y, beforeScale.y, accuracy: 0.005, "Actual vertical video scale changed at \(phase)")
    }
    private func assertGeometryNumbersEqual(_ lhs: Any, _ rhs: Any, field: String, phase: String) {
        if let left = lhs as? [String: Any], let right = rhs as? [String: Any] {
            XCTAssertEqual(Set(left.keys), Set(right.keys), "Geometry keys changed for \(field) at \(phase)")
            for key in Set(left.keys).union(right.keys) {
                guard let l = left[key], let r = right[key] else { continue }
                assertGeometryNumbersEqual(l, r, field: "\(field).\(key)", phase: phase)
            }
        } else if let left = lhs as? NSNumber, let right = rhs as? NSNumber {
            XCTAssertEqual(left.doubleValue, right.doubleValue, accuracy: 0.5,
                           "Actual geometry \(field) moved over 0.5pt at \(phase)")
        } else if let left = lhs as? String, let right = rhs as? String {
            XCTAssertEqual(left, right, "Geometry value \(field) changed at \(phase)")
        } else {
            XCTAssertEqual(String(describing: lhs), String(describing: rhs), "Geometry value \(field) changed at \(phase)")
        }
    }
    private func layout41VideoScale(_ fields: [String: Any]) -> (x: Double, y: Double)? {
        guard let scale = fields["sourceScale"] as? [String: Any],
              let x = scale["x"] as? Double, x > 0,
              let y = scale["y"] as? Double, y > 0 else { return nil }
        return (x, y)
    }
    private func assertChromePlayerIdentityUnchanged(_ before: [String: String], _ after: [String: String], phase: String) {
        for key in ["player", "prepare", "created", "muted", "rate", "taps", "rateHolds", "seekStarts"] {
            XCTAssertNotNil(before[key], "Missing actual player field \(key) before \(phase)")
            XCTAssertEqual(after[key], before[key], "Chrome transition changed actual player field \(key) at \(phase)")
        }
        XCTAssertEqual(before["muted"], "true", "Layout geometry case must keep actual video muted")
    }
    private func layout41ScrollToHittable(_ element: XCUIElement, in scrollView: XCUIElement,
                                          towardBottom: Bool) -> Bool {
        guard scrollView.waitForExistence(timeout: 5), element.exists else { return false }
        for _ in 0..<12 {
            if element.isHittable { return true }
            if towardBottom { scrollView.swipeUp() } else { scrollView.swipeDown() }
        }
        return element.isHittable
    }
    private func qaFields(_ text: String) -> [String: String] {
        Dictionary(text.split(separator: ";").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
        }, uniquingKeysWith: { _, new in new })
    }
    private func numericReadback(_ text: String) -> [String: Double] {
        qaFields(text).compactMapValues(Double.init)
    }
    private func waitPlayingFixture() {
        XCTAssertTrue(app.staticTexts.matching(identifier: "media.qa.player").firstMatch.waitForExistence(timeout: 10))
        waitUntil("A real muted AVPlayer must be advancing before gestures") {
            let fields = self.playerFields()
            return fields["player"] != nil && fields["player"] != "none" && fields["rate"] == "1.0" && (Double(fields["position"] ?? "0") ?? 0) > 0.2
        }
        XCTAssertEqual(playerFields()["muted"], "true")
    }
    private func assertUnchangedPlayer(_ before: [String: String], _ after: [String: String]) {
        for key in ["player", "prepare", "created", "muted", "rate", "taps", "rateHolds", "seekStarts"] {
            XCTAssertNotNil(before[key], "Missing actual player QA field \(key)")
            XCTAssertEqual(after[key], before[key], "Chrome/loading UI must not alter actual player field \(key)")
        }
    }
    private func watchFocus() -> Int {
        let geometry = app.staticTexts.matching(identifier: "collection.qa.geometry").allElementsBoundByIndex.first { (heightValues($0.valueDescription)["focused"] ?? -1) > 0 }
        return geometry.map { Int(heightValues($0.valueDescription)["focused"] ?? -1) } ?? -1
    }
    private func assertChromeNotHittable(_ elements: [XCUIElement], phase: String) {
        let receipt = elements.map { "id=\($0.identifier);label=\($0.label);exists=\($0.exists);hittable=\($0.isHittable);frame=\($0.frame)" }.joined(separator: "\n")
        print("CHROME40_SNAPSHOT phase=\(phase);\n\(receipt)")
        let attachment = XCTAttachment(string: receipt + "\n" + String(app.debugDescription.prefix(18000)))
        attachment.name = "chrome40-\(phase)-actual-AX-snapshot"; attachment.lifetime = .keepAlways; add(attachment)
        // Fixed subtrees may remain locatable in XCTest. Their actual snapshot
        // and hit state are evidence; .exists is not a VoiceOver visibility API.
        for element in elements { XCTAssertFalse(element.isHittable, "Hidden chrome must reject hits: \(element.identifier) \(element.label)") }
    }
    private func recordChromeAX61(_ elements: [XCUIElement], phase: String) {
        // XCTest's hidden UIKit activation-point lookup can itself fail. Keep
        // the AX receipt; actual pixel removal and taps at the old control
        // positions below verify visibility and interaction independently.
        let receipt = elements.map { "id=\($0.identifier);label=\($0.label);exists=\($0.exists);frame=\($0.frame)" }.joined(separator: "\n")
        print("CHROME61_AX phase=\(phase);\n\(receipt)")
        let attachment = XCTAttachment(string: receipt); attachment.name = "chrome61-\(phase)-AX"; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func captureChromePixels(named name: String) -> UIImage? {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        return UIImage(data: screenshot.pngRepresentation)
    }
    private func chromeWhitePixels(_ screenshot: UIImage?, in frame: CGRect) -> Int? {
        guard let image = screenshot?.cgImage, app.frame.width > 0, app.frame.height > 0, frame.width > 0, frame.height > 0 else { return nil }
        let xScale = CGFloat(image.width) / app.frame.width, yScale = CGFloat(image.height) / app.frame.height
        let crop = CGRect(x: (frame.minX - app.frame.minX) * xScale, y: (frame.minY - app.frame.minY) * yScale,
                          width: frame.width * xScale, height: frame.height * yScale).integral
        guard let region = image.cropping(to: crop), region.width > 0, region.height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: region.width * region.height * 4)
        let rendered = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: region.width, height: region.height,
                                          bitsPerComponent: 8, bytesPerRow: region.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(region, in: CGRect(x: 0, y: 0, width: region.width, height: region.height)); return true
        }
        guard rendered else { return nil }
        return stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0] >= 180 && bytes[$0 + 1] >= 180 && bytes[$0 + 2] >= 180 }.count
    }
    private func assertChromePixelsDisappear(before: UIImage?, hidden: UIImage?, regions: [String: CGRect]) {
        for (name, frame) in regions.sorted(by: { $0.key < $1.key }) {
            guard let visible = chromeWhitePixels(before, in: frame), let absent = chromeWhitePixels(hidden, in: frame) else {
                XCTFail("Could not decode actual screenshot pixels for \(name): \(frame)"); continue
            }
            print("CHROME40_PIXELS region=\(name);frame=\(frame);visibleWhite=\(visible);hiddenWhite=\(absent)")
            XCTAssertGreaterThan(visible, 8, "The controlled static image must first expose visible chrome pixels in \(name)")
            XCTAssertLessThanOrEqual(Double(absent), max(8, Double(visible) * 0.15), "Hidden chrome must remove the original white glyph/background pixels in \(name)")
        }
    }
    private func tapScreenFrame(_ frame: CGRect) {
        XCTAssertGreaterThan(frame.width, 0); XCTAssertGreaterThan(frame.height, 0)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
    }
    private func centralPress() {
        let frame = heightDeck().frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).press(forDuration: 0.7)
    }
    private func logAuthorReturnMotion(_ stage: String, _ motion: XCUIElement) -> String {
        let value = motion.exists ? motion.valueDescription : "missing"
        print("\(stage);page.return-motion.qa=\(value)")
        return value
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 8,
                           onTimeout: (() -> Void)? = nil, _ predicate: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        if result != .completed { onTimeout?() }
        if result != .completed && (message.hasPrefix("Actual missing-file") || message.hasPrefix("The current failure and three")) {
            print("FAILURE66_DIAGNOSTIC_BEGIN\n\(app.debugDescription)\nFAILURE66_DIAGNOSTIC_END")
            attachScreenshot(named: "failure66-current-native-player-state")
        }
        XCTAssertEqual(result, .completed, message)
    }

    private func mainTabButton(_ title: String) -> XCUIElement {
        let ids = ["时间线": "main.tab.timeline", "作者榜": "main.tab.2", "搜索": "main.tab.4", "收藏": "main.tab.3"]
        if let identifier = ids[title] { return mainTabBar().buttons.matching(identifier: identifier).firstMatch }
        // Negative checks for a removed tab must query it, never manufacture it.
        return mainTabBar().buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    private func mainTabBar() -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "main.tabs.compact").firstMatch
    }

    private func rootMotionFields181(_ value: String) -> [String: String] {
        Dictionary(value.split(separator: ";").compactMap { item in
            guard let separator = item.firstIndex(of: "=") else { return nil }
            let key = String(item[..<separator])
            let fieldValue = String(item[item.index(after: separator)...])
            return (key, fieldValue)
        }, uniquingKeysWith: { _, new in new })
    }

    private func tokenValue181(_ value: String, tab: Int) -> String? {
        value.split(separator: ",").first { $0.hasPrefix("\(tab):") }.map { String($0.dropFirst(String(tab).count + 1)) }
    }

    private func rootTabID181(_ title: String) -> String {
        ["时间线": "0", "作者榜": "2", "搜索": "4", "收藏": "3"][title] ?? "-1"
    }

    private func rootHeader181(_ title: String) -> XCUIElement {
        switch title {
        case "作者榜": return app.otherElements["leaderboard.top-bar"]
        case "搜索": return app.otherElements["search.top-bar"]
        case "收藏": return app.otherElements["collections.top-bar"]
        default: return app.buttons["timeline.account"]
        }
    }

    private func floatingPageTitle(_ title: String) -> XCUIElement {
        app.otherElements["page-title." + title]
    }

    private func openAccountSettings() {
        let settings = floatingPageTitle("账号与设置")
        guard !settings.isHittable else { return }
        let account = app.buttons["timeline.account"]
        let timeline = mainTabButton("时间线")
        if !account.isHittable && !timeline.isSelected { timeline.tap() }
        for _ in 0..<4 {
            if settings.isHittable { return }
            if account.isHittable { break }
            let backs = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["navigation.back", "BackButton"]))
            guard let back = backs.allElementsBoundByIndex.first(where: \.isHittable) else { break }
            back.tap()
        }
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        XCTAssertTrue(account.isHittable)
        account.tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
    }

    private func closeAccountSettings() {
        let backs = floatingPageTitle("账号与设置").buttons
            .matching(NSPredicate(format: "identifier IN %@", ["navigation.back", "BackButton"]))
        XCTAssertTrue(backs.firstMatch.waitForExistence(timeout: 5))
        backs.firstMatch.tap()
        XCTAssertTrue(app.buttons["timeline.account"].waitForExistence(timeout: 5))
    }

    private func timelineTools() -> XCUIElement { app.buttons["timeline.tools"] }

    private func selectTimelineSource(_ title: String) {
        let button = app.otherElements["timeline.source"].buttons[title]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func openTimelineTool(_ title: String, screenshot: String? = nil) {
        timelineTools().tap()
        let action = app.buttons[title]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        if let screenshot { attachScreenshot(named: screenshot) }
        action.tap()
    }

    private func toggleTimelinePresentation() {
        let isGrid = timelineTools().valueDescription.contains("双列网格")
        openTimelineTool(isGrid ? "逐条浏览" : "双列网格")
    }

    private func visualButton(_ id: String) -> XCUIElement {
        let candidates = app.buttons.matching(identifier: id).allElementsBoundByIndex
        return candidates.first(where: { $0.isHittable }) ?? app.buttons.matching(identifier: id).firstMatch
    }

    func testPlaybackOrientationLockAndSystemFollowing() {
        func launch(forceManual: Bool) {
            app = XCUIApplication()
            app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "--qa-chrome-geometry",
                                   "-muted", "YES", "-autoplay", "YES"]
            if forceManual { app.launchArguments += ["-civitviewer.automaticRotation", "NO"] }
            XCUIDevice.shared.orientation = .portrait
            app.launch()
            heightOpen("recommendation", expected: 28_037_102)
            heightCloseNotices()
            waitUntil("The video must be rendering before rotating") { self.videoGeometryReadback() != nil }
        }

        func verify(_ phase: String, landscape: Bool) {
            waitUntil("Window and video should agree at \(phase)") {
                let frame = self.app.windows.firstMatch.frame
                guard (frame.width > frame.height) == landscape,
                      let geometry = self.videoGeometryReadback()?.fields,
                      let window = geometry["window"] as? [String: Double],
                      let width = window["width"], let height = window["height"] else { return false }
                return (width > height) == landscape
            }
            heightAssert("recommendation", phase: phase, expected: 28_037_102)
            assertPlaybackRailWithinSafeArea(itemID: 28_037_102, landscape: landscape, phase: phase)
            attachScreenshot(named: "rotation-\(phase)")
        }

        launch(forceManual: true)
        verify("locked-portrait-start", landscape: false)
        XCUIDevice.shared.orientation = .landscapeLeft
        verify("locked-portrait-after-system-turn", landscape: false)
        app.buttons["手动切换横竖屏"].tap()
        verify("manual-portrait-to-landscape", landscape: true)
        XCUIDevice.shared.orientation = .portrait
        verify("locked-landscape-after-system-turn", landscape: true)
        app.buttons["手动切换横竖屏"].tap()
        verify("manual-landscape-to-portrait", landscape: false)
        func assertRestoredPortrait() {
            waitUntil("Leaving the inline player restores its opening portrait direction") {
                let frame = self.app.windows.firstMatch.frame
                return frame.width > 0 && frame.height > frame.width
            }
            XCUIDevice.shared.orientation = .portrait
        }
        app.buttons["手动切换横竖屏"].tap()
        verify("before-inline-tab-exit", landscape: true)
        mainTabButton("搜索").tap()
        XCTAssertTrue(app.textFields["search-title-input"].waitForExistence(timeout: 5))
        assertRestoredPortrait()

        mainTabButton("时间线").tap()
        XCTAssertTrue(app.buttons["手动切换横竖屏"].waitForExistence(timeout: 5))
        app.buttons["手动切换横竖屏"].tap()
        verify("before-inline-settings-exit", landscape: true)
        openAccountSettings()
        assertRestoredPortrait()
        app.terminate()

        launch(forceManual: false)
        openAccountSettings()
        let automatic = app.switches["自动旋转"]
        func revealRotationSetting() {
            for _ in 0..<8 where !automatic.isHittable { app.swipeUp() }
            XCTAssertTrue(automatic.isHittable)
        }
        revealRotationSetting()
        func toggleRotationSetting(to value: String) {
            XCTAssertTrue(automatic.isHittable)
            automatic.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.50)).tap()
            if automatic.value as? String != value {
                print("ROTATION_SETTING observed=\(String(describing: automatic.value));frame=\(automatic.frame)")
                attachScreenshot(named: "rotation-setting-after-toggle")
            }
            waitUntil("The automatic rotation switch must read \(value)") { automatic.value as? String == value }
        }
        let originallyAutomatic = automatic.value as? String == "1"
        if originallyAutomatic {
            toggleRotationSetting(to: "0")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        let window = app.windows.firstMatch
        XCTAssertGreaterThan(window.frame.height, window.frame.width)
        toggleRotationSetting(to: "1")
        waitUntil("Enabling system following must pick up the current landscape direction") {
            window.frame.width > window.frame.height
        }
        floatingPageTitle("账号与设置").buttons["navigation.back"].tap()
        verify("system-current-landscape-on-entry", landscape: true)
        XCUIDevice.shared.orientation = .portrait
        verify("system-landscape-to-portrait", landscape: false)
        XCUIDevice.shared.orientation = .landscapeLeft
        verify("system-portrait-to-landscape", landscape: true)
        XCUIDevice.shared.orientation = .portrait
        verify("system-portrait-before-opposite-landscape", landscape: false)
        XCUIDevice.shared.orientation = .landscapeRight
        verify("system-opposite-landscape", landscape: true)
        visualOpenDetails(itemID: 28_037_102)
        XCUIDevice.shared.orientation = .portrait
        waitUntil("Presented details follow the system to portrait") {
            window.frame.height > window.frame.width && self.floatingPageTitle("作品详情").isHittable
        }
        visualCloseDetails()
        verify("system-portrait-after-details", landscape: false)
        XCUIDevice.shared.press(.home)
        XCUIDevice.shared.orientation = .landscapeLeft
        app.activate()
        verify("system-landscape-after-foreground", landscape: true)
        mainTabButton("搜索").tap()
        XCTAssertTrue(app.textFields["search-title-input"].waitForExistence(timeout: 5))
        let searchWindow = app.windows.firstMatch
        XCTAssertGreaterThan(searchWindow.frame.width, searchWindow.frame.height,
                             "System following must stay active outside the player")
        XCUIDevice.shared.orientation = .portrait
        waitUntil("The search page must follow the system back to portrait") {
            searchWindow.frame.height > searchWindow.frame.width
        }
        if !originallyAutomatic {
            openAccountSettings()
            revealRotationSetting()
            toggleRotationSetting(to: "0")
        }
        app.terminate()
    }

    private func assertPlaybackRailWithinSafeArea(itemID: Int, landscape: Bool, phase: String) {
        let window = app.windows.firstMatch.frame
        guard let safe = videoGeometryReadback()?.fields["windowSafeArea"] as? [String: Double],
              let left = safe["left"], let right = safe["right"],
              let top = safe["top"], let bottom = safe["bottom"] else {
            XCTFail("Missing measured system safe area at \(phase)"); return
        }
        if landscape { XCTAssertGreaterThan(left + right, 0, "The simulator must expose its notch in landscape") }
        let rotate = app.buttons["手动切换横竖屏"]
        let rail = [visualButton("media.details.\(itemID)"), app.buttons["取消静音"]]
        for button in rail + [rotate] {
            XCTAssertTrue(button.isHittable, phase)
            let frame = button.frame
            XCTAssertGreaterThanOrEqual(frame.minX, window.minX + left - 1, phase)
            XCTAssertLessThanOrEqual(frame.maxX, window.maxX - right + 1, phase)
            XCTAssertGreaterThanOrEqual(frame.minY, window.minY + top - 1, phase)
            XCTAssertLessThanOrEqual(frame.maxY, window.maxY - bottom + 1, phase)
            XCTAssertGreaterThanOrEqual(frame.width, 43.5, phase)
            XCTAssertGreaterThanOrEqual(frame.height, 43.5, phase)
            XCTAssertEqual(frame.midX, rail[0].frame.midX, accuracy: 1, phase)
        }
        print("ROTATION_SAFE_AREA phase=\(phase);left=\(left);right=\(right);top=\(top);bottom=\(bottom);rail=\(rail[0].frame)")
    }

    func testWatchingViewportTimelineHeightAndRotation() {
        for route in ["recommendation", "following", "timeline-grid", "timeline-resume"] {
            auditWatchingRoute(route, rotates: route == "recommendation" || route == "timeline-grid")
        }
    }

    func testPlayback174SearchEntry() {
        auditWatchingRoute("search", rotates: false)
    }

    func testPlayback174AuthorVideoRotation() {
        auditWatchingRoute("author-video", rotates: true)
    }

    func testWatching175SearchRouteCompletes() { auditWatchingRoute("search", rotates: false, extra: ["--qa-terminal-tone175"]) }

    func testWatchingViewportOtherEntriesHeightAndRotation() {
        for route in ["author", "author-video", "search", "collections", "collections-video", "history", "history-resume"] {
            auditWatchingRoute(route, rotates: ["author-video", "collections-video", "history-resume"].contains(route))
        }
    }

    func testFullBleedSameVideoAcrossPlaybackEntries() {
        for route in ["timeline-resume", "timeline-grid", "author-video", "search", "collections", "history"] {
            assertFullBleedVideoEntry(route)
        }
    }

    func testFullBleedOfflineVideoEntry() {
        assertFullBleedVideoEntry("offline")
    }

    private func assertFullBleedVideoEntry(_ route: String) {
        let workID = 28_037_102
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "--qa-chrome-geometry",
                               "-muted", "YES", "-autoplay", "YES", "-civitviewer.automaticRotation", "NO"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        heightOpen(route, expected: workID)
        waitUntil("Open the same video from \(route)") { self.watchFocus() == workID }
        assertVideoReachesVerticalEdges()
        if let geometry = videoGeometryReadback()?.fields,
           let frame = geometry["videoWindow"] as? [String: Double],
           let window = geometry["window"] as? [String: Double],
           let top = frame["y"], let height = frame["height"], let windowHeight = window["height"] {
            XCTAssertLessThanOrEqual(top, 3, route)
            XCTAssertLessThanOrEqual(windowHeight - top - height, 3, route)
        } else {
            XCTFail("Missing rendered frame geometry for \(route)")
        }
        let seek = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "播放进度"))
        waitUntil("The seek bar remains interactive above the bottom edge in \(route)") {
            guard let control = seek.allElementsBoundByIndex.first(where: \.isHittable) else { return false }
            return control.frame.maxY < self.app.windows.firstMatch.frame.maxY
        }
        assertPlaybackRailWithinSafeArea(itemID: workID, landscape: false, phase: "\(route)-portrait")
        attachScreenshot(named: "full-bleed-\(route)")
        for landscape in [true, false] {
            let phase = "\(route)-\(landscape ? "landscape" : "portrait-return")"
            app.buttons["手动切换横竖屏"].tap()
            heightWaitOrientation(landscape: landscape)
            heightAssert(route, phase: phase, expected: workID)
            assertVideoReachesVerticalEdges()
            assertPlaybackRailWithinSafeArea(itemID: workID, landscape: landscape, phase: phase)
        }
        app.terminate()
    }

    func testOfflinePlaybackFloatingBarKeepsFullViewport() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "-muted", "YES"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        heightOpen("offline", expected: 28_037_100)

        let close = app.buttons["playback.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["作品"].exists)
        XCTAssertTrue(close.isHittable)
        let viewport = heightDeck().frame
        XCTAssertLessThan(viewport.minY, close.frame.midY)
        XCTAssertEqual(close.frame.height, 44, accuracy: 1)
        attachScreenshot(named: "offline-playback-floating-bar")

        app.buttons["纯净看图"].tap()
        waitUntil("The floating bar should hide with the playback controls") { !close.exists || !close.isHittable }
        XCTAssertEqual(heightDeck().frame, viewport)
        centralPress()
        waitUntil("The floating bar should return on a long press") { close.isHittable }
        close.tap()
        XCTAssertTrue(app.buttons["media.grid.cell.28037100"].waitForExistence(timeout: 5))
    }

    func testWatchingViewportHistoryResumeHeightAndRotation() {
        auditWatchingRoute("history-resume", rotates: true)
    }

    func testWatchingViewportTimelineResumeHeightAndRotation() {
        auditWatchingRoute("timeline-resume", rotates: true)
    }

    func testWatchingViewportCompactDynamicTypeHeightAndRotation() {
        auditWatchingRoute("recommendation", rotates: true, compact: true)
    }

    func testWatchingViewportShortLandscapeKeepsGesturesAroundResumePrompt() {
        app = XCUIApplication(); app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "-muted", "YES"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        mainTabButton("时间线").tap()
        let mode = timelineTools()
        XCTAssertTrue(mode.waitForExistence(timeout: 10))
        if mode.valueDescription.contains("双列网格") { toggleTimelinePresentation() }
        app.otherElements["timeline.media-kind"].buttons["视频"].tap()
        let resume = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "timeline.resume", "上次推荐")).firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 8)); XCTAssertTrue(resume.isHittable)
        heightAssert("recommendation", phase: "prompt-video", expected: 28_037_102)
        app.buttons["手动切换横竖屏"].tap()
        heightWaitOrientation(landscape: true)
        heightAssert("recommendation", phase: "prompt-video-landscape", expected: 28_037_102)
        XCTAssertTrue(resume.isHittable, "The prompt itself must remain interactive")
        let frame = heightDeck().frame
        func exposedPoint(itemID: Int = 28_037_102) -> XCUICoordinate {
            let viewport = heightDeck().frame, window = app.windows.firstMatch.frame
            let headerBottom = viewport.minY + (window.width > window.height ? 92 : 104)
            let social = app.buttons["media.author.\(itemID)"].frame
            let top = max(headerBottom, resume.isHittable ? resume.frame.maxY : headerBottom) + 6
            let bottom = social.minY - 6
            XCTAssertGreaterThan(bottom, top, "Actual header, prompt and author row must leave exposed media")
            return app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: viewport.midX, dy: (top + bottom) / 2))
        }
        let exposed = exposedPoint()
        let seek = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "播放进度")).firstMatch
        XCTAssertTrue(seek.waitForExistence(timeout: 10)); XCTAssertTrue(seek.isHittable)
        XCTAssertTrue(app.buttons["取消静音"].isHittable, "The player must stay muted throughout QA")
        seek.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)).tap()
        exposed.tap()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let paused = seekSeconds(seek.valueDescription)!
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        XCTAssertEqual(seekSeconds(seek.valueDescription)!, paused, accuracy: 0.5, "A tap beside the prompt must pause playback")
        exposed.tap()
        let playing = NSPredicate { _, _ in (self.seekSeconds(seek.valueDescription) ?? paused) >= paused + 1 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: playing, object: nil)], timeout: 4), .completed)
        let rotationControl = app.buttons["手动切换横竖屏"]
        let controlFrame = rotationControl.frame
        guard let rawSeeksBefore = playerFields()["seekStarts"], let seeksBeforeControlDrag = Int(rawSeeksBefore) else {
            XCTFail("Missing numeric seekStarts before control-origin drag"); return
        }
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: controlFrame.midX, dy: controlFrame.midY))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: controlFrame.midX - 168, dy: controlFrame.midY)))
        XCTAssertTrue(app.otherElements["timeline.media-kind"].buttons["视频"].isSelected,
                      "A drag starting inside the rotate control must not switch the media filter")
        guard let rawSeeksAfter = playerFields()["seekStarts"], let seeksAfterControlDrag = Int(rawSeeksAfter) else {
            XCTFail("Missing numeric seekStarts after control-origin drag"); return
        }
        print("TIGHT_FOOTER42_CONTROL_ORIGIN seekStartsBefore=\(seeksBeforeControlDrag);seekStartsAfter=\(seeksAfterControlDrag)")
        XCTAssertEqual(seeksAfterControlDrag, seeksBeforeControlDrag,
                       "A drag starting inside a control must not seek the video")
        let edgeY = seek.frame.minY - 4
        let edge = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.minX + 12, dy: edgeY))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.minX + 180, dy: edgeY)))
        let images = app.otherElements["timeline.media-kind"].buttons["图片"]
        waitUntil("A left-edge swipe switches from videos to images") { images.isSelected }
        heightAssert("recommendation", phase: "prompt-edge-switch-result", expected: 28_037_100)
        // Replacing a filtered queue may recreate its orientation scope. Use
        // the resulting viewport for the next gesture rather than stale points.
        exposedPoint(itemID: 28_037_100).doubleTap()
        XCTAssertTrue(app.descendants(matching: .any)["creator.top-bar"].waitForExistence(timeout: 8))
        print("HEIGHT_GESTURES prompt-visible landscape-video single-tap-pause-resume edge-switch double-tap-author passed")
        attachScreenshot(named: "height-landscape-prompt-author")
        app.terminate(); XCUIDevice.shared.orientation = .portrait
    }

    private func auditWatchingRoute(_ route: String, rotates: Bool, compact: Bool = false, extra: [String] = []) {
        app = XCUIApplication(); app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "--qa-pager-touch-trace", "--qa-caption-hit174", "-muted", "YES"]
        app.launchArguments += extra
        if compact { app.launchArguments += ["--qa-theme-compact"] }
        // Enter settings through the timeline without recording a new inline
        // viewing session over the seeded video checkpoint.
        if route == "history-resume" {
            app.launchArguments += ["-timeline.presentation", "grid", "-civitviewer.automaticRotation", "NO"]
        }
        if route == "timeline-resume" { app.launchArguments += ["--qa-chrome-geometry", "-civitviewer.automaticRotation", "NO"] }
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let videoStart = route == "author-video" || route == "collections-video" || route == "history-resume" || route == "timeline-resume"
        let start = 28_037_100 + (videoStart ? 2 : 0)
        heightOpen(route, expected: start)
        heightAssert(route, phase: "entry", expected: start)
        if route == "timeline-resume" { assertVideoReachesVerticalEdges() }
        heightCloseNotices()
        let next = videoStart ? 28_037_104 : start + 1
        heightDeck().swipeUp()
        heightAssert(route, phase: "next", expected: next)
        heightDeck().swipeDown()
        heightAssert(route, phase: "previous", expected: start)
        if !videoStart && route != "author" {
            heightDeck().swipeUp(); heightAssert(route, phase: "shorter-image", expected: start + 1)
            heightDeck().swipeUp(); heightAssert(route, phase: "third-image", expected: start + 3)
            heightDeck().swipeDown(); heightDeck().swipeDown()
            heightAssert(route, phase: "return-first", expected: start)
        }
        let details = app.buttons.matching(NSPredicate(format: "label == %@", "作品详情")).allElementsBoundByIndex.first(where: { $0.isHittable })
        XCTAssertNotNil(details); details?.tap()
        XCTAssertTrue(floatingPageTitle("作品详情").waitForExistence(timeout: 5))
        let detailsBack = app.buttons["details.back"]
        detailsBack.tap()
        XCTAssertTrue(detailsBack.waitForNonExistence(timeout: 5), "Details must finish closing before the next media gesture")
        heightAssert(route, phase: "details-return", expected: start)
        if rotates {
            app.buttons["手动切换横竖屏"].tap()
            heightWaitOrientation(landscape: true)
            heightAssert(route, phase: "landscape", expected: start)
            if route == "history-resume" || route == "timeline-resume" {
                visualOpenDetails(itemID: start)
                let window = app.windows.firstMatch
                XCTAssertGreaterThan(window.frame.width, window.frame.height, "Full-screen details must preserve manual landscape")
                visualCloseDetails()
                XCTAssertGreaterThan(window.frame.width, window.frame.height, "Closing details must restore the landscape player")
                heightAssert(route, phase: "landscape-details-return", expected: start)
                if route == "timeline-resume" {
                    waitUntil("The landscape video is ready before opening saved conditions") {
                        self.playerFields()["ready"] == "true"
                    }
                    if playerFields()["intent"] == "true" { heightDeck().tap() }
                    waitUntil("Pause the video before opening saved conditions") {
                        self.playerFields()["intent"] == "false" && self.playerFields()["rate"] == "0.0"
                    }
                    let seek = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "播放进度")).firstMatch
                    let durationLabel = seek.valueDescription.components(separatedBy: " / ").last ?? ""
                    if let duration = seekSeconds(durationLabel), duration > 2 {
                        seek.coordinate(withNormalizedOffset: CGVector(dx: (duration - 1) / duration, dy: 0.5)).tap()
                        waitUntil("Pause one second before the end") {
                            guard let position = self.playerFields()["nativePosition"].flatMap(Double.init) else { return false }
                            return duration - position > 0.05 && duration - position < 1.95
                        }
                    } else {
                        XCTFail("The fixture must expose a finite duration for the near-end regression")
                    }
                    let pausedAt = Double(playerFields()["nativePosition"] ?? "")
                    XCTAssertNotNil(pausedAt)
                    openTimelineTool("已存条件")
                    let back = app.buttons["preset.library.done"]
                    XCTAssertTrue(back.waitForExistence(timeout: 5))
                    XCTAssertGreaterThan(window.frame.width, window.frame.height, "The saved conditions page should retain manual landscape")
                    back.tap()
                    XCTAssertTrue(back.waitForNonExistence(timeout: 5))
                    XCTAssertGreaterThan(window.frame.width, window.frame.height, "Returning from saved conditions should keep the viewer in landscape")
                    heightAssert(route, phase: "landscape-presets-return", expected: start)
                    waitUntil("Closing saved conditions must preserve the manual pause and playhead") {
                        let state = self.playerFields()
                        guard let pausedAt, let position = Double(state["nativePosition"] ?? "") else { return false }
                        return state["ready"] == "true" && state["intent"] == "false" &&
                            state["rate"] == "0.0" && abs(position - pausedAt) < 0.75
                    }
                }
            }
            app.buttons["手动切换横竖屏"].tap()
            heightWaitOrientation(landscape: false)
            heightAssert(route, phase: "portrait-return", expected: start)
        }
        heightCloseNotices()
        // Tap the exposed media, above the actual footer, rather than a global
        // screen coordinate that may belong to a toolbar or a playback control.
        let deckFrame = heightDeck().frame
        let info = app.buttons.matching(NSPredicate(format: "label == %@", "作品详情")).allElementsBoundByIndex.first(where: { $0.isHittable })!
        let inline = ["recommendation", "following", "timeline-resume"].contains(route)
        let firstY = deckFrame.minY + (inline ? 5 : 115)
        let lastY = info.frame.minY - 8
        XCTAssertGreaterThan(lastY, firstY, "A usable media gesture area must remain between chrome and footer")
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: deckFrame.midX, dy: (firstY + lastY) / 2)).doubleTap()
        XCTAssertTrue(app.descendants(matching: .any)["creator.top-bar"].waitForExistence(timeout: 8))
        if route == "author" || route == "author-video" {
            XCTAssertTrue(app.buttons["playback.close"].waitForNonExistence(timeout: 5), "Returning to the author grid must finish before reopening media")
            XCTAssertTrue(app.buttons["media.grid.cell.\(start)"].waitForExistence(timeout: 5))
            heightTap(app.buttons["media.grid.cell.\(start)"])
        } else {
            let back = app.buttons.matching(identifier: "navigation.back").allElementsBoundByIndex.first(where: { $0.isHittable })
            XCTAssertNotNil(back); back?.tap()
        }
        heightAssert(route, phase: "author-return", expected: start)
        if extra.contains("--qa-terminal-tone175") {
            waitUntil("The visible playback bar releases its completed fallback tone") {
                self.app.staticTexts["playback.tone175"].valueDescription == "idle"
            }
        }
        if !inline {
            let close = app.buttons[route.hasPrefix("history") ? "关闭浏览记录" : "关闭作品"]
            XCTAssertTrue(close.waitForExistence(timeout: 5)); close.tap()
            XCTAssertTrue(close.waitForNonExistence(timeout: 5), "Playback must finish dismissing before reopening its source")
            heightOpen(route, expected: start)
            heightAssert(route, phase: "reentry", expected: start)
        }
        app.terminate()
    }

    private func heightOpen(_ route: String, expected: Int) {
        if ["recommendation", "following", "timeline-grid", "timeline-resume"].contains(route) {
            mainTabButton("时间线").tap()
            let mode = timelineTools()
            XCTAssertTrue(mode.waitForExistence(timeout: 10))
            let wantsGrid = route == "timeline-grid"
            if mode.valueDescription.contains(wantsGrid ? "信息流" : "双列网格") { toggleTimelinePresentation() }
            selectTimelineSource(route == "following" ? "关注" : "推荐")
            if route == "timeline-resume" {
                let resume = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "timeline.resume", "上次推荐")).firstMatch
                XCTAssertTrue(resume.waitForExistence(timeout: 8))
                attachScreenshot(named: "height-timeline-resume-before-tap")
                XCTAssertTrue(resume.isHittable)
                resume.tap()
            } else {
                heightCloseNotices()
                let kind = app.otherElements["timeline.media-kind"].buttons[expected == 28_037_102 ? "视频" : "图片"]
                XCTAssertTrue(kind.waitForExistence(timeout: 5)); kind.tap()
            }
            if wantsGrid { heightTap(app.buttons["media.grid.cell.\(expected)"]) }
            return
        }
        if route.hasPrefix("author") {
            if !app.descendants(matching: .any)["creator.top-bar"].isHittable {
                mainTabButton("作者榜").tap()
                let creator = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Pattern Creator 1")).firstMatch
                heightTap(creator)
                let kind = app.otherElements["creator.media-kind"].buttons[route == "author-video" ? "视频" : "图片"]
                XCTAssertTrue(kind.waitForExistence(timeout: 5)); kind.tap()
            }
            heightTap(visualButton("media.grid.cell.\(expected)")); return
        }
        if route == "search" {
            if !app.scrollViews["search.results"].exists {
                mainTabButton("搜索").tap()
                let field = app.textFields["search-title-input"]
                XCTAssertTrue(field.waitForExistence(timeout: 5))
                if expected == 28_037_102 { chooseSearchMedia("视频") }
                field.tap(); field.typeText("Paging\n")
                XCTAssertTrue(app.descendants(matching: .any)["search.results"].waitForExistence(timeout: 8))
            }
            heightTap(visualButton("media.grid.cell.\(expected)")); return
        }
        if ["collections", "collections-video", "offline"].contains(route) {
            // Offline works are opened from the local collection grid.
            mainTabButton("收藏").tap()
            if expected == 28_037_102 {
                let kind = app.otherElements["collection.media-kind"].buttons["视频"]
                XCTAssertTrue(kind.waitForExistence(timeout: 5)); kind.tap()
            }
            heightTap(visualButton("media.grid.cell.\(expected)"))
        } else {
            if !floatingPageTitle("最近浏览").exists {
                openAccountSettings()
                heightTap(app.buttons["最近浏览与接着看"])
            }
            if route == "history-resume" {
                let videoSubtitle = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "视频 ·")).firstMatch
                XCTAssertTrue(videoSubtitle.waitForExistence(timeout: 5), "The seeded recommendation checkpoint must be a video")
                heightTap(app.buttons.matching(NSPredicate(format: "label == %@", "推荐时间线")).firstMatch)
            } else {
                if expected == 28_037_102 {
                    let kind = app.otherElements["history.media-kind"].buttons["视频"]
                    if !kind.isSelected { heightTap(kind) }
                }
                heightTap(app.buttons["history.item.\(expected)"])
            }
        }
    }

    private func tapAboveMainBar(_ element: XCUIElement) {
        let window = app.windows.firstMatch
        for _ in 0..<12 {
            let bar = mainTabBar()
            if element.exists, element.isHittable, !bar.exists || element.frame.midY < bar.frame.minY - 12 {
                element.tap()
                return
            }
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.40)))
        }
        XCTFail("Page entry is not reachable above the tab bar: \(element.identifier)")
    }

    private func heightTap(_ element: XCUIElement) {
        for _ in 0..<12 {
            if element.exists && element.isHittable { element.tap(); return }
            let down = element.exists && element.frame.maxY < app.windows.firstMatch.frame.midY
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.35 : 0.65))
                .press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.65 : 0.35)))
        }
        XCTFail("Height audit entry is not reachable: \(element.identifier)")
    }

    private func heightDeck() -> XCUIElement {
        let candidates = ["media.viewer.deck", "timeline.media.deck"].flatMap { app.scrollViews.matching(identifier: $0).allElementsBoundByIndex }
        return candidates.first(where: { $0.isHittable }) ?? candidates.first ?? app.scrollViews["media.viewer.deck"]
    }

    private func heightCloseNotices() {
        for id in ["timeline.resume.close", "timeline.notice.close"] {
            let button = app.buttons[id]
            if button.exists && button.isHittable { button.tap() }
        }
    }

    private func heightWaitOrientation(landscape: Bool) {
        let stable = NSPredicate { _, _ in
            let f = self.heightDeck().frame, window = self.app.windows.firstMatch.frame
            return f.width > 0 && f.height > 0 && (window.width > window.height) == landscape
        }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: stable, object: nil)], timeout: 8)
        if result != .completed, app.staticTexts["pager.qa.trace"].exists {
            print("ROTATE174_PARENT " + app.staticTexts["media.qa.parent-ready"].valueDescription)
            print("ROTATE174_TRACE " + app.staticTexts["pager.qa.trace"].valueDescription)
            attachScreenshot(named: "rotation174-failure")
        }
        XCTAssertEqual(result, .completed)
        // The manual app request changes its geometry before the simulator's
        // device orientation. Match the device so screenshots use one orientation.
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
    }

    private func heightAssert(_ route: String, phase: String, expected: Int) {
        let geometries = app.staticTexts.matching(identifier: "collection.qa.geometry")
        let stable = NSPredicate { _, _ in
            geometries.allElementsBoundByIndex.contains { element in
                let v = self.heightValues(element.valueDescription)
                guard Int(v["focused"] ?? 0) == expected,
                      let py = v["pageY"], let vy = v["viewportY"], let ph = v["pageH"], let vh = v["viewportH"],
                      let px = v["pageX"], let vx = v["viewportX"], let pw = v["pageW"], let vw = v["viewportW"] else { return false }
                return vh > 0 && vw > 0 && abs(py-vy) < 1 && abs(ph-vh) < 1 && abs(px-vx) < 1 && abs(pw-vw) < 1 && v["neighborOverlap"] == 0
            }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: stable, object: nil)], timeout: 10), .completed,
                       "\(route)/\(phase) must expose one settled whole page")
        let geometry = geometries.allElementsBoundByIndex.first { Int(heightValues($0.valueDescription)["focused"] ?? 0) == expected }!
        let v = heightValues(geometry.valueDescription)
        if ["recommendation", "following", "timeline-resume"].contains(route) {
            let picker = app.otherElements["timeline.media-kind"].frame
            let tabs = mainTabBar().frame
            XCTAssertLessThanOrEqual(v["viewportY"] ?? 0, picker.minY + 1,
                                     "The stable canvas must extend behind the overlaid header")
            XCTAssertGreaterThanOrEqual((v["viewportY"] ?? 0)+(v["viewportH"] ?? 0), tabs.maxY - 1,
                                        "The stable canvas must extend behind the overlaid bottom tabs")
        }
        let seek = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "播放进度")).allElementsBoundByIndex.first(where: { $0.isHittable })
        if let seek {
            XCTAssertEqual(seek.frame.height, 44, accuracy: 1)
            XCTAssertGreaterThanOrEqual(seek.frame.minY, v["viewportY"] ?? 0)
            XCTAssertLessThanOrEqual(seek.frame.maxY, (v["viewportY"] ?? 0)+(v["viewportH"] ?? 0)+1)
            if ["recommendation", "following", "timeline-resume"].contains(route) {
                XCTAssertLessThanOrEqual(seek.frame.maxY, mainTabBar().frame.minY + 1,
                                         "The seek target must remain above the overlaid tabs")
            }
        }
        print("HEIGHT_AUDIT route=\(route);phase=\(phase);\(geometry.valueDescription)")
        attachScreenshot(named: "height-\(route)-\(phase)")
    }

    private func heightValues(_ text: String) -> [String: Double] {
        Dictionary(text.split(separator: ";").compactMap { item in
            let parts = item.split(separator: "="); guard parts.count == 2, let value = Double(parts[1]) else { return nil }
            return (String(parts[0]), value)
        }, uniquingKeysWith: { _, new in new })
    }

    private func attachScreenshot(named name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("CivitUI37Evidence", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: directory.appendingPathComponent("\(name)-\(UUID().uuidString).png"), options: .atomic)
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func activeMediaDeck() -> XCUIElement {
        let matches = app.scrollViews.matching(identifier: "timeline.media.deck").allElementsBoundByIndex
        return matches.first(where: { $0.isHittable }) ?? app.scrollViews.matching(identifier: "timeline.media.deck").firstMatch
    }

    private func metric(_ name: String, in value: String) -> Int {
        guard let range = value.range(of: #"\b\#(name)=(\d+)"#, options: .regularExpression),
              let digits = value[range].range(of: #"\d+"#, options: .regularExpression) else { return -1 }
        return Int(value[digits]) ?? -1
    }

    private func seekSeconds(_ value: String) -> Double? {
        guard let position = value.components(separatedBy: " / ").first else { return nil }
        let parts = position.split(separator: ":")
        guard parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) else { return nil }
        return minutes * 60 + seconds
    }
}

private extension XCUIElement {
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    func waitForValueToContain(_ value: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate { _, _ in self.valueDescription.contains(value) }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    var valueDescription: String { (value as? String) ?? label }
}
