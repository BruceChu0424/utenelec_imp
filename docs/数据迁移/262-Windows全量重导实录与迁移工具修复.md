# 262 · Windows 全量重导实录与迁移工具修复（2026-09-28）

> 背景：开发库基础资料需要从老库（本机 LocalDB `YTDQ_2023`，数据文件
> `C:\Users\bruce\YTDQ_2023.mdf`，业务截止 2026-07-22）完整重导。这是
> `export_legacy.ps1 All` + `migrate.sh` 全链首次在 Windows 上完整走通，
> 过程中修复了**三笔源代码级缺陷**并沉淀了一组 Windows 执行前提。
> 修复提交在分支 `fix/legacy-export-all-duplicate`（基于 main 0849eb31）：
> - `f2a55433` exporter All 分支重复导出清单条目
> - `841cae5f` color/mould/client 主档重复码按现行分配器重派（V276）
> - `88f25a01` supplier 补 legacy 旗标 / goods 负成本→NULL（V421）/
>   BOM 零用量显式排除（V739）+ 批量导入跳过逐行环检（V711/V739 先例）
> - hr-workers stub 与名录同人同证号让位（id_card_hash 跨集合去重）
>
> **合并提醒：以上修复必须并入 main，否则下次全量重导会在同样位置失败。**

## 一、源代码缺陷修复（两笔，均在 server/legacy_migration/，不触碰任何表设计）

### 1. exporter All 分支重复条目（f2a55433）

`export_legacy.ps1` 的 `All` 分支在采购段与委外段**各导一次**
`legacy_operators_ref.csv`，`$script:exportResults` 累积重复条目 →
formatVersion 4 manifest 的 `files[]` / sidecar 出现同名两行 → 导入端
`verify_full_bootstrap_export` 的唯一性校验直接拒绝
（`checksum sidecar has an invalid or duplicate row`）。
全量 All 此前从未被完整执行过，所以一直没暴露。

修复：`Export-Query` 累积结果按文件名去重、以最后一次为准。单模块导出不受影响。

### 2. 主档重复码 vs V276 主档码终身预留（841cae5f）

V276 上线后，同域**同码不同身份**的 INSERT 被触发器拒绝
（`master code is reserved for another identity`）。老库实测重复：

| 来源 | 重复组 | 多余行 |
|---|---|---|
| B_Color | `'01'`×18、`'02'/'48'/'101'/'102'/'103'` 各×2 | 22 |
| B_Mould | `'UF-30'`×2（2669 封存模 / 3019 新模） | 1 |
| B_Client | `'GD0001'`×2（5281 样品客户 / 5317 志邦家居） | 1 |

goods/unit/currency/warehouse/supplier 归一化后无重复，不受影响。

**处理口径 = 既有首导先例（旧开发库 590→YS000003、3019→MJ000002、5317→KH000005）：**

- 每组按 `legacy_id` 升序，**第一条保留老库原码**（keeper）；
- 其余行走现行统一分配器取号重派，**不改任何表结构、不改 keeper 行码值**：
  - 颜色：固定前缀主档分配器 `master_code_sequences(prefix='YS')`
    （`MasterCodePrefix.COLOR` + `MasterCodeService`，颜色无分类树，
    **不占** `category_master_code_sequences`——该表 CHECK 只允许
    GOODS/MOULD/CLIENT/SUPPLIER）；
  - 模具/客户：复用模块内已按行预留的 `category_master_code_sequences`
    序号，按 `MJ%06d` / `KH%06d` 重派（`CategoryDrivenCodeService.format`
    同格式）。

三个 SQL：`migrate_color.sql`、`migrate_mould_data.sql`、`migrate_client_data.sql`，
均以 `row_number() OVER (PARTITION BY upper(btrim(code)) ORDER BY legacy_id)`
判定组内序。

### 3. 触发器时代的三处漂移（88f25a01）

| 模块 | 漂移 | 处理 |
|---|---|---|
| supplier | V452 `fn_sync_supplier_default_settlement_method_reference` 要求默认结算 UUID；脚本缺 `uten.legacy_reference_import` 旗标（client 有） | 补同款 `set_config`，未解析默认保持 NULL 由 `v_supplier_default_settlement_migration_issues` 呈报 |
| goods | V421 `goods_cost_amount_range_chk` 成本金额非负；老库 -1=「未设成本」哨兵（source_e 4 / work_e 6 / machining_e 51 / total·c_total·g_total 各 15 行） | 负值→NULL（CHECK 允许 NULL），不改约束、不伪造 0 |
| goods-bom | ①V739 `goods_bom_qty_positive_chk` 要求 qty>0；老库 142 行零用量 ②V711 `fn_bom_learning_manual_ownership` 每行 INSERT 做整子树**递归环检测**，198k 行随表增长二次方退化（实测 5k 行 20.7s、50k 行 9:47，外推全量 >2.5h） | ①零用量按孤儿行同款口径显式排除留痕（`EXCLUDED_NON_POSITIVE_QTY`），守恒校验覆盖 ②按 **V739 迁移自身先例**以 `app.bom_learning_write='on'` 跳过逐行重校验，批量导入后一次性全图环检测兜底 |

