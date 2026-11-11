# 独立成本结构行复核（修复前证据）

复核候选为 c4b84f5465de1e6fcb4617a847f523383d07da64。独立探针只创建合成 XLSX、调用真实 `GoodsCostWorkbookParser`；未启动数据库、未调用应用/入账。原 audit 目录只读。被测 parser 源码 Git blob 为 `eed7fdec78a8a65b3a6871a458c94943bdd91750`，只读 `build-web-seed/classes` 内 parser class 的 raw SHA-256 为 `bb69937ec9d72388ed21f8dddb4d550d2c80997810b4a43cad964bc673a60bca`。

`HeaderProbe.java`、编译参数、运行参数和原始退出文件都在本目录。首轮 JVM 编码导致中文 stdout 不便阅读，原 `result.log` 保留；仅在新目录 `current-utf8` 重跑并显式设置 stdout/stderr UTF-8。两轮退出均为 0；探针用于显示事实，退出 0 不表示业务正确。

| 真实 XLSX | 表头及数据 | 实际预览 | 判定 |
|---|---|---|---|
| ordinary-control.xlsx | A:C 为材料名称/用量/单价；铜钉/1/4、铜片/1/4 | v2；2 行 | 合法对照保留 |
| reserved-name-control.xlsx | 同一模板；铜钉/1/4、材料名称/1/4 | v2；2 行 | 同名普通材料合法对照保留 |
| mixed-header-tail.xlsx | 同一模板；末行材料名称/1/4，D 无表头但有值“数量” | v2；只有铜钉 1 行，未拒绝 | 漏检并静默丢失材料行 |
| subtotal-name-control.xlsx | 同一模板；铜钉/1/4、小计数器件/1/4 | v2；只有铜钉 1 行，未拒绝 | 合法名称被子串小计规则丢弃 |

根因：parser 先用任意行里的同义关键词重新识别表头，再收集 populated cells；混合数据行绕过空表头有值和结构检查。另用任意材料名称包含“合计/小计/总计”判断汇总。应以唯一可核实结构识别标题/表头/汇总，混合数据不能静默忽略；合法任意材料名称不能按子串丢弃。

原文件和 raw SHA-256 位于 `current-utf8/file-sha256.json`，实际 `rows/names/columnVersion` 位于 `current-utf8/result.log`，退出码位于 `current-utf8/exit.txt`。未观察数据库写入，不能将本结果描述成已发生错误入账。修复后须读这四个原文件复跑，断言前两项 2 行、第三项明确拒绝（不能有可执行的丢行计划）、第四项 2 行；与首次生成的新文件分目录保留。

后续新增 `OriginalFileRegression.java` 只读上述四份原始 XLSX，不生成或写回输入；它断言正确业务结果。当前候选实际为 **2 通过 / 2 失败 / 0 错误 / 0 跳过，退出 1**：正常名称、与表头同名的材料各保留两行；混合表头行未拒绝、“小计数器件”被丢弃。原始参数、编译日志、实际输出和退出分别为 `reader-javac.args`、`reader-javac.log`、`reader-baseline-java.args`、`reader-baseline-result.log`、`reader-baseline.exit`。本组与前述发现探针重叠，不相加计总数。
