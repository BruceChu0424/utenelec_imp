# 成本结构行与安全版本 v3：冻结前实施证据

本目录全部是 **prep，不能代替最终冻结 SHA 的验收**。实施工作树基线 `c4b84f5465de1e6fcb4617a847f523383d07da64`，产品 `fafaaa665fd922754b66dc026246f0d94d21ae9e`，旧 v2 测试补充 `ecd132c6a81c2ad1b083cc283673f670d2cb001f`。主干未合并、未推送/部署/正式打包。最终 `7b912287e53315228b469790ff066a9fab643e3c` 由独立 final-c 工作树另作 fresh 编译和完整复验。

## 原反例及修复

`originals/` 是独立审查人指定 `current-utf8` 目录的四份原 XLSX，逐字节复制；原 2 通过/2 失败日志、原 Java 断言和报告在 `baseline/`，没有改写旧 audit。混合行“材料名称/1/4/D=数量”在旧 v2 仅保留铜钉；合法“小计数器件”亦丢行。新源码的真实 OriginalFileRegression 对同四原件 **4/4 通过**：前三个合法材料对照均保留两行、数量 1/单价 4；混合行明确拒绝，定位 `成本!第3行`、`第4列（未命名）`。`original-reader-v3.log` 与 `.exit` 为实测输出。

唯一结构判断先核对实际物理 cells，不能靠任意行包含表头关键词就跳过数据。`SpreadsheetEvidenceReader.Value.literalText` 保留原单元格类型事实，不能把数字、布尔、错误和公式缓存当作文字表头。该 reader 仅供成本 parser 使用。已识别区块的混合候选先按原列合同检查；合法独立文字表头与单格产品标题才可切块。第一份表头仍允许整列未使用的纯文字额外标题，不因空尾列拒绝合法文件，但其下任何数据/公式必须校验。

汇总只认名称列精确“合计/小计/总计”，且只有一个原始文字单元格；混合数量、单价、金额、公式或未知列时明确定位拒绝，不能 silent drop。“小计数器件/合计器/总计量器”等真实名称按材料保留。原模板单格合计、多区块和普通缓存公式对照通过。

`ImportColumnGuard.VERSION=3` 为唯一服务端事实；五类新构造全引用该常量，客户端请求不赋权。未应用 v1/v2 拒绝推进，不 UPDATE 旧 JSON，不修改 V755/V1090 或旧账。已完成、停止及原请求回执的 owner/原意图顺序保留；成本 apply 是新匹配动作，不冒称旧匹配的终态幂等重放。

## 真实 v2 签发、v3 拒绝与合法业务

只使用保留的 `uten-remediate-c-upgrade-1110`（127.0.0.1:26632/imports）和先前完全相同的合成 key；没有接 Root 统一 Web 库或 crypto。普通数据库用户 `360fcf1a-e8f2-4ab1-88ea-94758a36fc7a`（is_super_admin=false），原员工/货品/币种沿用真实 v1 谱系。

保留的旧编译程序由真实公开服务签发 v2；没有用 JSON 改版本。旧 parser class SHA-256 `bb69937ec9d72388ed21f8dddb4d550d2c80997810b4a43cad964bc673a60bca`，与独立反例使用的 class 一致。整个旧编译产物的精确源提交未独立证明；class manifest 的 c4b 是复制时仓库 HEAD，不把它冒称完整产物源版本。完整旧程序快照与哈希本地保留。

| 原件/类型 | 真实 v2 原 ID |
| --- | --- |
| mixed-header-tail | `944f2fc0-d664-4570-ae35-e12ef6a100b6` |
| subtotal-name-control | `1bfd1e34-c3bd-46d1-a0ba-c9877864787c` |
| 科目父/子 | `80220fd1-8392-4db5-9bfc-975020c33660` / `eaa16214-9004-47ba-9079-b89d38ffe674` |
| 备注 | `1537d547-5126-4140-b602-79dc1a343233` |
| 辅助 | `9aeb3a79-8883-44c2-9156-b9a0beb6d394` |
| 凭证/余额 | `964fed60-3163-4923-911d-50d470f0377c` / `40ad5d30-e143-428e-bd78-001e21d0558c` |

