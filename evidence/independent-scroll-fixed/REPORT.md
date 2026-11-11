# 滚轮收头坐标修正：独立复核

目标产品08af9d259111aeb692daafc2a357cdce20368f40。独立树正常merge以保留原178红证据，实际执行HEAD起止均50c873a286df47a070828297d56b201d2aea80e0；lib/server/clients/pubspec与08af产品逐Git diff为空。

四份原独立helper与上一轮红绿对照的原件raw bytes完全相同，没有修改断言/输入/超时：

| 独立组 | 结果 |
|---|---|
| 原compact宽/高两正确断言+外部outer.animateTo单例 | 3/3通过、退出0；原178为0/3红，原14e为3/3绿 |
| 默认宽高双向4事实+stableHierarchy相邻4事实 | 同运行均完成；结合前3项本轮11条事实的全部JSON字段按多重集与14e原事实严格相同，含反向旧Nested归0控制 |
| 原5文件public scroll/mode/touch/primary isolation/semantics | 18/18通过，0跳过，退出0；原96/24/48/gate/hold强断言和源码blob不变 |

第一轮运行共11个case，包含事实采集，故不靠其进程退出签正确。真正判定包括原3个行为强断言，以及独立behavior-comparison.json对11条原始行为字段逐值比较；没有把结构类型变换当失败或把事实probe exit0当通过。

源码修只把收头边界的inner归零限于旧normal Nested语义：非stableBodyViewport且presentationCompact=false。compact/stable原位置保留，反向旧normal归0行为仍与14e相同。没有一次性跳过标记、固定等待、新缓存或改预算。

原178950→0、原14e保持950、准备未建立真实非零offset及首次归档失误均完整留在evidence/independent-scroll，未覆盖/重标。新原件、源码起止/测试指纹、SDK保护证明见本目录manifest/source-start/result和原receipt。

这只是独立Flutter VM的真实ScrollPosition、PointerScrollEvent和外部controller行为复核，未接Root数据库/浏览器，不冒称真实Web、目标Win7或整体最后候选已通过。Root仍需冻结最终整合提交并对实际页面/权限/来源复核。
