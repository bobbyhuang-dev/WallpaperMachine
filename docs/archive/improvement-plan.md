# mac-wallpaper-engine 改进计划
## 以壁纸运行时功耗为首要目标的源码审查与实施路线

**审查日期：2026-09-17**  
**仓库：bobbyhuang-dev/mac-wallpaper-engine**  
**固定基线：`6dc8c327c6f7e2594d84722413f11d7168eb5898`**  
**状态：设计 / 待实施；未修改远程仓库。**

> 本报告基于固定提交的源码、项目文档，以及 Apple / FFmpeg 的官方 API 文档。当前环境未执行 macOS 构建、Metal/Vulkan GPU 测试、真实壁纸视觉对照或功耗测量。因此，“代码中存在该路径”与“已经在真实壁纸上复现故障”明确分开；所有节能收益必须在等画质、等帧率条件下实测。本次额外执行的仅是纹理尺寸、流量数量级和颜色公式的独立算术校验，不是项目测试。

---

## 0. 建议决策

**不要先把整个项目换一种语言重写。先减少不必要的工作，再缩短视频路径，最后决定是否替换场景后端。**

推荐保留 Swift/AppKit 宿主、Rust 的配置与资源调度，以及当前 C++ 场景兼容能力；增加统一的逐 Surface 能耗策略、按需调度、原生视频后端，并把原生 Metal 场景渲染器作为有明确收益门槛的渐进式替换项目。

优先顺序：

1. **先补可观测性并修正确性缺陷**：解码器 EAGAIN/EOF 状态机、Core Video 对象存活期、Web 页面身份与恢复、视频色彩范围。
2. **消除看不见的工作**：逐屏暂停、Web 实际挂起、无消费者时停解码/音频/输入/计时器；桌面、锁屏、预览统一约束。
3. **优化看得见的工作**：纯视频绕过通用场景后端、减少 NV12→BGRA 中间纹理与跨队列同步；真正接通内部渲染分辨率；静态子图和多屏资源共享。
4. **再试验更大改造**：统一 IR 后增加原生 Metal 场景后端；仅对符合条件的壁纸提供离线烘焙。没有同质量功耗优势，就不扩大迁移范围。

### 本次最重要的判断

- 硬解、纹理池、单帧在途限制、部分直接呈现、按需截图、全局暂停已经存在，不应当作尚未实现的功能重新开发。[S02][S03][S06][S10][S12]
- 优先级最高的能耗问题不一定是某段 CPU 代码慢，而是**不可见工作、重复工作、全分辨率中间结果和过于通用的播放路径**。
- 原生视频后端值得先做；完整场景后端重写尚缺功耗数据支撑。语言本身不是节能验收标准。

---

## 1. 范围、证据等级与当前架构

### 1.1 证据等级

| 标记 | 含义 | 可以作出的结论 |
|---|---|---|
| A：源码确认 | 已读到具体控制流、参数或资源操作 | 该实现行为确实存在；不等于已观察到用户可见故障 |
| B：可复现风险 | 源码与 API 契约/数据流存在矛盾，需要针对性用例 | 明确给出触发条件和测试，不声称生产环境已复现 |
| C：优化假设 | 合理的替代实现，收益取决于负载与系统 | 先做 A/B 原型，不承诺节省多少瓦或百分比 |
| D：已声明缺口 | 仓库文档明确列出不支持的功能 | 可以列为兼容性任务，但不是新发现的回归 |

本报告重点深入审查了呈现策略、Web 宿主、实际 C++ 视频解码与 Apple 互操作、Vulkan 帧提交、定时器、部分音频实现、锁屏 Surface 和测试体系。没有逐行覆盖所有 shader 翻译器、粒子算子、材质或 SceneScript API；这些部分的建议以测试矩阵和架构改进为主，不伪装成全面兼容性认证。

### 1.2 当前主要执行链

```text
Swift/AppKit 桌面与应用生命周期
  ├─ Swift / WKWebView 控制面板
  ├─ UniFFI → Rust bridge/core → C++ Open Wallpaper Engine
  │                                 ├─ SceneScript / 解析 / 场景图
  │                                 ├─ FFmpeg + VideoToolbox
  │                                 └─ Vulkan → MoltenVK → Metal → CAMetalLayer
  ├─ Swift / WKWebView Web 壁纸（与场景后端分开）
  └─ ExtensionKit 锁屏扩展 → 独立 Surface / 原生场景实例
```

纯视频也会构造成场景对象，生成复制 shader，经通用场景后端呈现。当前 Apple 视频路径确实启用了 VideoToolbox；Rust 中另有软件解码实现，但不能据此推断桌面播放默认走软件解码。[S02][S04][S07]

控制面板和 Web 壁纸是不同用途的 WebView。控制面板已有隐藏/遮挡时抑制状态更新等设计；没有证据说明“移除控制面板 WebView”会比视频与调度优化更有效。[S02]

### 1.3 必须保留的已有优化

| 已有实现 | 改造时的要求 |
|---|---|
| VideoToolbox 硬解、BGRA IOSurface 直接导入 | 保留零 CPU 像素回读方向，不退回逐帧 CPU RGB 转换 |
| NV12 转换目标池、纹理缓存 | 修复预算与生命周期，不凭空增加重复缓存 |
| `FrameTimer` 单个 DRAW 在途，慢帧丢 tick | 保留有界背压，禁止优化成无限积压 |
| 部分场景直接写最终呈现目标 | 扩展实际受益范围，而非再加一套重复快路径 |
| 桌面 poster 按需 GPU 回读 | 不改为周期性全屏截图或每帧 CPU 检测 |
| 音频按消费者启停、全局 suspend | 扩展为有效可见消费者，而不是重造开关 |
| 现有语义/alpha/puppet/缩放等回归测试 | 作为新后端与调度器的约束，不把历史修复再次报成当前 bug |

来源：[S03][S06][S10][S12][S15][S16][S18]。

---

## 2. 优先级总表

P0 表示基线、正确性和最直接的无效运行问题；P1 表示可分阶段实施的运行时优化；P2 表示需要 A/B 原型和更大兼容性投入的项目。工作量 S/M/L/XL 仅表示相对规模，不是工期承诺。

| ID | 优先级 | 任务 | 主要收益对象 | 规模 | 依赖 |
|---|---|---|---|---|---|
| M00 | P0 | 功耗基线、分后端计数器与 signpost | 让所有收益可验证 | M | 无 |
| V01 | P0 | 解码器 EAGAIN、EOF drain、取消状态机 | 视频正确性、异常耗电 | M | 合成视频用例 |
| V02 | P0 | Core Video / Metal 跨帧资源存活期 | 正确性与后续异步化基础 | M | 无 |
| W01 | P0 | Web 身份比较、状态重放、崩溃预算 | 重载开销、闪烁、状态丢失 | S–M | 无 |
| P01 | P0 | 逐 Surface/逐显示器暂停 | 多屏、遮挡、息屏功耗 | M–L | M00 |
| W02 | P0 | Web 媒体暂停 + 脱窗挂起 + 回退 | 非配合型 Web 壁纸功耗 | M | W01、P01 |
| V03 | P0 | 有限范围色彩转换与能力诊断 | 渲染正确性 | M | V01/V02 测试 |
| P02 | P1 | 统一 FrameDemand 和节能档位 | 静态、低频、后台工作 | L | M00、P01 |
| V04 | P1 | 原生纯视频快路径 | 长期视频播放功耗 | L | V01、V02、V03、M00 |
| V05 | P1 | 场景视频异步互操作、减少中间纹理 | 含视频纹理的场景 | L | V02、M00 |
| R01 | P1 | 接通独立内部渲染分辨率 | 高分屏、重后处理 | M–L | M00 |
| R02 | P1 | 纹理池预算、解码队列与尺寸匹配 | 超宽/高分视频分配抖动 | M | V02、M00 |
| I01 | P1 | 去掉纯视频整文件复制与重复临时文件 | 启动、内存压力与换壁纸 | M | V01 |
| A01 | P1 | 音频可见消费者与实时路径隔离 | 音频响应场景 | M | P01、M00 |
| R03 | P1 | 帧图脏传播、pass/带宽优化 | 多层、粒子、后处理场景 | L | P02、M00 |
| D01 | P1 | 多屏共享 SourceSession 与不可变资源 | 镜像、多显示器 | L | P01、V02、M00 |
| C01 | P1 | 视频/场景/Web 能力矩阵与时序金图 | 兼容性、渲染正确性 | L | M00；持续建设 |
| F01 | P1 | Swapchain 恢复、错误分级与限次重试 | 热插拔、唤醒、黑屏风险 | M–L | V02、C01 |
| Q01 | P1 | 测试分层与资源/功耗发布门禁 | 防回归 | M | M00；持续建设 |
| E01 | P1 | 桌面/锁屏/预览呈现所有权 | 避免重复后台实例 | M | P01 |
| R04 | P2 | 原生 Metal 场景后端 + 统一 IR | 待实测的长期收益 | XL | C01、R03、M00 |
| B01 | P2 | 有条件的静态缓存/循环烘焙 | 少数昂贵且可烘焙壁纸 | M–L | C01、V04、M00 |
| Q02 | P2 | FFI、私有 API、缓存/构建清理 | 维护性、系统升级稳定性 | M | 持续 |

