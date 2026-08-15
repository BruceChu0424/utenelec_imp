-- V291: 销售退货质检处置受控纠错（追加式补偿命令，SOP 06 §二唯一 🔴 上线阻断项）。
--
-- 背景：V189 落地「收货冻结 → GOOD_RELEASE/SCRAP/REWORK 受控处置」，事件账禁改禁删；
-- 但处置误判后没有任何受控回退途径（整单红冲被正确阻断），只能停线人工调查。
-- 本次补「追加式补偿命令」：撤回已登记的某类处置量，精确反向数量/库存投影，
-- 并以 *_REVOKED 事件追加留痕；事件账仍不可 UPDATE/DELETE。
--
-- 本迁移只扩展 action 枚举 CHECK（新增三种补偿动作）；不回填历史、不改任何既有行。
-- 权限沿用 sales_return_quality:handle（与处置同一受控人群）；双人复核/岗位分离
-- 属上线前业务签字项（见 2026-08-09 清单 BUS/UAT），不在本迁移内伪造。

ALTER TABLE sales_return_quality_events
    DROP CONSTRAINT sales_return_quality_events_action_chk;

ALTER TABLE sales_return_quality_events
    ADD CONSTRAINT sales_return_quality_events_action_chk CHECK (
        action IN (
            'RECEIVED', 'GOOD_RELEASE', 'SCRAP', 'REWORK', 'RECEIPT_REVERSED',
            'GOOD_RELEASE_REVOKED', 'SCRAP_REVOKED', 'REWORK_REVOKED'
        )
    );
