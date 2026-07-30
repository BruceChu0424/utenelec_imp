-- =====================================================================
-- V59：stock_movements.movement_type 字典更新（补 15-20）+ 分区策略记录
-- =====================================================================
-- 本期销售/委外模块新增 5 个 movement_type（15-19）+ 销售其它出库（20）。
-- stock_movements.movement_type 是 SMALLINT，无需改列即可写入新值；本迁移只更新
-- 注释字典，零结构变更、零锁表、可安全重跑。
--
-- ⚠️ 关于 stock_movements 分区（性能优化，本期【不做】，待低峰+测试后单独执行）：
--   stock_movements 当前非分区（V45 建），随销售/委外流水累积会持续增长。规划转为
--   PARTITION BY RANGE(transaction_date) 按年分区。但在线转分区需 CREATE 分区表
--   + INSERT SELECT 全量回灌 + rename + 重建索引（PK 须含分区键 → (id,transaction_date)），
--   会锁表，必须低峰执行并充分测试。脚本见 docs/数据迁移/27-DDL一致性契约.md §六附注，
--   本迁移不盲跑。当前规模（数十万行 + 索引命中）单表足够，分区作为后续优化项。
--
-- movement_type 全表（1-20）：
--   1采购入库  2采购退货  3销售出库  4销售退货
--   5生产领料  6生产退料  7调拨入    8调拨出
--   9盘盈入    10盘亏出   11其它入   12其它出
--   13产成品进仓 14产成品出仓
--   15委外材料出仓(E_SOut,dir-1)  16委外材料退回(E_SWithDraw,dir+1)
--   17委外成品进仓(E_In,dir+1,不照搬老库反向)  18委外成品退(E_WithDraw,dir-1)
--   19委外材料损耗(E_SWaste,dir-1)
--   20销售其它出库(S_OtherOut,dir-1)
-- =====================================================================

COMMENT ON COLUMN stock_movements.movement_type IS
    '出入库类型：1采购入库 2采购退货 3销售出库 4销售退货 5生产领料 6生产退料 7调拨入 8调拨出 9盘盈入 10盘亏出 11其它入 12其它出 13产成品进仓 14产成品出仓 15委外材料出仓 16委外材料退回 17委外成品进仓 18委外成品退 19委外材料损耗 20销售其它出库';
COMMENT ON COLUMN stock_movements.source_doc_type IS
    '来源单据类型：PURCHASE_RECEIPT/PURCHASE_RETURN/SALES_SHIPMENT/SALES_RETURN/SALES_OTHER_SHIPMENT/SUBCONTRACT_RECEIPT/SUBCONTRACT_RETURN/SUBCONTRACT_MATERIAL_ISSUE/SUBCONTRACT_MATERIAL_RETURN/SUBCONTRACT_WASTE/STOCK_DOC...';

-- 分区转换参考脚本（不在本迁移执行，仅存档；执行时需单独 Flyway + 低峰 + 校验）：
--   CREATE TABLE stock_movements_pt (LIKE stock_movements INCLUDING DEFAULTS INCLUDING CONSTRAINTS)
--     PARTITION BY RANGE (transaction_date);
--   -- 建 2018..2030 逐年分区 + DEFAULT
--   INSERT INTO stock_movements_pt SELECT * FROM stock_movements;
--   -- 重建索引（PK 改为 (id, transaction_date)，含分区键）
--   ALTER TABLE stock_movements RENAME TO stock_movements_bak;
--   ALTER TABLE stock_movements_pt RENAME TO stock_movements;
--   -- 校验 count 一致后 DROP stock_movements_bak
