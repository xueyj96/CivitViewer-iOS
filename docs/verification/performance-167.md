> 170更新：根转场与时间线预载已修复并通过独立审核、模拟器回归及最终逐帧检查，已覆盖Release1.1.0(170)。87条ready离线记录与174目录条目读回一致，未代用户启动手机App。详情见root-transition-170.md。整体卡顿仍未完成：本轮受控采样录到首次作者榜→搜索约340.76ms microhang，未归因、未记为修复。

> 手机覆盖更新：用户随后要求安装，已从166覆盖至Release 1.1.0(169)，设备应用列表读回确认。87条ready离线记录的index字节一致，174目录条目的名称/大小/mtime一致；未代用户启动或交互。签名和数据边界见build/phone169-delivery-readback.json。未推送/发布。

> 169 当前验收：根承载稳定化已由同模型A/B验证；r20 4/4、r21持续手势1/1、r22最终回归4/4通过。最终源码manifest `02207b75b54bb89e0424814e1776c166952cef0e6daa3af4990eded00fdced55`，Release iPhoneOS编译通过，尚未签名、安装或发布。r21有效46.002秒采样覆盖首次根页边缘切换及第二轮三类动作，Hangs可用且0事件；不作为全场景FPS或真机验收。下文保留失败与候选撤回记录。

# 167 连续拖动性能调查

用户报告上下滚动、中央横滑与边缘滑动均卡顿。本轮将这三段动作分开，不以测试总耗时、一次无 hang 记录或静态审核代替实际流畅度验收。

## 已实施的有限变更

`SegmentedContentPager` 不再读取连续变化的 `position`，逐帧位移由独立 `SegmentedPageOffset` 读取。原有参与页面、输入锁、动画事务、提交后帧边界与完成收尾保留。没有用相等比较冻结业务内容，没有跳过新的列表数据或页面身份校验。模拟器 QA 的 position/samples 读数也移到独立子视图，避免诊断本身反向使父层更新。

手机安装脚本配置默认改为 Release，并将构建与产物路径绑定同一配置；Debug 仍可显式选择。UI 回归新增可选 `CIVIT_UI_TEST_OPTIMIZED=1`，保持 Debug QA 功能而使用 `-O / wholemodule`。构建优化是一项独立变量，尚不能认定旧 Debug 包是全部卡顿的根因。

## 对照与限制

固定 1000 作者样例、同一模拟器、同一 Debug 优化级别，工作负载包含三轮上下滚动、四次中央切栏和四次主页面边缘切换。所有提交均检查选中状态。QA 计数仅在交互期间累加，结束时输出一行，不逐帧写日志。

| 记录 | 中央 move 次数 | Native host 更新合计 | 作者榜 body 合计 |
| --- | --- | --- | --- |
| r4 改前 | 35/36/38/37 | 48 | 46 |
| r6 leaf 改后，附加 profiler | 34/38/36/36 | 24 | 24 |
| r7 leaf 改后，无 profiler | 36/38/38/36 | 24 | 25 |

这证明本工作负载下重复更新减少，不证明帧率提高相同比例。r6 仍记录到边缘切主页面阶段一次 397.64 ms microhang：主线程采样 212 ms，其中 SwiftUI 框架分支较多，明确落到 `beginRootSwitch` 的分支仅 17 ms。不能据此把整次停顿归因于该函数，也不能称边缘卡顿已解决。原始记录为 `build/performance167-controlled-r6.trace`、对应 analysis.json 和 triage.md。

真实手机对运行中的 166 只附加一次约 26.7 秒 SwiftUI 采样，未自动操作账号。SwiftUI 更新 lane 没有有效事件，尚未得到该窗口确实覆盖用户连续拖动的确认；此记录不足以判定用户卡顿来源或称运行健康。对原始 trace 的另存符号化进程退出 139，原始记录保留。

## 回归路线纠正

r7 的两项历史测试仍从屏幕 12 pt 边缘起手切分栏；现行规则是中央切分栏、根页面边缘切主页面。QA lifecycle 保持 initial，说明分栏未开始，不能直接认定续滑动画坏了。纠正为中央 30%/70% 起手后保留原 110/20 pt 距离，以及中间帧、行程、回弹、循环、输入锁和固定栏断言。原失败日志 `build/regression167-final-debug.log` 保留，不计为通过。

## 后续回归与失败记录

