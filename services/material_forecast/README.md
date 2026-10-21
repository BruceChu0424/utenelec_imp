# 原材料自动行情与 CPU 预测 worker

主流程是**货品一次选择行情基准，后台自动更新行情并重新预测**，不需要采购人员导入 CSV。
内置沪铜、沪铝、沪银三个期货基准。worker 直接读取上期所公开日终统计及延时行情，
使用免费的 Apache-2.0 StatsForecast 2.1.1 在 CPU 上计算，不依赖 AKShare、GPU、
付费模型或大模型 API。PC 聚碳酸酯暂未找到同等适用的免费自动数据源，不能用 PP/PVC 代替。

本进程只知道三个公共基准，没有货品、员工、供应商、库存、ERP 登录凭据或交易事实。
这些信息不进入 HTTP 请求，也不上传外部。行情不会自动改写 ERP 历史成交参考价或采购单价。
公司内部使用公开统计与对外转载、转售的权限应分别确认，公开免费访问不是无限制转售授权。

## 自动采集主流程

正式部署随应用自动管理，无需采购人员安装 Python、导入 CSV 或手工运行采集命令：

1. 按原有发布流程升级应用并执行V890、V891等尚未应用的前向迁移；发行包内的
   `server/material_forecast/` 包含完整哈希锁定的离线依赖。公司标准 Ubuntu 24.04
   安装脚本准备 Python 3.12 与 venv，应用启动自动创建自己的运行环境。
2. 超级管理员在「系统设置 → 原材料行情」管理启用开关、检查间隔（15–60 分钟）、
   历史范围（3–3650 天）和每轮回填数（0–1000）。默认启用、15 分钟、1200 天、30 份。
   保存后需等状态卡显示服务器已确认；保存成功不等于进程已应用。
3. 员工在货品的价格分析页选择沪铜、沪铝或沪银并确认一次。关联随数据库保存；
   后续自动采集与模型重算不修改关联版本，页面自动读取新报价与预测。
4. 搬到公司内部服务器时恢复数据库及配对备份中的行情状态，再按标准部署启动应用。
   设置与货品关联自动保留，运行环境按本机重新准备，无需逐个货品重新配置。

行情数据默认位于当前持久附件根目录下的 `material-forecast/`，不写入只读发布目录。
可执行依赖缓存放在系统磁盘的独立目录，避开附件卷的 `noexec`；它不进入数据库设置或数据备份。
配对备份显式收录原始来源修订、历史预测、缓存指针与当前报价；恢复时旧心跳只作为证据保留，
新的存活状态必须由新进程确认。只备份数据库能保留关联与设置，缺失行情缓存时会自动重新采集。

本地 `server/dev.ps1` 也会使用正式 Python 3.12 准备私有运行环境；生产启动不访问 PyPI。
发行包与本地自举共用同一个 Git/SHA/版本绑定的严格构建器，完整哈希锁
`requirements.txt` 是唯一依赖依据。Linux 选26个包、Windows 选27个包（含 colorama），
离线准备先后复验同一清单，再执行 pip check 与真实库人工序列检查。
开发缓存仅允许与运行时无关的未提交修改；运行时源码、锁、构建/准备器、目录和
应用版本必须匹配已审查 HEAD，每次缓存命中都重新验证，不复用被篡改的旧包。
云端中转实例不启动采集。后台监管、OS 防重锁及实际运行回执见
[托管运行合同](MANAGED_RUNTIME.md)，标准服务器操作见
[部署手册](../../deploy/simple/RUNBOOK.zh-CN.md)。

### 开发与独立采集诊断

以下命令供开发、测试或显式独立部署使用。启用外部 collector 时关闭应用托管，
并让两者使用同一绝对状态目录；不要同时启动两个采集器。
推荐 Python 3.12 64 位，在仓库根目录安装并检查：

```powershell
python -m venv .venv-material-forecast
& ./.venv-material-forecast/Scripts/python.exe -m pip install --require-hashes --only-binary=:all: -r services/material_forecast/requirements.txt
& ./.venv-material-forecast/Scripts/python.exe -m pip check
& ./.venv-material-forecast/Scripts/python.exe -m unittest discover -s services/material_forecast/tests -v

# 一次有界检查：先最新日终和延时价，再回填最多30个日文件。不会假装后台已常驻。
& ./.venv-material-forecast/Scripts/python.exe services/material_forecast/worker.py `
  --auto --once --output-directory D:/MaterialForecast/snapshots

# 常驻：默认每15分钟同步，失败自动退避，每30秒写存活心跳。
& ./.venv-material-forecast/Scripts/python.exe services/material_forecast/worker.py `
  --auto --output-directory D:/MaterialForecast/snapshots
```

Linux 使用虚拟环境的 `bin/python`。服务器的
`uten.material-forecast.snapshot-directory` 与 `--output-directory` 必须指向同一个绝对目录。
例如在本地 `server/.env` 配置下列 properties，按现有发布/服务流程应用 V890 并重启后生效：

```properties
uten.material-forecast.snapshot-directory=D:/MaterialForecast/snapshots
uten.material-forecast.max-data-age-days=3
```

