# C收口交接：已完与未完严格分开

## 已完成可纳

- Panel产品83712ff8a412d325039bc99fbf05d0dbdad06fa1，Root已纳4664a939e。原3红、最终11绿、3文件分析0、Chrome pointer阴性2绿均在本目录。不得把阴性控制改称真实pointer修复。
- 之前C最终7b报告在feedback-final-c-20261110/evidence/c-final，产品源仅认7b912287，146项145过1私有skip及v1/v2/原件/公开PG证据不改标。
- Main语义整合c45c76c73、证据e31a06128；公共query publication修b0fe9f7f6、证据c83a1b576；完整主壳诊断7a0d26aed均已交Root。各自只认报告源版本。

## 未完Native view焦点

独立诊断树：D:/Projects/uten_imp_worktrees/feedback-posting-native-diag-20261111，分支uimp/feedback-posting-native-diag-20261111，HEAD178e5a295091b4e817676e6fe0e224b2765fd5ae。

仅诊断dirty生产副本2文件：lib/components/inputs/uten_dropdown_field.dart、lib/components/feedback/uten_overlay_lifecycle.dart。只是metadata trace，未修guard；完整patch在native/instrumentation-formatted.patch。evidence/posting-diag-native下main.dart、browser_focus.dart、web/、私有工具、构建日志、源码hash均本机保留；归档源码副本用.dart.txt避免进入正式分析。不得把dirty trace merge进产品。

native/只作原始位置源码归档，private_flutter.py复用时需恢复到evidence/posting-diag-native原层级；不要直接在native子目录执行而误算项目根。

真正原生复现原件：C:/Users/bruce/Downloads/UTEN-2.5.52-1794403069414.log，本目录native/raw副本及hash已保。Root普通/真实数据无关，纯内存合成也复现；无select-guard，首close=lifecycle、life=false、geometry=true。新JSON/标签/frame/业务数据均未伪造。

SDK核实路径（本机D:/Software/Flutter/flutter/bin/cache/flutter_web_sdk/lib/_engine/engine）：

- platform_dispatcher/view_focus_binding.dart:57-70在focusout时若document有焦点且active非body便忽略，否则用relatedTarget；86-115找不到view即unfocused。
- view_embedder/flutter_view_manager.dart:102-119用closest('flutter-view[flt-view-id]')，global_html_attributes.dart:21/30-39说明该DOM interop属性；dom_manager.dart:41-62证明semantics host属于对应view。
- semantics/semantics.dart:2314-2357换role重建/直接remove旧DOM；2148/2150重排，源码提示辅助焦点可能丢失；正常dispose2677走safeRemoveSync，view manager165-190先把焦点移回view以免bogus blur。这是可疑路径，不是已证明Root命中。

下一步应先只在诊断副本补native focusout target/relatedTarget/active的connected及closest view ID、原生调用栈/必要focused semantic DOM移除记录，确认BODY/null来自同view语义重建还是实际失焦。随后才形成唯一web adapter/binding策略；必须保真正document blur/hidden、外部DOM、其它view、owner/身份退休，不能忽略所有web unfocused、加固定延迟或关闭Tooltip/全部语义。core/responsive/view_focus_binding.dart尚无本轮产品修改。Root此前要求浏览器由Root独占。

服务已停：Node PID33980、127.0.0.1:28636。停止前已通知Root；命令/监听归属核对后停止，进程及端口均false。原静态构建未删，若新任务需重启应重新检查端口/源码与Root授权，不能把旧诊断当最终验收。

## C最终统一验收准备未完成

树：D:/Projects/uten_imp_worktrees/feedback-final-c-integrated-20261111，分支uimp/feedback-final-c-integrated-20261111，HEADa24c0eb331005a3b513e3e9cae317f17dbc092c2。

唯一WIP目录evidence/c-unified-final/，未提交，含CHECKPOINT.md、preparation.json、102输入hash、23类清单、三Java探针、原v1/v2产物副本。retained-programs/v1 12054文件、v2 8139文件，旧源/原manifest/owner/ID/谱系/存储文件未改。原v2全产物编译source commit仍不独立证明，沿旧报告如实，不把复制日期当源码证明。

未做freeze门控编排、fresh Maven新目录/TMP/每组source start/end接线、全部ordinary合法组覆盖补齐；未跑Maven/javac/java/JUnit/Flyway/种子/PG。没有明确最终freeze SHA，不能启动或改标旧7b。

覆盖缺口：原ordinary文件探针7类攻击、合法apply仅chart/note/aux/cost4类；其余goods/BOM/accounting合法需补普通岗位正常入口对照，至少原accounting PG类使用seedWorld.superAdminUserId，不能冒称ordinary七类合法。旧146断言不得松/关trigger/提高timeout。后续仍用自有26632旧key/独立新库，不碰Root26630或liveclasses。

用户已要求停止新增实施/诊断/验收；本交接仅保全WIP。新任务须读取用户完整剩余整改提示词、当前main/Root交接和本文件，保并行优化，再按新明确冻结SHA实施及验收。不得自行push/deploy/正式打包。