纠正中央起手路线后的 Debug 三项均通过：搜索模式独立视口、中央释放续滑／回弹、双向循环。随后 r8 `-O / wholemodule` 四项全部通过，包括原连续工作负载。其完整 source-before 与 source-after 相同，manifest 为 `ab22db3c080a1c287de119d78e7c14b0d9c434b08647e3a7d1676376032330cb`。独立审核逐条读回八次释放记录：完成均13个续滑采样，取消6–7个回弹采样，中间采样均受输入锁保护；固定栏与最终选中断言通过。

r9 同一优化配置的连续工作负载通过，并保存79.07秒录屏。独立抽查三段各两秒、共48帧，看见真实列表滚动、相邻分栏移动及边缘切根页，所抽帧未见收尾二次跳位。该抽样不证明整段帧率。

r9 profiler 未在工作负载结束前正确完成录制；结束后产物仅约40KB，导出报 `Document Missing Template Error`，analysis.json为空。原始失败日志保留；不得将其记为零卡顿。确切录制进程经 SIGINT、随后 SIGTERM 停止，无清理其他会话的 simulator 或 profiler。

手机167 Release候选构建和严格签名检查通过，但当前 CoreDevice 返回4016且设备列表为 unavailable，尚未覆盖。最后成功读回的手机版本仍为166；最新取得的离线索引仍为87条ready。目录读取失败没有被当成空目录或数据不变。用户后续明确仅需模拟器测试且保持静音，本轮不在实际账号上自动做交互。

未发布 Git Release，未推送。实际手机流畅度仍不作通过结论。

## r10 有效持续采样

新增一次启动内连续三轮的纯模拟器工作负载，全程 `-muted YES / -autoplay NO`。每轮仍使用相同手势距离和速度，阶段输出实际 epoch 时间，不依赖用户配合；没有修改产品等待时间。94.927秒用例通过，前后完整源码相同，manifest为 `8cf9a2a14b9955f336a10940f8445481dde017edb46e85a326969fbc21fcdc50`。本轮仅新增测试，产品源与r8一致。

Time Profiler正常到达45秒时限并保存20MB记录，可导出分析，实际trace时长46.143906秒。工具提示一张table缺known input source，但Time Profiler的8862个采样与Hangs lane均有效；SwiftUI causes及Animation Hitches lane仍不提供。不能以Hangs事件数替代掉帧指标。

仍有一次277.25ms microhang，起点对应第一轮作者榜→搜索的root-edge起步。独立复核该窗口208个主线程采样：明确的 `beginRootSwitchAttempt` 约21ms（内含Observation mutation约12ms、header raster约6ms）；RootTabHost.update约1ms。170ms SwiftUI父栈及114ms未解析框架self weight不足以归因到上述应用函数。另有26ms共用ObservableObject witness，当前binary UUID精确匹配、nm显示多个store共用该地址，不能指认某个store。

同进程第一次与第二次作者榜→搜索的相同1秒窗口，主线程采样分别317ms、200ms。这是采样CPU权重，不是转场时长或FPS；后续窗口未见同等级hang，不代表无丢帧。记录见 `performance167-root-cold-window.txt`、`performance167-root-warm-window.txt`。首次挂载Search graph较重仍是候选解释，不能记为已证实根因。

独立审核不支持直接改store观察、删host更新，或把preparedTab用于空闲预热；后者会干扰现有角色、输入锁与转场owner。预挂inactive host若要继续试验，须独立验证first mount/layout、业务任务gate与首次滚动，证明没有把成本搬到启动或当前交互。此轮没有加入未经验证的预热机制。性能问题仍未全部收敛，Release候选仅完成构建与签名，未覆盖或发布。


## r10 覆盖范围复核

UI用例执行三轮不等于trace覆盖三轮。按trace start_date与UI epoch重新对齐，46.144秒trace始于第一轮vertical中段，止于第二轮root-edge中段，第三轮未覆盖。全stack分阶段结果保存在`build/performance167-r10-scoped-source-diagnosis.json`：vertical有效12.344秒、1754个主线程1ms样本；central17.865秒、2633样本；root-edge15.936秒、3296样本。样本权重不能当调用次数或帧率。

vertical中明确LeaderboardList row/body仅2ms；central SegmentedPageMotion inclusive26ms、SegmentedNativePane11ms，其中configure7ms。root-edge PageBodyHandoff180ms、RootTabHostController167ms有重叠不能相加。NativeMediaPager全程未出现，因为此workload是在作者榜而非媒体pager，不能据此排除媒体页卡顿。probe更新也未显示为持续vertical主要成本。现有position隔离仍有效候选，不能重复套用165旧源码的每帧重交List结论。

r11以同一个静音、关闭自动播放、优化构建的现有三轮workload补100秒trace，拟单列首次edge与完整暖态vertical/central。结果尚待运行完成及解析；不得提前称整体性能已修复。