这是独立诊断模式的路径覆盖，正式托管使用前述自动目录及系统设置。
员工日常只在货品价格分析页选择行情品种并确认，系统记住后自动更新。
内置目录定义在 `server/src/main/resources/pricing/material-benchmarks.json`，可在数据尚未到达时先关联。
采集进程部署并启动后，ERP 页面会定时重新读取报价与预测；HTTP 请求不训练或抓取行情。

可设置 `--interval 1800` 改成每30分钟；允许900–3600秒。
`--history-days 1200` 是默认日历回填窗口，可设3–3650天；
`--backfill-budget 30` 限制每轮额外历史请求，可设0–1000。
网络请求最多每秒1次，固定官方 HTTPS 主机和路径，同主机重定向才允许。
请求/解压大小、读取时长和返回结构均有界；403/429停止当前同步，
将退避期限持久化，重启也不能绕过它。不伪造浏览器身份、不处理验证码或绕过反爬。

首次启动先获得最新两个完整交易日报告，用前日持仓选出最新主力结算价并显示；
历史以每天文件在后台渐进回填，默认每轮30个，通常需要多个轮次才能得到约600条有效报价。
完成时间取决于休市日、来源可达性和预算。历史不足时显示真实日终报价及依据不足，
不能立即声称已验证预测。达到足够窗口后自动计算，新增报告会重新计算；
即使日终未变化，每12小时也会重新生成一次模型证据，原始抓取时间不会随之改写。

