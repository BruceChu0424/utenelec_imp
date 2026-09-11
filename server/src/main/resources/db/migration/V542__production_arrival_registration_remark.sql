-- V542 生产成品送检登记备注（2026-09-09 用户口径：登记成品与库位对照采购入库
-- 补齐——单张/批量登记页头部卡带备注输入框，随登记批次留痕；品质侧与登记详情
-- 可回看）。空串归一 NULL；长度上限 500 与采购收货备注一致。
ALTER TABLE production_finished_arrival_registrations
    ADD COLUMN IF NOT EXISTS remark TEXT;

ALTER TABLE production_finished_arrival_registrations
    ADD CONSTRAINT production_finished_arrival_remark_chk
    CHECK (remark IS NULL OR length(remark) <= 500)
    NOT VALID;
