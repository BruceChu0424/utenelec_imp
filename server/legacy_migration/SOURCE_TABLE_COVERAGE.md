# 整个旧库的表级处置门禁

`validate_source_table_coverage.py` 不连接数据库。prepare 在创建最终输出目录和复制数据前读取完整 `source_table_disposition_exact.csv` 与 summary；apply 在重验已绑定的 referenceAudit SHA 后，再检查同一逻辑证明。任何未分类非空表、重复表身份、错误CSV列/行数、summary不守恒或源backup/raw manifest/cutoff不一致均在claim及业务写入前拒绝。

人数/表数/非空数/总行数都由实际清单动态计算，没有固定196、110或4686134。新空表可以记录为“来源为空”；将来有数据时必须得到已审处置，不能继续标空或未知。当前 exporter 的有效数据SELECT使用dbo命名空间，另一个非空schema必须先审清限定名导出规则，不能因同名就误认成dbo已导出的表。

summary 的 PowerShell Sum 可能写成 `4686134.0`，程序允许精确、有限、整值的数值，拒绝小数、bool、NaN/Infinity；CSV实际行数必须是非负十进制整数字符串。UTC cutoff按相同实际时刻核对，摘要必须明确来源是READ_ONLY及逐表COUNT_BIG精确计数。

prepare 把 `sourceTableCoverage` 的计数、分类数、两份audit文件SHA及源manifest/backup/cutoff写入派生manifest；不改旧封存文件。apply从referenceAudit中定位唯一的同目录两份文件，对已封存SHA和逻辑结果同时复验。旧输入没有这个证明时不能绕过新门禁。

表级处置不等于每列、每个子类型都已迁移。明确的“旧账号权限丢弃”“派生缓存归档”“历史配置归档”继续作为显式规则，不擅自转换成在线账号/库存/当期工资；这些规则的适用内容和未来变化仍须受源schema/profile门禁约束。例如：SystemItem按已选ItemclassID分区导出，新增非空子类型不能只靠整表标“导入”放行；MK_StockGoods既有归档理由依赖旧账为旧年零库存的事实，新事实不符时应重新处置，不能按表名永久忽略。源码新增列未进入固定SELECT时，CSV header本身不会改变，仍需独立完整列清单与profile复核。这些内容不是本模块已验证的保证。

私有测试：18项新回归，加现有coordinator9项，共27项通过；实际封存表清单动态得到196表、110非空、4686134行、非空未知0，原两份audit文件与raw manifest/backup绑定通过。没有访问或写任何业务数据库，没有修改sealed/Main/WT。
