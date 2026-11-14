# 尺寸收敛设计决策

本轮在 151 源码盘点基础上实施；不是宣称全 App 已完成运行验收。三类均逐项判断，例外不自动保留。

视觉目标：保持紧凑、轻量的卡片与半透明导航，统一同角色的文字边线和可见曲面。
内容分工：顶底栏负责导航；卡片负责作品与设置；状态不额外撑大内容。
交互目标：尺寸变化不引入新转场，保留已验证的顶部固定与主题渐变；内容状态变化不移动操作位置。

| 项目 | 原问题/设计初心 | 决定 | 验证 |
| --- | --- | --- | --- |
| 卡片内边与普通预览 R | 历史、离线、网格分别调整留下 14/R10/R6/R9 | 普通卡内12、普通预览R8；历史离线同一60×80预览角色 | 历史/离线卡、横屏和长作者名 |
| 关注胶囊 | 表达状态，三入口已共用；没有必须胶囊的交互理由 | 共用R4圆角矩形，保留caption/44操作区/等待态预留 | 播放/作者/详情，同状态不跳动 |
| 排序行50 | 容纳文字、开关、拖柄；实际拖柄44已足够 | 基准44，保留字体缩放增长；拖动步长由行高加4推导 | 开关、相邻拖动与辅助字号 |
| 搜索紧凑32 | 双排输入与条件需要控制密度 | 保留；辅助字号使用44行 | 两排/一排、长作者和输入 |
| 搜索清空28宽 | 这是重置全部条件，并非普通输入清除 | 目标宽32，保持原AX语义，不扩大可见框 | 清空文本/作者/标签/范围，无邻接误触 |
| 外R8内R4 | 四边内缩4的曲面关系 | 保留几何推导；不独立写两个常量 | 顶栏、分段、侧栏 |
| 头像与编号 | 身份与序号是不同信息；编号四位宽由用户指定 | 保留圆头像和R4居中编号，不统一两者形状 | 长作者名、1至4位序号 |
| 标签尺寸 | 目录44点击高、详情32造成相同26可见面的留白不同 | 常规统一32×32最小目标/26最小面/H8V4内边/4布局缝，辅助字号44；长词最多两行 | 不同入口、长词、选中前后、辅助字号 |
| 标签几何 | 点击框与可见面并非同一边线 | 行列布局缝4按点击框量；32/26差使单行可见纵缝约10，不谎称可见缝4，也不让命中框重叠 | 真实截图检查密度 |
| 底栏10字体 | 曾为减少内容占满而压缩；缺乏固定10必要性 | 采用语义caption2基准11，保持44点击行/36可见外框；文字尾截断不缩至65% | 四栏目横竖屏、辅助字号受现有上限约束 |
| 长标题缩字 | 0.5缩放导致同角色出现极小字 | 普通栏标签、分段、页标题尾截断，保留标准字号 | 窄宽度/长英文/中文 |
| 媒体轨道 | seek2.5和反馈3无独立操作含义 | 共用3；范围选择4另属双端输入 | 播放进度拖动、反馈和时长输入 |
| 下载进度厚度 | scale系统条无法控制最终厚度 | 显式3pt轨道；未知进度使用系统小进度指示，不假造百分比 | 已知/未知进度、0与100%、深浅色 |
| 备用管理底栏 | 独立48/R16/page12外观与主栏不同 | 复用主栏44布局/36外框/R8/page16的外观规则 | 无主栏环境和正常多选入口 |
| 业务整页与系统流程 | sheet混用造成双顶栏、底栏缺失和不一致的退出 | 收藏编辑/详情共享MediaDeck的整页route，批量用同一pinned presenter；授权由稳定root持有；播放内登录由PlaybackNavigation持有并显式跨native host传请求，官方浏览器内部仍由系统负责 | 返回放弃/保存、切底栏退出、账号变更、网络失败 |
| 动态字体与安全区 | 相同源值不证明横屏/大字实际可用 | 不全局放开既有封顶导致新溢出；逐角色记录现有上限，回归常规与辅助档 | 横竖屏、键盘、刘海、页头/页尾可点 |
| 光学2与描边0.5 | 字图微距和渲染线宽不是普通布局 | 保留明确命名；普通图文缝7合并8 | 不混入普通间距 |