---

## 3. 具体发现与改进任务

### P01：全局可见性不足以控制多屏工作

**等级：A；功耗收益：C，需测量。**

`WallpaperPresentationPolicy.desktopIsVisible()` 对所有桌面壁纸窗口做 `contains(.visible)`；策略只维护一个 `isSuspended`。任意一个壁纸窗口仍可见，就不会因遮挡暂停整个引擎。Web 宿主同样把一个 `suspended` 值传播给所有窗口。[S03][S09]

这不是“项目没有后台暂停”，而是**已有暂停粒度过粗**。双屏中 A 屏桌面可见、B 屏被应用完全遮挡时，B 的工作不能仅凭全局开关准确停下。

**实施：**

- 在 Swift 层建立 `SurfaceID → VisibilityState`；用稳定 display identity 配合 Surface generation，不仅用临时窗口号。
- 将 `userPaused`、`occluded`、`displayAsleep`、`sessionLocked`、`thermalPolicy`、`batteryPolicy` 分开，最终取有效暂停原因，不互相覆盖。
- Rust/core 提供逐 Surface 呈现暂停接口；视频、脚本、音频和输入根据实际消费者推导是否继续。
- 遮挡使用迟滞/短 debounce，锁屏和息屏立即进入停止提交流程。保留现有串行状态交付思想；重试有上限且不依赖下一次无关事件才能恢复一致性。
- 不在高频 timer 中枚举全桌面窗口；以通知为主。`.occlusionState` 在桌面层/Spaces 下的行为要做真实 macOS 对照，不能假定它能计算任意窗口覆盖面积。

**验收：**双屏互换可见/遮挡时，隐藏 Surface 的 `render_submission`、`present` 不再增长；其独占解码/脚本/输入工作在排空允许的在途任务后停止。共享源仍有可见消费者时可以继续，但不为隐藏 Surface 再合成/呈现。测试覆盖全屏、Spaces、热插拔和快速遮挡抖动。

### W02：Web 的“暂停”目前只是配合型协议

**等级：A。**

`WebWallpaperPage.setPaused()` / `setPresentationSuspended()` 最终调用页面可选的 `wallpaperPropertyListener.setPaused`；`fps` 也只是 `applyGeneralProperties` 参数。页面不实现回调，或者仅暂停了一部分动画时，宿主不能据此认定 JS、CSS、WebGL、媒体与 Worker 已停止。[S08]

**实施分三级：**

1. **协议层**：保留 WE 回调，去重并按文档 generation 有序发送。不要通过重置时间或突然跳到播放起点实现节能。
2. **公开宿主能力**：调用 `WKWebView.setAllMediaPlaybackSuspended`。保存静态 poster 后，将 WebView 从窗口视图树移除、由静态视图占位；在可用系统上显式采用 `WKPreferences.inactiveSchedulingPolicy = .suspend`。Apple 文档的触发条件是“不在窗口中”，不是单纯 `isHidden` 或被其他窗口覆盖；媒体播放、媒体采集等活动还可能豁免该策略。[A04][A05]
3. **兜底**：对仍不能有效挂起、长期不可见或超过预算的页面，按用户选择销毁并恢复 WebView。说明此操作不能透明保存任意 JS 堆/WebGL 状态；由页面导出状态和宿主持久化配置分别恢复。

禁止把包装 `requestAnimationFrame` 当作所有页面的硬暂停；Worker、CSS、AudioContext、嵌套页面和自带计时器不受这种简单包装完整约束。也不通过 SIGSTOP 共享 WebKit 进程来暂停某一张壁纸。

**验收：**创建不实现 WE pause 回调的测试页，分别含 rAF、interval、CSS、WebGL、视频、音频、Worker；检查窗口脱离和媒体挂起前后的推进计数，并在真实系统记录 WebContent CPU/GPU。恢复保留宿主配置，用户原本暂停的媒体不得被错误恢复播放。测试 API 不可用和活动豁免时的回退。

### W01：Web 重建和恢复存在三个具体问题

**等级：A / B；分别修复，不混成一个泛泛“优化 WebView”的任务。**

**W01-a：嵌套入口路径的身份比较。** `WebWallpaperHost.apply` 使用 `entryURL.lastPathComponent == wallpaper.entryFile` 判定旧页面是否可复用。若入口是 `sub/index.html`，左侧只有 `index.html`，比较恒不等；在该入口能进入描述符的情况下，每次 reconcile 都可能重新创建页面。[S09]

改成规范化完整 entry URL 比较，同时验证解析符号链接后的入口仍位于允许项目根目录内。测试嵌套入口、同名不同目录入口、路径规范化、重复相同 snapshot；相同配置连续 reconcile 不得增加 WebView 创建次数。

**W01-b：崩溃恢复没有完整重放已提交状态。** `flush()` 清空 pending properties/general/paused；WebContent 终止后重新 `load()`，但旧的已提交配置没有重新排入 pending。Host 的 descriptor diff 对未改变的属性不会重新发送。[S08][S09]

建立 `committedSnapshot` 与 `pendingDelivery` 两层，在每个新 document generation 上强制重放全部状态。所有异步 JS 任务携带 generation；旧页面的延迟完成不能覆盖新页面。区分“某次属性变化”和“新文档需要初始化”。

**W01-c：一次重启标志可被短暂加载成功清零。** `didFinish` 把 `recoveryAttempted` 清回 false；持续在加载完成后崩溃的页面可以一直重启，而不触发真正的滚动熔断。[S08]

使用按 wallpaper/source 统计的时间窗口失败预算、指数退避和静态 poster 降级；稳定运行达到阈值才重置预算。验收覆盖连续 post-load crash、并发切换与旧回调、用户手动重试。

### V01：FFmpeg 解码状态机有丢包和尾帧风险

**等级：A：控制流确认；B：实际可见丢帧需合成视频复现。**

`FfmpegVideoTextureSource::Impl::decodeNextFrame()` 有两处与 FFmpeg 契约不符：[S07][A01]

- `avcodec_send_packet` 后无论是否 EAGAIN 都立即 `av_packet_unref`。EAGAIN 表示输入未接受，需要读出旧输出后重试同一个输入包，不能丢掉它。
- `av_read_frame` 返回 EOF 后直接 seek 并 `avcodec_flush_buffers`，没有先送 NULL packet 进入 draining 并读完延迟输出。含 B 帧/重排序的视频可能丢失循环尾部帧。

**实施：**做显式 receive-first 状态机；维护 `PendingPacket / Feeding / Draining / LoopSeeking / Stopped / Failed`，packet 仅在接受后释放，EOF 仅发送一次 drain 标记，直到 decoder EOF 再切下一轮。PTS、容器 start_time、可变帧率、非零起点和 loop epoch 分开处理。

**异常功耗附项：**内层 decode/EOF-seek 循环未看到取消检查；外层 `stop()` 会 join 线程。对可 seek 但始终不产出可用帧的坏输入，可能出现无法及时退出的循环。加入无进展预算、原子取消令牌和适用的 FFmpeg interrupt callback；不能指望外层“首帧 2 秒超时”自动终止不响应取消的内层工作。[S07]

**验收：**合成 H.264/HEVC B 帧片段，验证每轮最后帧与预期帧数；mock send EAGAIN 验证同 packet 被重新提交且只释放一次；测试多 frame/packet、VFR、seek、截断、空流、无输出流和循环时取消。超时后线程和资源必须可回收，不依赖强制退出应用。

### V02：Core Video 纹理包装对象的生命周期必须补齐

**等级：A：提前释放路径；B：GPU 下具体故障待复现。**

`CreatePixelBufferBackedMetalTexture` 调用 `CVMetalTextureCacheCreateTextureFromImage`，取出 `MTLTexture` 后立即释放 `CVMetalTextureRef`，只返回底层纹理。Apple 明确要求持有输出的 Core Video texture 包装对象直到 GPU 使用结束，单独持有底层 MTLTexture 不能替代这条 API 契约。[S06][A02]

**实施：**引入拥有明确所有权的 `VideoFrameLease`，同时持有 CVPixelBuffer、CVMetalTextureRef（多 plane 时各自持有）、MTLTexture 与 generation/完成凭据；只有最终使用该帧的队列完成后才退休。NV12 现有路径在同步 wait 后释放包装对象，与这个 BGRA 分支不同；异步化时 NV12 也必须纳入相同生命周期。

不要简单把所有 CFRelease 移除：那只是把风险变为持续泄漏。跨 C ABI 输出 opaque owned handle 和唯一 release 函数，记录 retain/release 计数与失败路径。

**验收：**大量切换、池复用、丢帧、取消、设备错误与异步延迟下没有提前释放/泄漏；Metal validation 和 synthetic IOSurface 测试通过。此任务是 V05/R04 的先决条件。

### V03：有限范围 YUV 色彩转换不完整

**等级：A：公式差异已确认；未做实机色彩管理链验证。**

