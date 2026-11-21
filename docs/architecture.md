# Civit Viewer 工程架构

Civit Viewer 是单一 iOS App target。时间线、作者作品、搜索结果和收藏共用作品分页与媒体加载。作者榜由 LeaderboardList 调用站点榜单接口读取，进入作者主页时接入共用导航。排查问题时，先确定谁有权改变出问题的状态。例如，点作者后封面迟到要看读取和解码，连返回也点不动则要同时检查主线程和导航的触摸拦截。

## 状态归属与代码入口

| 要改的行为 | 持有状态的模块 | 从哪里追 |
| --- | --- | --- |
| 根页面切换、再次点击底栏 | App 接收选择意图，Navigation 保留根页面、驱动正文移动并完成输入交接 | [MainTabs](../CivitViewer/App/MainTabs.swift)、[RootTabHost](../CivitViewer/Navigation/RootTabHost.swift)、[TabPageMotion](../CivitViewer/Navigation/TabPageMotion.swift) |
| 页内切栏、交互式返回、整页弹出 | 各自的手势或呈现组件持有一次操作的进度和身份。UIKit 生命周期回报页面是否已出现或关闭 | [SegmentedPageGesture](../CivitViewer/Navigation/SegmentedPageGesture.swift)、[PageEdgeReturn](../CivitViewer/Navigation/PageEdgeReturn.swift)、[PresentationLifecycle](../CivitViewer/Navigation/PresentationLifecycle.swift) |
| 时间线焦点、作者图片／视频、搜索条件 | 对应功能页面持有选择；时间线模型管理队列。作者浏览区保留已经访问的栏，滚动锚点按媒体类型存放 | [TimelineModel](../CivitViewer/Features/Timeline/TimelineModel.swift)、[CreatorView](../CivitViewer/Features/Authors/CreatorView.swift)、[SearchView](../CivitViewer/Features/Search/SearchView.swift) |
| 当前账号、请求范围、分页、去重 | Site 提供账号范围和站点接口。Feed 按读取协议获取一页，持有游标、可见结果及提交代次 | [SiteSession](../CivitViewer/Site/SiteSession.swift)、[读取协议](../CivitViewer/Feed/MediaReading.swift)、[FeedStore](../CivitViewer/Feed/FeedStore.swift)、[FeedAccumulator](../CivitViewer/Feed/Models.swift) |
| 封面与视频字节、预载优先级、播放状态 | Loading 调度读取、缓存和解码，播放器会话管理播放资源。网格控制对可见作品的封面需求 | [MediaLoadQueue](../CivitViewer/Media/Loading/MediaLoadQueue.swift)、[MediaCache](../CivitViewer/Media/Loading/MediaCache.swift)、[VideoPlaybackSessions](../CivitViewer/Media/VideoPlaybackSessions.swift)、[MediaGrid](../CivitViewer/UI/MediaGrid.swift) |
| 云端收藏列表、收藏列表预览、本地文件 | Collections 负责选择、列表展示和业务操作。列表缓存服务于打开收藏的首屏。Offline 管理下载状态、文件验证和本地存储 | [CollectionsView](../CivitViewer/Features/Collections/CollectionsView.swift)、[CollectionListCache](../CivitViewer/Features/Collections/CollectionListCache.swift)、[OfflineLibrary](../CivitViewer/Features/Offline/OfflineLibrary.swift)、[OfflineFileStore](../CivitViewer/Features/Offline/OfflineFileStore.swift) |
| 浏览历史、标签库、设置和反馈 | History 保管浏览记录，Search 管理标签查询和本地标签库，Settings 组织配置页面。已有错误提示由共享 Toast 展示 | [History](../CivitViewer/Features/History)、[LocalTagLibrary](../CivitViewer/Features/Search/LocalTagLibrary.swift)、[Settings](../CivitViewer/Features/Settings)、[AppToast](../CivitViewer/UI/AppToast.swift) |

## 请求、提交与触摸

站点负责返回作品、作者和收藏数据。客户端负责账号范围内的列表、缓存和播放。页面把账号身份、来源和筛选组合为请求键。异步返回时，FeedStore 检查请求键、代次和取消状态，再提交列表及游标。同一作者的图片与视频有不同的请求键。切回旧页面可以恢复会话内的选择与位置；账号或筛选范围改变时应重新核对可复用的数据。

主线程处理 UIKit 和 SwiftUI 的界面变更、手势进度、导航结果及小规模状态提交。站点请求采用异步读取，媒体磁盘操作交给 MediaDiskStore，离线文件操作经过 OfflineFileStore 的有序队列。FeedStore 本身位于主线程，单页过滤、合并和发布仍有开销；遇到大页卡顿，要测量该次提交。异步函数所在的执行器和实际耗时都需要单独核对。

触摸保护属于一次视觉交接，由导航代码取得和释放。分页、下载进度、封面生成和后台刷新可以在交接期间继续。新增数据任务时，沿用已有读取接口、取消令牌与缓存层。新增页面时，先明确根页面、导航子页面或整页弹出的归属，再接入相应组件。业务确认由用户动作触发，动画完成回调只处理视觉和生命周期。

## 一次作者页返回由谁完成

以作者榜进入作者主页、分页途中向内拖动为例。手势开始后，导航驱动页面位移，作者网格仍可接收属于当前请求的封面和分页结果。松手取消时，导航恢复原页及其输入，作者页沿用原来的筛选和滚动锚点。完成返回时由导航确认退出，离开页面的媒体消费者释放自己的订阅。随后到达的旧请求按原请求身份处理。

如果页面停在加载中，先区分两种现场。返回键和底栏仍可用时，检查请求键、游标、传输及解码；连返回也点不动时，检查输入交接是否结束，并采样主线程。一次分页超时能解释结果为什么未到，不能单凭它推断触摸由谁拦截。验收必须在故意延迟响应的窗口内操作。

## 修改后的验收

修改前记录入口、账号或受控夹具、数据量、缓存冷热以及触发动作。修改后按相同条件复测。加载中点返回、拖到一半取消、刚完成切换就点另一个底栏，分别覆盖不同的故障。计时应区分点击处理、第一张可用封面、最长显示回调间隔。签名包、真机版本和安装前后数据连续性各自核对。

工程目录与 target 成员可用 `python3 scripts/verify-project-layout.py` 检查，呈现状态机可用 `bash scripts/verify-presentation.sh` 检查。场景、夹具和具体 UI 用例见[浏览与呈现设计](browsing-design.md)。动效规范和播放资源策略分别见[页面动效](page-motion.md)与[播放架构](playback-architecture-174.md)。
