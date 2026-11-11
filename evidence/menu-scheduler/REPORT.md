# 菜单 Scheduler / 回宽布局独立诊断

本阶段没有编写或修改任何生产文件。隔离树 `D:/Projects/uten_imp_worktrees/feedback-menu-scheduler-20261111` 从 Root实际 `4e5a0a4b0c6bc9fa65a35c73c045dac8684df3a0`（原47产品）开始，保存原例后仅在本隔离分支 fast-forward 到 Root `14e7be5e7e9278c1b0f2a8732fde95f0b9a592a0`（A235产品）做同夹具对照；差异只有A的4个布局产品文件及3个测试。main、Root工作树、A生产文件和运行中的服务/账号/ACL/数据库未操作。未推送、部署或正式打包。

## 当前可支持的结论

1. **原47与235在完整真实主外壳的回宽步骤均仍有RLB首红**。动作：合成1626模具行/扩展值 → 真实点击“全部模具” → 1280×720 → 714×764 → 实际ellipsis显示“预览打印/导出模具” → Escape → 回1280×900。首错phase为 `restore-wide`，`_RenderLayoutBuilder` mutation，`OverlayPortalElement.activate → Theater._addDeferredChild`。相关widget为CollapsingHeader `_SqueezeGuard` 的LayoutBuilder（47行894、235行905），后继为hierarchy Tooltip（936）。已交A继续修，不能算235完整应用已闭环。
2. **本夹具未复现真实Web的SemanticsNode child.attached Scheduler首错**。有效semantics轮在235从mount启用、收窄后开菜单前启用两种时点，均明确 `tester.ensureSemantics()` + `SemanticsBinding.instance.semanticsEnabled` true断言，日志 `MENU-SEMANTICS ... actual=true`。VM两时点、headless Chrome晚启用轮均在开菜单/Escape期间没有该Semantics首错，最终仍被回宽RLB阻断；这绝不等于真实Web已修好或排除真实问题。
3. Root的真实Web原47和235内置日志均已抓到不同的有效首错：`SemanticsNode._replaceChildren` 的 `assert(!child.attached)`。Root47为11:09:54.036Z，菜单打开即首红；Root235为11:41:16.704Z，额外分类抬头变体，Escape+回宽两动作当时未分采样，不能精确归因其中一个动作，也不能用不同scope宣称原ALL例已关闭。两个首条flutter.error原JSON行及原文件hash存本目录，完整原文件由Root保全。

## 必须保留的夹具错误及降级

我在诊断中有一次未校验文本替换是否命中的错误：早期名字虽写 `semantics=true`，实际没有创建handle。发现后已立即向Root/A更正，**这些轮次全部降级为无semantics控制**，不作可访问性结论。原代码快照、日志、随后编译暴露的错误均保留，未覆写。

| 原日志tag | 实际状态与用途 |
|---|---|
| full-app-first | 缺MainShell的UtenApp初版，2个fixture标签错误（把“预览打印”写成“打印”），非产品Scheduler红 |
| full-app-mouse | 真mouse动作，无MainShell；仅debugTarget恢复晚于test invariant导致两红，非产品首错 |
| full-app-mouse-cleanup | 无MainShell、无semantics，两组menu/Escape/回宽绿；只作较弱控制，不能代替完整主壳 |
| actual-shell-vm | 加BusinessWindowHost+MainShellPage+实际/basicinfo/mould路由；无semantics，首例回宽真实RLB，第二例树已坏后No element是后果 |
| semantics47-first | 名字替换未命中，筛选没选到任何测试；不是业务红 |
| semantics47-exact | **误标，无handle**；47回宽RLB真实，不能作semantics结论 |
| candidate235-same-vm / candidate235-chrome-semantics | **误标，无handle**；235回宽RLB真实，不能作semantics结论 |
| candidate235-chrome-late-semantics | 中间插入遗漏local，编译错误 `semanticsHandle` setter undefined；没有进入产品，原红保留 |
| real-semantics235-mount-vm | **真正启用且断言true**，开菜单无Scheduler，回宽RLB |
| real-semantics235-late-vm | **真正启用且断言true**，开菜单无Scheduler，回宽RLB |
| real-semantics235-late-chrome | **真正启用且断言true**，开菜单无Scheduler，回宽RLB |

日志中的 `MENU-FIRST-ERROR` 标记由handler打印每个error；判断首错只取时间上第一条，不能把后继异常误称另一个独立首因。handler打印完整原stack后仍交原Flutter handler处理，未屏蔽断言或改SDK。所有过程自然结束，未取消失败轮。

## 复现边界与证据

夹具使用真实UtenApp、ControlTheme、DisplayZoom、PlatformTablesHost、BusinessWindowHost、MainShellPage（含左Rail、主Tab保活）、MouldCategoryPage/分类树/详情表与实际UtenActionOverflow/AnchoredPopup。数据、身份、API响应全为本地合成，未接Root账号、浏览器或PG。以同一个冻结夹具对照47与235，原47文件树/夹具SHA在 `source47-proof.json`；真正semantics冻结夹具在 `probe-real-semantics.dart.txt`，两处ensure和finally dispose及assert均由 `source235-proof.json`校验。两个误标旧快照也原位保留，不把它们改成后来的正确夹具。

Root提供的实际Windows below-min714首JSON位于其独立Windows证据树（sha256 `214ac0586adac1317d05e4d66b4a21637732dbf84843520fc907dff09bfb9191`），phase `mould-wide-restored`，与本RLB原例同型；本文不替代该native原件，也不把它与Web Semantics自动合并归因。

运行命令与SDK前后hash在各tool receipt；共享SDK未修改。原日志/JSON/夹具快照以binary属性保留字节。manifest按归档Git blob列SHA-256。没有新的绿色发布或性能结论。

复跑 `./evidence/menu-scheduler/rerun.ps1 -Tag 唯一标签 -Platform vm -Timing mount`，Chrome改Platform；晚启用改Timing beforeMenu。默认semantics=true。脚本只在目标测试文件不存在或字节一致时复制归档夹具，不覆盖并行文件；建议独立工作树，并按实际被测HEAD单列结果。诊断probe未加入日常suite，避免把尚未修复的独立反例悄悄混进已冻结验证。Root/A继续持有产品修复及真实Web验收，本阶段仅交诊断证据。