三个品种共用每天一次下载的持久缓存。缓存保留原始内容摘要、实际 `firstObservedAt/fetchedAt`
和后续修订；未请求过的日期或网络失败会截断历史窗口。
每次实际生成的预测也在 `.auto-feed/issued/` 按内容摘要保留，不用今天的新模型覆盖旧预测，
方便后续对照真实新报价；这只是前向证据积累，不代表首版已经实现或通过前向验收。
只有已检查的空日可跳过，连续报告还必须满足官方 `o_trade_day` 序号差1，
不会把缺失的真正交易日当休市后错误使用两天前持仓。
最近7日会轮换复查修订，最近2日404不永久标成休市。
官方[年度下载清单](https://www.shfe.com.cn/reports/tradedata/datadownload/download.json)
每周缓存发现，但首版不自动下载包含全部品种的大型年度 ZIP，也不解压到文件系统。

主力规则是前一交易日 `OPENINTEREST` 最大，并列取最近交割月；
先选约再验证本日结算，原赢家缺失时不临时改选次名。
同一合约前后日 `SETTLEMENTPRICE` 收益前向连接，避免换月价差变成假涨跌；
预测及 MAE 再按最新实际主力结算价折算，铜铝为 CNY/吨、银为 CNY/千克。
这是透明的衍生基准，不是交易所发布的官方主力指数。

延时价单独保存为 `<seriesId>.quote.json`，按日终选出的同一合约匹配，
显示真实合约、行情时间与抓取时间，标称至少延时30分钟。
它不进入日终训练标签，也不冒充收费实时行情。服务器按行情时间2小时/抓取时间1小时
独立判断过期，午休、闭市或来源停更可能导致正常的“已过期”展示。

历史档案没有可证明的完整发布时间版本，所以自动模式明确使用
`LATEST_HISTORY_REPLAY`，通过同样的每跨度验收也只能是 `RESEARCH_ONLY`。
历史数据足够且每个跨度都胜 Naive、区间覆盖达标时，可以展示研究价格与方向，
但 `procurementSignal` 始终 `INSUFFICIENT`，不会升级为 READY 或建议下单。
原始首次抓取时间不会倒写成历史已知时间；真实长期前向验证需要另外持续积累，
首版没有把档案研究回测当成这项证据。

输出日终预测快照、独立延时价和 `auto-feed-health.json` 均为原子完整替换。
源失败保留旧数据，同时独立报告错误；ERP 再检查快照时效。
后台有30秒心跳，10分钟未见心跳不得显示“正在更新”。`--once` 的
`autoUpdateEnabled=false`，常驻进程才为true，正常停止后重新写false。
应用托管另外要求90秒内、本轮runId与配置revision一致的存活回执；到期停止声称配置已应用。
HTTP请求不启动后台任务。独立模式可用系统进程管理器或下方容器例子监管。

## 容器常驻示例

提供 Dockerfile 和 `compose.yaml` 作为部署模板；本轮只验证了本机 Python，未构建或上线容器。
在仓库根目录执行 `docker build -f services/material_forecast/Dockerfile -t uten-material-forecast:local .`。
Compose 的 `MATERIAL_FORECAST_DIRECTORY` 必须设为服务器同样读取的绝对目录，
Linux 目录须可由 uid 10001 写入；缓存 `.auto-feed/` 要持久化并与快照一起备份。
Linux 正式安装使用独立 worker 身份。输出目录由该身份拥有、组为 ERP 只读组，设置 SGID
和 `2750`；只有公开快照、延时报价、心跳以 `0640` 原子发布，ERP 可以读、不能写。
缓存、已发行预测档案、状态账本和锁仍为 `0600`，不要对私有状态递归放宽权限，
也不要让 worker 加入 ERP 组或复用 ERP 运行身份来解决读取问题。
镜像构建与虚拟环境安装使用同一份完整 hash 锁，强制 `--require-hashes --only-binary=:all:`，
并执行 `pip check`；常驻进程启动时不安装或更新依赖。
本进程不需要 ERP 密钥。容器仅请求官方公开统计，未安装订阅行情服务。

## 旧版可选 CSV 模式

下面保留自有/已授权供应商现货等诊断工具及旧版读取兼容；当前内置关联目录不提供新增自定义 CSV 品种。
它不是内置沪铜/沪铝/沪银的主流程。
CSV 模式在安装后只读取本地文件，不访问网络，也不修改现有采购事实。

### CSV 安装与运行

推荐 Python 3.12 64 位。依赖安装需要能访问 PyPI；安装后计算不访问网络，
不需要 GPU 或模型权重。依赖与 worker 版本一起发布，不能在每次启动时自动升级。
在仓库根目录执行，下面用 PowerShell 表示：

```powershell
python -m venv .venv-material-forecast
& ./.venv-material-forecast/Scripts/python.exe -m pip install --require-hashes --only-binary=:all: -r services/material_forecast/requirements.txt
& ./.venv-material-forecast/Scripts/python.exe -m pip check
& ./.venv-material-forecast/Scripts/python.exe -m unittest discover -s services/material_forecast/tests -v

& ./.venv-material-forecast/Scripts/python.exe services/material_forecast/worker.py `
  --manifest D:/MaterialForecast/input/copper.manifest.json `
  --csv D:/MaterialForecast/input/copper.csv `
  --output-directory D:/MaterialForecast/snapshots
```

Linux 使用虚拟环境的 `bin/python`。输出目录必须与服务器配置
`uten.material-forecast.snapshot-directory` 指向同一个本地绝对目录。
目录配置使用前述自动采集章节的同一属性。

CSV诊断必须显式配置独立目录；不要把 `examples/generated` 配成正式目录。
首次启用前先按既有发布流程应用 V890 迁移，不对公司数据库手工建表。
一次成功计算会以原子替换写入 `<seriesId>.json`；失败保留上一次完整快照。
ERP 会独立检查数据和快照是否过期，失败后不会把旧价格重新标为实时有效。

本地 CSV 更新可以自动检查：同样的命令增加 `--watch 60`，进程每 60 秒
检查文件修改时间和大小，只在输入改变时重新计算。最小间隔 10 秒；
按 Ctrl+C 停止。需要常驻时由运维进程管理器监管这个命令。
也可以在每日完成数据导出后执行一次批处理命令。worker 不会向来源网站索取更新。
来源导出应先写临时文件，再替换 CSV，避免读到写了一半的文件。

## CSV 授权数据与修订

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
同一基准不能并行导入；OS锁在异常退出后自动释放，不能凭锁文件是否存在判断进程存活。

重复的 `date+available_at`、未来发布时间、非正价格、明显单位跳变、超限文件会拒绝。
引号未闭合的截断 CSV 也会拒绝，保留上一次完整快照。账本缺少字段、版本不兼容、
行清单被截短或完整前缀摘要不符时停止导入，须恢复可信备份，不能重新建立空账本。
相邻首报价或同日修订相差超过 5 倍会视为可疑，需核对单位与来源。
CSV 最大 8 MiB、50,000 行修订，不允许用插值或填充伪造缺失报价。

## CSV 预测和验收方法

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

## SYNTHETIC CSV 演示与真实库验证

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
`requirements.in` 登记直接依赖，`requirements.txt` 固定完整传递依赖及 PyPI 包摘要；
安装强制校验摘要，不能让启动时的解析悄悄引入未审查的新版本。当前锁用 uv 0.8.22
生成，可在独立工具环境安装相同版本后，于仓库根目录执行：

```powershell
uv pip compile services/material_forecast/requirements.in --universal --python-version 3.12 --generate-hashes --only-binary :all: --no-annotate --no-header --output-file services/material_forecast/requirements.txt
```

每个 PR 和 main 提交都运行离线模型回归，OSV 同时扫描这份完整锁；发布必须通过
同一提交最新的 Quality、CodeQL、OSV 和 Material forecast 四项门禁。
这只代表新版本候选通过软件检查；生产升级还需使用自有授权数据进行滚动评估，
确认每个品类/跨度没有退化后再部署新 worker，保留前一版本和输入账本备份。
不允许把开源项目发布新版本直接等同于更高预测准确率。

代码/算法许可证参考 [StatsForecast](https://github.com/Nixtla/statsforecast)；
方法参考 [滚动回测文档](https://nixtlaverse.nixtla.io/statsforecast/docs/tutorials/crossvalidation.html)。
源数据的使用和转发权必须另行确认；[AKShare 官方说明](https://akshare.akfamily.xyz/introduction.html)
限定其接口及相关数据为学术研究，开源采集代码本身不提供商用行情授权。