NV12 的 CPU 转换路径和 `nv12_to_bgra` 对 video-range luma 使用 16/255 偏移和 255/219 缩放，但 chroma 使用 `sample - 0.5`，配合未做有限范围放大的标准系数。8-bit limited-range 的 chroma 应围绕 128 code value，按 224 code-value 跨度解释；FFmpeg 的参考转换也区分 luma/chroma 范围。[S06][A06]

以 BT.709、`Y=126, Cb=128, Cr=160` 为独立算术例子：目前公式约得到 RGB `(179,113,129)`，按 `(Y−16)/219`、`(Cb−128)/224`、`(Cr−128)/224` 得到 `(185,111,128)`。这是公式对照，不是截图实测。

**实施：**统一 CPU/Metal 的颜色参数结构，独立描述 bit depth、Y/chroma offset/scale、matrix、primaries、transfer 和 chroma siting。保持 full-range 与 limited-range 独立测试。不要在转换中过早 clamp HDR 或需要保留 superwhite 的数据；先定义 SDR 输出契约。

BT.2020 constant-luminance 不能仅与 NCL 共用同一套简化 matrix 就宣称完整支持。未知元数据采用可诊断的保守 fallback；不默默按 BT.601 显示所有内容。

**验收：**BT.601/709 full/limited 色条、中性灰、黑白边界与已知像素；对照可靠参考转换，并对合理量化误差设阈值。新增 Metal 路径与旧路径不能靠“看着差不多”验收。

### V04 / V05：硬解后的呈现路径仍然可以更短

**等级：A：中间转换与同步确认；C：节能幅度待测。**

当前 NV12 经过 CVMetalTextureCache 导入 Y/UV plane 后，compute 写出 BGRA8 中间纹理；随后 `[command_buffer waitUntilCompleted]` 等待 GPU 完成，再交给后续呈现路径。Vulkan 的普通帧也在提交/Present 后等待该帧 fence。这是两个可审查的同步边界，**不是“每帧 vkDeviceWaitIdle”**；后者只在特定 quiescence 条件触发。[S06][S12]

**V04：纯视频新后端。** 用功能开关对照：

- 基线：现有 FFmpeg/VideoToolbox + 场景/Vulkan 路径。
- 候选 A：AVPlayer/AVQueuePlayer + AVPlayerLayer；适用于不需要任意场景合成的常规视频，验证循环、缩放、音量、显示器和 poster。
- 候选 B：保留所需 demux/VideoToolbox，使用双 plane Metal 采样，在最终呈现 pass 中完成 YUV→RGB、crop、scale；不写独立全尺寸 BGRA 中间纹理。

AVPlayerLayer 不保证每种 codec/布局都最省电，直接 YUV 采样也不保证在多次重复采样时比一次预转换更优；选择由同条件实测决定。纯视频成功后再评估包含单视频底图的简单场景，不自动把任意自定义 shader 改写为视频。

**V05：保留旧场景后端时的优化。** 先将转换结果按 frame generation 缓存/核验，避免重复消费导致重新转换；当前其他纹理层可能已有去重，因此要用计数确认，不能直接认定每次 render 都在转相同帧。进一步通过有界帧槽和完成事件退休实现异步互操作；跨 Metal/Vulkan 队列的等待、资源所有权与图像布局必须可证明。

切勿只删 `waitUntilCompleted` 或 fence wait。先建立完成依赖，最多保留小规模在途槽；在目标 FPS 下验证节能，而不是以提高渲染吞吐量为成功标准。

**数量级说明（不是 DRAM 实测带宽）：**若为全尺寸 BGRA 中间结果多一次写入和一次读取，4K/30 FPS 的逻辑流量约 1.99 GB/s，6880×2880/30 FPS 约 4.76 GB/s。缓存、压缩和 tile 行为会改变实际内存流量，不能据此换算瓦数。

**验收：**等显示面积、等源视频、等真实呈现帧率、等缩放和颜色契约；无额外掉帧、无循环接缝回归；记录 GPU pass、转换次数、纹理分配、CPU/GPU 等待和系统增量能耗。

### R02：固定 64 MiB 转换池对高分辨率视频失效

**等级：A，触发条件可算术验证。**

`AppleVideoMetalTexturePool` 有 4 个条目和 64 MiB 总预算；单张纹理超过预算会直接释放而不复用。6880×2880 的 BGRA8 纹理理论数据大小约 **75.59 MiB**，大于预算；只要解码源达到该尺寸，该转换目标无法被此池保留。实际 `allocatedSize` 还可能更大。[S06]

**重要边界：**这里看的是解码源视频的尺寸，不是显示器尺寸。4K 视频铺满超宽屏不自动触发 75.59 MiB 纹理分配。

**实施：**优先减少/移除 BGRA 中间结果；旧路径采用按实际 frame size 和完成帧槽计算的预算，同时加全进程/全 GPU 总预算与内存压力响应。不要给每张壁纸都无限扩大缓存。调整 decoded frame queue 时用“缓冲时间 + 字节”而不只固定 8 帧，保持 jitter 和 codec 重排序所需空间。

**验收：**固定分辨率稳定播放预热后，每个新 frame 不再持续创建/销毁转换目标；大尺寸、尺寸变化和内存压力时有受控降级，无分配振荡。记录命中率、`allocatedSize` 和同时存在的解码 Surface 数量。

### I01：纯视频存在整文件复制与重新落盘链路

**等级：A；主要改善启动、内存压力，不夸大为持续磁盘写入。**

`LoadVideoProjectImage` 读取整个视频到 ImageData；`FfmpegVideoTextureSource` 再复制到 `m_payload`，按内容 hash 寻找/写临时文件，然后 FFmpeg 重新从临时文件读取。至少存在明确的加载期重复内存与磁盘处理，源 payload 也保留在 source 对象中。[S04][S07]

**实施：**将来源表示为 `FileSource / PackageSlice / ExtractedAsset`，普通本地视频直接安全打开原文件；包内资源使用有界 AVIO reader 或一次性流式提取。缓存按内容标识和版本管理，临时写入使用唯一文件 + 完成校验 + 原子发布，避免同源并发打开半成品。缓存复用/清理按引用和额度管理。

现有 temp cache 通过 hash + size 复用，不是每次循环重写视频；本任务不声称它在每帧写磁盘。

**验收：**普通视频不再产生整文件双份副本/多余落盘；大文件启动峰值内存有记录；同源并发打开、取消、磁盘满、缓存损坏和清理仍正确。

### P02：从固定 tick 改为内容需求驱动，而非简单换计时器

**等级：A：当前 timer 行为；C：新调度器收益。**

`FrameTimer` 默认 30 FPS，使用条件变量定时线程，并限制一个 DRAW 在途。它不是 busy-spin，也不是无限堆帧；解码器的有界队列装满后也会等待，不能把未使用的 `kPausedPoll` 常量解释成暂停时持续 100 Hz 轮询。[S07][S10][S11]

要优化的是：何时确实需要下一帧，哪些系统还需要推进，而不是单纯把 `sleep` 换成 display link。

**实施：**新增 `FrameDemand`，输出 `Idle / At(deadline) / Interactive(targetFPS)`。需求来自新视频 PTS、可见动画/粒子、定时文本、属性变化、输入、音频分析和网络/媒体事件。只在有需求时启动可见帧节奏；无需求保留最后一帧，注销/暂停时钟。

静态判断必须基于语义依赖：shader 时间 uniform、SceneScript、副作用、父子变换、音频、反馈纹理、随机性、可见性脚本都可能使“看似不动”的场景仍有依赖。未知脚本先按动态处理，不通过每帧截图比较或“几秒没有鼠标移动”来推断静态。

对持续动态内容，在原生 Metal 后端使用支持的平台显示调度并明确设置帧率范围；`CAMetalDisplayLink` 默认可能跟随显示最高刷新率，不能让省电方案反而在 120 Hz 唤醒。系统帧率范围是偏好而非精确硬保证，应记录真实 cadence。[A03]

**与 MoltenVK 的边界：**不要把一个会自行取得 CAMetalDrawable 的 `CAMetalDisplayLink` 直接叠在同一 CAMetalLayer 的 Vulkan swapchain 上，让两者争用 drawable。原生后端可拥有显示调度；旧后端先用单一有界 pacer/平台节奏通知配合 Vulkan WSI，或经过明确的外部呈现接口改造。

动画与物理时间分离：按实际 elapsed 或固定 simulation step + 有限 catch-up 推进；不为弥补后台停顿补画数千帧。脚本时钟/真实日期各自遵循兼容语义。

**验收：**静态首帧后没有周期 draw；分钟时钟按下一次可见变化唤醒；24/30/60 FPS 视频不被显示刷新率无条件驱动成 120 次处理；恢复后不出现动画加速/物理爆炸；帧排队有界。

### R01：内部渲染分辨率需要独立于输出与构图缩放

**等级：A：已审查类中的参数使用缺口；B：端到端质量选项行为需追踪。**

`VulkanRender::Impl::initPresentation` 接收并保存 `m_requested_render_extent`，但在已完整读取的 `VulkanRender.cpp` 内，该字段没有参与后续 render target 尺寸计算；`setRenderTargetSize` 仍按输出 extent 和场景规则计算。这不能直接解释为某个 UI 控件必然失效，但说明该低分辨率渲染入口在这个后端中没有真正接通。[S12]

