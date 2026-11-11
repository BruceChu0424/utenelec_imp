# A：最终统一候选复跑计划与 native 来源台账提案

这是计划和来源元数据，不是最终验收。候选 SHA 尚待总任务冻结；所有实施期、Windows 预验与 D3 本机证据继续保留，不能改称最终同版通过。执行者只在独立工作树、PG 容器、回环动态端口、Maven 输出和 TMP 操作，不访问总任务的 28630/26630 数据服务。

## 提交与原计数

`ec6f82065db9f20a11c861adc98b5ba3b0cfb8e3` 是完整已提交的 Windows harness 修复，父提交 `5d1401caa31cd33929b519ab397ab95a1f42eeea`，只改 `integration_test/company_feedback_actual_windows_test.dart`。包括点击真实“全部模具”节点、跳过日志文件之间的空行、保留场景首因及清理次因；没有延长原 60 秒等待门槛。该文件工作改动为零；桌面树四份 l10n 的 CRLF 与未提交 evidence 均不是依赖。应在已整合父链的候选 cherry-pick 此提交，最终再从固定 SHA 用新私有根构建/运行。

原 audit 专项 14 类 163/163；原部分领料链 9/9。普通双账号 1/1、执行段 UI 2/2、草稿反例 1/1、错误投影仍逃过的变异 10/10 是不同组，不相加。实施期长轮 15 类 184 项的 16 错误继续保留，不能当最终绿。最终重新清编译同 15 类，当前 owning PG 类 26 项、部分领料业务类 11 项；实际总数取最终 JUnit XML，不预写通过数。

## 公共服务及升级矩阵

公共权威是 `fn_execution_partial_material_report_room`、`fn_execution_full_kit_checkpoint_valid`、`fn_capture_execution_full_material_kit`；保存/审核继续在 `DailyReportExecutionSegmentGuard` 原锁内复算。候选统一为 `ReportablePlanLineQueryService` 的原日报 ID+rowVersion，工作台使用 `ProductionExecutionWorkbenchService` 实际 SQL。Flutter repository 位于 `lib/features/production/repositories/production_repository.dart`，原来源 picker 共用同一身份/版本合同。WPF 相应生产页面仍未迁移。

升级工具扩为 12 个独立最终候选数据库：V1128、已实际迁至 V1129 两个起点，分别验证原计划缩量反例和三料 6000 反例，各自公开创建/修改旧草稿/审核旧草稿。六个 V1129 起点在迁 latest 前保留真实 dump；另外保留 V1128 原库和原 dump。共 1 次公开旧库准备、6 次 V1129 staging、12 次最终候选 launcher（每次单项 JUnit，分开记），不把多次启动合计成一个端到端界面通过。

缩量原链保持计划20→实发10→退9→CAP10，原已审产量10、两个旧草稿3；最终 capacity=1、room=0、无可信旧证明，新增/编辑/审核3均拒，原已审分录、用料、原草稿等完整事实不变。三材料计划10000、需求10000/10000/10000、实发5000/5000/5000；普通岗位6000+原因+实际5000/6000/6000的新建/编辑拒，独立审批岗审核修前6000旧草稿拒，原事实不变、已审产量0。

合法300→400由 `ProductionPartialReportQuantityEndToEndTest#partialIssueLimitsCombinedDraftsAndEditsWhilePreservingExactInputs` 与 `#onlyTheOwnersCurrentEditableDraftReleasesItsStoredOccupancy` 真实服务验证，同时核对旧版本、他人草稿、并发双普通账号。投影按正确→仅交换布尔表达式的 mutant 必须出现业务断言失败→恢复正确的三轮真实 SQL 验证；不能用异常启动失败代替反例被捕获。

## 可复制命令

在最终候选的独立工作树执行；`$Out` 必须新建，下面示例后缀每次换新。所有输出不复用运行后端的 classes。