`old-v2-public-seed-3.log`、`old-v2-finance-seed.log` 均 exit0，原 JSON/owner/来源 SHA/存储坐标和科目谱系冻结于 `old-v2-program.json`、`old-v2-finance.json`。`v3-public-upgrade-verify-2.log` exit0：两个错误成本 pending 用完整合法 Apply 请求拒绝；全部五类 v2 的公开 apply/submit 拒绝，辅助 accounting adapter valid=false；原 JSON/来源仍相同，七业务表计数不变，改文件名也不能绕过。合法 v3 原件两行公开 Apply 新增一份匹配回执，其余业务表计数与 gl=0 不变；另一 owner 在版本检查前拒绝。

`v3-retained-v1-verify.log` exit0：真实原 v1 五类 pending、父子 JSON 仍不可推进；旧已完成备注在原期间锁定后精确返回原回执，不产生第二行；另一 owner 拒绝。该 verifier 复制自原 C2，仅把新日志写到本目录，历史 seed 阶段禁止运行。

## 定向回归及所有红轮

- 正常隔离 Maven（独立 build/TMP）：14 个文件解析类 **64 项，63 通过/0 失败/0 错误/1 私有 Excel 环境 skip**。含 5 项新结构测试，其内部逐项穷举别名、实际数字/布尔/错误、首表头和空缓存公式、汇总混杂以及合法名称与重复纯文字表头。日志 `parse-suite/maven.log`；原 Surefire 报告复制到 `parse-suite/reports/`。
- 五类持久化 PG：**32/32 通过**，成本/备注原测试历史循环补 v2；真实 remapping、手工更改、回滚、锁期/owner、科目接续、辅助和凭证接续原断言不减。自写 runner 在全部测试完成后残留一个缓存 Spring context；核对成功摘要和专用 PID 后仅关闭该测试 context，进程 exit0。未取消运行中测试。cleanup 源码、目标命令、收尾日志和 Java 动态 agent 告警原样保留；最终组使用正常 Maven/Surefire。
- 科目原命令及真实 V1090 升级 PG：**14/14 通过、exit0**，保留未知/停止/成功回执、权限、并发顺序和原件/父子身份；没有关闭 SQL 审计或不可变触发器。
- 初始 seed/seed-2 仅在 javac 的 Windows 反斜线参数转义失败，未启动业务服务；修为正斜线后 seed-3 实际签发。首 v3 探针成功拒绝第一份旧成本后，来源快照比较因 Jackson IntNode/LongNode 区分而红，两边打印 JSON 相同；改成双方相同 JSON 解析规范后完整字段等值通过。原红日志不覆写。
- 初次旧 class 清单是在复制尚未结束时捕获，最终完整重查为 8139 文件，954 个资源补入、所有已记录 class 字节未变；初清单与完整清单同时保留，不用初清单冒称完整程序证明。

## 恢复与现场步骤

旧 pending 保留为历史。用户保留原件、原 ID、owner、谱系和未知回执，不能只改文件名/把版本填 3/UPDATE preview。根据拒绝位置在副本中核对真实表头、材料和额外列，再由当前系统/原 Excel 正常重新生成支持的系统列文件并重新检测；新 SHA、新预览须完整显示所有真实材料，逐条核对或明确映射/跳过后才提交。目前没有可直接升级旧 JSON 的安全重检入口。已完成/停止/未知原意图继续按原编号核查；需要业务更正的按原更正流程办理，不改旧账。

公司私有真实模板、目标设备和原业务单据仍未提供，本轮私有 Excel 对照明确 skip；现场须以同一候选原文件重复以上原件/材料总数、数量、价格、来源、权限、回执与停止恢复步骤。Root 的真 Web chart/note 验收另记，不能把本目录的 Java 公开服务调用写成网页验收。