实施结果、运行证据和剩余缺口在本文件末尾记录。高级审核需绑定最终差异；源码扫描不代替实际触摸和视觉检查。

## 审核落实与验证口径

高级只读审核先审设计、再审实际差异，且查看默认字体的竖横屏截图。修复了payload提前清空、旧close影响新页、closing期间新请求排队、授权叶子被替换后suspend泄漏等问题。业务展示已从底栏文件抽到`BusinessPagePresentation.swift`，页壳、展示生命周期和tab出口有单一实现。

进一步取舍：榜单与作者身份卡内边统一12/4；诊断行使用4/8间距；普通加载失败、批量完成和授权提示使用紧凑共享卡片。授权提示不再保留大号系统空态，其目的只是说明缺少授权并给入口，不需要撑满页面。系统所有的授权浏览器和菜单仍保留系统内部规格。

图标可见框、实际布局与AX目标必须分别看。无权限收藏行的下载glyph可见位置正常，但单子AX元素被整行提升，AX宽度曾为370。仅在按钮内部或外部增加44 frame没有解决；使用明确row容器、隐藏装饰glyph并保留原生NavigationLink后，原流程与44宽AX断言已通过。不是以假按钮填右侧，也未把整个栏做成点击目标。

回归失败曾包含测试定位问题：通用“收藏”label会误选底栏子元素，应按作品ID定位生产书签；匿名测试清缓存会破坏合成媒体，已改隔离匿名fixture、保留准备的图像并避开重试区域单次进入。此类失败不当作已复现的登录服务故障，也未用sleep或重复tap掩盖。

页面交接完成与视觉handoff结束分开：UIKit completion后恢复真实header显示、命中及AX；window视觉副本继续淡换。原先“恢复命中但保持真实控件opacity0”的做法不够可靠。媒体覆盖状态保持至finishPage，图片侧栏动作数量只按稳定媒体能力决定，不随暂停临时移除再插回。

## 本轮运行回执

环境：独立 iPhone 18 Pro / iOS 27.0 模拟器；使用合成媒体与隔离账号状态。测试脚本为每次运行保存源码前后 SHA-256、xcresult 和附件，以下结果跨多轮，不冒充同一 artifact 上的全套通过。

| 场景 | 结果与回执 |
| --- | --- |
| 深浅色跨栏、详情/收藏/作者往返；设置/标签/已存条件横竖屏；匿名播放登录与取消 | 三项各自通过；`build/dimensions-focused-confirm.log`，run `20261111T083423Z-dadb1a61-262d-4f76-913f-e20949388cca`。同轮AX用例曾失败，另轮修复复验，不能把此轮记为全通过 |
| 嵌套收藏、取消授权后立即进入下载、AX操作目标44宽 | 通过；`build/dimensions-ax-confirm.log`，run `20261111T084740Z-fd7b81a7-bf48-4e66-946d-59d8b3afe996` |
| 作者批量收藏重试、业务收藏页单底栏与退出、纯净模式恢复、下载/账号导航、四主栏对齐、历史批量收藏、标签选择不移位、竖屏尺寸矩阵 | 八项通过；`build/dimensions-acceptance.log`，run `20261111T084940Z-9ea36cf8-ebe4-4344-a0e6-310bbcfc997c`。竖屏覆盖当前宽/375常规与320辅助字号；横屏项因测试错误查询不存在的deck失败，单独修正复验 |
| 缺失视频自动前进到可播放作品 | 最终媒体生命周期guard修改后通过；`build/dimensions-last-confirm.log`，run `20261111T090024Z-62fddd63-2ba7-4466-8359-813149374d4c` |
| 横屏尺寸矩阵 | 440常规与全宽辅助字号两组通过，188.982秒；`build/dimensions-landscape-confirm.log`，run `20261111T090202Z-646e0042-4f04-4e53-b0d1-e6cd0652235e`，source SHA-256 `39f888d8a3c8d5ea9c3be1c49872fa93195c7b840a26f54fbfed7c85acb35b77`；退出码0 |
| 进度条本地数学检查 | 358项通过；`build/dimensions-seek-check.log` |