**实施：**定义并分别传递：

- `OutputExtent`：屏幕 drawable 的物理像素大小。
- `SceneExtent`：作者定义的画布/相机语义。
- `RasterExtent`：内部实际光栅化分辨率与每个 pass 的质量尺度。

内容的 fit/fill/zoom 参数不得兼任省电 renderScale。单独建立输出与渲染目标变换，把输入 hit test、texel size、屏幕空间 shader uniform、截图和最终 crop 一起测试。分辨率变化只重建受影响资源，不重新解析整个项目。

先支持用户明确选择 100% / 75% / 50% 或像素上限；动态降分辨率使用迟滞，防止频繁重建。对文字/像素精确 shader 可固定高质量子 pass，对 blur 等后处理单独半分辨率。采用高成本超分算法前先与简单采样比较功耗。

75% 宽高意味着像素数约为原来的 56.25%，这是几何关系，**不是承诺功耗降低 43.75%**。文本清晰度、codec 解码、WindowServer 合成等不会按相同比例缩减。

**验收：**GPU capture 中内部纹理尺寸确实改变而最终输出尺寸保持正确；letterbox/crop/旋转/鼠标坐标不回归；同质量档位温态持续运行，无分辨率振荡和全场景重复加载。

### A01：音频已有启停，但实时路径与消费者粒度值得继续改

**等级：A：已有实现；C：收益需 profiling。**

`AudioCaptureController` 已有 enabled handles 和全局 suspended gating。Core Audio 回调使用固定 1024-sample scratch，是已有优化；但回调中仍加 Mutex 并同步调用 consumer，consumer 接口本身不限制后续工作量。`AudioResponseResampler` 构造临时 Vec、drain 前缀并生成新的 block Vec，存在可优化的分配/移动路径；本报告未确认所有生产 consumer 都在同一个实时回调内调用该 resampler。[S17][S18]

**实施：**

- 消费者按“可见且启用音频响应的运行实例”聚合；与壁纸声音播放音量分开。把音量设为 0 不等于可以停止用户要求的系统音频响应，反之亦然。
- 实时 callback 只做验证、有限拷贝和入队；用预分配 SPSC ring 或等价有界队列，在工作线程完成降采样/FFT/FFI 分发。溢出丢旧分析数据并计数，不阻塞音频设备。
- 重用 resampler 缓冲，避免 `Vec::drain` 的前缀搬移。按场景可见帧率合并输出，多个消费者共享同一份输入/频谱；不为每层各开一个 tap。
- 12 kHz 目标采样下核查抗混叠处理；线性插值本身不能被当作充分的降采样低通滤波。用高于目标 Nyquist 的合成信号验证，选择满足质量要求的低开销滤波。
- 全部消费者退出或暂停后关闭 tap/analysis timer；暂停瞬间允许有限资源排空，不宣称任何系统调用都绝对不唤醒。

**验收：**实际实时 callback 无堆分配、无阻塞等待、耗时有界；全隐藏无分析提交；不同采样率、设备切换、停止中回调和队列溢出均有测试。

### R03：场景帧图优化应以依赖与带宽为中心

**等级：C；不得覆盖现有 batching/纹理复用优化。**

已有 render graph、last-read 生命周期处理、部分直接呈现和 scratch 复用。[S12][S16] 建议在测量具体 pass 成本后增加：

**静态子图缓存。** 为材质/节点/视频 frame/音频 block/时间依赖建立 generation。只有输入变化才更新该子图；父节点变换、动态 visibility、历史反馈纹理和脚本写入必须参与脏传播。一个不可见 layer 仍可能影响后续 compose、阴影或脚本副作用，不能一律跳过。

**中间目标与 pass 降本。** 优先减少相邻 copy、重复全屏 pass、无需求 mipmap、全尺寸 blur 和不必要的 load/store。按实际资源最后使用点做复用；原生 Metal 后端只在资源确实不跨 pass/帧读取时使用 transient/memoryless 方向。跨 pass 采样、poster 或反馈所需数据不能直接丢弃。

**提交与 CPU 热点。** 不变 descriptor/pipeline/vertex 数据复用；动态 uniform 与粒子数据使用有界 ring；避免每帧 map/string 查找、反射、重复 JSON、堆分配。透明 layer 严格保持绘制顺序，不能只按材质排序换取批次减少。

**粒子/骨骼。** 根据实际 profile 选择可见粒子裁剪、合并更新、SIMD 或 GPU simulation；小粒子数量可能 CPU 更省。不得以“转 compute”作为天然更省电的结论。

**验收：**以每类场景记录 passes/frame、written pixels、GPU 时间、上传字节、CPU allocation 和正确性金图。帧图模式支持开关对照；静态缓存前后的完整时间序列等价，而不只比较某一张静帧。

### D01：多显示器优先共享解码与不可变资源，不强行共享所有状态

**等级：C。**

推荐引入 SourceSession 与 Surface 分离。对于相同文件/属性/播放时钟/音轨/质量约束的镜像视频，一次解码可以由多个呈现 Surface 消费，各自做 crop/scale；每个 Surface 独立可见性。首次只做视频共享，场景共享更谨慎。

需要独立鼠标、日期/网络上下文、属性和随机种子的实例不能直接合并 simulation。能共享的是不可变 package、解压资产、shader 编译结果和可能相同的 texture；共享 GPU 对象还必须处在兼容的 device/队列和生命周期内。当前 VulkanRender 拥有其设备对象，不能只把 map 变全局就合法跨 device 复用。[S12]

SourceSession 的 key 必须包括内容版本与影响输出的配置；引用数应按活跃消费者而非窗口总数。一个暂停消费者不能暂停另一个可见消费者。

**验收：**两个同源镜像视频只建一个期望的解码 session，而异步播放/不同属性不错误共享；任意一屏停用后另一屏继续；两屏均隐藏后 decoder 不再生产新帧。

### E01：锁屏、预览与桌面需要统一“谁有权持续呈现”

**等级：A：多条独立实例路径；C：重复工作风险需追踪。**

锁屏扩展创建独立 renderer，已有静音、禁用音频响应/媒体集成及 `applyPolicy`；普通桌面则由应用策略管理。这不是已确认的锁屏双重渲染 bug，但两套系统与预览 Surface 需要联合观测，尤其在锁屏/解锁、系统预览、多个 Spaces 与通知竞态下。[S03][S20]

**实施：**每个 display/场景使用有界 generation 的呈现授权状态；跨应用和扩展用低频状态消息协调，不做逐帧 CPU 像素 IPC。常驻静态桌面 poster 不得意外维持扩展的持续 simulation。预览优先短时首帧/动画预览后挂起；保留需要持续预览的显式模式。

首帧成功与“允许持续渲染”分开：为 readiness 渲染一帧不应永久取得播放资格。当前 snapshot/readback 按请求产生，后续若改为 GPU 直接导出 IOSurface，要保留最后完成帧的安全所有权。

**验收：**记录各进程的 Surface 状态和提交计数；锁屏、解锁、显示睡眠、预览关闭后，不存在无人消费仍持续呈现的实例。异常时回静态 poster，不请求用户桌面权限作为默认单测步骤。

### F01：Swapchain 错误恢复与故障隔离

**等级：A：局部实现；B：用户可见恢复是否失败需要端到端验证。**

`drawFrameSwapchain` 在 acquire/present 收到非成功且非 suboptimal 的结果时走 `failFrame`，后者置 `m_frame_faulted`。本类没有对 OUT_OF_DATE 提供就地重建后继续播放的分支；上层可能通过重建实例恢复，不能直接断言每次 resize 都永久黑屏。`destroy()` 在某些 quiescence 错误分支会 `std::terminate()`，说明故障影响可能不限于单张壁纸。[S12]

**实施：**将错误分类为可恢复 surface change、格式/能力不支持、内容无效、设备丢失和不可恢复内部错误；分别执行重建 swapchain、回退后端、静态 poster、一次有预算的重新初始化。重建时保留可以证明仍有效的 device-scoped 资产，避免普通尺寸变化就重新解析与上传一切。

进程隔离只在崩溃风险/内容不可信边界确有需要时增加，例如 renderer helper/XPC。跨进程用 IOSurface 等共享呈现载体和低频控制消息，不序列化每帧 RGBA；隔离会增加进程/内存/同步成本，需与 in-process 模式比较，不能声称隔离本身节能。

**验收：**故障注入 acquire/present out-of-date、suboptimal、设备丢失、超时、销毁时仍有在途资源；恢复或降级有明确结果，无无限失败重试、错误帧提交和主 UI 无故退出。

### C01：兼容性缺口、疑似 bug 与非目标明确区分

