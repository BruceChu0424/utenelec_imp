-- 报工 -> 成品入库 / 补产计划的运行时关系改为 UUID。
-- source_doc_no 继续保留创建当时的报工单号快照，只用于展示和人工检索。
ALTER TABLE stock_documents
    ADD COLUMN source_daily_report_id UUID;

ALTER TABLE production_plans
    ADD COLUMN source_daily_report_id UUID;

-- 历史 source_doc_no 是通用自由文本，不能证明单据确由某张报工单自动生成。
-- 因此本迁移不按单号猜测或回填；历史关系需依据审计证据另行确认。

CREATE INDEX idx_stock_documents_source_daily_report
    ON stock_documents(source_daily_report_id)
    WHERE source_daily_report_id IS NOT NULL;

CREATE INDEX idx_production_plans_source_daily_report
    ON production_plans(source_daily_report_id)
    WHERE source_daily_report_id IS NOT NULL;

ALTER TABLE stock_documents
    ADD CONSTRAINT ck_stock_documents_daily_report_source_type
        CHECK (source_daily_report_id IS NULL OR doc_type = 'FINISHED_IN')
        NOT VALID;

ALTER TABLE stock_documents
    VALIDATE CONSTRAINT ck_stock_documents_daily_report_source_type;

ALTER TABLE stock_documents
    ADD CONSTRAINT fk_stock_documents_source_daily_report
        FOREIGN KEY (source_daily_report_id)
        REFERENCES production_daily_reports(id)
        ON DELETE RESTRICT NOT VALID;

ALTER TABLE stock_documents
    VALIDATE CONSTRAINT fk_stock_documents_source_daily_report;

ALTER TABLE production_plans
    ADD CONSTRAINT fk_production_plans_source_daily_report
        FOREIGN KEY (source_daily_report_id)
        REFERENCES production_daily_reports(id)
        ON DELETE RESTRICT NOT VALID;

ALTER TABLE production_plans
    VALIDATE CONSTRAINT fk_production_plans_source_daily_report;

COMMENT ON COLUMN stock_documents.source_daily_report_id IS
    '自动成品入库的来源报工 UUID 真源；source_doc_no 仅为报工单号快照';

COMMENT ON COLUMN production_plans.source_daily_report_id IS
    '自动补产计划的来源报工 UUID 真源；source_doc_no 仅为报工单号快照';
