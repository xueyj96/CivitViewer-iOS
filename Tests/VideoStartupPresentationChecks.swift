import Foundation
// INSERT_STARTUP_POLICY
// INSERT_CACHED_POSTER_IDENTITY
@main struct VideoStartupPresentationChecks {
    static func main() {
        var count = 0
        func check(_ result: Bool, _ description: String) { precondition(result, description);count += 1 }
        let primary = URL(string:"https://fixture.invalid/image-a")!
        let fallbackA = URL(string:"https://fixture.invalid/fallback-a")!
        let fallbackB = URL(string:"https://fixture.invalid/fallback-b")!
        let imageIdentityA = CachedPosterResourceIdentity.image(primary:primary,fallbackURLs:[fallbackA])
        check(imageIdentityA != .image(primary:primary,fallbackURLs:[fallbackB]),"A changed fallback is a distinct image resource identity")
        check(imageIdentityA == .image(primary:primary,fallbackURLs:[fallbackA]),"Same source candidates retain identity across quality-only refresh")
        check(imageIdentityA != .image(primary:primary,fallbackURLs:[fallbackA,fallbackB]),"Every fallback URL participates in image resource identity")
        check(imageIdentityA != .poster(source:primary,declared:fallbackA),"Static image and video poster identities cannot alias")
        check(CachedPosterResourceIdentity.poster(source:primary,declared:fallbackA) != .poster(source:primary,declared:fallbackB),
              "Video poster identity includes its declared resource")
        check(!VideoStartupPolicy.nativeVisible(layerReady:true,itemReady:true,resumePending:false,wantsPlayback:true,nativePlaying:false,committed:false),"Prerolled but paused native frame must not replace the autoplay preview")
        check(VideoStartupPolicy.nativeVisible(layerReady:true,itemReady:true,resumePending:false,wantsPlayback:true,nativePlaying:true,committed:false),"Ready and actually playing may take over immediately")
        check(VideoStartupPolicy.nativeVisible(layerReady:true,itemReady:true,resumePending:false,wantsPlayback:true,nativePlaying:false,committed:true),"Buffering retains an already presented native frame")
        check(VideoStartupPolicy.nativeVisible(layerReady:true,itemReady:true,resumePending:false,wantsPlayback:false,nativePlaying:false,committed:false),"Explicit/autoplay-off pause may present a ready native still")
        for committed in [false,true] {
            check(!VideoStartupPolicy.nativeVisible(layerReady:true,itemReady:true,resumePending:true,wantsPlayback:true,nativePlaying:true,committed:committed),"Resume seek must finish before any native reveal")
            check(!VideoStartupPolicy.nativeVisible(layerReady:false,itemReady:true,resumePending:false,wantsPlayback:true,nativePlaying:true,committed:committed),"A layer without a drawable frame cannot be ready")
            check(!VideoStartupPolicy.nativeVisible(layerReady:true,itemReady:false,resumePending:false,wantsPlayback:true,nativePlaying:true,committed:committed),"Candidate allocation does not qualify an unready item")
        }
        check(VideoStartupPolicy.preview(held:.poster,posterReady:true,transitionReady:true) == .poster,"Late warm frame does not replace a visible poster")
        check(VideoStartupPolicy.preview(held:.transition,posterReady:true,transitionReady:true) == .transition,"Late poster does not replace a visible warm frame")
        check(VideoStartupPolicy.preview(held:nil,posterReady:true,transitionReady:true) == .transition,"Use the prepared video frame when both are available before reveal")
        check(VideoStartupPolicy.preview(held:nil,posterReady:false,transitionReady:false) == nil,"Placeholder is not a committed preview")
        check(VideoStartupPolicy.preview(held:.transition,posterReady:true,transitionReady:false) == .poster,"A removed warm frame can fall back to a valid poster")
        check(VideoStartupPolicy.display(nativeVisible:false,nativeBuffering:false,waiting:true,active:false,sceneActive:true,paused:false,
              selected:.poster,posterAllowed:true,transitionAllowed:false,waitRequested:true) == .poster,
              "A prepared page keeps its actual poster without a waiting indicator")
        check(VideoStartupPolicy.display(nativeVisible:false,nativeBuffering:false,waiting:true,active:true,sceneActive:true,paused:false,
              selected:.transition,posterAllowed:true,transitionAllowed:true,waitRequested:true) == .transition,
              "A transition frame is the sole first-frame preview")
        check(VideoStartupPolicy.display(nativeVisible:false,nativeBuffering:false,waiting:true,active:true,sceneActive:true,paused:false,
              selected:.poster,posterAllowed:true,transitionAllowed:false,waitRequested:true) == .poster,
              "A cover suppresses the first-frame waiting indicator")
        check(VideoStartupPolicy.display(nativeVisible:false,nativeBuffering:false,waiting:true,active:true,sceneActive:true,paused:false,
              selected:nil,posterAllowed:false,transitionAllowed:false,waitRequested:true) == .waiting,
              "An active first-frame wait without an image can show one indicator")
        check(VideoStartupPolicy.display(nativeVisible:false,nativeBuffering:false,waiting:true,active:false,sceneActive:true,paused:false,
              selected:nil,posterAllowed:false,transitionAllowed:false,waitRequested:true) == .neutral,
              "A prepared neighbor without a cover remains neutral and silent")
        check(VideoStartupPolicy.display(nativeVisible:true,nativeBuffering:true,waiting:false,active:true,sceneActive:true,paused:false,
              selected:nil,posterAllowed:false,transitionAllowed:false,waitRequested:true) == .nativeBuffering,
              "A real rebuffer keeps native video with its existing small indicator")
        check(VideoStartupPolicy.display(nativeVisible:true,nativeBuffering:true,waiting:false,active:true,sceneActive:true,paused:true,
              selected:nil,posterAllowed:false,transitionAllowed:false,waitRequested:true) == .native,
              "Pause suppresses a false buffering indicator while retaining native video")
        check(VideoStartupPolicy.display(nativeVisible:false,nativeBuffering:false,waiting:true,active:true,sceneActive:false,paused:false,
              selected:nil,posterAllowed:false,transitionAllowed:false,waitRequested:true) == .neutral,
              "An inactive scene does not show a fake waiting indicator")
        check(!VideoStartupPolicy.pauseVisible(active:true,wantsPlayback:true,failed:false,overlaid:false,seeking:false,restoring:false,hasVisual:true),"Autoplay's initial playing=false is not a user pause")
        check(VideoStartupPolicy.pauseVisible(active:true,wantsPlayback:false,failed:false,overlaid:false,seeking:false,restoring:false,hasVisual:true),"A deliberate pause keeps its control")
        check(!VideoStartupPolicy.pauseVisible(active:true,wantsPlayback:false,failed:false,overlaid:false,seeking:false,restoring:true,hasVisual:true),"No false pause during position restoration")
        let player = NSObject(), item = NSObject(), otherPlayer = NSObject(), otherItem = NSObject()
        let source = URL(fileURLWithPath: "/fixture/a.mp4"), attachment = UUID()
        let identity = VideoLayerReadinessIdentity(player: ObjectIdentifier(player), item: ObjectIdentifier(item),
            attachment: attachment, generation: 1, source: source)
        let gate = VideoLayerReadinessGate()
        let first = gate.bind(identity)
        let queuedFirst = { gate.accepts(first) }
        check(queuedFirst(), "The mounted identity may publish its actual layer readiness")
        check(gate.bind(identity) == first, "Unchanged SwiftUI updates keep the same qualified observer")
        let reattached = gate.bind(.init(player: identity.player, item: identity.item, attachment: UUID(), generation: 1, source: source))
        check(!queuedFirst() && gate.accepts(reattached), "A delayed event from the old attachment cannot write the new binding")
        let newGeneration = gate.bind(.init(player: identity.player, item: identity.item, attachment: reattached.identity.attachment, generation: 2, source: source))
        check(!gate.accepts(reattached) && gate.accepts(newGeneration), "A changed generation replaces the observer qualification")
        let newItem = gate.bind(.init(player: identity.player, item: ObjectIdentifier(otherItem), attachment: attachment, generation: 2, source: source))
        check(!gate.accepts(newGeneration) && gate.accepts(newItem), "A different item cannot receive the previous item's ready event")
        let newPlayer = gate.bind(.init(player: ObjectIdentifier(otherPlayer), item: newItem.identity.item, attachment: attachment, generation: 2, source: source))
        check(!gate.accepts(newItem) && gate.accepts(newPlayer), "A different player cannot receive the previous layer's ready event")
        let newSource = gate.bind(.init(player: newPlayer.identity.player, item: newPlayer.identity.item, attachment: attachment, generation: 2, source: URL(fileURLWithPath: "/fixture/b.mp4")))
        check(!gate.accepts(newPlayer) && gate.accepts(newSource), "A new source invalidates an already queued event")
        gate.invalidate()
        check(!gate.accepts(newSource), "Dismantle prevents all queued callbacks from publishing")
        let remounted = gate.bind(identity)
        check(!queuedFirst() && !gate.accepts(newSource) && gate.accepts(remounted), "Remounting the same identity never revives an earlier mount's event")
        print("VideoStartupPresentationChecks: \(count) actual startup presentation policy assertions passed")
    }
}