| 类别 | 当前证据 | 改进方式与验收 |
|---|---|---|
| P010 / 10-bit 视频 | Apple 导入分支主要处理 BGRA32 和 8-bit NV12；其他格式未进入有效导入路径 [S06] | 先明确拒绝/SDR fallback；再加入适当 plane 格式、range 和 tonemap 测试。硬解成功不等于后续像素格式受支持 |
| 无 VideoToolbox 配置的 codec | `openDecoder` 会直接失败，而不是完整的一般软件解码重开路径 [S07] | 硬解优先、有限软件 fallback、功耗提示和可选代理视频；不能静默让高分软件解码长期跑满 |
| HDR / Wide Color | 8-bit BGRA、现有 matrix/clamp 不构成完整 HDR 管线 [S06][S20] | 把 SDR 正确 tonemap 与真正 EDR 输出分成两个能力；后者显式开启并单独测功耗 |
| 视频方向 / SAR / display matrix | metadata probe 存在旋转尺寸交换，但本次未完成所有后续 UV/方向传递追踪 [S07] | 列为 B 级专项测试，不直接报“所有竖视频都会旋转错”：0/90/180/270、镜像、非方形像素均需验证 |
| 视频透明 / 特殊 chroma | 未覆盖所有 YUVA、4:2:2、4:4:4 与编码 profile | 建立按 codec × profile × pixel format 的矩阵；明确不支持项，不仅按扩展名打“支持视频”标签 |
| Web 音频响应与媒体监听 | 文档声明未安装相应监听 API [S21] | 复用统一音频/媒体 provider，feature-detect；只给实际订阅的可见页面数据，不默认 60 Hz 向全部页面推 JSON |
| Web 音量 / mute | 文档声明未应用到页面媒体 [S21] | 建立明确的媒体控制适配，覆盖新增 media element / AudioContext；不能声称一个 HTMLMediaElement volume 遍历能控制全部声音来源 |
| Web 目录属性 / 随机文件 API | 文档声明尚未支持 [S21] | 受控资产枚举与授权根目录，避免任意本地路径访问；异步回调语义匹配 |
| Web 键盘 / 点击路由 | 键盘不转发；Finder 图标点击也镜像到页面；中键号码缺失 [S21] | 先修 button identity；提供显式交互模式，避免为了兼容抢走用户其他应用键盘焦点 |
| Web 私有 API | hover/private KVC keys 存在 [S08] | 能力探测与系统版本 smoke；不把私有方法调用存在当作长期稳定保证 |
| SceneScript / shader / 粒子 / puppet | 已有广泛回归，但 probe 不提供所有作者参考结果 [S16] | 能力报告 + 官方/合法持有的参考时间序列；未知功能诊断到具体资源/层，不默默显示空白后报告完全支持 |

**兼容性报告建议格式：**显示“场景可加载”“已使用的特性”“已回退的功能”“已知缺失”“是否通过参考帧验证”五个独立字段。应用可运行、项目成功导入和视觉等价是不同结论。

### Q02：代码质量与较低优先级能耗清理

**生命周期与接口。** 用 typed handle/RAII 封装 CF、Metal、FFmpeg 和 Vulkan 资源；在 C ABI 处明确 borrowed/owned、线程归属、错误通道、可取消操作和 generation。不要把多个 bool 任意组合成无法检查的运行状态。Web host、应用策略和 renderer 共用语义契约，但不强制使用同一种语言。

**输入。** Scene 原有输入路径已做消费者 gating。[S02] Web 的全局事件 monitor 在存在窗口时启用，宿主暂停不会在这条实现中直接关闭 monitor；每个 move 还需查询前台窗口并可能重新合成事件。[S09][S22] 用实际交互消费者控制启停；move 合并到每个目标呈现帧的最新位置，保留 down/up/drag 顺序；暂停前取消/收尾手势，避免恢复后“按钮一直按下”。这不是空闲时 timer 轮询，收益主要出现在用户持续移动指针时。

**音频与配置重复实现。** 审查多种 controller/decoder 的实际入口和覆盖，减少相同语义在 Rust/C++/Swift 中分别演化。不要仅因为存在第二个软件 decoder 就删掉测试/特殊路径。

**Power watcher。** 已有 IOKit 事件源，只是其工作循环最长每 5 秒返回检查停止标志。[S23] 这是约 0.2 Hz 的低优先级清理，不是主要耗电嫌疑；可用显式唤醒/stop runloop 改善退出延迟。电池/插电事件与系统 Low Power Mode、thermal state 不是同一个信号，新策略应分别处理。

**日志与面板。** 默认只记录生命周期和聚合计数；细粒度逐帧日志仅在限时诊断开启。保留控制面板隐藏更新抑制；只有 profile 证明可见面板热路径值得优化，才调整 snapshot diff、序列化与缩略图。

**私有 API / 资产隔离。** Web 的通用文件访问权限、共享数据存储以及锁屏私有宿主能力需要逐项隔离和可恢复失败。引入 per-project origin/存储与受限 scheme 前，测试 ES module/fetch/media 的兼容性，不能用“全部禁止网络”破坏天气等合法壁纸。能力检查失败应给可理解的降级提示。

**构建与审计。** 固定可复现工具链和实际运行依赖版本，保留补丁来源及升级说明；检查产物链接、许可证清单、包内动态库与架构切片。编译时间和包大小改进不能冒充运行时功耗改进。

---

## 4. 推荐的新运行架构

以下名称为**建议新建的组件**，不是声称仓库已经存在这些文件或接口。

```text
Swift OS adapters
  display / occlusion / lock / sleep / power / thermal / input
                  │ 状态变化，不是每帧全量快照
                  ▼
        RuntimePolicyCoordinator
          ├─ SurfaceRegistry（显示、预览、锁屏与 generation）
          ├─ ActivityBudget（用户档位 + 系统限制）
          └─ VisibleConsumerRegistry
                  │
                  ▼
           SourceSessionRegistry
      内容版本 + 属性 + playback clock + 后端能力
                  │
       ┌──────────┼───────────┬───────────┐
       ▼          ▼           ▼           ▼
 NativeVideo   LegacyScene  NativeMetal   WebSession
 Presenter     Vulkan/MVK   Scene（后续）  WKWebView
       │          │           │           │
       └──── FrameDemand / FrameLease / Lifecycle ────┘
                             │
                 Surface-specific presentation
                  crop / scale / color / poster
```

### 4.1 三个不能混淆的对象

**SourceSession** 管解码/模拟与源数据；**Surface** 管某块屏幕或系统宿主的呈现；**FrameLease** 管一份已生成数据及其 GPU/消费者存活期。一个 source 可以有多个 surface，但暂停、删除和屏幕切换不能打乱共享资源所有权。

控制平面使用小型状态消息；热路径不穿过 Swift Observable 全量状态、JSON 或主线程 actor。需要跨进程时，同样不通过每帧 CPU RGBA 复制实现共享。

### 4.2 运行状态机

| 状态 | 允许的工作 | 退出条件 |
|---|---|---|
| `Preparing` | 有界解析、编译、首帧生成 | 首帧成功、取消、错误或超时 |
| `VisibleDynamic` | 按内容/显示预算解码、模拟、呈现 | 需求停止、遮挡、锁屏或用户暂停 |
| `VisibleIdle` | 保留最后一帧；等待事件/最近 deadline | 属性、视频帧、时钟、输入等变化 |
| `Suspended` | 排空已提交工作；保留必要恢复资源 | 有可见消费者且所有暂停原因解除 |
| `Dormant` | 静态 poster；大资源按策略释放 | 用户选择/重新可见后按策略准备 |
| `FailedPoster` | 显示最后安全帧与诊断 | 显式重试或有限自动恢复 |

暂停不是“FPS = 0 后某个 API 恢复默认 FPS”；应有明确停止语义。保留用户设置的目标 FPS 与临时有效 FPS，退出 Low Power Mode 后能恢复原用户偏好。

### 4.3 FrameDemand 的建议契约

```text
FrameDemand {
    visual_generation: u64,
    next_visual_deadline: Optional<MonotonicTime>,
    continuous_animation: bool,
    consumes_pointer: bool,
    consumes_audio: bool,
    consumes_media_events: bool,
    uncertainty: KnownStatic | KnownDynamic | Unknown,
}
```

这是概念数据结构，不是可直接粘贴编译的现有 API。`Unknown` 不默认静态。调度器可推导下一次需要醒来的时刻，但实际执行必须考虑资源 readiness、显示节奏和多消费者时钟。

### 4.4 不变量

1. 无有效消费者时，不产生新的 decode/simulation/render 工作；允许最后有界帧和系统资源完成退出。
2. 用户 pause 与策略 suspend 正交；恢复可见性不自动解除用户 pause。
3. 同一资源不可在 GPU 完成前重新交给写入者；每个 retained 对象恰好释放一次。
4. 任何队列、临时缓存和重试都有容量/期限；过载时丢弃不再可见的旧工作，而不无限延长队列。
5. 输出分辨率、场景坐标和内部质量分辨率相互独立。
6. 新后端发生能力缺失时可以返回旧后端，不要求重新导入或修改作者原文件。
7. 不同 Surface 的独立交互/属性不能被错误合并；共享只发生在等价输入与明确时钟契约下。

---

## 5. 是否重写架构、渲染器或语言

### 5.1 方案比较

