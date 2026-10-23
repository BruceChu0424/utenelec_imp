# V918：运行账号 DDL 与迁移历史只读

当前为源码与隔离回归完成状态，不代表公司服务器已经执行。公司只读检查发现：业务账号 `uten` 虽为非 superuser、与维护身份分离且不能执行业务清空函数，仍直接拥有 `public` 的 `CREATE`，并拥有 `flyway_schema_history` 的表级写权限。现行角色加固脚本要求业务账号无数据库/业务 schema 的 CREATE 和迁移历史写权限；生产应用禁用自身 Flyway，迁移由独立维护程序执行，这些宽授权不属于正常业务需要。

V918 仅收敛权限：撤销 `PUBLIC` 与 `uten` 对当前数据库及 `public` 的 CREATE，撤销迁移历史的表级、列级写权限和 grant option，再保留 `uten` 的迁移历史 SELECT。普通业务表 CRUD、序列授权、CONNECT 与 TEMP 不受影响；不修改业务数据、已有 Flyway 行、对象 owner、维护角色或成员关系。

运行账号若拥有或能切换到数据库、schema、历史表 owner，或可通过 SET ROLE、ADMIN option、管理属性、继承权限取得 DDL/历史写入能力，迁移会拒绝。未知共享角色的权限和成员关系不会被批量重写。存在依赖授权时使用 RESTRICT 拒绝，不通过 CASCADE 扩大撤权；整条 DO 语句事务回滚，先前撤权也不残留半套状态。应查清具体授权链后再按受审方案处理，不能屏蔽守卫继续发布。

维护身份仍须与业务账号分离。正式独立 migrator 固定使用本机 `127.0.0.1:5432/uten_imp`、`uten_migrator` 和 `public`，正常 `outOfOrder=false`；它不读取 Spring 数据源覆盖，也不是隔离候选迁移入口。后续旧库首次导入仍通过官方受控迁移身份、完整 run/manifest/来源与事务守卫，不把写来源证明或迁移历史的能力交给普通 runtime。V917 对生产累计来源证明的只读约束继续保留。

正在执行的冻结 H `c9efaf11b63d6ec78acd06aa18c5d00e274bcbe1` 仍为最高 V916、841 份 SQL，不包含 V915；不得修改这份冻结代码、封包或已应用历史。当前源码目录为 V918/844，与该 H 的新增差异为 V915、V917、V918。最终签名 R 必须按真实完整目录逐项重验共有资源的 script/checksum/SHA 和实际 pending，不照抄固定份数。

兼容候选先完成官方 R0/R1 及真实 owner/ACL oracle。对于缺失的低版本 915，既有一次性工具须先核对完整 R/H 差异，并用 `target=915` 将受控 pending 限为 `{915}`；只有候选上的一次受审调用可暂时允许 out-of-order。随后恢复正式 false，应用 R 实际剩余前向迁移，最终 validate 成功、normal migrate=0、pending=0，所有原 H 行原样保留。不得永久放开 outOfOrder、repair、手补 history，或恢复旧 schema 后直接启动新 JAR。具体公司数据恢复、七项独立门、切换和三件套回退仍以[正式执行手册](重建彩排与正式导入执行手册.md)为唯一入口。

`RuntimeDdlAndFlywayHistoryPrivilegesPostgresTest` 在独立 PostgreSQL 16.15 上验证八类场景：真实 Flyway 收敛旧 PUBLIC/直接/列级宽授权，runtime 正常业务读写与 TEMP，维护身份继续受控导入和后续迁移，继承/SET ROLE/ADMIN option/owner/管理属性绕过拒绝，以及依赖授权失败时权限与历史原子保全。该回归不连接现役或并行导入数据库，不能代替最终同 SHA CI、签名、目标库迁移与服务器验收。
