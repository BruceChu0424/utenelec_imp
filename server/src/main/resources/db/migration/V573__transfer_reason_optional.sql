-- V573 2026-09-13 调拨/让出业务原因改为可选
-- 背景：跨计划调入、专属在途调入弹窗简化（多选+自动匹配）后，业务原因不再强制；
-- 撤销类操作仍保留强制原因（撤销迁移未动）。列保持 NOT NULL，缺省由服务端写 ''。

ALTER TABLE preplan_material_reallocations
    DROP CONSTRAINT preplan_reallocation_reason_chk;
ALTER TABLE preplan_material_reallocations
    ADD CONSTRAINT preplan_reallocation_reason_chk
    CHECK (reason = btrim(reason) AND length(reason) <= 1000);

ALTER TABLE preplan_future_supply_transfers
    DROP CONSTRAINT preplan_future_supply_transfers_reason_check;
ALTER TABLE preplan_future_supply_transfers
    ADD CONSTRAINT preplan_future_supply_transfers_reason_check
    CHECK (reason = btrim(reason) AND length(reason) <= 1000);
