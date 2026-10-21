# 原材料离线预测 worker

这个 worker 免费使用 Apache-2.0 的 StatsForecast 2.1.1，在本机 CPU 上计算。
它只读取操作员提供且有使用授权的 CSV，不抓网页、不需要付费行情 API，
不读取 ERP 交易，也不会修改 ERP 原有的采购成交历史参考价。

货品与基准的关联由 ERP 中的显式选择完成。金属现货、某个期货合约、
连续合约以及不同 PC 牌号分别建基准，不能直接混为同一个价格。

## 安装与运行

推荐 Python 3.12 64 位。依赖安装需要能访问 PyPI；安装后计算不访问网络，
不需要 GPU 或模型权重。依赖与 worker 版本一起发布，不能在每次启动时自动升级。
在仓库根目录执行，下面用 PowerShell 表示：

```powershell
python -m venv .venv-material-forecast
& ./.venv-material-forecast/Scripts/python.exe -m pip install -r services/material_forecast/requirements.txt
& ./.venv-material-forecast/Scripts/python.exe -m unittest discover -s services/material_forecast/tests -v

& ./.venv-material-forecast/Scripts/python.exe services/material_forecast/worker.py `
  --manifest D:/MaterialForecast/input/copper.manifest.json `
  --csv D:/MaterialForecast/input/copper.csv `
  --output-directory D:/MaterialForecast/snapshots