| 方案 | 可能改善什么 | 主要代价 | 建议 |
|---|---|---|---|
| 在当前架构上修生命周期/逐屏策略 | 直接减少不可见工作，风险较低 | 需要打通多后端状态 | 立即实施 |
| 原生纯视频路径 | 避开通用场景、部分跨 API 同步和中间纹理 | 原生 codec/循环/颜色/多屏语义验证 | 最优先的后端试验 |
| 保留 Vulkan，优化等待/帧图/尺寸 | 不牺牲现有复杂场景兼容 | 仍保留 MoltenVK 抽象；同步改造需谨慎 | P1 主线 |
| C++/ObjC++/metal-cpp 原生 Metal | 更直接控制 pass、资源与 Apple GPU | 新后端与 shader 转译投入 | 根据 A/B 收益推进 |
| Rust 编写调度/资源核心 + Metal 绑定 | 更强的所有权与错误边界，减少部分生命周期问题 | unsafe/FFI/平台 binding 仍存在 | 适合新共享核心，不为换语言而迁移所有 parser |
| Swift 全面重写 renderer | Apple API 使用便利 | 重做兼容性；ARC/数组/COW/跨线程热点仍需设计 | 不作为第一阶段节能项目 |
| Rust + wgpu 替换 Vulkan | 可提升抽象统一性与资源验证 | 不自动消除所有抽象开销或带宽；兼容功能受模型约束 | 只作为独立原型，不默认更省电 |
| Web 全换 Chromium/CEF/Electron | 某些 WE Web API/浏览器语义可能更接近 | 进程、内存、功耗和分发成本 | 不以“省电”为理由直接采用 |
| 全部壁纸预渲染成视频 | 简化特定确定性动画运行时 | 丢交互/实时响应、增加磁盘与烘焙成本 | 限定可选能力 |

**关键结论：**现有项目已经使用 Rust 和原生 macOS 技术。把同样的算法、同样的帧率、同样的全屏 pass 从 C++ 改写成 Rust/Swift，不构成可信的节能依据。[S02] 真正应该重写的是资源与工作调度的边界，以及不必要的通用呈现路径。

### 5.2 R04：原生 Metal 场景后端的迁移边界

**先抽象场景语义，后换 GPU API。** 保留现有 package/parser/SceneScript 前端，输出可版本化的 backend-neutral IR：节点与变换、材质输入、blend/depth/cull 状态、shader 接口、render target、动态依赖、视频/字体资源和帧图依赖。

第一批 Metal 后端仅支持已验证子集：静态图层、普通变换、基础透明混合、少量标准 effects 与视频纹理。每项有能力声明，遇到未知 shader、复杂 feedback、特殊 particle/puppet 不做静默近似，回旧后端。

Shader 迁移保留现有解析/反射知识；评估当前工具链能否可靠生成 MSL，而不是假设任意 WE GLSL 经过自动转译都完全等价。测试矩阵覆盖坐标原点、纹理方向、sampler、精度、uniform packing、alpha、matrix convention 和 framebuffer feedback。

可利用 Apple 平台原生资源/命令组织方式减少某些转换和 pass，但 tile/memoryless、argument buffer、FP16、compute、间接绘制和 Metal 4 都是按负载选择的工具，不是必须全部采用的升级清单。FP16 只用于允许误差的运算，不能盲目降低世界坐标/时间/颜色精度。

**继续投入的门槛：**在预先指定的至少三类代表性场景上，以相同输出/真实 FPS/画质与功能比较，原生后端的系统增量能耗有超出测量噪声的稳定优势，且视觉、帧时间、内存无不可接受回归。若收益仅体现在跑满时 FPS 更高，不能据此替换稳定后端。

### 5.3 B01：离线烘焙与静态缓存

静态内容直接缓存完成帧；有限确定性循环可选烘焙视频。候选必须排除：实时音频、鼠标、网络、系统媒体、真实时钟、用户动态属性、不可控随机性以及无法证明的 loop state。

烘焙使用单独离线任务，在用户明确选择、插电且允许资源使用时执行；保留原项目，按源 hash/属性/shader/输出质量生成缓存 key；设置容量、失效与删除策略。GPU 临时编译/编码的能量不能从统计中消失。

理论摊销公式：

```text
若 P_live > P_cached：
    break_even_seconds = E_bake / (P_live - P_cached)
否则：
    没有能耗意义上的摊销收益
```

其中功耗和烘焙能量都要实际测量。简单场景实时渲染可能比解码高分视频更省，不能全局自动烘焙。

---

## 6. M00：以真实能耗而不是单个 CPU 百分比验收

### 6.1 基线边界

记录完整配置：commit、Release/Debug、硬件、macOS build、实际动态库版本、显示器像素/缩放/刷新率、亮度、HDR、插电/电池/充电状态、热状态、壁纸 hash、属性、FPS、后端、窗口覆盖与时长。不能把不同屏幕亮度或输出分辨率的结果直接比较。

优先覆盖普通 Apple Silicon 笔记本与高分多屏负载。可加入 **M3 Max、6880×2880 外屏 + 3456×2234 内屏**作为具体压力配置；两屏合计 27,535,104 像素。此配置来自用户此前提供的信息，执行前应核对当前设备，不视作本次实机检测结果。

基线至少包括：

| 编号 | 状态 | 目的 |
|---|---|---|
| B0 | 退出应用，系统静态壁纸 | 系统基础噪声与显示功耗 |
| B1 | 应用启动但无活动壁纸，面板关闭 | 宿主基础成本 |
| B2 | 相同内容静态 poster | 分离动画成本与画面/合成差异 |
| T1 | 单屏静态/低频时钟/普通场景 | 检查静态 tick 与脏传播 |
| T2 | 1080p/4K/超宽视频，24/30/60 FPS | 解码、转换、帧率、池预算 |
| T3 | 简单/多层后处理/粒子/视频纹理场景 | 分离 CPU、GPU 与带宽 |
| T4 | 配合暂停与不配合暂停的 Web | 验证宿主实际节能 |
| T5 | 双屏一可见一遮挡、均遮挡 | 逐屏与共享消费者 |
| T6 | 锁屏、解锁、息屏、系统预览 | 应用/扩展的联合所有权 |
| T7 | 频繁换壁纸、热插拔、窗口/分辨率变化 | 回收、恢复和泄漏 |
| T8 | 故意坏输入/不支持格式/反复 Web crash | 错误路径是否持续耗电 |

壁纸素材使用自行生成或合法持有的本地测试 corpus；不要把完整 Workshop 版权资产打包进公开 CI。

### 6.2 指标与工具

- **系统级功耗/能量**：可用的 `powermetrics` CPU/GPU/平台采样、经过验证的电池/平台能量计数，或实验室外部功率仪；先检查本机 `--help` 与支持的 sampler，不硬编码所有 Mac 都支持同一个 energy 字段。
- **因果分析**：Instruments CPU/Time Profiler、Metal System Trace/性能工具、GPU capture、调度/唤醒、内存分配与 page fault。Power Profiler 按实际 Xcode/目标设备支持情况使用，不假定所有指标在所有 Mac 可用。[A07]
- **进程范围**：应用、renderer/helper、WebContent、锁屏扩展和 WindowServer 都计入观察；不能只看 App 进程 CPU 就声称整体变省电。
- **渲染质量**：实际呈现 FPS、重复帧/丢帧、p50/p95/p99 frame time、首帧/恢复延迟与视觉误差。

Activity Monitor 的 Energy Impact 不等于瓦数；GPU utilization 不等于能量。外接显示器自身功率和 Mac 芯片功率不是一个计量范围，必须明确。面板亮度或 HDR 导致的显示能耗变化不能归功于 renderer 算法。

### 6.3 低开销可观测性

建议新增限时诊断开关及每 1–5 秒聚合输出（默认关闭高频详细 tracing）：

```text
surface_id, source_id, generation, backend, effective_policy
render_requested, render_submitted, presented, duplicate_content_presented
decode_requested, decoded, decoded_discarded, hardware_decode_active
video_convert_count, new_video_generation_count
texture_alloc_count, texture_pool_hit/miss, gpu_resident_bytes
bytes_uploaded, bytes_readback, cpu_wait_ns, gpu_pass_count
script_ticks, audio_blocks, active_audio_consumers, pointer_deliveries
reload_count, recovery_count, failure_reason, active_timer_count
```

用 signpost 关联 `decode → convert → submit → complete → present`，同时记录 input/state 变化；Release 下默认不逐帧打印文本。异步 GPU 时间要来自正确完成点，不能把 CPU encode 时间当成 GPU 执行时间。

### 6.4 实验协议

固定一项改动，以 A/B/A 或交错顺序运行；先预热 shader/cache 和温度，再进行每次约 5–10 分钟的稳定窗口，重复至少 3 次，有条件则 5 次以上。冷启动、解码首帧、首次 shader 编译单独报告，不混入长期稳态平均。

这些时间是**建议实验窗口**，不是本次交付时间，也不表示报告已经做过测试。用户尚未授权真实桌面改动、截图、音频采集或系统权限操作时，先运行无桌面合成测试；真实能耗实验由独立授权执行。

```text
增量平均功耗 = 活动条件平均功耗 - 配对基线平均功耗
增量能量     = ∫(活动条件功耗 - 配对基线功耗) dt
节能率       = (旧增量功耗 - 新增量功耗) / 旧增量功耗
```

