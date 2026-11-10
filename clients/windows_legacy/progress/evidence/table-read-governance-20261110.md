# 既有 WPF 盘点与生成漂移归集（2026-11-10）

本记录与表格性能实现分开：归集此前已存在源码和登记事实，不增加业务迁移完成数，也不是性能改善。

原失败仍保存在[性能适用性证据](table-read-performance-20261110.json)：`progress_tracker.py check` 在本次追加前即报告 `Business source inventory drifted`。登记的 controller/动作候选为291/566，当前源码为293/568；当前页面仍230、feature仍36。

同步前还发现 owning 工具缺陷：`build_registry` 只从139项种子 catalog重建公共任务，会删除已登记而未回填catalog的 `W7-FLOW-019`，把实际373项降为372；既有人工依赖也没有显式继承。先修唯一同步器：保留catalog外已登记公共任务及其历史/DoD/依赖，已有任务保留审核过的dependencies，公共数量按实际非BIZ任务计算。增加两项回归，当前17项工具测试通过。没有另建同步器或复制一套状态账。

使用 owning `business_inventory.py --write` 和 `progress_tracker.py sync`。注册表落盘前先在内存生成候选，核对全部373个任务ID及status、owner、definitionOfDone、dependencies、nativeTargets；实际写入后再次对比，全部相同，没有新增或移除任务。计数修正为230当前页面+3历史页面+140公共/流程=373。原FLOW019和所有未完成状态保留，完成仍10，未完成363。

这次捕获的是累计源码证据漂移：228个既有页面的静态线索变化，13个被索引来源加入、1个来源移除、460个来源指纹变化。没有新增页面工作包。完整路径差异和工具命令/日志见[机器回执](table-read-governance-20261110.json)。初步对460个变更源比较旧指纹与当前LF归一化摘要，没有仅靠CRLF归一化即可解释的匹配；不能把这份大diff当成本次新增业务。

生成00/01、各任务页和页面来源页均来自同一登记表与inventory，原来的11-06/11-09说明与FLOW019不是本次创建。原初始失败和修复前会丢任务的事实未删。当前检查和源指纹仍需要随产品最后一处修改冻结核对；图表/源码存在、静态盘点fresh或17条工具回归都不能代表完整ERP、Win7真机或公司业务验收。

未运行公司API、数据库、部署、正式包、推送或提交。

## 产品冻结后的最终核对

主任务完成后续 RowWindow 与5页接入并确认源码冻结后，再次执行 owning inventory write、registry sync 和 `progress_tracker.py check`，三个命令实际退出均为0。最终仍为373项（230当前页面、3历史页面、140公共/流程）；落盘前候选和落盘后实物均证明所有ID/status/owner/DoD/dependencies/nativeTargets不变，仍10项完成、363项未完成。该轮未启动UI或压测。

最终inventory SHA256为 `ab47e1a0582ad2baf162564c79fc17b0256df3fa9bfc6c06638bee04a3fcbcb8`，登记表SHA256为 `e0e85349ee0e120771e9b001b31c025642aed3f51758989f8ec64c2343cc9537`。精确命令、日志摘要、owning工具指纹与时间保存在机器回执 `finalSynchronization`，没有覆盖首次失败和首次治理归集记录。以后源码再变化，仍须重新检查，不能复用本次冻结结果。