横屏助手的方向判断改为窗口几何：媒体切换会重建deck，瞬态AX中没有deck不等于窗口不是横屏。不放宽后续尺寸断言，也不增加重复tap掩盖问题。

高级独立审核已复核最终媒体guard、共享页面生命周期、授权宿主、AX容器与尺寸收敛，没有新的确定性发现。实际 OAuth 成功、系统方向锁下真机手感及所有真实网络分支仍不由这些模拟器结果证明。本轮不安装、不提交、不发布。

## 152之后：自绘单值选择器

用户要求参考HGViewer的选值逻辑、适配本App，不使用系统选值界面。已核对HGhub的`src/ios.css`：它使用base-select渐进样式与select语义；本App借鉴紧凑入口、就近展开、点击提交、颜色表示选中，不复制Web实现。

`AppValueSelector`统一SettingsChoice（排序、时间范围、模型、显示模式、预载数量、缓存上限）和作者榜更新时间。设置行与顶栏各保留自己的入口样式；展开列表统一宽240、最多6行（默认272高）、外R8/内R4、内距4、选项随字号缩放固定高44/横12。列表可滚动，长文本单行尾部截断，继承源字号与主题。使用源window挂载自绘浮层，避让安全区并在空间不足时向上展开；不使用系统Menu/Picker或popover外壳。分段切换、收藏夹多选、动作菜单不在本次替换范围内。

退出不改值，点击选项立即提交并关闭。源入口移除、离开window、换window或disabled时释放浮层；VoiceOver有按钮/选中语义及escape退出。独立审核指出的字号环境、脱离window清理、escape和入口继承样式已落实。

验证中保留了失败记录：选项AX目标原先只包文字18高，已修为完整44；严格浮点比较43.99999999999997与44造成假失败，使用0.01pt容差；按label查询重开选项会混淆入口当前值，改用独立option ID与明确button语义。最终几何及业务断言不依赖重复tap或sleep。

最终定向回归run `20261111T110530Z-b1d9b861-1504-47f4-bf0f-2a07070eda07`，source-before/after SHA-256均为`3425b53187f6b0d6c22c719ed3a5ae91855aa5a1e73f7983bbe4db038713a5d2`，两项通过、退出码0：选择器含实际窗口方向断言的竖横屏选值/重开高亮/外部取消/入口与选项44目标（27.703秒），设置子页往返及浅深色选择（59.032秒）。记录在`build/value-selector-acceptance.log`。此前只请求设备转向、未确认窗口方向的用例不计为横屏证据。独立审核最终未发现新的确定问题；本次选择器改动尚未覆盖手机。

## 153：分栏手势、同页顶栏高度与最终回归

