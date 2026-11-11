# 同事件轮查询退休修复的独立确认

审查目标 `6ee00bbba4e76d7f34cc6734b1f7e66a10754c7f`。独立review树正常merge此提交以保留原失败；执行HEAD为 `9785290715e8e098f44eb8466bf559d093be5aa6`，生产lib/server/clients/pubspec与6ee逐Git diff为空。起止、源码blob与原件指纹在source-start.json/result.json/manifest.json，不改写实际执行身份。

原独立三例源码与上一轮2绿1红的原文件按raw bytes完全相同，未修改任何断言。新增生产发布栅栏后，本轮同时跑原三例与既有owner预算文件的两项，**5/5通过，0失败/跳过，退出0**。

- 不改变查询的合法单页结果仍通过。
- 仅live query从A改B、Future同事件轮立即完成，旧A现在正确退休。
- 显式invalidate仍正确退休。
- 原600行owner预算测试本轮实际打印3641次owner检查、7次深比较、1211次loop检查；沿用原“深比较*2 < ownerChecks”等断言，没有钉死上轮的3644/8或放松要求。
- 原mid-read query切换与新查询完成对照仍通过。

阅读新mixin确认：fetch完成/逐prefix发布/consumer回调后/outer Activity最终返回（含cache hit）有实核/失效边界，热循环仍保留事件轮答案；挂载/显式退休代际一直在memo外。merge后的MasterDataTableView/PlatformTableController相对前一8c没有变化。未发现本修复通过删main优化、伪造完整或跳过403处理来过测。

原13红、14 import编译失误、15旧mixin绿原件仍在evidence/independent-query-turn，没有覆盖。共享Flutter SDK输入哈希前后不变，见原工具receipt。本组是独立Flutter VM公共API/预算验证，不冒称真实Web→PG或整体最终验收。

Tooltip宽窄搬移仍属A另行修复；本轮没有重标其旧2红2绿或关闭该缺陷。新统一候选仍需独立重跑对应Tooltip四例、实际Mould hover/无hover与真实Web/Windows。