## r11 执行与采样失败

同一三轮workload通过95.771秒，source-before/after一致：4734679bd636f12dc167d0f94b67e02ce97a857cd012bed6e2e701a3120d16e1；同批次新增同文toast新事件测试通过16.766秒。此次100秒Time Profiler附加未完成：日志停留Starting recording，目标已由用例正常terminate，超过时限后产物仍40KB且进程未退出。核对准确PID75522及其own simulator/attach PID75423后依次SIGINT、SIGTERM终止。没有操作其他会话simulator。此trace不可作为性能采样，不记录零卡顿或完整覆盖。

现有central日志仍显示每次34–38个move对应6次nativeHostSubmissions，列表body约4–7次；该计数只证明提交次数未随每个move增长，不证明帧率。下一步需针对媒体pager独立取证，不能继续用作者榜trace代表媒体上下滑动。


## r12 实际媒体sample

复用r11已构建binary/runner（source manifest4734679b...d16e1）直接test-without-building，未将后续toast调用端修改混为该binary。testNative67WaitingForwardDragIsBoundedAndDoesNotRestartLoading通过37.550秒。sample2ms请求35秒，header18:22:58.257+08，覆盖三次Swipe up及一次长竖拖。聚合9024个main观察中5193在mach_msg2_trap等待；不是busy CPU时间，也无逐stack时间可切片。

receive14、refreshHosts5，其中4在移动中分支、1明确rootView.setter；不能认定是卡顿大头，也不能停掉负责waiting canvas更新的该路径。底栏CompactBarHeightKey.reduce→GeometryProxy.size→AttributeGraph/LayoutEngine有163个inclusive观察，VideoSurface362包含冷prepare和player建立；QA专用readback/日志亦占样本，不外推普通手机。完整小JSON：build/performance167-media-r12-source-diagnosis.json。

下一步仅实验底栏测量改为局部等值高度观察，保留动态布局与原实际尺寸。底栏求值是候选成本，未证明整个拖动期间的主因；不得用样本inclusive数当调用频率或帧率。


## 底栏局部测量实验

TimelineTabGesture移除仅单一写入/读取的CompactBarHeightKey与根onPreferenceChange；在原measuredBar层、viewingChromeHidden之前以onGeometryChange读取同一个底栏最终高度。仅有限、正数且不同于当前值才写compactBarHeight。保留动态字号、旋转、多选和媒体底部inset的真实尺寸更新，没有缓存固定高度、改动顶底栏位置或冻结业务页面。

独立高级源码审核已读回实际patch，确认原来reduce(max)没有多个writer聚合语义；新实现没有遗留PreferenceKey引用。r13运行媒体拖动/compact动态字号旋转/收藏多选/连续拖动功能回归，并以相同sample35s/2ms比较媒体链。待结果；此处未作整体卡顿解决结论。


## r13 对照与失败回归

source-before/after一致94e51123d825d56e6601b70f982b5276832fc2ef0179336827117dd442e8dadd。4项中连续拖动52.877s、媒体边界拖动27.294s通过；收藏部分移除状态等待超时、compact旋转查到同名按钮重复，失败仍保留，未记为4/4。

r12/r13比较小JSON在build/performance167-bar-r13-comparison.json。旧CompactBarHeightKey163→0、MainTabs.measuredBar165→0，证明旧路径移除。媒体总37.550→27.294s，但首滑提前10.63s，首次Swipe至结束12.010→12.384s；不同冷setup及r13下一用例重启被采PID导致聚合观察时长不齐，不能称提升10秒、CPU优化比例或FPS提高。整体滑动仍未完成验收。

旋转失败AX树明确包含active timeline.media.deck及inactive.timeline.media.deck的同focused作品按钮。此为原native叶host仅按boundaryWaiting设置可访问性的遗漏，不是单纯查找器不唯一可忽略。拟修nativehost自身与SwiftUI内容根按isVisible/等待态同步隐藏AX及禁触，不隐藏native UIView，不影响手势完成callback。收藏失败尚UNKNOWN，需实际失败状态截图/AX确认，未擅改云端保存逻辑。


## 未激活媒体控件隔离

失败AX证据包含同focused作品在active/inactive timeline.media.deck的两套旋转按钮。NativeMediaPager在receive即时同步isVisible和controlsWaiting，以exposesControls统一控制现有/新建/刷新host的UIKit AX与触摸，以及SwiftUI内容根AX。这样pending延迟旧队列时新建neighbor也不能按旧active配置重新暴露。保留分页容器、手势回调与renderPage/queue/focus原提交规则。高级独立审核读回确认延迟配置边界闭合。