- 浏览分栏复用 `SegmentedPageGesture`，作者作品页只接受右边缘；主时间线保留已有上／下分区。选中面用单个 Animatable Shape 裁交容器范围，避免循环副本扩大 AX frame。
- 原型回归确认了进入转场时缓存禁用状态、SwiftUI网格动作与成功分栏并发的问题。最终识别器按配置启用、每次触摸检查当前页面，成功识别取消源触摸；共享 `MediaGridCell` 在分栏拖动／吸附期间不打开作品或开始多选。正常和减少动态效果分支都保留 touch-end 的动作互斥，后者仅推迟到下一次 main queue，并校验 revision，不增加毫秒冷却。
- 同页行数变化复用现有 `NativeHeaderMotion` / `HeaderHandoff`，固定上沿、先收放下沿、再换首行；同页最新布局 revision 续接到同一外框。过渡中保留短暂输入锁，避免不可见的新布局接收输入。
- 独立只读审核发现上述生命周期问题并复核修复；未更改原生返回代理架构。原生返回完成以 depth=2→1、beginCalls 增长、目标作者榜可见和作者页消失验证，不能仅凭全局 QA 的旧快照判断。
- 正常五项回归 `20261111T122242Z-b1a98cc6-0e29-4f7e-b0ab-e4d665a034c9` 全通过：选择器真实横／竖屏选择与取消、作者右侧循环与左返回、搜索单双行三轮往返、作者榜拖动／短拖回弹及收藏横屏、主时间线旧分区手势。该次源清单前后不变，exit=0。
- 更早的失败回归保留在 build 日志及各自 xcresult。历史不可用卡片／方案旧用例曾因持久化测试状态、AX查询及方向基准失败；这些失败不作为本轮全 App 已通过证据，也未据此声称全场景覆盖。
- 最终补验 `20261111T122610Z-94ab2e92-bedc-48fb-9842-a554dcf60776`：普通作者边缘循环／原生返回、分栏组件的 Reduce Motion 分支、搜索单双行往返三项全通过，exit=0，前后源清单一致。Reduce Motion 通过 DEBUG simulator 的组件参数强制验证，不宣称已操作整个系统的辅助功能设置。中间 QA 根环境注入编译失败已删除并由组件参数替代。

## 154：真实分栏内容跟手

用户明确补充内容区也必须跟手。`SegmentedPageMotion`统一拖动、吸附、取消和revision；`SegmentedContentPager`用真实源／目标页面随视口宽度平移，顶底栏保持固定。两栏保留各自滚动位置，只有当前栏可点击和被辅助功能读取；作者页保留左返回、右切栏。视口宽高变化取消旧手势，外部条件变化也使旧提交失效。主时间线的既有分区行为不变。

所有者分工：作者／收藏各持有两个FeedStore，历史持有两份展示限制与各自ScrollView，标签目录每栏持有自己的目录请求及续页；共享账号与屏蔽规则仍由原服务负责。参与预览只准备所需数据，分页和内容打开只允许稳定当前栏。收藏按条件、账号和collectionRevision记录准备状态；打开作品前的异步结果不能在拖动中突然打开播放，退出播放后重新对齐变化的收藏列表。

UIKit List 的隐藏栏仅用SwiftUI accessibilityHidden不足以隔离，会在AX树里留下两个列表。改为稳定的普通UIViewController包裹子UIHostingController：空闲隐藏非当前host，拖动同时展示源／目标，暴露及命中只给稳定当前栏；不创建第二个NavigationStack。榜单行打开作者由外层统一路由。

失败证据保留：`content-pager154-first/confirm/navigation-check/state-check/native-host-check/ax-return-check.log`。其中有已修复的leading分栏与返回冲突、隐藏List重复AX节点、旧测试找离线入口方向错误，以及QA默认离线作品误当远端收藏的测试前提问题。作者系统返回仍观察到偶发取消，额外无UI状态写入的native trace记录过三次完成；不能由这三次通过宣称取消根因已经证明。独立审核指出原生edge/content返回间的failure关系被覆盖。content优先及edge优先的两个单driver实验均未通过，已撤回；分别有receive但未begin记录，不能混称为取消。当前仅对两个系统binding互相转发原delegate的failure关系，App继续限制当前页面、leading范围与分栏归属；不新增返回手势、不手动pop。后续完成／取消回归需绑定该最终artifact。

后续运行区分了property身份：content-property确实开始、拖至约83%且正向结束速度，UIKit仍取消；不能把它归为未开始。进一步移除手势modifier的可见性State缓存，避免导航源页在交互返回重新出现时写入导航祖先；当前页资格由既有控制器top/window/transition检查决定。idle cancel不再发布revision变化，活动手势消失仍取消。原生返回的两种单driver实验已撤回，仅保留原系统pair仲裁和自定义边缘资格。