旧增量功耗接近噪声或小于等于零时，不报告不稳定的巨大节能百分比；报告绝对差和离散程度。把渲染从 60 FPS 降到 30 FPS 的数据归类为“质量/流畅度档位节能”，不是“同质量算法节能”。

### 6.5 建议发布门槛

以下为**项目应采用的目标，不是已测成绩**。

| 项目 | 验收目标 |
|---|---|
| 暂停/息屏 | 有界排空完成后，独占消费者不再 decode/simulate/submit；电量结果接近配对静态基线的测量噪声范围 |
| 静态壁纸 | 首帧和必要事件之后没有周期 render；不为检测静态而每帧截图 |
| 超宽视频 | 温态固定尺寸时转换目标重复利用，没有每帧创建/销毁纹理 |
| 视频正确性 | 不丢 EAGAIN packet；EOF 处理完 delayed frames；循环和 PTS 测试通过 |
| Web 挂起 | 媒体暂停且满足脱窗策略；测试页计数停止/符合 documented exceptions，恢复不丢宿主配置 |
| 新视频后端 | 同真实 FPS 与输出下能耗优势超过噪声，且无可见色彩/循环/缩放回归 |
| 异步化 | 队列有界，无资源提前释放；不能以更高 GPU 忙碌率/吞吐替代省电证据 |
| 故障恢复 | 有限重试后能恢复或留在静态错误态，不持续重建/忙等 |
| 新 Metal 场景后端 | 所声明特性通过时序参考测试；未支持项可靠回到旧后端 |

可以预先登记相对能耗收益的项目门槛，但应基于 M00 的噪声水平与负载重要性制定，不由代码阅读凭空承诺“降低 50%”。

---

## 7. Q01：测试与代码交付拆分

现有 `scripts/test.py` 与 Rust/C++/GPU 检查是分层的；不能把默认 Swift 测试成功当作整个渲染器成功。`scripts/check_renderer.py` 已做 pooled/isolated 对照和已知像素断言，但文档明确 `full_compatibility_verified: false`；offscreen scene probe 也不等于纯视频、Web 或 AppKit 呈现验证。[S15][S16]

### 7.1 CI 分层

**无设备测试层：**Swift 状态机/页面身份/代际重放；Rust policy/source registry/生命周期；C++ codec API 状态机和 parser；恶意/损坏输入 fuzz 与资源额度；确保 skipped cases 显式统计。

**Apple GPU 层：**使用现有 synthetic IOSurface/probe 能力，增加 V02 生命周期、P010/颜色、超预算池、同步依赖、尺寸变化与帧图金图；独立 job 运行，失败不可被普通单测掩盖。

**授权桌面层：**真实 NSWindow 遮挡、Spaces、桌面输入、Web 脱窗/恢复、锁屏/扩展、首帧与热插拔。它们不能偷偷加入默认测试抢占用户桌面。

**功耗层：**在稳定自托管硬件上做配对趋势测试；控制热态/充电/后台任务，不使用噪声大的单次 CI 值硬判 1% 差异。原始样本、配置和版本必须随结果归档。

### 7.2 回归资产

Synthetic fixtures：有限灰阶/色条、透明合成、多级 compose、含时间 uniform 的 shader、静态文字与日期文字、隐藏但有副作用的脚本、B 帧循环、奇数尺寸、不同 chroma、旋转/SAR、坏流、嵌套 Web 入口、非配合暂停页、反复 crash 页、音频高频/不同采样率。

真实 corpus：按复杂度/特性分类，私有环境变量指向合法资产；新增 Windows 原引擎参考结果时记录版本、属性、随机种子/时间、分辨率和依赖。不在没有参考的情况下输出“完全兼容”。

### 7.3 每个 PR 的完成定义

每个 PR 必须包含：触发问题的最小用例；修改前后可观察结果；受影响文件；功能开关/回滚；资源所有权说明；对应测试层；功耗相关变更的等条件计数与测量结果，或明确标注尚未测量。

不要把格式化、语言迁移和行为改变混在同一大 PR 中。先加失败用例，再修复；新后端默认仅覆盖经过验证的特性子集。

---

## 8. 实施阶段与可直接执行的工作包

### 阶段 A：冻结基线与修明确缺陷

**工作包：M00、V01、V02、W01、V03。**

输出：固定 benchmark manifest 与限时 counters；FFmpeg 正确状态机；VideoFrameLease；Web canonical identity + committed snapshot + 重启预算；SDR range/颜色回归。

进入下一阶段的门槛：已有项目测试与新反例通过，没有新增泄漏/崩溃/颜色回归。记录当前功耗基线，但不等待所有大型性能工作才能修这些确定性错误。

### 阶段 B：让后台真正停止

**工作包：P01、W02、P02 第一版、A01 gating、E01。**

先落地逐屏 policy 与有效消费者，不要求同时完成整个 FrameDemand 系统。静态/低频内容从最可证明的子集接入，未知内容继续安全运行。

输出：SurfaceRegistry、统一状态表、Web 脱窗挂起与恢复、音频/输入/解码消费者控制、应用/扩展联合诊断。

门槛：双屏隐藏场景的计数器不再增长，真实系统 A/B 证实后台功耗下降；所有用户 pause/锁屏/恢复行为保持正确。

### 阶段 C：优先解决长期播放开销

**工作包：V04、V05、R01、R02、I01。**

先对纯视频做独立后端 A/B；同时修现有转换池的大尺寸预算与原文件输入。对旧后端的异步化采用独立开关，避免一次同时改变解码、颜色、同步和呈现，失去归因能力。

输出：原生视频 adapter；可选择的旧后端；内部 renderScale；格式/后端诊断；转换与内存预算报告。

门槛：同质量测量收益成立、颜色/音频/循环/多屏正确；没有收益的候选保留实验状态或删除，不强制切换所有视频。

### 阶段 D：场景精细优化与兼容性补齐

**工作包：R03、D01、C01、F01、Q01。**

按 profiler 显示的高成本场景逐个加入静态子图/合并 pass/适当降采样；先共享视频 source 和不可变资产，再决定是否共享 simulation。按实际 corpus 覆盖补 Web API、特殊视频格式和图形语义。

门槛：效果可定位到减少的 pass/更新/字节，时间序列对照通过；错误可恢复或安全降级，不能出现只追求性能的视觉近似。

### 阶段 E：决定是否投入原生场景渲染器

**工作包：R04、B01。**

只迁移统一 IR 的受控子集。每新增一个复杂特性都要说明：是否确实带来兼容性或能耗收益、哪些旧后端用例可替代、哪些继续回退。烘焙单独选择与计费/容量/能量统计，不与实时兼容性混为一谈。

### 建议首批 PR 顺序

| PR | 范围 | 不应混入的内容 |
|---|---|---|
| 1 | M00 的最小 counters + benchmark manifest +现状记录 | 大范围架构重写 |
| 2 | V01 FFmpeg 状态机与合成视频回归 | 新视频呈现后端 |
| 3 | V02 Core Video lease / completion 生命周期 | 无界 GPU 多帧并行 |
| 4 | W01 Web 重放、身份与崩溃预算 | 全面替换 WebKit |
| 5 | V03 颜色范围修复与已知像素测试 | 未完成定义的“完整 HDR 支持” |
| 6 | P01 逐屏状态与消费者 gating | 所有场景静态分析 |
| 7 | W02 Web 实际挂起、输入 gating 与恢复 | private WebKit 进程冻结 |
| 8 | R02/I01 可独立验证的内存与源文件路径 | 全部缓存架构迁移 |
| 9 | V04 原生纯视频 A/B | 自动替换所有场景 |
| 10 | R01/P02 按测试拆分的分辨率与按需调度 | 为追求低功耗静默改动画速度 |

---

## 9. 给实施者的约束

- 从本报告固定 SHA 新建工作分支；若 main 已变化，先重新确认问题是否仍存在，不按旧源码覆盖新修复。
- 以仓库现有测试和 contributor/agent 规则为准。默认不启动桌面自动化、不改变系统壁纸、不采集音频、不替换已安装应用；这些操作需要独立授权。
- 不把这里的设计组件名称当成现成代码；先定位实际调用方，再做最小接口迁移。
- 每个问题保留证据与状态：`confirmed-in-code / reproduced / fixed / visually-verified / power-verified`，分别填写，不用一个 PASS 包办。
- 不为提高“兼容率”吞掉错误、关闭诊断或移除独立像素断言。没有实际跑到的私有资产用例是 skip，不是 pass。
- 不通过删除 GPU 等待、无界缓存、忽略取消、压制异常或缩短动画内容获得虚假的性能优势。
- 项目原文件保持不变；缓存/代理视频为可删除的派生资产，用户属性和暂停状态可恢复。

## 10. 审查结论

最值得先投资源的是 **逐屏与 Web 实际挂起、正确且可取消的解码器、视频呈现路径简化、大尺寸纹理复用、内部渲染分辨率、内容驱动调度**。它们既能直接对应当前源码，也适合用明确的计数和功耗实验验证。

原生 Metal 场景后端具有试验价值，但应建立在统一 IR、可靠兼容性回归和能耗基线之上；全面语言重写不应成为前置条件。目标不是“把每帧跑得更快然后继续多跑”，而是**只运行用户看得见、且确实需要运行的工作，以最短且正确的路径呈现它**。

