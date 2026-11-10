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
        visualLaunch(width: 0, large: false, landscape: false, extra: ["-muted", "YES", "--qa-continuous59", "-civitviewer.automaticRotation", "NO"])
        app.otherElements["timeline.media-kind"].buttons["视频"].tap()
        waitPlayingFixture()
        let name = "Video-" + String(UUID().uuidString.prefix(6))
        openTimelineTool("已存条件")
        XCTAssertTrue(app.descendants(matching: .any)["preset.library"].waitForExistence(timeout: 5))
        savePreset59(name)
        XCTAssertTrue(presetRow59(name).valueDescription.contains("当前筛选"))
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
        // The timeline's icon hit regions extend 4 pt beyond their visible edges.
        let timelineHeader = app.buttons["timeline.account"].frame.union(timelineTools().frame).insetBy(dx: 4, dy: 0)
        for (tab, headerID) in [("作者榜", "leaderboard.top-bar"), ("搜索", "search.top-bar"), ("收藏", "collections.top-bar")] {
            mainTabButton(tab).tap()
            let header = app.otherElements[headerID]
            XCTAssertTrue(header.waitForExistence(timeout: 5), tab)
            let window = app.windows.firstMatch.frame
            XCTAssertGreaterThan(window.width, window.height, tab)
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
        app.launchArguments = ["--qa-collection-paging", "--qa-theme-ui", "--qa-style48", "-muted", "YES", "-app.appearance", "dark"]
        app.launch(); mainTabButton("搜索").tap()
        let title = app.textFields["search-title-input"]
        XCTAssertTrue(title.waitForExistence(timeout: 6)); title.tap(); title.typeText("City")
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
        let name = "Night-" + String(UUID().uuidString.prefix(6)); savePreset59(name)
        app.buttons["preset.library.done"].tap()
        let clear = app.buttons["清空全部条件"]
        if !clear.isHittable { app.swipeDown() }; XCTAssertTrue(clear.isHittable); clear.tap()
        app.buttons["search.presets"].tap(); XCTAssertTrue(presetRow59(name).waitForExistence(timeout: 5)); presetRow59(name).tap()
        XCTAssertEqual(title.value as? String, "City")
        XCTAssertTrue(app.buttons["移除搜索标签 portrait"].exists); XCTAssertTrue(app.buttons["移除搜索标签 night"].exists)
        XCTAssertTrue(range.label.contains("视频") && range.label.contains("本月") && range.label.contains("热度"))
        XCTAssertFalse(app.descendants(matching: .any)["search.results"].exists, "Loading a saved search must leave explicit search under user control")
        attachScreenshot(named: "presets59-search-complete-conditions-restored")
        let submit = app.buttons["search-submit"]
        if !submit.isHittable { app.swipeUp() }; XCTAssertTrue(submit.isEnabled); submit.tap()
        XCTAssertTrue(app.descendants(matching: .any)["search.results"].waitForExistence(timeout: 8))
        XCTAssertTrue(title.isHittable)
        attachScreenshot(named: "presets59-search-results-with-saved-range")
        app.buttons["search.presets"].tap()
        let presetHeader = floatingPageTitle("已存条件 · 搜索")
        XCTAssertTrue(presetHeader.waitForExistence(timeout: 5))
        XCTAssertTrue(presetRow59(name).exists)
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
        XCTAssertGreaterThanOrEqual(unknown.frame.height, 44)
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
        let selectedLabel = "移除搜索标签 " + sparse.label
        back.tap()
        XCTAssertTrue(app.buttons["search-tag-picker"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons[selectedLabel].exists)
        app.buttons["search-tag-picker"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.buttons["全部标签"].tap()
        XCTAssertTrue(sparse.waitForExistence(timeout: 5))
        XCTAssertFalse(sparse.valueDescription.contains("已选择"))
        sparse.tap()
        done.tap()
        XCTAssertTrue(app.buttons[selectedLabel].waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.buttons["移除搜索标签 paging fixture 01"].waitForExistence(timeout: 5))
    }

    func testTags70RequiresBothMediaToWithdrawLocalSuggestion() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-theme-ui", "--qa-tag-availability55", "--qa-tag-empty-result56", "-muted", "YES"]
        app.launch()
        mainTabButton("搜索").tap(); app.buttons["search-tag-picker"].tap()
        let tag = app.buttons["tag-directory.tag.42001"]
        XCTAssertTrue(tag.waitForExistence(timeout: 8)); tag.tap(); app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["移除搜索标签 portrait"].waitForExistence(timeout: 5))
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
        app.buttons["移除搜索标签 portrait"].tap()
        app.buttons["search-tag-picker"].tap()
        XCTAssertTrue(tag.waitForExistence(timeout: 8), "An empty image search alone cannot rule out video matches")
        tag.tap(); app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["移除搜索标签 portrait"].waitForExistence(timeout: 5))
        waitUntil("Search is ready for the second tag request") { submit.isHittable && submit.isEnabled }
        submit.tap()
        XCTAssertTrue(empty.waitForExistence(timeout: 8))
        chooseSearchMedia("视频")
        XCTAssertTrue(app.buttons["search.range"].label.contains("视频"))
        XCTAssertTrue(empty.waitForExistence(timeout: 8))
        app.buttons["移除搜索标签 portrait"].tap()
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
        launchQA("restart-recommendation")
        let state = app.descendants(matching: .any)["qa-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 10))
        XCTAssertTrue(state.waitForValueToContain("recQueueCount=5", timeout: 15), "Recommendation lane must be seeded; state=\(state.valueDescription)")
        let initialState = state.valueDescription
        XCTAssertTrue(initialState.contains("recFocus=28029101"))
        XCTAssertTrue(initialState.contains("recCursor=qa-next"))
        XCTAssertTrue(initialState.contains("recQueueCount=5"))

        mainTabButton("作者榜").doubleTap()
        mainTabButton("时间线").tap()
        XCTAssertTrue(state.valueDescription.contains("recFirstPageRequests=0"), "Other tab double tap must not restart")
        XCTAssertTrue(state.valueDescription.contains("recFocus=28029101"), "Single selection must preserve focus")
        XCTAssertTrue(state.valueDescription.contains("recCursor=qa-next"), "Single selection must preserve the old cursor")
        XCTAssertTrue(state.valueDescription.contains("recQueueCount=5"), "Single selection must preserve the loaded queue")

        mainTabButton("作者榜").tap()
        XCTAssertTrue(state.valueDescription.contains("recFirstPageRequests=0"), "Leaving Timeline must not request a page")
        let timelineTab = mainTabButton("时间线")
        timelineTab.doubleTap()
        XCTAssertTrue(state.waitForValueToContain("recFirstPageRequests=1", timeout: 10), "Real timeline double tap from Works should issue one first-page request")
        XCTAssertTrue(state.valueDescription.contains("recCursor=nil"), "Restart request must leave the recommendation lane at its initial-page cursor")
        XCTAssertTrue(state.valueDescription.contains("recFocus=28029101"), "A successful restart should focus the first returned item")
        XCTAssertTrue(state.valueDescription.contains("recQueueCount=5"), "The refreshed queue should contain only the new first page")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(state.valueDescription.contains("recFirstPageRequests=1"), "One double tap must not issue duplicate first-page requests")
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

        let beforeLeaving = state.valueDescription
        let firstPageBeforeLeaving = metric("firstPageRequests", in: beforeLeaving)
        let requestsBeforeLeaving = metric("pageRequests", in: beforeLeaving)
        mainTabButton("作者榜").tap()
        let afterSingleWorksTap = state.valueDescription
        XCTAssertEqual(metric("firstPageRequests", in: afterSingleWorksTap), firstPageBeforeLeaving, "Single navigation to Works must not issue a first-page request")
        XCTAssertEqual(metric("pageRequests", in: afterSingleWorksTap), requestsBeforeLeaving, "Single navigation to Works must preserve the request count")
        mainTabButton("时间线").doubleTap()
        XCTAssertTrue(state.waitForValueToContain("lastSource=following", timeout: 15))
        let readback = state.valueDescription
        XCTAssertTrue(readback.contains("lastSource=following"), "Refresh from Works must apply to the active followed lane")
        XCTAssertTrue(readback.contains("lastKind=video;lastSort=Most Comments;lastPeriod=Month"), "Refresh must retain filter and sort")
        XCTAssertTrue(readback.contains("lastCursor=nil"), "Refresh must discard the old continuation cursor")
        XCTAssertTrue(readback.contains("followFocus=28029101"), "The first returned item should become focused")
        XCTAssertTrue(readback.contains("followQueueCount=5"), "The refreshed queue should use the first page")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(metric("firstPageRequests", in: state.valueDescription) - metric("firstPageRequests", in: afterSingleWorksTap), 1,
                       "One double tap from Works must issue exactly one new first-page request")
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
        let manage = mainTabBar().buttons["collection-batch.manage"]
        XCTAssertTrue(manage.waitForExistence(timeout: 5))
        XCTAssertEqual(mainTabBar().frame, originalBar)
        XCTAssertEqual(manage.label, "管理 1")
        XCTAssertEqual(first.frame.width, original.width, accuracy: 1)
        XCTAssertEqual(first.frame.minY, original.minY, accuracy: 1)
        XCTAssertFalse(app.buttons["关闭作品"].exists)
        second.tap()
        XCTAssertEqual(manage.label, "管理 2")
        manage.tap()
        let remove = mainTabBar().buttons["collection-batch.remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        XCTAssertEqual(mainTabBar().frame, originalBar, "Management changes only the buttons inside the bar")
        XCTAssertEqual(first.frame.minY, original.minY, accuracy: 1)
        attachScreenshot(named: "favorites-collection-manage-in-bottom-bar")
        remove.tap()
        XCTAssertTrue(floatingPageTitle("批量移除").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["分页测试收藏"].exists)
        XCTAssertFalse(app.staticTexts["另一个收藏夹"].exists)
        let save = app.buttons["favorite-batch.save"]
        waitUntil("The current folder has been verified") { save.isEnabled }
        save.tap()
        waitUntil("After partial removal only the unconfirmed work remains") {
            self.app.staticTexts["待移除 1 项作品"].exists && save.label == "重试"
        }
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
        let entry = history.buttons["favorite-batch.select"]
        XCTAssertTrue(entry.waitForExistence(timeout: 8))
        entry.tap()
        heightTap(app.buttons["history.item.28037100"])
        heightTap(app.buttons["history.item.28037101"])
        let selection = history.buttons["favorite-batch.open"]
        XCTAssertEqual(selection.label, "收藏 2")
        attachScreenshot(named: "favorites86-history-selection")
        selection.tap()
        let save = app.buttons["favorite-batch.save"]
        waitUntil("Default folder is ready") { save.exists && save.isEnabled }
        save.tap()
        XCTAssertTrue(app.staticTexts["已收藏 2 项作品"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
    }

    func testFavoritesRestoreCachedListBeforeFreshAccountResponse() {
        app = XCUIApplication()
        let cache = "--qa-collection-cache-key=\(UUID().uuidString)"
        let common = ["--qa-collection-paging", "--qa-visual-controls", cache,
                      "-app.appearance", "light", "-muted", "YES", "-autoplay", "NO"]
        XCUIDevice.shared.orientation = .portrait
        let previous = app.buttons["media.grid.cell.28037100"]
        let fresh = app.buttons["media.grid.cell.28037106"]
        let receipt = app.staticTexts["collection-cache.qa"]

        app.launchArguments = common
        app.launch()
        let favorites = mainTabButton("收藏")
        XCTAssertTrue(favorites.waitForExistence(timeout: 8))
        let coldStart = ProcessInfo.processInfo.systemUptime
        favorites.tap()
        XCTAssertFalse(previous.exists, "The cold list has to wait for the controlled server reads")
        XCTAssertTrue(previous.waitForExistence(timeout: 12))
        let coldFirstPaint = ProcessInfo.processInfo.systemUptime - coldStart
        waitUntil("The first confirmed list must be persisted before relaunching") { receipt.exists && receipt.label == "stored" }

        app.terminate()
        app.launchArguments = common + ["--qa-collection-cache-update"]
        app.launch()
        XCTAssertTrue(favorites.waitForExistence(timeout: 8))
        let warmStart = ProcessInfo.processInfo.systemUptime
        favorites.tap()
        XCTAssertTrue(previous.waitForExistence(timeout: 3), "The previous list should appear while folders and works still wait on the server")
        let warmFirstPaint = ProcessInfo.processInfo.systemUptime - warmStart
        XCTAssertFalse(fresh.exists)
        XCTAssertLessThan(warmFirstPaint, coldFirstPaint)
        attachScreenshot(named: "collection90-cached-before-network")
        XCTAssertTrue(fresh.waitForExistence(timeout: 12))
        XCTAssertFalse(previous.exists, "A work removed upstream should disappear after reconciliation")
        waitUntil("The refreshed list replaces the stored preview") { receipt.exists && receipt.label == "stored" }
        print("COLLECTION_CACHE_FIRST_PAINT cold=\(coldFirstPaint);warm=\(warmFirstPaint)")
        attachScreenshot(named: "collection90-reconciled")
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
            // Scope this action to the focused work and its production label;
            // a parent SwiftUI identifier can shadow this button's own identifier.
            let favorite = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "收藏", "main.tab.3"))
                .allElementsBoundByIndex.first(where: { $0.isHittable })
            XCTAssertNotNil(favorite); if let favorite { openFavoriteFolders(favorite) }
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
        let option = app.buttons[title]
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

    func testTimelineEdgeSwipeUsesStartingHalf() {
        visualLaunch(width: 0, large: false, landscape: false, extra: ["--qa-pager-touch-trace", "-muted", "YES", "-autoplay", "YES"])
        let source = app.otherElements["timeline.source"], media = app.otherElements["timeline.media-kind"]
        let window = app.windows.firstMatch
        func drag(from x: CGFloat, _ y: CGFloat, to endX: CGFloat, _ endY: CGFloat) {
            window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: endX, dy: endY)))
        }
        XCTAssertTrue(source.buttons["推荐"].isSelected && media.buttons["图片"].isSelected)
        let trace = app.staticTexts["pager.qa.trace"]
        let initialX = heightDeck().frame.minX
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.34))
            .press(forDuration: 0.05,
                   thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.02 + 40 / window.frame.width, dy: 0.34)),
                   withVelocity: XCUIGestureVelocity(rawValue: 90), thenHoldForDuration: 0.35)
        let shortDrag = try? JSONSerialization.jsonObject(with: Data(trace.valueDescription.utf8)) as? [String: Any]
        let events = shortDrag?["events"] as? [[String: Any]] ?? []
        let shiftedViewport = events.contains { event in
            guard event["event"] as? String == "window.action", event["name"] as? String == "pan",
                  event["state"] as? Int == 2, let native = event["native"] as? [String: Any],
                  let viewport = native["viewportWindow"] as? [String: Double], let x = viewport["x"] else { return false }
            return x > initialX + 8
        }
        if !shiftedViewport { attachEdgeTrace("short-drag-motion") }
        XCTAssertTrue(shiftedViewport, "The actual media viewport must move before the finger lifts")
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
        app.launchArguments = ["--qa-collection-paging", "--qa-style49", "-app.appearance", "dark", "-muted", "YES"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        openAccountSettings()
        assertCompactSettingsHeader(phase: "initial-dark")
        mainTabButton("收藏").tap()
        mainTabButton("时间线").tap()
        assertCompactSettingsHeader(phase: "return-from-timeline-dark")
        app.swipeDown()
        assertCompactSettingsHeader(phase: "after-pull-down-dark")
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
        app.buttons["preset.library.save"].tap()
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
        let authorField = app.textFields["输入作者昵称"]
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
        visualLaunch(width: 0, large: false, landscape: false)
        openAccountSettings()
        let settings = floatingPageTitle("账号与设置")
        let reference = settings.frame

        for (entry, title) in [
            ("账号内容偏好", "账号内容偏好"),
            ("关注的作者", "我的关注"),
            ("离线收藏与空间管理", "离线收藏与空间"),
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
            XCTAssertEqual(header.staticTexts[title].frame.midX, header.frame.midX, accuracy: 1, entry)
            let cardListIDs = ["我的关注": "following.card-list",
                               "离线收藏与空间": "offline.storage-list",
                               "本机诊断记录": "diagnostics.card-list"]
            if let id = cardListIDs[title] {
                let list = app.descendants(matching: .any).matching(identifier: id).firstMatch
                XCTAssertTrue(list.waitForExistence(timeout: 5), title)
                XCTAssertLessThanOrEqual(list.frame.maxY, mainTabBar().frame.minY + 1, title)
            }
            attachScreenshot(named: "settings-child-" + title)
            let back = header.buttons["navigation.back"]
            XCTAssertTrue(back.waitForExistence(timeout: 5), entry)
            back.tap()
            XCTAssertTrue(settings.waitForExistence(timeout: 5), entry)
        }
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
        XCTAssertTrue(app.descendants(matching: .any)["feed.continuation.error"].firstMatch.waitForExistence(timeout: 3))
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
        app.launchArguments = ["--qa-collection-paging", "--qa-compatibility-template", "-muted", "YES", "-autoplay", "NO"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(mainTabButton("收藏").waitForExistence(timeout: 8))
        heightOpen("collections", expected: 28_037_102)
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

    private func visualLaunch(width: Int, large: Bool, landscape: Bool, state: String? = nil, extra: [String] = []) {
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
        XCTAssertTrue(visualButton("media.details.28037100").waitForExistence(timeout: 10))
        if landscape { visualEnsureLandscape() }
    }

    private func visualEnsureLandscape() {
        let frame = heightDeck().frame
        if frame.width <= frame.height {
            let active = app.buttons.matching(NSPredicate(format: "label == %@", "手动切换横竖屏")).allElementsBoundByIndex.filter { $0.isHittable }
            XCTAssertEqual(active.count, 1, "Only the currently visible lane may supply the rotation action")
            guard let rotate = active.first else { return }
            rotate.tap(); heightWaitOrientation(landscape: true)
        }
        let stable = NSPredicate { _, _ in let frame = self.heightDeck().frame; return frame.width > frame.height && frame.height > 0 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: stable, object: nil)], timeout: 5), .completed)
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
        visualLaunch(width: 0, large: false, landscape: false)
        openAccountSettings()
        heightTap(app.buttons["settings.media-rail"])
        let settings = floatingPageTitle("播放侧栏")
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["settings.media-rail.cleanImage"].exists)
        let reset = app.buttons["settings.media-rail.reset"]
        if reset.exists { reset.tap() }
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
        XCTAssertTrue(reset.isHittable)
        XCTAssertEqual(detailsVisibility.value as? String, "0")
        reset.tap()
        waitUntil("Reset restores both visibility and order") {
            detailsVisibility.value as? String == "1" && !reset.exists
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
        app.buttons["近 24 小时"].tap()
        let spinner = app.descendants(matching: .any)["leaderboard.activity.loading"].firstMatch
        XCTAssertTrue(spinner.waitForExistence(timeout: 4))
        XCTAssertLessThanOrEqual(spinner.frame.width, 28)
        XCTAssertLessThanOrEqual(spinner.frame.height, 28)
        attachScreenshot(named: "author70-small-inline-loading")
        let summary = app.descendants(matching: .any)["leaderboard.activity.summary"].firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 8))
        waitUntil("Only the bounded first forty authors are checked") { summary.valueDescription.contains("符合 10 位") && summary.valueDescription.contains("40/1,000") }
        let first = app.buttons["leaderboard.author.59004"]
        XCTAssertTrue(first.exists && first.isHittable)
        XCTAssertLessThan(first.frame.minY, app.frame.height * 0.45, "The results begin in the upper half of the screen")
        XCTAssertFalse(app.buttons["leaderboard.activity.more"].exists)
        attachScreenshot(named: "author70-results")
        app.buttons["leaderboard.activity.next"].tap()
        waitUntil("An explicit next batch checks forty more and preserves the denominator") { summary.valueDescription.contains("符合 20 位") && summary.valueDescription.contains("80/1,000") }
        XCTAssertTrue(first.exists)
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
            XCTAssertEqual(app.buttons["search-submit"].frame.minX, range.frame.minX, accuracy: 1)
            XCTAssertEqual(app.buttons["search.presets"].frame.maxX, range.frame.maxX, accuracy: 1)
            author.tap()
            let authorHeader = floatingPageTitle("选择作者")
            XCTAssertTrue(authorHeader.waitForExistence(timeout: 5))
            XCTAssertTrue(app.textFields["输入作者昵称"].exists)
            let authorField = app.descendants(matching: .any).matching(identifier: "author-picker.field").firstMatch
            XCTAssertEqual(authorField.frame.minX, authorHeader.frame.minX, accuracy: 1)
            XCTAssertEqual(authorField.frame.maxX, authorHeader.frame.maxX, accuracy: 1)
            XCTAssertTrue(mainTabButton("搜索").isHittable)
            XCTAssertTrue(authorHeader.buttons["navigation.back"].isHittable)
            attachScreenshot(named: "style48-\(appearance)-author-picker")
            authorHeader.buttons["navigation.back"].tap()
            let picker = app.buttons["search-tag-picker"]
            XCTAssertTrue(picker.isHittable); picker.tap()
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
            XCTAssertTrue(app.buttons["移除搜索标签 portrait"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["移除搜索标签 night"].exists)
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

    func testAuthorSelectionCommitsOnlyOnDone() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "-app.appearance", "light", "-muted", "YES"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        mainTabButton("搜索").tap()
        let picker = app.buttons["search-author-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let field = app.textFields["输入作者昵称"]
        let result = app.buttons["author-picker.author.28037001"]
        let done = app.buttons["author-picker.done"]

        func chooseDraft() {
            picker.tap()
            XCTAssertTrue(done.waitForExistence(timeout: 5))
            XCTAssertFalse(done.isEnabled)
            field.tap()
            field.typeText("PagingFixture")
            XCTAssertTrue(result.waitForExistence(timeout: 6))
            result.tap()
            XCTAssertTrue(done.isEnabled)
        }

        chooseDraft()
        floatingPageTitle("选择作者").buttons["navigation.back"].tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertEqual(picker.value as? String, "未选择")
        chooseDraft()
        done.tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertEqual(picker.value as? String, "@PagingFixture")
    }

    func testDownloadsBackAndTabSwitchKeepTheirNavigationContexts() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-download-tasks", "-app.appearance", "light",
                               "-muted", "YES", "-autoplay", "NO"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let collection = app.otherElements["collections.top-bar"]
        let downloads = collection.buttons["collections.downloads"]
        let header = floatingPageTitle("下载管理")
        XCTAssertTrue(downloads.waitForExistence(timeout: 8))
        downloads.tap()
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        header.buttons["navigation.back"].tap()
        XCTAssertTrue(downloads.waitForExistence(timeout: 5))
        mainTabButton("时间线").tap()
        XCTAssertTrue(timelineTools().waitForExistence(timeout: 5))
        mainTabButton("收藏").tap()
        XCTAssertTrue(downloads.waitForExistence(timeout: 5))
        downloads.tap()
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        mainTabButton("搜索").tap()
        XCTAssertTrue(app.otherElements["search.top-bar"].waitForExistence(timeout: 5))
        XCTAssertFalse(header.isHittable)
        mainTabButton("收藏").tap()
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        let back = header.buttons["navigation.back"]
        XCTAssertTrue(back.isHittable)
        back.tap()
        let video = app.otherElements["collection.media-kind"].buttons["视频"]
        XCTAssertTrue(video.waitForExistence(timeout: 5))
        video.tap()
        let work = app.buttons["media.grid.cell.28037102"]
        XCTAssertTrue(work.waitForExistence(timeout: 5))
        work.tap()
        let playerTabs = app.descendants(matching: .any)["playback.tabs"]
        let search = playerTabs.buttons["main.tab.4"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        XCTAssertTrue(app.otherElements["search.top-bar"].waitForExistence(timeout: 5))
        XCTAssertFalse(playerTabs.isHittable)
        mainTabButton("收藏").tap()
        XCTAssertTrue(downloads.waitForExistence(timeout: 5))
        downloads.tap()
        XCTAssertTrue(header.waitForExistence(timeout: 5))
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
        let alert = app.alerts["Civit Viewer"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertTrue(alert.staticTexts["收藏结果尚未确认，请刷新收藏状态后再操作。"].exists)
        XCTAssertTrue(app.staticTexts["favorite69.qa.state"].valueDescription.contains("pending=-1;saved=false;message=true"))
        attachScreenshot(named: "favorite69-failed-save-stays-actionable")
        alert.buttons["好"].tap()
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
        let alert = app.alerts["Civit Viewer"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "A save failure must remain visible above an author work's full-screen presentation")
        XCTAssertTrue(alert.staticTexts["收藏结果尚未确认，请刷新收藏状态后再操作。"].exists)
        attachScreenshot(named: "favorite69-failure-above-author-work")
        alert.buttons["好"].tap()
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

    func testAuthorPageCenterSwipesChangeMediaAndLeftEdgeReturns() {
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
        waitUntil("Cancelling the edge return restores the author header") {
            authorBar.buttons["navigation.back"].isHittable
        }
        XCTAssertEqual(authorBar.frame.minX, beforeCancel.minX, accuracy: 1)
        XCTAssertEqual(authorBar.frame.minY, beforeCancel.minY, accuracy: 1)

        swipe(from: 28 / window.frame.width, 0.52, to: 0.84, 0.52)
        XCTAssertTrue(authorBar.waitForNonExistence(timeout: 5), "A left-edge pan returns through the native navigation stack")
        waitUntil("The same timeline item is visible after the return") {
            self.visualButton("media.author.28037100").isHittable && self.watchFocus() == 28_037_100
        }
        XCTAssertTrue(app.otherElements["timeline.media-kind"].buttons["图片"].isSelected)
    }

    func testTabSwitchAfterOpeningAuthorKeepsSearchHeaderHittable() {
        visualLaunch(width: 0, large: false, landscape: false, extra: ["-muted", "YES", "-autoplay", "NO"])
        let window = app.windows.firstMatch
        let searchTab = mainTabButton("搜索")
        let searchPosition = searchTab.frame
        let searchCoordinate = window.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: searchPosition.midX - window.frame.minX, dy: searchPosition.midY - window.frame.minY)
        )

        visualButton("media.author.28037100").tap()
        searchCoordinate.tap()

        let searchHeader = app.otherElements["search.top-bar"]
        XCTAssertTrue(searchHeader.waitForExistence(timeout: 8))
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
        visualLaunch(width: 0, large: false, landscape: false, extra: ["--qa-details-tags", "-muted", "YES"])
        app.otherElements["timeline.media-kind"].buttons["视频"].tap()
        app.buttons.matching(NSPredicate(format: "label == %@", "作品详情")).firstMatch.tap()
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
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "移除搜索标签 ")).count, 2,
                       "Both selected real tags should navigate as initial AND criteria")
        XCTAssertTrue(app.buttons["search-submit"].exists)
        attachScreenshot(named: "layout41-details-combined-search")
        authors.tap()
        XCTAssertTrue(app.otherElements["leaderboard.top-bar"].waitForExistence(timeout: 5))
        XCTAssertFalse(tabs.isHittable)
        XCTAssertTrue(mainTabButton("作者榜").isSelected)
    }

    func testDetailsTagRefreshFailureLeavesWorkCardWithoutTagControls() {
        visualLaunch(width: 0, large: false, landscape: false, extra: ["--qa-details-tags", "--qa-details-tags-failure"])
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
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "--qa-details-tags", "-muted", "YES", "-autoplay", "NO"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        heightOpen("offline", expected: 28_037_102)
        let playback = floatingPageTitle("离线播放")
        let share = playback.buttons["playback.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        visualOpenDetails(itemID: 28_037_102)
        let tag = app.buttons["details.tag.portrait"]
        XCTAssertTrue(tag.waitForExistence(timeout: 5))
        tag.press(forDuration: 0.8)
        app.buttons["屏蔽此标签"].tap()
        app.buttons["details.back"].tap()
        XCTAssertTrue(app.staticTexts["media.empty.message"].waitForExistence(timeout: 5))
        XCTAssertFalse(share.isHittable)
        let close = playback.buttons["offline.playback.close"]
        XCTAssertTrue(close.isHittable); close.tap()

        app.buttons["navigation.back"].tap()
        tapAboveMainBar(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "屏蔽标签")).firstMatch)
        let remove = app.buttons["删除屏蔽标签 portrait"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
    }

    func testOfflineAndHistoryUseSharedPlaybackAndDetailTabs() {
        app = XCUIApplication()
        app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "-muted", "YES", "-autoplay", "NO"]
        for (route, title) in [("offline", "离线播放"), ("history", "最近浏览")] {
            XCUIDevice.shared.orientation = .portrait
            app.launch()
            heightOpen(route, expected: 28_037_102)
            let tabs = app.descendants(matching: .any)["playback.tabs"]
            XCTAssertTrue(tabs.waitForExistence(timeout: 8), route)
            XCTAssertTrue(tabs.buttons["main.tab.timeline"].isSelected)
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
        XCTAssertTrue(app.descendants(matching: .any)["feed.continuation.error"].exists)
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
        app = XCUIApplication(); app.launchArguments = ["--qa-collection-paging", "--qa-theme-timeline", "--qa-auto-continuation=\(scenario)", "-timeline.presentation", "stream"]
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
    private func waitUntil(_ message: String, timeout: TimeInterval = 8, _ predicate: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
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

    func testWatchingViewportOtherEntriesHeightAndRotation() {
        for route in ["author", "author-video", "search", "collections", "offline", "history", "history-resume"] {
            auditWatchingRoute(route, rotates: ["author-video", "offline", "history-resume"].contains(route))
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

        let close = app.buttons["offline.playback.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["离线播放"].exists)
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
        XCTAssertTrue(floatingPageTitle("离线收藏与空间").waitForExistence(timeout: 5))
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

    private func auditWatchingRoute(_ route: String, rotates: Bool, compact: Bool = false) {
        app = XCUIApplication(); app.launchArguments = ["--qa-collection-paging", "--qa-height-audit", "-muted", "YES"]
        if compact { app.launchArguments += ["--qa-theme-compact"] }
        // Enter settings through the timeline without recording a new inline
        // viewing session over the seeded video checkpoint.
        if route == "history-resume" {
            app.launchArguments += ["-timeline.presentation", "grid", "-civitviewer.automaticRotation", "NO"]
        }
        if route == "timeline-resume" { app.launchArguments += ["--qa-chrome-geometry", "-civitviewer.automaticRotation", "NO"] }
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let videoStart = route == "author-video" || route == "history-resume" || route == "timeline-resume"
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
        app.buttons["details.back"].tap()
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
            XCTAssertTrue(app.buttons["media.grid.cell.\(start)"].waitForExistence(timeout: 5))
            heightTap(app.buttons["media.grid.cell.\(start)"])
        } else {
            let back = app.buttons.matching(identifier: "navigation.back").allElementsBoundByIndex.first(where: { $0.isHittable })
            XCTAssertNotNil(back); back?.tap()
        }
        heightAssert(route, phase: "author-return", expected: start)
        if !inline {
            let close = app.buttons[route.hasPrefix("history") ? "关闭浏览记录" : "关闭作品"]
            XCTAssertTrue(close.waitForExistence(timeout: 5)); close.tap()
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
            if !app.descendants(matching: .any)["search.results"].isHittable {
                mainTabButton("搜索").tap()
                let field = app.textFields["search-title-input"]
                XCTAssertTrue(field.waitForExistence(timeout: 5))
                if expected == 28_037_102 { chooseSearchMedia("视频") }
                field.tap(); field.typeText("Paging\n")
                XCTAssertTrue(app.descendants(matching: .any)["search.results"].waitForExistence(timeout: 8))
            }
            heightTap(visualButton("media.grid.cell.\(expected)")); return
        }
        if route == "collections" {
            mainTabButton("收藏").tap()
            if expected == 28_037_102 {
                let kind = app.otherElements["collection.media-kind"].buttons["视频"]
                XCTAssertTrue(kind.waitForExistence(timeout: 5)); kind.tap()
            }
            heightTap(visualButton("media.grid.cell.\(expected)"))
        } else if route == "offline" {
            let row = app.buttons["offline.item.\(expected)"]
            if !floatingPageTitle("离线收藏与空间").exists {
                openAccountSettings()
                heightTap(app.buttons["settings.offline-library"])
            }
            if expected == 28_037_102 {
                let kind = app.otherElements["offline.media-kind"].buttons["视频"]
                if !kind.isSelected { heightTap(kind) }
            }
            tapAboveMainBar(row)
        } else {
            if !floatingPageTitle("最近浏览").exists {
                openAccountSettings()
                heightTap(app.buttons["最近浏览与接着看"])
            }
            if route == "history-resume" {
                let videoCheckpoint = NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "推荐时间线", "视频")
                heightTap(app.buttons.matching(videoCheckpoint).firstMatch)
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
        return candidates.first(where: { $0.isHittable }) ?? app.scrollViews["media.viewer.deck"]
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
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: stable, object: nil)], timeout: 8), .completed)
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