最终154定向回归：`20261111T134642Z-c05d0767-e4e1-47d2-a4e9-af24077befc9` 三项通过（作者普通右分栏／左返回重复三次、中心切栏与短拖取消返回、组件减少动态效果）；`20261111T134915Z-fb404e7d-cf4f-4679-ad36-9ed1b89cb86b` 八项通过（历史／离线／标签跟手、深色横屏原生列表、作者榜／收藏固定栏与短拖、收藏revision对齐、缓存先呈现、搜索单双行往返、主时间线旧分区、自绘选择器横竖屏）。两轮source-before/after均为`64f7d6248798363dd72ac293fe2c76e9ee765cddaf5c548e0c000f58f14951a8`，当前源码逐文件复核一致；共11项、均exit=0。几何断言读取真实内容位移并要求源／目标同时进入视口，隐藏List要求AX节点唯一，不以只动选择块或firstMatch替代。

高级独立审核绑定同一差异及运行回执。通过范围是本轮受影响路径；不宣称全App所有场景100%覆盖，也不把最终通过等同于已严格A/B证明此前取消的唯一根因。真机包为1.1.0(154)，签名校验通过；实际Swift代码debug.dylib SHA-256=`5e4ad4c51d1585eb19b2064772d2979adc4bd2a2a828afe927683d4f0fb5b530`。安装与设备读回单独记录，模拟器回归不替代用户真机手感验收。

154已于2026-11-11覆盖安装到既有Phocnflag，未卸载；`devicectl device install app`返回App installed，独立`device info apps`读回`com.xueyj.civitviewer / version 1.1.0 / bundleVersion 154 / containerAccessible=true`。记录为`build/phone154-install.log`、`build/phone154-device-readback.json`。手机保持连接，无需切热点。此读回证明设备安装身份，不证明所有用户数据逐项连续性或真机手感已经验收。本轮未发布Release或推送Git。

## 155：App菜单全部共用浮层，补充边缘循环验收

用户要求把所有选择器和长按／副键菜单统一。App自己的8处原Menu、5处context、收藏夹popover和7处破坏性确认均迁移，搜索结果排序补入AppValueSelector；没有再套系统Menu/Picker/popover外壳。系统授权、系统分享、文本编辑和错误提示不是App菜单，不伪造它们的平台流程。四种角色（单选、命令、多选、确认）共用来源window定位、240宽、44缩放行高、H12／外4内边、R8／R4和200ms动效；多选保留草稿与应用，确认明确取消，动作先触发再关闭以保留删除目标。

交互边界落实：新AppContextButton同时拥有普通点击和上下文gate；长按识别开始时同步拦普通动作，菜单关闭后释放，不加时间冷却。裸modifier不对调用者开放。来源移除／账号或多选选项变化时关闭浮层。键盘frame变化时重新定位，锚点及最终y均裁到可用区域。分享命令由源window稳定控制器呈现，不由即将关闭的临时菜单host持有；Link仍走openURL。

初审与运行修正保留：第一轮发现自定义primitive嵌套Button造成AX重复、多选容器ID覆盖应用按钮；已分别改单节点primitive与AX contain。旧QA账号的50条方案已达到原有容量上限，按owner28037001定位并在模拟器备份后清空该测试文档，其它账号不动；历史用明确height fixture、分享按系统Copy Cell而非Button查询。初轮红项分别定位，未据测试准备错误改业务限制。长按源曾同时执行主动作，改成共用gate并允许长按与SwiftUI高亮识别并行后，方案、书签、历史、标签均实测通过。离线原生List的默认行样式拦住普通按钮回调，显式plain后，长按取消及随后正常打开通过（`app-menus155-offline-style.log`，40.774秒）。定位用临时CONTEXT日志已移除。

用户补充边缘切换应循环。共享索引原本使用正模运算，保持两侧向内均可首尾相接；作者页左边缘仍返回、右边缘循环，主时间线保留上／下两组二值循环。最终回归新增同一侧连续两次及反侧连续两次，检查选中值、内容移动和固定顶底栏，避免只验证普通相邻切换。