---

## 附录：固定源码与官方参考

下面的源码链接均指向本报告固定提交；源文件中的函数名/行为是定位依据，不依赖会变化的 main。个别大文件只审查了正文说明的片段，不能据此宣称整仓库完整覆盖。

### 源码索引

- **S01** — [项目 README](https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/README.md)；`README.md`。
- **S02** — [总体架构 / 数据流 / 输入与面板设计](https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/docs/architecture.md)；`docs/architecture.md`。
- **S03** — [全局呈现策略](https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/App/Services/Desktop/WallpaperPresentationPolicy.swift)；`App/Services/Desktop/WallpaperPresentationPolicy.swift`。
- **S04** — [纯视频构造为场景（重点审查文件前 300 行）](https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/upstream/renderer/external/open-wallpaper-engine/src/Scene/SceneWallpaper.cpp)；`upstream/renderer/external/open-wallpaper-engine/src/Scene/SceneWallpaper.cpp`。
- **S05** — [Rust 软件视频解码路径](https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/upstream/renderer/crates/core/src/media/video/decoder.rs)；`upstream/renderer/crates/core/src/media/video/decoder.rs`。
- **S06** — [Apple 视频互操作 / 色彩转换 / 纹理池](https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/upstream/renderer/external/open-wallpaper-engine/src/Platform/Apple/FfmpegVideoInterop.mm)；`upstream/renderer/external/open-wallpaper-engine/src/Platform/Apple/FfmpegVideoInterop.mm`。
- **S07** — [生产 C++ 视频解码器与临时文件路径](https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/upstream/renderer/external/open-wallpaper-engine/src/Video/FfmpegVideoTextureSource.cpp)；`upstream/renderer/external/open-wallpaper-engine/src/Video/FfmpegVideoTextureSource.cpp`。
- **S08** — [WebView 页面 / JS 回调 / 崩溃恢复](https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/App/Services/WebWallpaper/WebWallpaperWindow.swift)；`App/Services/WebWallpaper/WebWallpaperWindow.swift`。
- **S09** — [逐显示器 Web 窗口 / descriptor diff / poster](https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/App/Services/WebWallpaper/WebWallpaperHost.swift)；`App/Services/WebWallpaper/WebWallpaperHost.swift`。
- **S10** — [渲染帧定时器与单帧背压](https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/upstream/renderer/external/open-wallpaper-engine/src/Scene/Timer/FrameTimer.cpp)；`upstream/renderer/external/open-wallpaper-engine/src/Scene/Timer/FrameTimer.cpp`。
- **S11** — [条件变量计时线程](https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/upstream/renderer/external/open-wallpaper-engine/src/Scene/Timer/ThreadTimer.cpp)；`upstream/renderer/external/open-wallpaper-engine/src/Scene/Timer/ThreadTimer.cpp`。
- **S12** — [Vulkan 呈现 / 同步 / render extent / 恢复](https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/upstream/renderer/external/open-wallpaper-engine/src/Scene/VulkanRender/VulkanRender.cpp)；`upstream/renderer/external/open-wallpaper-engine/src/Scene/VulkanRender/VulkanRender.cpp`。
- **S13** — [原生后端构建与链接](https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/upstream/renderer/external/open-wallpaper-engine/src/CMakeLists.txt)；`upstream/renderer/external/open-wallpaper-engine/src/CMakeLists.txt`。
- **S15** — [测试分层与可验证性边界](https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/docs/testing/README.md)；`docs/testing/README.md`。
- **S16** — [GPU probe / 已有语义回归 / 兼容性限制](https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/docs/testing/renderer.md)；`docs/testing/renderer.md`。
- **S17** — [Core Audio capture / callback（审查主要实现 1–270、300–600 行）](https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/upstream/renderer/crates/core/src/media/audio/capture.rs)；`upstream/renderer/crates/core/src/media/audio/capture.rs`。
- **S18** — [音频 controller / resampler（审查前 550 行）](https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/upstream/renderer/crates/core/src/media/audio/mod.rs)；`upstream/renderer/crates/core/src/media/audio/mod.rs`。
- **S20** — [锁屏 Surface 与策略（审查前 280 行）](https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/Extension/WallpaperSurface.swift)；`Extension/WallpaperSurface.swift`。
- **S21** — [Web 壁纸已声明的不支持功能](https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/docs/features/web-wallpapers.md)；`docs/features/web-wallpapers.md`。
- **S22** — [Web 指针路由与 event monitor](https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/App/Services/WebWallpaper/WebWallpaperMouseForwarder.swift)；`App/Services/WebWallpaper/WebWallpaperMouseForwarder.swift`。
- **S23** — [IOKit 电源通知与 runloop](https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/upstream/renderer/crates/bridge/src/power.rs)；`upstream/renderer/crates/bridge/src/power.rs`。

### 官方 API 参考

- **A01** — [FFmpeg send/receive、EAGAIN 与 EOF drain 契约](https://ffmpeg.org/doxygen/trunk/group__lavc__encdec.html)。
- **A02** — [Apple：CVMetalTextureCache 包装对象须保留到 GPU 使用完成](https://developer.apple.com/documentation/corevideo/cvmetaltexturecachecreatetexturefromimage(_:_:_:_:_:_:_:_:_:))。
- **A03** — [Apple：CAMetalDisplayLink preferredFrameRateRange](https://developer.apple.com/documentation/quartzcore/cametaldisplaylink/preferredframeraterange)。
- **A04** — [Apple：WKWebView 媒体暂停公开 API](https://developer.apple.com/documentation/webkit/wkwebview)。
- **A05** — [Apple：脱离窗口后的任务策略与豁免条件](https://developer.apple.com/documentation/webkit/wkpreferences/inactiveschedulingpolicy-swift.property)。
- **A06** — [FFmpeg：YUV/RGB range 参考实现（7.1，有限/全范围处理）](https://www.ffmpeg.org/doxygen/7.1/yuv2rgb_8c_source.html)。
- **A07** — [Apple：功耗分析与多次前后测量方法](https://developer.apple.com/documentation/xcode/measuring-your-app-s-power-use-with-power-profiler)。
- **A08** — [Apple：Metal Display Link 节奏和能效设计](https://developer.apple.com/documentation/metal/achieving-smooth-frame-rates-with-a-metal-display-link)。

### 引用定义

[S01]: https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/README.md
[S02]: https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/docs/architecture.md
[S03]: https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/App/Services/Desktop/WallpaperPresentationPolicy.swift
[S04]: https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/upstream/renderer/external/open-wallpaper-engine/src/Scene/SceneWallpaper.cpp
[S05]: https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/upstream/renderer/crates/core/src/media/video/decoder.rs
[S06]: https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/upstream/renderer/external/open-wallpaper-engine/src/Platform/Apple/FfmpegVideoInterop.mm
[S07]: https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/upstream/renderer/external/open-wallpaper-engine/src/Video/FfmpegVideoTextureSource.cpp
[S08]: https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/App/Services/WebWallpaper/WebWallpaperWindow.swift
[S09]: https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/App/Services/WebWallpaper/WebWallpaperHost.swift
[S10]: https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/upstream/renderer/external/open-wallpaper-engine/src/Scene/Timer/FrameTimer.cpp
[S11]: https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/upstream/renderer/external/open-wallpaper-engine/src/Scene/Timer/ThreadTimer.cpp
[S12]: https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/upstream/renderer/external/open-wallpaper-engine/src/Scene/VulkanRender/VulkanRender.cpp
[S13]: https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/upstream/renderer/external/open-wallpaper-engine/src/CMakeLists.txt
[S15]: https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/docs/testing/README.md
[S16]: https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/docs/testing/renderer.md
[S17]: https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/upstream/renderer/crates/core/src/media/audio/capture.rs
[S18]: https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/upstream/renderer/crates/core/src/media/audio/mod.rs
[S20]: https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/Extension/WallpaperSurface.swift
[S21]: https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/docs/features/web-wallpapers.md
[S22]: https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/App/Services/WebWallpaper/WebWallpaperMouseForwarder.swift
[S23]: https://github.com/bobbyhuang-dev/mac-wallpaper-engine/blob/6dc8c327c6f7e2594d84722413f11d7168eb5898/upstream/renderer/crates/bridge/src/power.rs
[A01]: https://ffmpeg.org/doxygen/trunk/group__lavc__encdec.html
[A02]: https://developer.apple.com/documentation/corevideo/cvmetaltexturecachecreatetexturefromimage(_:_:_:_:_:_:_:_:_:)
[A03]: https://developer.apple.com/documentation/quartzcore/cametaldisplaylink/preferredframeraterange
[A04]: https://developer.apple.com/documentation/webkit/wkwebview
[A05]: https://developer.apple.com/documentation/webkit/wkpreferences/inactiveschedulingpolicy-swift.property
[A06]: https://www.ffmpeg.org/doxygen/7.1/yuv2rgb_8c_source.html
[A07]: https://developer.apple.com/documentation/xcode/measuring-your-app-s-power-use-with-power-profiler
[A08]: https://developer.apple.com/documentation/metal/achieving-smooth-frame-rates-with-a-metal-display-link
