# A：7b 冻结后端原轮验收报告

本轮产品/测试源码严格为 `7b912287e53315228b469790ff066a9fab643e3c`，tree `c633a95d896111d42aa0698b97d3764d8138f565`，独立工作树 `D:/Projects/uten_imp_worktrees/feedback-final-a-20261110`。编译、运行前后 tracked diff 为空。本报告仅交 A 的该版本证据；Root 在实际 Web/Windows 发现的纯前端生命周期/布局问题及 B 性能问题仍需新全局候选复核，不能把本轮写成整体或后续 HEAD 通过。

证据根为本工作树 `evidence/a-final-7b912287-1`，机器摘要 `acceptance-summary.json`。没有连接 Root 28630/26630、公司数据库、公司原单/私有文件，没有合并 main、推送、部署、安装或正式打包。

## 同版执行结果

| 独立验证组 | 真实结果与原始证据 |
| --- | --- |
| 干净编译 | 3275 主源码、2755 测试源码；218 个依赖均为 JAR。`compile-2.log`/`compile-2-exit.json`，exit0。11710 个实际 class/SQL 字节快照聚合 `fef5d14956af77e78e8bb8f1162df20ee2484a461f4d96d0f46954a523b99834`，详见 `compiled-provenance.json`。升级使用不可变副本，Maven 再编译测试时不覆盖运行字节码。 |
| A 原15类 | `a-backend.log`、`maven-a/surefire-reports`：15类实际209项，失败0、错误0、跳过0、进程exit0。owning PG 26项属于这个209子集，不另相加；部分领料11、数量反向13、公共份额17、候选真PG14等均在 XML 内。 |
| 旧 V1128/V1129 双起点 | `upgrade/`：1个真实 V1128 公开造原库；两个起点×两反例族×创建/编辑/审核共12个隔离最终候选副本，另有6次 V1129 staging，共19次单项 launcher 各1/1、进程exit0。原库、V1128 dump、6份迁latest前的真实V1129 dump及12个副本保留。 |
| 原错误配套信用 | 两起点均核验原计划20→实发10→退9→CAP10，原已审10、两个旧草稿3；候选实际capacity=1、room=0、无有效历史证明，公开新建/修改旧草稿/审核旧草稿额外3全部被物料配套守卫拒绝。已审分录、原草稿、用料与所有所比对事实保持原样。 |
| 原三料6000 | 两起点计划10000、各需10000、实发5000/5000/5000；普通岗位候选5000，新建/编辑6000+原因+实际5000/6000/6000被拒。独立普通审批岗审核修前6000/实际5000各料旧草稿被拒，原事实不变、已审产量0。 |
| 合法300→400与权限 | `ProductionPartialReportQuantityEndToEndTest` 11/11，含本草稿300在配套500中重选/保存400、旧版本/他人草稿拒绝、真正不同普通账号并发只允许一份300、合法退料/红冲/恢复等；使用公开业务服务/真实PG，不冒充HTTP界面。 |
| 证明扫描与大量流水 | owning PG warm 513/1025/2049 检查点49/106/122ms，输出0；20k流水容量27ms/room41ms；1000 posting单次capture91ms。`proof/` 独立真实PG原反例及原始EXPLAIN：SQL26.494/35.782/152.182ms，ISSUE/REVERSE各257/513/1025行、loops=1。外层Docker启动/往返墙钟单列，不当SQL时延或一秒UI通过。 |
| 冻结投影变异 | 专用新空PG库的 `projection/`：正确1/1→仅交换布尔SQL的mutant出现业务 `AssertionFailedError`、1 test failed/预期exit1→恢复正确1/1，driver exit0。产品源从未被变异，不能用启动异常代替反例被捕获。 |
| DIRECT_LOT真实路径 | `direct-return/direct-2.log` 与退出回执：原两条真实业务/PG场景2/2、exit0；没有扩展通用撤审。首个额外launcher收尾问题另见下文，未作自然退出通过。 |
| 原三曲线合法对照 | `three-curves/original` 保留原脚本、步骤、日志实际字节；原步骤未改，补齐当前函数所需最小DDL上下文并应用实际V609曲线函数及V1129/1130/1131。PER_UNIT/PER_PACKAGE/FIXED_BATCH分别需求20000/1200/400、半发均支持5000；checkpoint=false，已审1500+草稿500后3000，本草稿编辑3500，删除释放后3500。断言/观测验证，exit0。此组为函数级真PG，不冒充公开造单或界面。 |
| Flutter VM 原5例 | `vm-five.log`/退出回执：5/5、exit0，7b tracked diff仍空；合法草稿重选保存400、6000拒绝及重复输入保留、步骤/颜色/读屏状态。使用受控API的Widget VM，独立于真实Web、Windows。 |

上述组保持分栏，不将209、26、19次launcher、5个VM或独立函数对照相加成新的端到端用例总数。当前普通岗位真实HTTP/同版全应用交互由 Root 另列。

## 版本与原始失败保全

旧程序来自 Git `86dffb9dbcb52b248ade1f2b3ea4a7c72db738a2`，最高迁移V1128；原source archive实际字节SHA256为 `6461e81f998762c1d877876f7fb303c87a7308fdcb27e0f5de78acd186ca3ee6`，独立3269主源码编译exit0。旧产物位于 `D:/Projects/uten_imp_worktrees/feedback-wpf-export-20261110/evidence/a-final-preparation-20261110/legacy/legacy-build`，归档/源码/日志保留；新业务产物取本轮7b不可变快照，不混旧class。

V1129对原main、V1130对首次实施81cc、V1131对59364的Git blob逐个相同，未改已应用迁移。原 audit 与 A 实施期失败证据继续位于 `feedback-audit-20261110/audit/production`、`feedback-remediate-a-20261110/tmp/feedback-a-20261110`，不覆盖它们。原184项长轮的16错误没有改写为本轮通过。

本轮两项执行设施失败保留：首次PowerShell把未加引号的 `-Dmdep.includeScope=test` 拆成未知phase，尚未进入编译，`compile.log`/exit1保留；第二次参数整体加引号才编译成功。计划命令应写为 `'-Dmdep.includeScope=test'`。额外DIRECT_LOT初版launcher在JUnit已2/2结束后，因没有成功退出而留下Spring scheduling线程，已保留summary、PID/命令与jcmd线程栈（无main/JUnit运行，仅DestroyJavaVM等待），确认身份后只清理该已结束私有harness。按仓库FeedbackRunner同样方式在JUnit完成后退出的新launcher以新日志重跑2/2并exit0；没有取消仍执行的测试或把首次驻留写成自然0。

## 下一全局候选与现场边界

Root 后续前端/Java性能修复产生新SHA时，先逐blob对比A owning Java/SQL/测试/工具及共享依赖，再在新冻结候选复核受影响原例；7b证据保留身份，不冒写后续HEAD。本轮仅新增报告/证据提交，不改7b产品。

WPF相关生产页面仍未迁移、373任务状态/owner/DoD/依赖/nativeTargets不因本轮服务验证而升级。公司真实历史单的当时计划、料品/颜色/单位、曲线/规则证据和下游成本财务需现场核对；没有专有证据的旧记录不自动追认，也不自动红冲旧账。目标Win7设备、公司原文件、正式分发仍未在此组验证。
