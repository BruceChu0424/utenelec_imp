# V908 首次历史累计数量基线协议

本协议用于本地完整重建的首次历史导入；实际目标仍须在整批SUCCESS后核验。现有 V132 已明确允许旧历史超交的纠正减少，禁止继续新增超限。V908 补齐的是全新库第一次插入原始历史累计数时，被当作 `old_counter=0` 的缺口。

## 范围和数量边界

| 目标 | 完整源文件及键数 | 可识别的原始累计数 | 新流程字段必须保持 |
|---|---|---|---|
| purchase_order_items | purchase_order_items.csv，18 键 | received_qty / returned_qty | gift_qty/gift_received_qty/gift_returned_qty/arrival_overage_posted_qty 全为 0；allowed_over_receipt_pct/total_amount_input 为 NULL；quantity_semantics=LEGACY_RECORDED |
| purchase_receipt_items | 复用 V627 purchase_receipt_items.csv 原始完整行证明，17 键 | returned_qty | V627 已绑定 gift_qty；gift_returned_qty=0；charged_base_qty/gift_base_qty/gift_replacement_intent/finance_approval_case_id=NULL；quantity_semantics=LEGACY_RECORDED |
| sales_order_items | sales_order_items.csv，27 键 | shipped_qty / returned_qty | reserved_qty/planned_qty/produced_qty=0；chain_status=0；priority=3；源 flag_qty/inbound_qty 保持原表达式 |
| sales_shipment_items | sales_shipment_items.csv，27 键 | returned_qty | warehouse_id/deleted_at 保持 NULL；源 parcel_qty/carton_count/weight 等完整绑定 |

三种新投影还绑定 qty、unit_rate、weight、goods/color/unit UUID、原始父单 UUID、上游来源 UUID、原始 legacy_id、目标 UUID、run UUID、单号日期、已有金额表达式和 is_deleted=false。所有数值经既有 `fn_legacy_finance_snapshot` 规范小数尾零后计算 SHA，不改变真实数值。

有真实旧 ID 的引用仍只按相同 legacy_id 查找目标 UUID，保持当前 loader 表达式。目标缺失的历史软/断引用继续留 NULL 并保留 source row/hash 及待核记录，禁止按姓名、货品或单号猜绑。此协议不为缺失的源关联造记录。

## 认可条件

1. 专用迁移身份/超级用户，持有目标数据库的排他 bootstrap advisory lock。
2. 同一个 RUNNING、`--bootstrap-all`、BOOTSTRAP run；既有 V626 要求的单事务、目标数据库、系统标识、mapping、仓库 commit、manifest、批准引用等完整一致。
3. 仅允许注册的具体 source kind/文件，源 JSON 必须有全部且仅有原 CSV 的 typed 键，原始 ID 为正数。文件 SHA 必须对应 run_files；注册后再次篡改文件 SHA 会在目标插入时拒绝。
4. 注册时生成真实新目标 UUID；当时目标 legacy_id 尚不存在。新不可变证明保存 canonical source-row SHA、file SHA、固定不可缩减 target_fields、完整目标投影 SHA、`issued_txid=txid_current()`。
5. 只有真实第一次 BEFORE INSERT 的原超限异常分支调用认可函数。目标 UUID、legacy_id、父子关系和所有绑定数量/新默认值精确匹配；同一 target UUID 或 legacy_id 已存在就拒绝。
6. 新证据的目标 run/id/legacy_id 不能后加、解绑或重绑；已有原始身份不能 DELETE 后重新播放证明。证据 UPDATE/DELETE 一律拒绝。

此处的执行上下文继承 V626，**不声称新增了授权 security epoch 或 business_reset_generation 证明**。`issued_txid` 只允许本次真实首次插入；线上新增、跨事务重放、跨 run/候选重放及后续 UPDATE 不得据此增加任何容量。

## 原守卫与副作用

V908 使用有命中次数核验的前向补丁，仅在 `fn_guard_processed_quantity`、`fn_guard_return_allowance`、`fn_guard_procurement_received_with_arrival_allowance` 的原超限异常分支追加严格首次插入判断。原负累计数检查在此之前执行；所有 UPDATE 的增长/回退规则保持原定义。赠品 counter 与委外等非白名单不使用此例外。

无截断计数、无修改源 CSV、无抬高超收比例、无批准超量、无到货异常审批、无新库存/需求/财务批准。263 项采购收货缓存差异、2 项采购退大于收、其他历史销售/收货异常仍是原始历史待核，不能解释成财务已批准。

不可变 source 表按当前 V670 三清单登记为 legacy/NONE，和现行 receipt source 一样由迁移 run 汇总审计；不是手写逐行 audit trigger。业务清空策略 PRESERVE908，同步独立 ResetSqlContract/Audit 分类 oracle。映射协议由 bootstrap-v13 前向升 bootstrap-v14，不改旧 run 或任何已应用迁移文件。

新 source 注册只 INSERT proof，不先逐行查增长中的 proof 表。目标身份查重与 proof 唯一身份查询使用参数化动态 EXECUTE 重计划，避免首个小家族或空表缓存的 SeqScan 在同事务后续大批增长时变成平方级扫描。现有 V627 不改；其本批头/行先整批注册再首次断言。实际 1k/5k 生产触发器性能和计划由独立测试收据证明，代码审阅不等于计时结果。

## 复跑入口和验证

- `mapping-version.txt`、`migrate_purchase.sql`、`migrate_sales.sql` 与前向迁移 V908 必须来自同一冻结提交，执行 `bootstrap-v14`。不得给旧成功 run 改版本。
- [独立 PostgreSQL 回归](tests/quantity_counter/README.md)提供可复跑的合成数据、完整迁移、对抗断言及可选性能量测。
- [整批只读验收](RESULT_VERIFICATION.md)必须使用本轮封包、run 和管理员保护快照；源行数随本轮数据重新计算，不能沿用本次的 198520。
- `verify_source_counter_baseline.sql` 是成功后的附加只读报表，展示 proof→target 完整投影及六类历史待核计数；它不单独签发验收通过结论，也不调用仅限首次插入的断言函数。
- 采购收货目标仍须扣除既有 DROP 仓整单排除，不把 raw 行数当成目标数。静态和独立回归通过均不替代真实全量导入通过。

## 已完成的独立验证

冻结 SQL SHA `9326b593fb20714520a1ccb75588bbb1d9424ef8c8d5ab2506c8ac579ccfa092` 的独立随机 PostgreSQL 容器：834 个完整 Flyway 迁移成功至 V908，261 个对抗断言全部通过。1,000 行完整源登记 2,934 ms、INSERT 含 deferred 生产守卫 3,715 ms；5,000 行分别 8,678 ms 和 13,579 ms。精确 proof 查找为索引扫描，测试容器已删除。基准证明此合成负载没有平方增长，不能代替实际 198,520 行全量耗时与成功验收。

收据：`D:/uten_legacy_rehearsal/20261022/private-counter-protocol-tests-20261022/portable-final-9326/execution-20261022-220849-516a96bcc5/driver-receipt.json` 和同目录 `test-receipt.json`。未读取 .env、真实源数据或候选库；没有权限改动、假审批、库存或需求副作用。

独立回归源文件已纳入仓库 `tests/quantity_counter/`，实际导入及切换结果另记执行手册的本轮回执。