最终审核补充：实际截图发现History等普通页确认壳误继承媒体深色，单独叠加环境key会被整包environment覆盖；最终构造单份presentationEnvironment合并ordinaryColorScheme再传入，实际98BEF873...png已由root和独立审核者分别查看，白壳黑字/灰说明/红删除与页面一致。原生Link不经过菜单行primitive，已用AppMenuLink统一Button命令行、保留openURL行为；分享与外部链接分别验证，不把两者视为同一条呈现路径。

定向回归证据：`app-menus155-final.log`中的8项通过覆盖单选横竖屏、多选收藏夹、搜索筛选、方案长按管理、分栏双向首尾循环、主时间线旧手势、标签／离线长按、历史确认／书签长按。第9项新增外链路径曾失败，后续定位并修复Link角色、补充返回前台的实际状态等待；失败记录保留。最终受影响补验`app-menus155-final-color.log`两项通过：commands/confirmation42.326秒，keyboard/share/link/browser-return27.538秒；before/after=`24b055f66a50ee6ef86233c2807fe0602c2bbc476bdaa10adbff817a07b906ad`。先前已通过的不相关项不重复扩大测试。

高级审核者在模拟器空闲后亲自独立运行唯一KeyboardAndShare用例：`20261111T150614Z-bbc6dc8e-c7da-479f-ad93-3de0f5ec892f`，28.605秒、exit0，源码前后均为上述24b055...。实际走完键盘B选择、分享Copy、取消、44pt外链打开Safari、回App作者操作可点；没有编辑源码或操作手机。最终构建按同源码核对，签名通过；手机安装和读回记录单列。此结论限定此次菜单及相关交互，不宣称全App所有环境100%覆盖。

155交付：已覆盖安装到原Phocnflag，未卸载；`phone155-install.log`返回App installed。首次安装后立即查询为空列表，未重复安装；随后仅重复同一只读查询，`phone155-device-readback-final.json`独立读回`com.xueyj.civitviewer / version 1.1.0 / bundleVersion 155 / containerAccessible=true`。最终Swift代码dylib SHA-256=`1e81daad7eba413c247bb22d2d410d25387a20ed27bb818a4c0e4b98b5c4d946`，完整artifact身份见`phone155-artifact.json`，与最终24b055...源码一致。无需切换热点。设备安装身份已确认，用户真机手感验收尚待反馈；本轮没有发布Release、推送Git或扩大清理范围。


## 156：分栏实帧、原生列表误触与交互互斥

用户报告作者榜边缘横拖误进作者、收藏切栏无动画、搜索切到作者时收栏无动画，以及动画期间仍可点。作者榜行增加选中/可见/共享motion idle的动作判定；边缘识别仍负责取消原触点，窗口挡板只拦截新触点。曾尝试整层disabled，实际使原生List在idle后仍不可点，已删除该重复禁用；保留行级判定、pane曝光和共享窗口挡板三种各自有边界的职责。

收藏的点击启动改成先begin、提交Binding、跨一个实际display间隔再settle，避免起点和终点被SwiftUI合并为一次绘制。一次性CADisplayLink两tick保证源状态跨渲染周期，不硬编码刷新率或sleep。边缘拖动已有实际起始帧，不额外等待；Reduce Motion直接完成。fallback的程序选择复用同一路径；revision、resize、换账号、不可见及scene非active时统一取消和清理，保留已提交的目标选择。

窗口PageInteractionShield使用独立lease管理分栏、顶栏接管、底栏切页及自绘菜单开合，结束、取消与被替换都释放各自token，旧completion不能解锁新转场。原有拖动触点继续交给原识别器，只阻止中途新增的触点。原生顶栏收放的source高度取已确认旧appearance的高度，位置仍取当前真实frame；未找到probe的提前返回也走remove，避免留下遮罩和lease。