hr-workers 在干净库按顺序（cleanup→roster→workers）仍有两处要懂：
①岗位域预留为 `POSITION/<部门uuid>`，且 `master_code_reservation_members`
**只追加不可清**——手工回放若中途半提交，残留预留只能推倒重建库；
②`uk_employee_sensitive_id_card_hash` 全库唯一，B_Worker 与 HR 正式名录
**同一人同证号**（实测 72 个 stub 中 12 人）时 stub 让位留 NULL（真员工为
权威身份，查重语义保留给唯一档）——修复 `migrate_hr_workers.sql` 的
id_card_hash 增加跨集合 NOT EXISTS 让位判定（与集合内 rn=1 同一语义）。

## 二、Windows 执行前提（Git Bash，复用必读）

### 1. 导出必须用 PowerShell 7（pwsh）

`export_legacy.ps1` 是**无 BOM UTF-8**且含中文注释。Windows PowerShell 5.1
按 GBK 误读：中文注释的 UTF-8 尾字节恰为 GBK 引导字节时会**吞掉行尾换行**，
下一行代码被并入注释——All 分支有 SQL 变量定义行被吞 → 运行到中段报
`Export-Query: Sql is empty`（且报错点与真实被吞行错位，极具误导性；
单模块分支恰好没吞到关键行所以能跑）。pwsh 默认 UTF-8 解析，无此问题。
绿色版即可：GitHub Releases 下载 `PowerShell-7.x-win-x64.zip` 解压使用。

### 2. python3 shim（Git Bash 无 python3 命令）

`migrate.sh` 内部硬编码 `python3 -I`。本机只有 `python`（LibreOffice 自带
3.13 可用）。shim（放独立目录并 `PATH=<dir>:$PATH`）：

```sh
#!/bin/sh
PY="/c/Program Files/LibreOffice/program/python"
for a in "$@"; do
    case "$a" in
        *verify_candidate.py) exec "$PY" -I "$(dirname "$0")/vc_driver.py" "$@" ;;
    esac
done
exec "$PY" "$@"
```

### 3. verify_candidate.py 的 676 参数超 Windows 32K 命令行上限

`verify_candidate.py` 把 670 个迁移文件路径一次性传给
`git ls-files --error-unmatch` / `git status --porcelain`，
Windows CreateProcess 32K 上限直接 `WinError 206`（约 450+ 个迁移起必炸，
7 月的 426 个尚能侥幸通过）。shim 里 `vc_driver.py` 对 `subprocess.run /
check_output` 做 **git 长参数分批**（每批 150 路径、语义等价：逐路径验证
tracked、status 输出为不相交批次并集），再 `runpy` 执行原脚本。见仓库外
`.local-tmp/py3shim/vc_driver.py`（配方可按本节重建）。

### 4. docker shim：`exec` 子命令必须保留容器 /tmp 字面量

MSYS 默认把 `/tmp/...` 参数转成 `C:/Users/<u>/AppData/Local/Temp/...`
再传给 docker.exe：`migrate.sh` 的锁目录 `mkdir /tmp/uten-legacy-migration.lock`
变成嵌套相对路径 → mkdir 失败 → 守卫**误报**「已有迁移正在运行」。
但 `docker cp` 的本地源路径又**需要**转换。解法=仅对 `exec` 子命令设
`MSYS_NO_PATHCONV=1` 透传（同 shim 目录）：

```sh
#!/bin/sh
REAL='/c/Program Files/Docker/Docker/resources/bin/docker.exe'
[ -x "$REAL" ] || REAL=$(command -v docker.exe) || REAL=docker.exe
is_exec=0
for a in "$@"; do
    if [ "$a" = "exec" ]; then is_exec=1; break; fi
    case "$a" in -*) ;; *) break ;; esac
done
if [ "$is_exec" -eq 1 ]; then MSYS_NO_PATHCONV=1 exec "$REAL" "$@"; fi
exec "$REAL" "$@"
```

