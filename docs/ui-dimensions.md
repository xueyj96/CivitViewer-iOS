# Civit Viewer 控件与尺寸标准

盘点基线为 `c5bcc94`，对应 1.1.0（151）。本文件维护 Civit Viewer 自己的尺寸规则，HGhub 和 ExHViewer 独立维护各自标准。跨 App 共用盘点分类、证据口径和经验。

本轮已在盘点后实施尺寸收敛。表里的“现行”来自当前工作区；具体取舍、审核和运行证据见 [尺寸收敛决策](ui-dimensions-decisions.md)。源码基线为151，未提交的收敛差异由逐文件哈希标识。运行时尺寸随父容器、系统字号、安全区和控件状态变化，不能把源码常量直接记作全场景实测值。

## 覆盖范围与统计

按 32 类组件与布局角色登记规格，并逐文件扫描 `CivitViewer/` 下全部 85 个 Swift 文件。39 个文件包含生产 UI 类型，5 个文件为 QA UI，41 个文件是模型、服务或其他非 UI 文件。后者也在清单里登记，防止遗漏或把缓存容量、媒体分辨率当成控件尺寸。

源码共有 236 项 UI 相关声明，包含 View、样式、布局、UIKit 桥接、扩展及 QA 类型。它不是屏幕控件实例数。

| 源码口径 | 数量 | 含义 |
| --- | --- | --- |
| 生产 UI 文件调用点 | 2451 | 含显式 DEBUG 分支 |
| 显式 DEBUG 调用点 | 147 | 下项已排除 |
| 非 DEBUG UI 调用点 | 2304 | 静态词法构造/修饰/几何调用，不展开实例 |
| 组件与布局角色 | 32 | 人工登记类别，不与其他App数量比较 |

完整清单在 [ui-control-inventory.json](ui-control-inventory.json)。每个文件有 SHA-256、声明、条件编译、构造调用、尺寸表达式和来源行号。共享 UI 类型另列全项目的词法引用位置。字符串插值、类型推断、继承样式、实际实例数和 UIKit 属性赋值的生效结果仍需人工核对。

重新生成与核对使用以下命令。

```sh
python3 scripts/audit-ui-dimensions.py
python3 scripts/audit-ui-dimensions.py --check
```

`--check` 核对源码哈希和清单内容，文档提交本身不使清单失效。新增控件或调整 UI 源码后重新生成。扫描器是维护工具，审核时仍要读共享组件与使用入口。

## 标准的组织方式

每个组件同时登记可见框、内容尺寸、点击区和周围留白。相同角色复用同一个组件，尺寸从角色推导。按用途需要不同规格时，登记使用条件。

| 角色 | Civit Viewer 现行值 | 维护方式 |
| --- | --- | --- |
| 页面左右内容边 | 16 pt | `AppTheme.spacing` / `FloatingPageChrome.pageInset` |
| 同栏内沿、成组按钮中缝 | 4 pt | `groupInset` / `surfaceInset` |
| 常规同组内容间距 | 8 pt | `FloatingPageChrome.spacing` |
| 卡片内容内边距 | 12 pt | `FloatingPageChrome.cardInset` |
| 普通操作点击高度 | 44 pt | `controlHeight`，图标动作通常 44 × 44 |
| 单行栏可见外框 | 36 pt 高、R8 | `surfaceHeight` / `controlShape` |
| 内层控件可见外框 | 28 pt 高、R4 | `visibleHeight(nested: true)` / `surfaceShape(nested: true)` |
| 搜索紧凑行点击高度 | 32 pt | `compactRowHeight`，辅助功能字号切回常规行 |
| 常规标题栏内容到下一组 | 10 pt | 现行附录约定，需按可见边测量 |
| 光学微间距 | 2 pt | 徽标上下留白、底栏图文间距、紧凑标签行距等已存在用途 |
| 栏边线 | 0.5 pt | 可见细线，不能作为点击区或外框宽度 |

4 pt 是布局基数。2 pt、0.5 pt、文字基线和原生媒体轨道属于光学或渲染规格，需有明确角色。普通内容卡片的 14 pt、未登记的 5／7／10 pt 间隔先进入例外清单，再决定是否合并。