QA采样由UIKit presentation layer逐帧读取实际内容位移和顶栏高度，不用SwiftUI model端点冒充动画证据，QA计数不发布可观察状态以免干扰绘制。初轮保留的失败记录包括：模型geometry只有端点、原生List禁用恢复失败，以及收藏begin/finished但实际0中间帧。分帧后run `20261111T153919Z-b0e3c430-4def-4526-b6c3-9c14257d491f`三项通过：收藏四次点击分别13/15/15/15个中间帧，实际window hitTest均落在挡板；搜索收放每次8中间帧且上沿固定；首尾双向循环顶底栏固定。其源码SHA为67c25d...，最终scene取消补丁之后另跑受影响回归，见后续记录。


最终共享pane修正：156较宽回归发现History边缘横拖后出现两个同名顶栏，失败AX证实是旧触点打开了真实HistoryPlaybackView，并非转场快照。修复收敛为pane根显式disabled(!exposed)：普通SwiftUI内容直接设置；原生host在明确exposed参数下重建root，再注入源环境。避免把disabled放在整层手势modifier导致跨host缓存失效。窗口shield处理新触点，pane禁用处理原按钮尚未结束的旧触点，导航行判定保留防线。History/Offline/Tag回归54.664秒已通过。

后台恢复检查曾在activate刚返回就点击菜单失败；没有直接按静态猜测改菜单。补充实际runningForeground及源按钮isHittable完成条件后，仅点击一次即可展开，locks始终0；收藏四次实际动画及后台恢复18.584秒通过。菜单anchor首次open时window暂nil的静态边界并未被本次证实，不冒充已修复结果。


156最终artifact受影响回归run `20261111T154744Z-707060de-ad76-4445-b3aa-e064a0d39b76`三项全部通过：收藏18.584秒、History/Offline/Tag54.664秒、作者榜53.483秒（普通及Reduce Motion、短取消/长提交、拖后正常点开）。高级审核者独立亲自运行 `20261111T155037Z-e4bd8069-20c9-4389-936e-00d64d4ce18b`，收藏18.635秒、搜索18.263秒、菜单/长按/确认42.904秒全部通过；收藏12/15/15/15实际中间帧且每帧拦新点击，搜索四次各8中间帧且上沿70不变。两轮before/after均为`a72bada4c852032bd73b0c280993518e86c5d2c7346d19c0d3bb81f809ca3376`。较早宽回归的作者页返回33.931秒、收藏夹多选24.667秒、横屏分栏18.193秒、分享/键盘/外链30.099秒通过；其中两处红项已按上述证据修复后重验，失败原始记录保留，不把宽回归写作全绿。

最终设备构建签名检查通过，version1.1.0/build156；代码dylib SHA-256=`dd97496884f89244465b2ddff0e3cb746a29b02049fda2a7b7e5e7331b2468ba`，身份与源码manifest见`build/phone156-artifact.json`。安装前只读确认Phocnflag当前155，已配对localNetwork；设备交付结果另记录。此轮未推送Git或发布Release，也未扩大清理范围。


156交付完成：`build/phone156-install.log`返回App installed，未卸载；随后独立设备查询`build/phone156-device-readback.json`确认`com.xueyj.civitviewer / version1.1.0 / bundleVersion156 / containerAccessible=true`。手机通过既有localNetwork连接，无需热点，未自动启动App。安装身份已读回，真机手感尚待用户验收。


## 157：松手必须延续到目标，取消才回源

用户真机反馈156只能跟手、松手不是滑过去。156的QA把dragging与settling中间帧累计，不能证明释放后补间正确。本次增加独立release阶段presentation layer采样，分别记录帧、实际行程、输入拦截；RED run `20261111T155618Z-f8582e61-2b76-4f8c-96b6-a394748c528d`清楚复现拖动40帧但松手0帧。没有用原先累计帧绿覆盖这个失败。

确定性主因是recognizer的clearDragState先把成员direction归零，commit分支随后又用sourceIndex+direction算视觉终点，导致业务Binding已经切到目标，内容却先回源再跳新页。现在在clear之前捕获未取模destinationPosition与业务用wrapped destinationIndex，prepareCommit/Binding/settle各使用对应的同一目标。首尾循环不能拿wrapped index作视觉position。