**不要**全局 `export MSYS_NO_PATHCONV=1`：那会同时废掉
`python3 <script> /d/... `（原生 Python 解析不了 /d 路径）和
`docker cp` 本地路径转换，两头翻车。

### 5. flyway checksum 清单必须 LF

`verify_candidate.py` 生成的 tsv 若被 Windows Python 以文本模式写出会变
CRLF，与 `psql -At` 输出逐字节比对必失配（`tail -n +2 tsv` vs 库内
flyway_schema_history）。生成后 `write_bytes(...replace('\r\n','\n')...)`。
tsv 本身可用同文件里的 `flyway_checksum()` 函数从受审提交逐文件计算。

### 6. sidecar 与 manifest 互相绑定 → hr-roster 只能两阶段

`export_manifest.json` 的 `checksumManifestSha256` 绑 sidecar 字节；而
`--hr-roster` 的 `copy_csv` 又要求 sidecar 里有 `hr_roster.csv /
hr_managers.csv` 条目（build_hr_roster.py 合并写入）。**同时满足 =
破坏绑定**。正确编排：

1. Phase 1：把 `export_manifest.json` 移开（hr 流程按无 manifest 走
   `legacy_export_free` 分支）→ 跑 `--hr-cleanup --hr-roster`；
   `--hr-cleanup` 是**首装前置**，员工有履历（employment_history 只追加）
   后不可重跑；
2. Phase 2：manifest 复位、sidecar **从 manifest 字节级重建**
   （`'\r\n'.join(f"{sha} *{file}") + '\r\n'`，ASCII，用
   `sha256(sidecar)==manifest.checksumManifestSha256` 自证）→ 跑其余模块。

## 三、本轮完整命令序列（dev 演练）

```bash
# 0) 前置：干净 worktree（主工作树有并行 WIP 未提交迁移文件会挡 scoped 检查）
git worktree add --detach D:/Projects/uten-imp-reimport-wt <受审提交>
# tsv 生成（verify_candidate.py 的 flyway_checksum）+ LF 修正

# 1) 导出（pwsh7；四个自洽 dev 演练值）
LEGACY_SOURCE_AUTHORITY_ID=dev-localdb-ytdq2023 \
LEGACY_SOURCE_BACKUP_SHA256=<停库后 YTDQ_2023.mdf 的 sha256> \
LEGACY_SOURCE_SNAPSHOT_AS_OF_UTC=2026-07-22T16:00:00Z \
LEGACY_EXPORT_APPROVAL_REFERENCE=dev-drill-2026-09-28-bruce \
  <pwsh7>/pwsh.exe -NoProfile -File export_legacy.ps1 All

# 2) hr_roster/hr_managers/shelf_labels.csv 复制进 data/，sidecar 合并 hr 行

# 3) 目标库：Flyway 建到受审头（maven 容器编译 worktree → java -jar 起服即建）

# 4) 两阶段导入（PATH 含 python3/docker shim；UTEN_* 与 LEGACY_* 与导出一致）
#    Phase 1: --hr-cleanup --hr-roster（manifest 移开）
#    Phase 2: --goods --mould --client --supplier --color-data --unit-data
#             --currency-data --warehouse-data --mould-data --client-data
#             --supplier-data --goods-data --goods-bom --hr-workers
#             --goods-owner --client-owner --shelf-labels

# 4b) 【重导后必跑第二步】产品列表 Excel 补新 ERP 属性（来源/空值补齐/所属仓库/
#     生产车间，V498 单位让位与车间映射表见 49 号文档）：
python server/legacy_migration/import_product_lists.py \
  --data-dir "D:/uten_legacy_inputs/product lists" --apply   # 先干跑看报告

# 5) 冒烟：起服 → /api/auth/login → 基础资料列表端点 → 行数对账
```

**注意：修复提交（exporter/三个 SQL）之后必须重导出**——manifest 的
`repositoryCommit` 绑定导出时的 HEAD，任何后续提交都会让导入预检拒绝
「export repository commit does not match the importer candidate」。
先改代码并提交，再导出，再导入。

## 四、口径与边界

- 本轮是 **dev 演练**：四个 LEGACY_SOURCE_* / UTEN_LEGACY_TARGET_* 值为
  自洽的开发值（备份摘要=停库后 mdf 实测 sha256、快照截止=老库最后业务日），
  **不构成生产授权**；单模块 `reconciliation_status=NOT_RUN`。
- 分支 `fix/legacy-export-all-duplicate` 共两笔修复，待并入 main；
  并入后总索引模块表无需改口径（颜色/模具/客户仍为「已实现」，
  重复码处理已内化为迁移脚本行为）。
