-- =====================================================================
-- V97：生产领料单部分出库 + 单据领料车间
-- =====================================================================
-- 背景（仓库部门需求·庞宗荣·高）：
--   ① 生产领料单能被引用、部分出库，未出库部分作为「未完成生产领料单」存在
--      （老系统不能引用，部分出库要删行重新做单）；
--   ② 各车间领料能单独统计、领料单能查到是哪个车间领走的。
-- 设计：
--   stock_document_items.issued_qty  每行已出库量（分轮累计，与委外 received_qty 同构）
--   stock_documents.issue_status     0未出库/1部分出库/2已出完（Service 派生）
--   stock_documents.department_id    领料车间/部门（DRAW 用，报表按车间统计）
-- 语义变更：DRAW 审核不再直接动库存（审核=确认领料单），
--   库存流水由「出库」动作按行分轮产生；历史已审 DRAW 单按旧语义回填为已全部出库。
-- =====================================================================

ALTER TABLE stock_document_items
    ADD COLUMN IF NOT EXISTS issued_qty NUMERIC(18,4) NOT NULL DEFAULT 0;

ALTER TABLE stock_documents
    ADD COLUMN IF NOT EXISTS issue_status SMALLINT NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS department_id UUID REFERENCES departments(id);

-- 历史已审 DRAW 单：旧语义「审核即全部出库」→ 回填为已出完，保持账目一致
UPDATE stock_document_items i SET issued_qty = i.qty
FROM stock_documents d
WHERE d.id = i.doc_id AND d.doc_type = 'DRAW' AND d.status = 1;

UPDATE stock_documents d SET issue_status = 2
WHERE d.doc_type = 'DRAW' AND d.status = 1;

CREATE INDEX IF NOT EXISTS idx_sd_department ON stock_documents(department_id);
CREATE INDEX IF NOT EXISTS idx_sd_draw_issue ON stock_documents(issue_status) WHERE doc_type = 'DRAW';