非动画Binding提交与补间分开到实际显示帧，tap与edge commit复用同一settle入口；cancel没有Binding提交，直接回源补间。初版仅要求释放后有帧仍可让回源100pt假绿，因此最终QA再要求commit源pane移到接近整宽、释放后走完剩余行程、目标选中正确；cancel限制峰值并保留源选项。`motion157-final.log`初步运行因发现这一明确错误主动中断（exit73），不当作完整通过。`motion157-endpoint.log`修正后四项通过：释放方向/终点28.790秒、收藏点击19.227秒、History/Offline/Tag54.140秒、作者误触/RM/点击恢复53.396秒。

独立复核`motion157-independent.log`释放8路径29.722秒通过，但两个旧连续手势用例未等actual phaseidle，读到前一长尾动画状态，exit65如实保留。视觉上页面切换不需要弹簧尾段，最终收敛为0.26秒有限timingCurve+.removed：实际到位才清pane/解锁，同时避免看着已到位仍在等待长尾。测试手势helper显式等待真实phaseidle，帧中实际hitTest挡板检查仍保留。

实际录屏又发现156的pane.disabled会使主按钮和封面变淡；本版保留disabled输入与AX语义，在pane内用同一exposed参数同步注入temporary visual-lock标志。共用SegmentedContentButtonStyle仅在此锁下保持内容外观，普通disabled继续0.45、正常按下0.65。只应用于作者行、作品封面、历史checkpoint/行、离线行及标签结果，不修改播放侧栏或AppContextButton本体，不开启嵌套按钮交互。最终颜色与方向由新录屏/回归共同确认，后续记录列出结果。


157最终root回归run `20261111T160658Z-12d5f4af-619f-4916-90d4-b1aab4eaac20`六项全部通过：收藏18.590秒、释放方向/终点37.867秒、History/Offline/Tag56.652秒、作者误触/恢复/RM53.963秒、横屏24.047秒、双向循环30.598秒。source-before/after=`36daaf4d73fd56473bed3f574e913c922c0c3ad39aab75c30514ccbec260f010`。后续只补QA helper对readbacks非空的要求，避免allSatisfy空集假成功；生产代码不变，独立最终回归绑定新manifest。

颜色验证由root与独立审核者分别查看实际录屏导出帧。新视频`motion157-color-and-release.mp4`74/75秒、源封面固定像素的RGB均为(0,134,252)，旧视频43秒为(0,134,252)、44秒拖动时变为(120,189,249)；读数见`motion157-color-samples.json`。这仅证明对应固定fixture/采样帧的颜色稳定，未冒充全内容/所有颜色的穷举。另留17秒真实时间节选`motion157-paging-preview.mp4`，没有加速或重制动画。


157最终独立回归run `20261111T161205Z-2965eeeb-04ff-4ffd-a5cb-f0ef75792e1e`四项全部通过：释放38.739秒、横屏24.077秒、双向循环30.098秒、菜单长按确认40.580秒；before/after=`0f7818a7becccc249aa1affd99dbdf9aada32ea9e56101d8aeaf5b727934ef97`。与root六项的唯一文件差异为UITests/ResumePromptUITests.swift的readback非空校验；生产源码一致。提交13释放帧/301.93pt、源峰值401.93(宽402)；取消7帧/约10pt；目标/源选中正确且结束locks0。独立审核者实际查看新旧导出帧并确认保色，未再发现本次范围material阻断项，不把此结论扩大为全App或真机验收。

签名157包严格校验通过，dylib SHA-256=`5e7a239ec4a39b3e60a66014fe03caf06f85b1405a22dcc60b0c11f59e8e3728`，完整身份与源码绑定见`build/phone157-artifact.json`；设备交付记录另列。未发布Release、推送Git或清理其它项目。


157设备交付完成：原Phocnflag经既有localNetwork连接，未切热点、未卸载。`phone157-install.log`返回App installed，随后`phone157-device-readback.json`独立确认`com.xueyj.civitviewer / version1.1.0 / bundleVersion157 / containerAccessible=true`。未自动启动App。设备安装身份已核，真机观感留待用户验收。
