# 每行 checkpoint await：本阶段暂不修改

范围：独立合成 microbenchmark，仅研究 `UiWorkBudget` 每行创建/await Future 的成本。未修改产品预算、complete reader、`mapInUiSlices` 或验收fixture；未运行公司服务。

脚本：`tool/benchmarks/ui_work_budget_checkpoint_benchmark.dart`。原组调用实际 `UiWorkBudget.checkpoint()`；实验组为同4ms/256项、同当前性检查及observer的nullable同步原型，只有触及预算才等待真正的 `Timer(Duration.zero)`。实验组最终额外保留一个微任务发布栅栏。两组执行相同checksum计算，交替顺序并先预热，未扩大预算。

| 环境 | 数据 | 原await中位 | 原型中位 | 绝对差 / 相对差 |
|---|---:|---:|---:|---:|
| 本机 Dart VM JIT，5轮交替 | 100k | 16.013ms | 10.827ms | 5.186ms / 32.4% |
| 本机 Dart VM JIT，5轮交替 | 1m | 151.233ms | 85.725ms | 65.508ms / 43.3% |
| 独立 Chrome 157 headless，真实时钟/可见页，无CPU节流 | 100k | 2011.6ms | 1972.9ms | 38.7ms / 1.92% |

原始证据：`checkpoint-native-jit.jsonl`、`checkpoint-web-prototype.json`。原生每组的timer yield与当前性检查数一致。Web编译参数把大样本也设成100k；当时常量集合生成结果仍列出两个100k，因此Web实际上每种模式10个样本，报告两个相同median；这里按实际样本解释，不冒充独立规模。脚本随后改为运行期集合去重，未为此重跑或修改产品。Web静态文件：`checkpoint-bench.html`、`checkpoint-bench.js`；重编译可使用 `dart compile js -O2 -DCHECKPOINT_LARGE_ROWS=100000 -o tmp/table-performance-validation/checkpoint-bench.js tool/benchmarks/ui_work_budget_checkpoint_benchmark.dart`。

结论：存在可重复的纯CPU成本下降，但原生100k仅省约5ms，当前Web合成路径仅省约39ms。它不能解释真实页面完整读取约15秒，也不足以证明能显著改善整页延迟。保留测量结论，后置该改动，继续维持产品源码冻结；不把32%-43%的局部百分比用于整个平台提速宣传。

如果将来实际画像证明这里重新成为大头，必须先补齐异步语义回归：原async `checkpoint`继续把异常交给Future；新快路仅在预算到限时Timer让出，前后均检查当前性；每批临时结果及最终map发布前保留微任务栅栏，防止idOf/convert中排入的退休先于发布意图却晚于快速循环完成。还须验证observer异常、微任务/定时器取消、协变、mutable批次冻结及onPage原对象。不能仅机械删除await后用单次微基准通过代替这些边界。

该Web实验是单独headless窗口，不是低配真机、真实页面、HTTP/NDJSON或Windows IME验收。执行时与root功能检查可能重叠，不将该段用于正式页面安静A/B结论。
