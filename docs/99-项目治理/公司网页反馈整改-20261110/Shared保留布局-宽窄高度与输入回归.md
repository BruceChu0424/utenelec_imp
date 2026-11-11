# Shared 保留布局：宽窄、高度与输入回归

产品基准 `4d45dc9b6c291e9d8e9121b48017b69030fd1f4c`。宽度根因提交 `fa157d1114f9a945215f46c8ac3e3950a6fbbf0f`（Root 纳为47），高度/紧凑Header增量 `23566b68e15b323496e0f85b165a02ae20bd9c73`。独立工作树 `D:/Projects/uten_imp_worktrees/feedback-split-20261111`；所有原始日志、失败原型和脚本运行回执位于 `evidence/split-20261111`，没有改 Root 活库、共享 SDK、Main 或业务写权限。

本报告是共享控件/完整Widget宿主证据，不把 Widget VM 当真实 Web/Windows。Root 实际Web47已另确认：完整1280→714时原RenderLayoutBuilder首错消失，但真实ellipsis菜单后来出现新的Scheduler断言，仍未由本报告判为解决。

## 原因与公共入口

LayoutBuilder 在布局回调中有独立 BuildScope。原 Adaptive 根据宽度把带同一 GlobalKey 的 leading/trailing 从 Row 迁到 Stack；活 Tooltip 的 OverlayPortal.activate 会在新 render 父链尚未attach时重新激活 deferred render child。历史已经布局的 overlay box 在不相关布局子树被重新标脏，引发原首错。SDK原行与原栈均保全，未修改SDK或关闭断言。

Shared 宿主现在让 leading、trailing、Header 和gutter保留固定 Element/render 槽位，仅更新约束、offset和可见性。UtenSplitView 是 Adaptive 唯一生产调用方，所有既有Split调用方沿这个公共入口；Adaptive 的私有 splitBuilder 迁为显式宽度/分隔控件，两个直接测试调用方同步迁移，断言原值不变。

600高度仍有原 Column→Collapsing 迁移，已用独立真实控件抓到header/body活Tooltip各自红例。Adaptive 新配置 `stableBodyViewport` 复用同一viewport与primary-controller拓扑；高视口填剩余高度、矮视口按原最小body滚走header，输入不迁父槽。Collapsing 其他调用方默认保持原路径。

应用的 `UtenControlTheme` 通过 `UtenCompactPresentationScope` 决定iconSearch，裸MediaQuery缩窄不代表跨此分支。真实Scope false→true时原Header还会搬控件或剥wrapper，造成活Tooltip重挂或普通ValueKey编辑器丢IME。Header现为固定Flex槽，`utenCompactToolbarChild` 的新 `preserveWrapperState` 策略只在本入口启用；其他调用方默认行为不变。PageEdgePadding.copyWith保留pane/边距语义，输入、controller、focus与回调不被换掉。服务端权限、原资格、请求范围和所有数据props继续即时生效，未缓存旧业务Widget或放松数量/生命周期边界。

## 已执行证据

| 分栏 | 结果与原件 |
| --- | --- |
| 独立最小宽度原例 | 实际minTwoPaneWidth=840，1280→714确实split→compact；leading/trailing Tooltip关闭2绿、可见2红，`baseline-minimal.log`。默认600不跨界的早期探针不列通过。 |
| 宽度修后 | 同原4例4/4；原完整FullUtenApp/GoRouter/PlatformTables/Mould 1626的category hover→714原红、none合法控制均过。独立review另从原样源复跑47也4/4及Full原例1/1/none1/1。 |
| 高度原例 | `height-active-baseline.log`：800→300，header/body Tooltip关闭绿、可见各红；原7.125与Element断言保留。稳定viewport后4/4。 |
| 实际应用Header原例 | 必须实际ControlTheme并断言iconSearch false→true、resize前IME已建立。fresh进程 `actual-header-visible-fresh-red.log`、`actual-header-value-fresh-red.log` 各exit1；修后GlobalKey/ValueKey×有无Tooltip共4/4。 |
| 快速极端回归 | leading/trailing Tooltip×LTR/RTL，各24次即刻宽高交替（1280/714/540、320/420/650/764/800/900），保留精确7.125、输入Element、composing/focus、连续更新selection，原断言全过。 |
| 最终共享15文件 | `commit-boundaries-15.log`：83通过、0失败、1既有 `UTEN_CAPTURE_UI` 可选截图skip，exit0。含宽度、控制/拖动/持久化、短高目录可达、IME/focus、scroll/touch/primary、semantics、正文边缘、窗口/软键盘等原合法控制。 |
| 完整Mould宿主 | `final-full-mould.log`：真实生产控件装配、受控API的VM原category/none两例2/2；不冒充HTTP或实际Windows。 |
| 分析/SDK | `commit-analyze.log`：11个定向文件，0问题、exit0。原一次新测试unused underscores info已修、不加ignore；私有Flutter工具/TMP，保护SDK字节未变。 |

## 保留的失败和未验项

只把canSplit延至post-frame仍2红，因为其State仍在LayoutBuilder私有BuildScope；加局部Overlay也仍红。日志/源码diff分别为 `prototype-deferred-mode-*`、`prototype-owned-overlay-*`，没有把延期、关Tooltip或固定120ms当修复。旧宽度helper误取“首个SizedBox.width”得到Infinity，改为实际leading render尺寸后仍逐项断言原300/220/428/拖动/持久化预期，未改松边界。

Header夹具首次在focus尚未建立时就设置composing，产生夹具时序失败；源/日志保留，修正后显式断言resize前IME范围。未装应用CompactPresentationScope的embedded对照也保留为合法控制，不能声称覆盖iconSearch。实际ControlTheme的真红才作为Header修复依据。所有这些组保持独立，不累加为全端通过总数。

新菜单Scheduler回调断言、真实Windows714压力与最终统一候选的完整UI仍由Root/独立运行继续验收，不能用本控件绿盖住。当前未合并Main、推送、部署、安装或正式打包；Win7/公司原单与设备未因此计通过。
