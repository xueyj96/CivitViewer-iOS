# 170 根页面转场：复现与待修边界

169 的 root hosting 身份稳定修复不等于根页面视觉协议已正确。用户在真机报告作者榜切时间线时顶栏、底栏与内容不同步，上下空色带没有内容，时间线拖动仍卡。当前不能把169记为整体滑动验收通过。

## 当前源码与复现

沿用169已编译的模拟器测试产物，目标模拟器 `9B54B2ED-72E2-4D25-A001-6DF9E93E4B72`，只运行 `testRootVideoCanvasRemainsUnderFixedChrome165`。用例静音，使用本地合成媒体；未操作用户手机。测试通过，但它主要断言终点和栏位置，不能覆盖中间帧内容语义。

- 测试日志：`build/root170-baseline-ui.log`
- 测试结果：`build/root170-baseline.xcresult`
- 原始录屏：`build/root170-baseline.mp4`，28.591667秒
- 作者榜至时间线中间帧：`build/root170-authors-to-video.jpg`，从原始录屏23.3至25.4秒完整解码后按8fps生成，仅用于视觉定位，不是帧率测量。

录屏可见：进入的合成视频正文已在滑动，固定顶栏仍显示 Legacy／Seasonal；顶部及底部存在未显示视频的色带；滑动终点附近固定栏随后更换。当前复现支持转场视觉不一致，不证明真机所有白边来自同一条链路，也不证明连续滚动卡顿的原因。

## 源码确认

`TabPageMotion.settleRoot` 先等待 body 位移到终点，再提交业务 selectedTab，随后异步执行 header.replace，最后释放 body。底栏选中态直接使用 selectedTab，顶栏替换有独立阶段，所以同一帧可以表达不同页面。

`PageBodyHandoff.install` 在顶部和底部系统安全区创建纯色 UIView。媒体 header band 从 safeArea.top 开始，不包含最顶部安全区。正文区域在 `PageViewportGeometry.rect` 被截到 fixedBottomBarTop；固定底栏区域没有完整移动内容副本负责，外层 body overlay 透明，可能暴露 live root。普通页本来的白底与媒体缺失必须按坐标分别验证。

`stageTarget` 快照失败仍会返回纯背景 fallback，当前 ready 不代表应显示的所有媒体区域均准备完成。本次录屏尚未证明发生了该失败路径。

## 修复范围与验证要求

继续使用 RootFlight 作为根切换协调者，不增加第二套导航管理器。来源和目标的 header、正文、footer、canvas角色、几何与捕获状态应绑定同一 flight token。固定栏位置不动，其内容与选择表现从同一进度派生；安全区和透明栏后应显示的媒体也由该 flight 负责，不得由提前切换的 live root 补缝。

正文位移、顶栏形态与内容让位需要共同到达视觉终点，不能在正文终点后另做一次顶栏／正文伸缩。提交一次业务选中状态，等待真实目标完成相同最终布局与绘制，再一起撤下视觉副本并释放输入。取消在同一进度反向恢复，不提交目标；提交后的视觉失败不回滚业务导航。

验证必须增加实际2→0中间帧检查，以及同色页面、单双栏变化、反向取消。需要记录来源／目标身份、进度、body与footer矩形和媒体边带捕获状态，并对照原始像素。已有终点断言保留，但不能单独作为视觉验收。滚动性能仍需另用相同工作负载对照，不以该测试通过或录屏抽帧数量宣称流畅度修复。

## 实施与失败记录

根转场已接入统一视觉进度：HeaderHandoff.stageRoot/updateRootProgress、根正文与canvas水平位移、固定footer两端像素淡换共用body进度。业务selectedTab仅在接受后的p=1提交，不再随后另起header.replace。普通子页仍使用原有返回路径。

目标普通页在atTop且允许重排时，以min(sourceClearance,targetClearance)捕获最大正文视口；内容副本使用两端均非负的位移，真实目标保持捕获布局直到提交，再在副本遮护下切到最终布局。根专用正文捕获延伸到owner/window可绘制底部，使footer后的像素与正文使用同一坐标映射；媒体额外保留最多一端的完整canvas底副本，覆盖全部中间顶栏裁剪区间。固定footer控件单独置顶，媒体内容不会带动控件。

终点不再仅等display tick：rootFinalGeometryMatches读回正文最终rect、footer frame与目标header frame/layoutIdentity/canvasRole/colorScheme。视觉校验失败沿现有abort收尾，不撤销已提交导航。

