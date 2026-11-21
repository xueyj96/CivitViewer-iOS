@main struct PageToneClockChecks {
 @MainActor static func main() {
  var n = 0
  func check(_ yes: Bool, _ message: String) { precondition(yes, message); n += 1 }
  let root = PageToneClock(suspended: true)
  check(root.progress == 0, "root starts at source")
  root.suspendLiveUpdatesForRootCanvas()
  check(root.liveUpdatesSuspended, "full canvas owns visible updates")
  var observations = 0
  withObservationTracking { _ = root.progress } onChange: {
   MainActor.assumeIsolated { observations += 1 }
  }
  root.setInteractiveProgress(0.7)
  root.start()
  check(root.startedAt == nil, "hidden live clock does not start")
  check(root.progress == 0, "hidden live tone remains source")
  check(observations == 0, "gesture does not invalidate live tone graph")
  var releases = 0
  _ = root.whenStarted { releases += 1 }
  check(releases == 0, "covered waiter remains held")
  root.finish()
  check(root.finished && !root.liveUpdatesSuspended, "terminal handoff releases suppression")
  check(root.progress == 1, "live target is terminal before exposure")
  check(observations == 1, "terminal target still invalidates consumers")
  check(releases == 1, "terminal waiters release once")
  root.setInteractiveProgress(0.2); root.start(); root.finish()
  check(root.progress == 1 && releases == 1, "late updates cannot revive finished clock")
  let bodyReturn = PageToneClock(suspended: true)
  bodyReturn.setInteractiveProgress(0.35)
  check(bodyReturn.progress == 0.35, "nonroot gesture still tracks tone")
  bodyReturn.start()
  check(bodyReturn.startedAt != nil && bodyReturn.progress >= 0.35, "nonroot time animation still resumes")
  let cancelling = PageToneClock(suspended: true)
  cancelling.suspendLiveUpdatesForRootCanvas(); cancelling.finish()
  check(!cancelling.liveUpdatesSuspended && cancelling.finished, "cancel cleanup leaves no suspension")
  print("PageToneClock175 checks passed: \(n)")
 }
}