```powershell
$Root = 'D:/Projects/uten_imp_worktrees/feedback-final-a-20261110'
$Out = "$Root/evidence/a-final-SHA-1"
$Build = "$Out/maven-a"
$Deps = "$Out/deps-cp.txt"
New-Item -ItemType Directory "$Out/tmp" | Out-Null
$env:TMP = "$Out/tmp"
$env:TEMP = "$Out/tmp"
$env:UTEN_RUN_DB_TESTS = 'true'
$env:MAVEN_OPTS = "-Xmx1900m -Djava.io.tmpdir=$Out/tmp"
$Tests = 'ProductionPartialReportQuantityEndToEndTest,ProductionQuantityAdversarialEndToEndTest,WorkshopPublicSurplusEndToEndTest,ProductionMaterialKitProofsTest,DailyReportExecutionSegmentGuardTest,ReportablePlanLinePostgresTest,ReportablePlanLineQuerySecurityContractTest,ProductionExecutionSegmentServiceTest,ProductionExecutionWorkbenchProjectionTest,ProductionExecutionWorkbenchSecurityContractTest,ProductionWorkshopTaskStageContractTest,ProductionMaterialSettlementServiceTest,ProductionMaterialStockLedgerCancellationPolicyTest,ProductionMaterialStockLedgerRoutingTest,PartialMaterialReportCapacityPostgresTest'
Push-Location "$Root/server"
mvn -B -ntp "-Duten.build.directory=$Build" -DskipTests test-compile dependency:build-classpath -Dmdep.includeScope=test "-Dmdep.outputFile=$Deps" *> "$Out/compile.log"
mvn -B -ntp "-Duten.build.directory=$Build" "-Dtest=$Tests" test *> "$Out/a-backend.log"
mvn -B -ntp "-Duten.build.directory=$Out/maven-direct-return" '-Dtest=ProductionExecutionRouteGateEndToEndTest#unissuedDirectMaterialCanGoToNormalStockBeforeIssueOnAnExplicitBatchRoute+unusedPreparedDirectReturnAndReversalAdjustOnlyExactPickingInstructions' test *> "$Out/direct-return.log"
Pop-Location
python "$Root/tool/company_feedback_production/compile_legacy.py" --root $Root --output "$Out/legacy"
python "$Root/tool/company_feedback_production/proof_probe.py" --root $Root --output "$Out/proof"
python "$Root/tool/company_feedback_production/upgrade_probe.py" --root $Root --output "$Out/upgrade" --build-dir $Build --legacy-build "$Out/legacy/legacy-build" --deps $Deps
python "$Root/tool/company_feedback_production/prepare_projection_database.py" --upgrade-output "$Out/upgrade" --output "$Out/private/projection-runtime.json"
python "$Root/tool/company_feedback_production/projection_mutation.py" --root $Root --output "$Out/projection" --build-dir $Build --deps $Deps --runtime-config "$Out/private/projection-runtime.json"
```

每步分别检查真实退出码，失败保留日志/DB并先解决，不将上面多条裸命令视为自动短路脚本。最后两步只使用该轮专用升级容器的新空库及私有 JSON；不读取 Root runtime 账号/密钥，不连接 Root PG。DIRECT_LOT 两个原场景分组记录，不扩大通用撤审业务。

Flutter VM 分栏复跑 `flutter test --no-pub --reporter expanded test/features/production/pages/production_daily_report_exact_segment_test.dart test/features/production/widgets/production_execution_segments_card_test.dart --name "editing draft reselect|partial issue blocks|shared process steps|authoritative partial material"`（原5个场景，使用私有工具/TMP，不改共享 SDK）。Root 负责真实 Web 与 Windows：

```powershell
python tool/run_feedback_actual_windows.py run --run-tag final-SHA-windows-1 --runtime-config D:/Projects/uten_imp_worktrees/feedback-remediate-20261110/evidence/root/private/runtime.json --account feedback-mould-win-qa --runtime-ready
```

Windows 命令在 Root 最终干净候选目录执行，本地后端/普通账号就绪且所有 seed 写入结束后启动；`run` 自身重编译实际引擎。新 tag、私有 prefs/DPAPI/日志/TMP，不能复用 ec6f 预验根。该命令由 Root 执行，不属于 A 后端隔离 PG 组。原 8.896s 完整模具预验性能不计一秒通过。

## WPF 来源 inventory 安全同步提案

本增量仅给 8 个相关任务追加未迁移说明和证据位置，373 个 task 的 ID/status/owner/definitionOfDone/dependencies/nativeTargets 原值完全保留；不触发 `set`/`init`、不改历史状态、不标验收。本记录 JSON 为 `clients/windows_legacy/progress/evidence/feedback-final-a-and-native-output-plan-20261110.json`，含保护字段前后哈希。没有在此旧来源树直接生成全项目 inventory，以免覆盖后续 C/选择谓词等并行来源。

应在所有最终源改动整合完成后、冻结验收 SHA 之前，从该候选再建独立工作树，保全 registry/history 原字节；运行 `business_inventory.py --write`、`progress_tracker.py sync`、`business_inventory.py --check`、`progress_tracker.py check`。核对 373 条保护字段、原 history 与并行 notes/evidence 未丢失，审查生成文档后单独提交，再让 Root 整合并冻结。inventory 元数据核对通过不表示本机/Win7业务或最终整体通过。最终测试不再修改冻结来源。