```

Linux 使用虚拟环境的 `bin/python`。输出目录必须与服务器配置
`uten.material-forecast.snapshot-directory` 指向同一个本地绝对目录。
例如在本地 `server/.env` 配置下列 properties，按现有服务流程重启后生效：

```properties
uten.material-forecast.snapshot-directory=D:/MaterialForecast/snapshots
uten.material-forecast.max-data-age-days=3
```

默认没有目录配置时功能为未接入；不要把 `examples/generated` 配成正式目录。
首次启用前先按既有发布流程应用 V890 迁移，不对公司数据库手工建表。
一次成功计算会以原子替换写入 `<seriesId>.json`；失败保留上一次完整快照。
ERP 会独立检查数据和快照是否过期，失败后不会把旧价格重新标为实时有效。

本地 CSV 更新可以自动检查：同样的命令增加 `--watch 60`，进程每 60 秒
检查文件修改时间和大小，只在输入改变时重新计算。最小间隔 10 秒；
按 Ctrl+C 停止。需要常驻时由运维进程管理器监管这个命令。
也可以在每日完成数据导出后执行一次批处理命令。worker 不会向来源网站索取更新。
来源导出应先写临时文件，再替换 CSV，避免读到写了一半的文件。

## 授权数据与修订

复制 `templates/manifest.json` 和只有表头的 `templates/prices.csv`。
模板中的 `authorized` 故意为 `false`；确认数据来源的使用权后再设为 `true`，
填写真实来源、牌号、地区、单位、币种、含税/运费/加工费口径。
模板没有市场示例价格，空 CSV 不会生成快照。

公司自有报价或有授权的供应商离线报价可以没有公开网址：

```json
{
  "seriesId": "supplier_a_pc_110_shanghai",
  "name": "供应商 A PC-110 上海含税报价",
  "commodity": "POLYCARBONATE",
  "market": "SPOT",
  "grade": "PC-110",
  "region": "上海",
  "currency": "CNY",
  "unit": "吨",
  "priceBasis": "含税，运费另计，原厂新料",
  "sourceName": "供应商 A 授权报价文件",
  "sourceUrl": "",
  "authorized": true,
  "rollPolicy": null
}
```

有公开来源时 `sourceUrl` 填 HTTP(S) 网址，不含账号密码。
`seriesId` 为小写字母、数字、下划线或连字符，最长 64 位。
`commodity` 支持 COPPER、ALUMINIUM、SILVER、POLYCARBONATE。
PC 只接受明确牌号及地区的 SPOT 数据，不接受拿 PP/PVC 期货冒充 PC。
FUTURES 必须明确 `rollPolicy`：如何选合约、何时换月、是否复权。
币种、单位、税费和价格口径只是明确标签，worker 不做隐式换算。

CSV 字段固定为 `date,price,available_at`。每行是一个观察日期的某次公开版本：

- `date` 是该报价所属的中国业务日期；时间比较按 Asia/Shanghai。
- `price` 必须为正且有限，最大 1 万亿元，精度不超过 36 位、小数不超过 18 位。
- `available_at` 是本系统或授权采购工作流首次真正可知这个**版本**的时间，必须包含时区。
  修订追加新行并填写修订发布时间；不能把今日更正回填成过去已知。
- 不知道历史发布时间、拿到的只是今天最终修订视图时，使用今天首次可知的时间。
  这类资料仍能显示基线，但无法凭空证明过去的预测表现。
  只有原始发布/接收档案能证明当时已有权取得该版本，才填写对应历史时间。
  由这些档案重建的回测是离线研究，不代表 ERP 当时已实时运行模型或发出预测。

首次导入在输出目录 `.state/` 建立持久账本。后续完整 CSV 必须保留旧行及原顺序，
新增观察或修订只能追加。删行、改旧价格、改旧发布时间、改基准口径都会拒绝导入。
换来源、换口径或换牌号请新建 `seriesId`，不要清除账本绕过检查。
备份时同时保存输入、快照和 `.state/`；如另设 `--state-directory`，也要备份它。
同一基准不能并行导入；进程异常退出遗留锁时，先确认该进程已停止再处理该锁文件。

重复的 `date+available_at`、未来发布时间、非正价格、明显单位跳变、超限文件会拒绝。
相邻首报价或同日修订相差超过 5 倍会视为可疑，需核对单位与来源。
CSV 最大 8 MiB、50,000 行修订，不允许用插值或填充伪造缺失报价。

## 预测和验收方法

预测 1、5、20 个**后续有效报价**，不是自然日。没有交易日历时不编造未来日期，
假期和缺失数据不会被补成持平价格。输入若缺少本来应有的报价，跨度会更长，
需要操作员保证同一来源的观察序列完整。

候选为 StatsForecast 的 RandomWalkWithDrift、AutoETS、AutoTheta，
基准为最近价格 Naive。每次拟合只用截至对应起点真正已公开的各日期最新版本；
回测目标采用该未来日期首次发布的报价，避免今天的修订影响过去的标签。
首次发布后更正的目标口径与最终结算价可能不同，应在选择数据源时明确。

滚动起点间隔 20 个有效报价，目标区间不重叠；至少需要：

1. 每个起点 120 个已知历史观察。
2. 前面的 4 至 8 个起点用于选择候选模型。
3. 后面的 20 至 30 个独立起点用于验收，不能重新据此挑选另一个模型。

因此至少约 600 个有可信历史发布时间的有效报价才能达到 READY；
延迟发布或资料缺失会需要更多。选型使用的全部目标必须在首个验收起点之前已公开。
只保留最近的有界回测窗口，每次训练最多 1,000 条历史，单次单进程、无 GPU。

只有 1/5/20 **每个跨度**的独立验收 MAE 都小于相同跨度 Naive，
且每个跨度的 80% 区间实际覆盖率至少 70%，才标 READY。
区间直接来自该起点已知数据拟合的 StatsForecast 模型；不使用验收残差调区间。
`validation` 展示独立验收的汇总指标，`folds` 只计验收起点。
区间包含真实未来价格是统计目标，不是每次保证。

资料不足时标 BASELINE_ONLY，只有 1 条观察时标 INSUFFICIENT；
空文件直接拒绝发布。候选失效、未胜 Naive、覆盖不足时只显示 Naive 基线，
所有方向为 UNCERTAIN、采购信号为 INSUFFICIENT。
模型产生无效或非正价格区间时降级；连基线也失效时不生成预测点。

READY 时只有区间完全高于/低于最近价才显示 UP/DOWN。
至少 5 或 20 个报价跨度出现 UP，且所有跨度都没有 DOWN，才给出 RISING；
多跨度冲突或区间仍重叠最近价时为 WATCH。
这仅是市场方向信号，采购还要考虑库存、交期、刚需数量和供应商实际报价。

## SYNTHETIC 演示与真实库验证

`examples/generate_synthetic.py` 只生成明确标记的人工曲线，不提交大样本文件。
默认 worker 拒绝它；只有 `--allow-synthetic` 才能测试，输出仍保留
`synthetic:true`，生产 ERP 读取器会拒绝。测试输出必须用独立目录：

```powershell
& ./.venv-material-forecast/Scripts/python.exe services/material_forecast/examples/generate_synthetic.py `
  --directory services/material_forecast/examples/generated/input
& ./.venv-material-forecast/Scripts/python.exe services/material_forecast/worker.py `
  --manifest services/material_forecast/examples/generated/input/SYNTHETIC.manifest.json `
  --csv services/material_forecast/examples/generated/input/SYNTHETIC.prices.csv `
  --output-directory services/material_forecast/examples/generated/output `
  --allow-synthetic
```

这些曲线特意容易预测，只验证真实库、回放、隔离验收和快照契约可运行，
**不能作为铜/铝/银/PC 的准确率证据**。测试还覆盖常数序列无法胜过完美 Naive、
迟到修订不改变历史回测、未知可知时间不能造回测、无授权及 PC 代理拒绝、
北京时间跨日、原子保留旧快照、追加账本和输入边界。

## 升级

依赖升级通过仓库依赖更新检查产生可审查变更，再运行上述真库回归。
这只代表新版本候选通过软件检查；生产升级还需使用自有授权数据进行滚动评估，
确认每个品类/跨度没有退化后再部署新 worker，保留前一版本和输入账本备份。
不允许把开源项目发布新版本直接等同于更高预测准确率。

代码/算法许可证参考 [StatsForecast](https://github.com/Nixtla/statsforecast)；
方法参考 [滚动回测文档](https://nixtlaverse.nixtla.io/statsforecast/docs/tutorials/crossvalidation.html)。
源数据的使用和转发权必须另行确认；[AKShare 官方说明](https://akshare.akfamily.xyz/introduction.html)
限定其接口及相关数据为学术研究，开源采集代码本身不提供商用行情授权。