- 第一轮编译失败：试图写入只读accessibilityReduceTransparency环境；改为PageToneBarSurface显式opaqueOverride，拆分MainTabs较长View表达式。
- 第二轮UI：cachedNeighbor通过，三条root路径因source-canvas-not-ready失败。fixedBottomBarFrame支持传入UIWindow本身后修复。记录保留在build/root170-second-run.log。
- 第三轮三条root UI通过；独立审核指出负位移仍可能在正文下缘留下空带，终点还缺几何读回。两项均修正。
- 第四轮四项UI通过，包含新增正常视频暂停→离开→边缘返回的位置、暂停意图、prepare次数与静帧复用断言。独立审核继续发现顶端媒体捕获范围不足，以及静止尾带与正文映射不同；已改成完整媒体底副本与延伸正文统一映射。
- 第五轮冻结候选：PageBodyHandoff SHA256 a56c95ff2ff88a4633657b182275474aa771d05ac24cfe132abd070123303d60，TabPageMotion SHA256 dd65f3043509ab62eba4430b73a82a178e1addd27f1b4452bf09b64be156d8a5。独立只读高级审核在根转场范围内通过；第五轮5/5模拟器测试通过，但逐帧复核又抓到一帧黑屏，因此当时没有覆盖手机。

## 时间线预载

同feedIdentity:queueRevision下保留当前与+1/-1/+2窗口的静态预览帧，失活只停新解码，不清除仍符合过滤条件的已准备帧；scope、队列、过滤窗口与缓存失效继续清理。prepared只消费静态帧，active条件未放宽。root托管的同focused作品暂失活保留cursor与用户播放意图，AVPlayer仍释放；跨账户/队列隔离依赖已有pager.id(feedIdentity)与page.id(item:queueRevision)。

上一条有效视频占用现有预载count中的一个位置，futureCount相应减一，并发/Wi-Fi/磁盘预算不扩大。本地HTTP新增中间焦点count=3用例验证上一视频+后两件、第三件不请求、重复update不重下、上一件改为图片后恢复后三件；scripts/verify-media-prefetch.py已退出0，build/prefetch170-result.json包含adjacentWindow170记录，原三轮各5/5完成和并发/取消用例也通过。

## 最终首帧与封面交接

第五轮原始PTS139.578333秒存在一帧中央YAVG约16的纯黑正文，几何通过并不等于媒体画面可显示。VideoSurface新增同内容实例的preservesPreparedCover，prepared失活时已有的preview在激活后持续显示，直到原有native first-frame guard确认真实画面，避免preview→hidden→native之间的空档。不增加固定延迟或播放器。CachedPoster.Key同时移除未参与loadPoster参数或诊断的active字段；source/declared/local/retry/workID/cacheRevision变化仍按原规则重新加载，单纯活动态切换不清掉已加载封面。

第六轮4/4通过，原始交接97帧没有黑屏/placeholder。最后CachedPoster两处补丁再次独立只读审核通过，最终局部4/4通过（root video、暂停位置与预览帧返回、缓存producer更新、底层取消）。最终源码manifest前后及当前读回一致：`50ab1e10ad2a5f0b152d6cd8d1d8403b6c8d42e57b03c87f9351ea76df07a639`。

最终录屏build/root170-final-run.mp4编码时长15.188333秒；独立高级审核完整解码PTS8.0～10.5秒的90帧，橙色prepared直接交给青色视频，最低中央YAVG95.8461，没有黑屏或placeholder插帧、终点二次位移或底栏媒体残留。帧图为build/root170-review-final-terminal.png。早期录屏内稳态顶部白条/底部黄条已从原始fixture解码确认是测试媒体内容，不计作真实安全区缺陷。

## 性能仍未完成

同一受控三轮上下/中央/根边缘工作负载通过（95.770秒）；Time Profiler实际46.984578秒，Hangs lane可用并录到一次340.76ms microhang。对齐在首轮作者榜→搜索根边缘开始216.37ms后；181ms主线程CPU样本中beginRootSwitch仅12ms，另有101ms未解析SwiftUI与39ms partial backtrace。首次Search host创建/更新有直接样本，但不足以归因整次停顿，也没有源榜1000行大量重算的直接证据。详情build/root170-hangs.txt；采样artifact基于首帧补丁之前的170候选4265c40a，不能写成最终整包FPS验收。最终首帧与封面补丁有单独UI和原始帧证据。

因此本次转场正确性和预载修复通过，不宣称整体滑动卡顿已解决。首次Search目标冷/已挂载对照仍是后续性能调查；未盲目eager mount全部页面。

## 手机覆盖

Release1.1.0(170)构建、签名校验及目标设备profile检查通过；从169覆盖后设备应用列表读回170。87条ready记录的index字节一致，174个目录条目的名称/大小/mtime一致。未代用户启动或操作实际手机。证据build/phone170-delivery-readback.json。未推送Git或发布GitHub Release，等待用户体验验收。