r13同工况sample显示底栏旧测量链消失，但首滑后到测试结束12.010→12.384秒；不据前置setup缩短声称滑动提速。r14复测两项失败和Native67；收藏部分移除仅添加失败时截图及AX，尚未改业务保存。


## r14–r18 生命周期定位

r14 source ef3e784d...9fac31：Native67通过23.173s；旋转仍有inactive scroll子树，批量移除partial阶段这次通过，但重试后未显示完成。导出真实AX与视频证明编辑页回到“待移除2/移除”，未据此修改保存请求。r13单用例重放后sim截图只得到系统桌面，不能当失败页面证据；真实失败数据以r14 xcresult附件为准。

补充原生内部scroll自身accessibilityElementsHidden和空elements列表后，r15 compact动态字号/旋转通过40.193s。r15 source 8bb7578c...05233e 的批量仍失败。仅DEBUG+原qa-collection-batch-manage记录state UUID/剩余数量/呈现会话，未记账号或错误原文。日志证明同一外层prepare E556会话内，编辑器C2B保存返回remaining1后被卸载，A35C新建恢复remaining2；内部授权空presenter的source-detach不能误认外层终结。

r16尝试目的根.id(session.id)，source 1f383d88...833349：收藏失败关闭后toast、视频详情返回通过；同一C4DA编辑器两次save正确2→1→0后仍被替换成6A2 remaining2，故该尝试无效，已撤回。未把正确保存返回值误改为重复提交。

r17尝试隔离header ImageRenderer的环境，因误用不存在/readonly SDK属性编译失败65，无运行结论；已查当前SDK接口并去掉两行。r18仅将HeaderHandoff.renderControls从复制完整源EnvironmentValues改为新环境的public渲染值，FloatingPageBar与TimelineLane显式提供session/oauth依赖；保留原motion元数据。候选依据是跨graph渲染不应继承live navigation/presentation上下文，因果仍待原同工况UUID/partial/retry验证。此时尚未宣布重建或整体卡顿已修复。


## r19–r22 已验证结果

r18的raster环境隔离不能解决重挂，已完全撤回，未把未验证的降低透明度差异带入最终候选。r16的.id实验同样已撤回。

Request-owned EditorState静态独立核查通过：读Task按同请求/账号复用，token保护提交与清理，保存中状态在首await前设置，旧结果不写新操作。r19作者批量收藏与收藏批量移除通过；历史用例使用已被用户长按方案替换的顶栏入口，失败不算产品保存失败。该用例改为真实长按首条、再选第二条、使用共用底栏，保留两作品确认和记录仍在的断言。

根承载A/B：r19和r20应用源码仅RootTabHost.swift不同，CollectionsView.swift相同。r19同PID/同操作内View UUID有4个，操作模型保持2→1→0；r20固定RootPageHostView与observable content.page后，同一操作全程只有一个View UUID，slot根安装1次，内容更新仍14次，保存输入仍2再1。独立审核去重并核对source manifest、PID和request/model后确认这条复现链路的无故重挂已消除，没有以业务冻结伪造稳定。

r20四项通过：作者选择器进入/双边缘返回31.251s、收藏部分移除与其他收藏夹保持24.599s、连续三类拖动50.806s、历史长按多选收藏18.235s。定向查询SwiftUI更新期修改/发布和AttributeGraph cycle未检出匹配日志；此查询仅覆盖该次运行。

r21复用同一R20已构建binary/runner进行93.195秒三轮工况。45秒时限profile在App仍活跃时结束并正常保存20MB；之后才启动Release编译，未让该编译混入采集。trace实际46.002089s、8374样本，potential-hangs存在、available=true/count0。独立epoch对齐首次root-edge完整7.208–17.889秒；第二轮vertical/central/root-edge均完整，第三轮仅109.9ms，不能声称采样覆盖三轮。旧r10首次edge后约332.8ms的277.25ms hang在此次对应完整窗口未复现；未提供Animation Hitches/FPS，不能声称所有卡顿消失。

r22最终四项通过：身份在holding/handoff失效34.162s、收藏失败关闭后中央toast21.579s、真实native媒体等待边界纵拖22.841s、compact动态字号/旋转56.251s。

Release iPhoneOS27.2 build169通过，CODE_SIGNING_ALLOWED=NO；Info.plist读回bundle com.xueyj.civitviewer、版本1.1.0(169)，源码与R20 manifest逐文件复核无变化。证据在build/release169-evidence.json。它证明Release条件分支编译，不证明签名、手机覆盖或用户验收。未推送Git、未发布版本、未清理其他会话产物。