当前 Apple HIG 给 iOS 的默认控件尺寸为 44 × 44 pt，最小控件尺寸为 28 × 28 pt。本 App 采用 44 pt 常规操作目标，同时已有 32 pt 的紧凑栏例外。判定时分别看字形、可见底框、完整点击区域、邻近目标和实际可操作性。[Apple 辅助功能](https://developer.apple.com/design/human-interface-guidelines/accessibility)

## 全组件规格目录

| 类别 | 共享实现或入口 | 当前可核查规格 | 归类与后续 |
| --- | --- | --- | --- |
| 页面壳与顶栏 | `FloatingPageBar`、`PageHeaderLayout`、`BusinessPageSurface`、`PinnedPageCover` | 页边 16；外 R8、内 R4；常规点击高 44；搜索行 32；多排高度按行数计算 | 继续作为顶栏单一来源，测量可见框和预留空间时分开 |
| 标题左右按钮 | `FloatingPageBackButton`、`FloatingPageButtonStyle`、`FloatingPageIcon` | 常规 44 宽；字形 16；外观高度随 nested 状态为 36／28；文字为 footnote medium | 不在页面单独写宽高；长标题和多动作保留截断条件 |
| 搜索模式按钮与搜索框 | `SearchView`、`SearchTitleField` | 左上复用图标按钮；提示“搜标题／搜作者”；输入沿当前行高；全部条件重置目标宽 32 | 这是全部条件重置，不是输入清除；保持明确AX名称，紧凑目标按用途登记 |
| 双排搜索顶栏 | `PageHeaderLayout.search`、`SearchView.workFilters` | 默认两行，各 32；外观内部 28；模式切换到作者为单行；辅助字号改五行各 44 | 现有设计附录仍有旧的三列描述，应按实际布局修订时核对 |
| 底栏与管理态底栏 | `MainTabs.compactBar`、`FavoriteBatchBarButtons` | 点击行 44，垂直 padding 2+2，总预留约 48；可见外框 36；图标 13、标签 caption2（约11）；横缝 4 | 管理态共享底栏尺寸；caption2 替代固定10，保持栏尺寸 |
| 播放侧栏 | `MediaPageView.mediaActionRail`、`MediaIconActionLabel` | 每动作点击 44 × 44，字形 16；可见整栏宽 36、R8；动作间距 4，整栏上下 4 | 动作无独立底框；按相同动作数和安全区比较图片、视频位置 |
| 分段控件 | `FloatingSegmentedControl` | 平分可用宽度；点击高 44；单独轨道可见 36，nested 28；选中块内缩 4／2，R 随层级推导 | 选中块与轨道的内缩、曲面和最小宽度由组件负责 |
| 筛选与菜单标签 | `AppFilterLabel`、`SettingsChoice`、`AppValueSelector`、`AppMenu`、`AppContextButton`、`AppMultiValueSelector` | 单选列表宽240、最多6行（默认272高）；外R8/内R4/内距4；选项固定缩放44高、横12、subheadline、一行尾部截断；设置入口保留原规格 | App共用自绘浮层：单选用颜色、点选提交；多选本地草稿+应用；命令触发后关闭；长按与主点击由同一组件互斥。源window持有，按安全区与键盘避让，随入口移除；无系统Menu/Picker/popover外壳 |
| 普通动作和重试 | `AppActionButtonStyle`、`StatusReloadButton` | 可见面 32；圆形或矩形 R8；点击最小 44 × 44；正文 subheadline medium | 圆形动作按形状角色保留；普通矩形共用外框R8 |
| 关注按钮 | `FollowButton`、`FollowButtonStyle` | caption semibold；横 8、竖 4；R4圆角矩形背景；最小点击 44；预留关注／待确认文案宽 | 胶囊外形无功能必要，已合并为内层状态动作R4，作者页、详情、播放共用 |
| 设置行与内容卡片 | `SettingsControlCard`、`PageContentCard`、`SettingsRowLabel` | R8、卡内横 12；设置行最小 44；标题 subheadline；图标 16、图标列 22；分组间 8 | 行高以内容和字号增长；复式设置另登记布局 |
| 开关 | `CompactSettingsToggleStyle` | 可见 36 × 20；滑块 14、内沿 3；操作高 44；无文字版本操作宽 44 | 常规设置和侧栏管理共用，不直接依赖系统 Toggle 外观尺寸 |
| 预载并发滑块 | `PrefetchConcurrencySlider` | 操作高度 44；数字按 caption 缩放，基准 13、最高 22；基准 thumb 图像 42 × 44，实际可见面约 36 × 22 | UIKit 绘制尺寸与整张图像尺寸分列；保持本组件职责 |
| 视频时长范围 | `VideoDurationRangeControl` | 操作高 44；双端圆点可见 18、目标 44；轨道高 4；左右内缩 22；窄屏 endpoint 菜单换行 | 媒体输入控件例外，不能套普通按钮外框 |
| 播放进度和手势反馈 | `VideoSeekControl`、`VideoProgressChrome` | seek 操作高 44；轨道 3，圆角为轨道半高；时间字 12；滑动反馈时间 26／11，进度 3 | seek与反馈共用3pt媒体轨道；时长范围4pt另属输入角色 |
| 全屏图片与视频 | `BitmapMediaSurface`、`VideoSurface`、`NativeMediaPager` | 画面按可用视口和媒体比例布局；暂停提示圈 64；媒体 caption 基准 14，支持缩放 | 画面、覆盖层、安全区和触控排除区分别盘点，不能固定媒体画面高度 |
| 双列作品网格 | `MediaGrid`、`MediaGridCell` | 两列、列缝及行缝 8；卡高 230／辅助字号 300；图片裁切随卡；圆角 R8；多选标记外距 8 | 网格高度档保留，圆角与标记外距已统一 |
| 头像与作者行 | `AuthorRowIdentity`、`AvatarView` | 头像 28；昵称 footnote medium；头像到文字 8；行最小 44；作者摘要含关注按钮可长高 | 列表头像统一28；作者行共用H12/V4/min44，摘要卡片按内容增长 |
| 顺序编号 | `AuthorRowIdentity.position` | 预留 4 个等宽 caption 数字；横 padding 4、竖 2、R4；数字居中；到头像间距 6 | 静态徽标，无单独点击目标；6 作为已确认的编号光学间隔 |
| 作品标签 | `WorkTagLabel`、`TagPillLayout` | caption；可见最小高26；横8、竖4、R4；常规最小目标32×32，辅助字号44×44；文本最多两行，移除式一行 | 标签统一32×32目标/至少26高可见面及4目标框间距；单行可见纵缝还包含6pt透明目标余量 |
| 类型／状态徽标 | `FilterPresetLibraryView`、`FavoriteSelectionMark` | 媒体类型 caption2 semibold、横 6 竖 2；多选标记字形 22 | 类型标与交互标签分开登记；颜色与可读文字共同表达状态 |
| 详情摘要 | `MediaDetailsView` | 预览共用60 × 80、R8；摘要标题 title3 semibold，作者 subheadline；元信息 footnote／caption | 图片、视频复用；内容不足时自然高度，不能用等分空行撑高 |
| 历史与离线行 | `BrowsingHistoryView.historyRow`、`OfflineRecordRow` | 历史与离线共用60 × 80、R8；历史行内边12、图文缝12 | 同类单列预览已统一容器，图片原显示与模糊策略保留；作者卡与榜单卡也用12/4内边 |
| 下载任务与进度 | `OfflineDownloadTasksView` | 卡片 R8、横 12 竖 4；动作复用 32 可见／44 点击；确定进度为显式3pt轨道；未知总量用系统mini等待 | 确定/未知进度语义分开，AX名称和值保留，下载队列实际交互已有回归 |
| 已存条件与编辑页 | `FilterPresetLibraryView`、`FilterPresetNameView` | 可点击条目H12/V4/min44；说明摘要四周12；标题 subheadline；类型 caption2；长名称一行截断；右侧信息限宽 | 对齐共享卡片；双行摘要可增长，区分文案基线和标签顶边 |
| 收藏夹选择弹出层 | `CollectionFolderPicker` | 宽 264；行高 44，最多 6 行后滚动；内容横 12 | 锚点 popover 例外，需核对窄横屏与键盘可用宽度 |
| 空、失败、首屏加载 | `PageStatusCard`、`FailureView`、`AuthorLookupResults` | 卡片 R8 横 12；状态图标 15；首屏搜索进度居中；追加进度在列表底部；重试点击 44 | 列表空/错误/完成/授权说明采用共享卡片；媒体全屏等待单列；系统浏览器内部交给平台 |
| 登录、授权与系统菜单 | `LoginView`、`CollectionAuthorizationView`、`FavoriteEditor`、`SystemAuthBrowser` | 业务页共用 pinnedPageCover、整页壳及唯一底栏；系统浏览器走系统页 | 收藏请求由MediaDeck持有，批量payload冻结，授权由稳定根持有；系统授权内部交给平台 |
| 诊断、许可、标签库 | `LocalDiagnosticsView`、`MediaRepairLicenseView`、`LocalTagLibraryView` | 共用标题栏、页面边距，正文 subheadline／footnote／caption 组合，诊断内部缝4/8、行上下padding4 | 特殊密集文本保留独立文本角色，避免散落字号 |
| 拖动排序 | `MediaRailOrderView` | 行高基准 44，ScaledMetric 可增长；行缝 4、外包 padding 4、内 R4；手柄点击 44 | 50没有额外内容依据，已并入44；辅助字号仍随ScaledMetric增长 |
| 手势区域 | `ScreenEdgeGesture`、`MediaGestureLayer`、`SegmentedPageGesture` | 边缘带 30，提交距离 45；默认顶部／底部排除 110／120，实际排除以覆盖控件帧为准 | 操作范围与可见尺寸分开；横屏、刘海侧、锁方向单独验收 |
| 材质、边线与交互状态 | `PlaybackChrome`、`FloatingPagePanelSurface`、`FloatingPageButtonStyle` | 媒体面黑色透明度 0.48，媒体边线白色 0.12；普通顶栏面 0.90、底栏面 0.68；边线 0.5；按钮禁用透明度 0.38，按下 0.65 | 主题、选中、禁用和等待只改变允许的视觉字段；Reduce Transparency 使用实底；不同材质按普通页／媒体／状态动作登记 |

## 字体角色

下表数值是 iOS 默认 Large 字号的基准说明。SwiftUI 语义字体会随 Dynamic Type 改变，不能把它们替换成固定像素。SF Symbols 的字形尺寸单列，不与同号文字混为一类。

| 角色 | 当前基准 | 主要使用位置 | 建议 |
| --- | --- | --- | --- |
| 栏标签／作者列表 | footnote medium，约 13 pt | 顶栏、模式、分段、作者名字 | 保留同一角色；长作者名截断，避免按字符串长度缩字 |
| 正文／设置行 | subheadline，约 15 pt | 设置、历史、空卡标题、输入 | 一行和两行共享字号，行高随内容增长 |
| 作品标题 | title3 semibold，约 20 pt | 详情摘要 | 保留标题层级，最多两行；辅助字号可增长 |
| 次要信息／标签 | caption，约 12 pt | 标签、状态、作品参数、编号 | 标签正文统一使用该角色 |
| 微状态 | caption2，约 11 pt | 类型徽标、日期、次级提示 | 限定短辅助内容，长说明回到 caption |
| 播放标题／作者 | ScaledMetric，基准 14 pt | 深色媒体覆盖层 | 在视频和图片共用，缩放和换行统一 |
| 底栏文字 | caption2，约 11 pt | 四个主栏目 | 采用 caption2 语义字号，保持现有栏外框和点击行 |
| 统计数字 | 当前 29 pt rounded semibold | 离线空间摘要 | 由AppTypography.statistics持有，统计摘要角色，与普通行文字分开 |
| 图标档位 | 顶栏、设置、侧栏主图标统一16；辅助箭头10；底栏13 | 不同操作区域 | 相同角色保持统一；图标列和点击区分别量 |

Apple 建议支持更大文字，并列出 iOS 自定义文字默认 17 pt、最小 11 pt。当前紧凑产品的文字层级需要结合 App 密度和系统语义样式核对，不能仅凭 `.caption` 或固定数字判定整页合格。[Apple 字体](https://developer.apple.com/design/human-interface-guidelines/typography) · [Apple 辅助功能](https://developer.apple.com/design/human-interface-guidelines/accessibility)

## 收敛结果与剩余边界

历史/离线/网格圆角、卡内边、关注外形、排序行、标签目标高度与布局缝、普通动作圆角、底栏字体、标题截断、备用底栏和确定下载进度已经按角色收敛。二类例外均追溯原设计问题，决定与证据见 [尺寸收敛决策](ui-dimensions-decisions.md)。

保留的差异：紧凑搜索32与辅助字号44；嵌套外R8内R4；圆头像/四位编号；网格封面与单列预览用途；数值滑块、双端时长输入；光学2和0.5线；系统授权内部。不是页面自行覆盖尺寸的许可。

现有 Dynamic Type 上限仍按角色记录：底栏xLarge、作者榜xxxLarge、部分媒体微状态medium。未全局解除这些上限，避免未经验证的溢出。系统字号/刘海/真实触摸可用性须结合运行证据判断；源码哈希一致不证明像素一致。

旧设计附录若描述了早期三列搜索顶栏，应以本文件所列当前实现为准；本轮没有重写三个工程共用的原则正文。

## 页面与状态覆盖表

本表登记入口与盘点范围，所有项已按源码检查。未标注运行证据的项目不宣称本轮已全流程实测。

| 页面族 | 页面和状态 | 主要共享组件 |
| --- | --- | --- |
| 时间线 | 关注／推荐，图片／视频，流／网格，首屏等待、空、失败、续页、返回恢复 | FloatingPageBar、FloatingMediaPicker、MediaGrid、MediaDeck |
| 作者榜 | Legacy／Seasonal、更新时间过滤、加载、空、待核实、两位到四位编号 | FloatingSegmentedControl、AuthorRowIdentity、状态控件 |
| 搜索 | 作品／作者，作者条件、标签、范围、排序，首屏与续载、重试、无结果、键盘 | SearchTitleField、AuthorLookupResults、SearchResultGrid |
| 作者页 | 身份卡、关注状态、图片／视频、作品网格、从作者进入作品搜索、批量收藏 | CreatorIdentityCard、AuthorRowIdentity、FollowButton、MediaGrid |
| 收藏 | 授权不足、缓存列表、图片／视频、收藏夹多选 popover、管理态、编辑 | CollectionAccessView、CollectionFolderPicker、FavoriteBatchBarButtons |
| 作品详情 | 图片／视频、可用／缺失元信息、标签折叠／选择、作者／关注、长标题 | MediaDetailsView、WorkTagLabel、TagPillLayout、FollowButton |
| 在线／离线观看 | 时间线、作者、搜索、收藏、历史、缓存入口；原生／兼容；加载／修复／失败 | MediaPageView、PlaybackNavigation、MediaIconActionLabel、VideoSeekControl |
| 历史 | 搜索、记录开关、续看卡、日期分组、选择／删除、空与核实 | PageContentCard、CompactSettingsToggleStyle、历史行 |
| 下载与空间 | 等 Wi-Fi、队列、进行／暂停／失败／完成、移除、容量、重试 | OfflineDownloadTasksView、OfflineRecordRow、动作按钮 |
| 账号和设置 | 登录／退出、显示模式、下载、播放、预载、缓存、诊断、开源 | SettingsControlCard、SettingsChoice、CompactSettingsToggleStyle |
| 设置子页 | 范围筛选、内容偏好、作者屏蔽、标签屏蔽、侧栏排序、下载偏好、标签库 | SettingsRowLabel、WorkTagLabel、拖动行、共享标题栏 |
| 已存条件 | 列表、空、长方案名、重命名、删除、保存、错误 | FilterPresetLibraryView、FilterPresetNameView、卡片 |
| 系统表面 | OAuth 浏览器、系统分享面板、文本编辑菜单、键盘 | 系统流程保留平台实现；App自己的操作／长按／破坏性确认统一自绘，负责入口、内容和可返回性 |

## 收敛顺序与验收

1. 导航继续由 `FloatingPageChrome` 持有；内容由 `ContentMetrics` 的 Tag/Preview/Action/Media/Optical 和 `AppTypography` 持有。跨角色不互相冒充，也不新增万能组件。
2. 优先处理历史／离线／网格的内边和圆角，状态动作与标签排布其次。每次只改同一类控件，至少对照两个实际调用入口。
3. 字体与布局共同验收。固定相同设备宽度、主题、字号，量可见边、文字基线和点击区；常规与辅助字号各一档，横竖屏、刘海方向、键盘和长文本分别检查。
4. 有加载、选中、禁用、管理态的控件需分别核对位置。播放页还要核对首帧、图片／视频侧栏、底栏叠放、纯净模式和方向锁。
5. 新增例外必须在本文件登记用途、来源、范围和验证条件，再复用到同类入口。例外的存在不等于对运行结果的验收。

现有 151 证据覆盖作者搜索中央进度、20 后续载、作者选择提交／取消和模式切换。属于这些场景的实测可以引用对应结果。全 App 的实际几何、主题、横屏与辅助字号矩阵仍需在收敛具体组件时补齐。

## 与另外两个 App 的交换口径

三方共同检查页面壳、操作区、输入与选择、开关和滑块、卡片与媒体、标签与徽标、文字、状态、弹层、系统表面以及各类横竖屏／大字边界。各自记录组件、数值、可见框、点击区、字形、调用页、例外、源码位置与运行证据。

HGhub 的 Web/CSS 与原生桥接需要额外检查 computed style、伪元素命中区和单位转换。ExHViewer 的阅读器、缩略图、站点标签与官方网页需要额外检查。Civit Viewer 的混合图片／视频、时间线四项双分组切换、播放侧栏和收藏夹选择需要额外检查。

共同经验为集中同角色尺寸、给类型差异命名、区分可见面与点击区、在变化状态下保住布局，以及为可重复盘点保留源文件和明确统计口径。


## 三方盘点交叉结果

本轮已与两个既有 App 会话核对盘点范围，各项目独立维护文档与清单。以下为当前源码规格对照，不能跨层级比较，也不是统一三个 App 数值的提案。

| 项目 | Civit Viewer | HGhub / HGViewer | ExHViewer |
| --- | --- | --- | --- |
| 本地规格文档 | 本文件 | `/Users/bytedance/Documents/ChatGPT/个人工作/HGhub-iOS/docs/ui-dimensions.md` | `/Users/bytedance/Documents/生活/artifacts/exviewer-ios-20261026/docs/ui-dimensions.md` |
| 盘点目录 | 32 类角色；83 个 Swift 文件 | 42 类角色；8 个页面模块、24 个 TSX 组件模块及相关 CSS / 原生桥接 | 24 类角色；69 个 Swift 文件 |
| 常规操作布局高 | 44 pt | 44 CSS px（按视口换算） | 44 pt；页标题两侧目标宽 34 为紧凑例外 |
| 单行栏可见外框 | 36 pt | 36 CSS px | 42 pt，由 34 pt 内层面加上下各 4 推导 |
| 卡片/栏内边距 | 普通卡内 12；栏内 4 | 栏内 4；内容卡按类型登记 | 详情卡内 6；栏内 4 |
| 主要圆角 | 栏外 R8 / 内 R4；其余偏差另列 | 内 R4 / 卡 R8 / 弹窗 R12 | 控件 R8 / 卡 R12；嵌套由内缩推导 |
| 标签 | 可见最小 26；常规目标最小32、辅助44 | 可见28、点击44、R4 | 可见最小26；目标最小高30、宽44 |
| 独有范围 | 图片/视频播放、侧栏、作者身份、收藏夹选择 | Web/CSS 与原生桥接、剧集/评论/图文、线路/清晰度 | 阅读器、站点标签分组、画廊卡、官方网页；无侧栏 |

角色目录的拆分粒度不同，32／42／24 不用于判断哪个 App 覆盖更完整。三方共用“角色、现行定义、可见面、操作目标、文字/图形、内外留白、状态、调用入口、例外、来源、验证层级”的登记口径；值仍由本项目持有。

三方都发现了应优先治理的同类问题：旧行与新卡并存、父子留白累加、原生控件与自定义文字不匹配、可见面和操作区混算、紧凑例外缺少用途登记。跨 App 交换这些检查方法与可复用方案；不引入跨工程的万能尺寸包。


交付核验：三个 App 均已按各自标准实施收敛。HGhub 当前文档为1.1.101，增加了共享组件；ExHViewer维护独立收敛方案与运行回归记录。本文的跨 App 表只交换角色口径，最新尺寸与测试状态以各项目文件为准。Civit Viewer 的最终源码哈希由本清单核对；运行证据见尺寸收敛决策，不把其他App的回报当成本App验收。

## 本轮角色收敛补充

用户确认主图标16、摘要预览合并，并要求已确定项落地、剩余差异至少有角色规则。普通操作行使用H12/V4/min44；非交互摘要和详情使用四周12；文字行gap4、信息组gap8。已存条件不再按页面scope分10/4，显式按row/summary选择。

媒体错误/可关闭banner用R8：短banner H12/V4，多段说明四周12；只读时间/倍速HUD用R4/H8/V4/min26；双行手势反馈用R8/H12/V8。播放状态圆形64、进度/开关轨道保留功能几何，不套成卡片。Reveal提示改R8并保留整个画布可点。

作者搜索/榜单/选择/关注行复用authorCardRow；由List已有横内距的入口不重复加12。历史分隔线由12+Preview.width+12推导。详情、历史、离线共用Preview的60×80/R8，原fill、模糊与失败策略保留。

## 浏览分栏手势与顶栏布局变化

主时间线保留上半／下半边缘分区。作者榜、作者作品、收藏、浏览历史及离线收藏作为分栏浏览页，左右边缘均复用 `edgeSwitchingSegments` 循环切栏。标签目录是配置页，分段控件只通过点击切换；所有配置子页、无分栏浏览子页均支持左右边缘返回。临时禁用切栏不会改变页面角色或退化成返回。边缘带30，向内横移45，或速度450且距离至少12时提交；不足则回弹。选中块和真实源／目标内容按内容视口宽度共同跟手；顶栏容器和底栏固定。松手以同一位置连续完成或回弹，不用截图替代内容。两栏各保留独立列表与滚动状态，隐藏栏不参与命中和辅助功能；UIKit List 通过稳定的子 hosting controller 隔离。旋转改变视口尺寸时取消旧手势，避免旧尺寸提交。开弹窗、进入作品或批量管理时停止相应页面的分栏提交。

同页布局从单行到双行或反向变化，复用 `NativeHeaderMotion`／`HeaderHandoff`：固定上沿，先调整下沿，再淡换第一排；外框不整体淡出。过渡期间短暂锁住顶栏输入，避免命中新旧布局语义不同的控件。状态重入记录最新高度并在同一handoff内续接。Reduce Motion沿已有静态切换路径。


## 选择、命令与上下文菜单

共用实现位于`AppMenus.swift`，不再在主题文件中混放呈现生命周期。AppValueSelector、AppMenu、AppContextButton、AppMultiValueSelector和appConfirmationDialog共享来源window、单浮层所有权、定位、关闭与动效。可见宽240，普通行按subheadline缩放44，横内距12，外内距4，R8/R4；短菜单按内容收起，超过6行滚动。多选最多6条选项加固定应用行，草稿在应用前不写回。确认同壳居中，说明可换行，取消只提供一份。

长按0.45秒、允许移动12；源行和菜单共用主动作gate，不使用毫秒冷却。鼠标副键复用同一面板。键盘变化时重新定位，并将上下位置最终限制在可用区域。标签、作品等长名称保留完整AX标签，可见文字单行尾截断。命令先触发、再关闭旧菜单，避免丢失删除目标；系统分享交给源window的稳定控制器。离线列表的非编辑操作显式使用plain按钮，保留编辑时的原生List多选。

边缘分栏使用模运算循环索引，首尾连续；两侧各自向内拖动均可循环。作者页左边缘仍归原生返回，右边缘循环，主时间线保持上半关注／推荐、下半图片／视频的两组循环。
