-- V692 热表延迟约束触发器按相关列起跳, 补齐 V646/V690 新增的四个触发器(ADR-106 口径)。
--
-- 背景: ADR-106(V674)规定热表上的 DEFERRABLE 约束触发器对 UPDATE 起跳时必须带 WHEN,
-- 只有相关列真变了才排队到提交时校验; JPA/整行更新会把每一列都写进 SET, 只写 UPDATE OF 不够。
-- V646(委外子件精确库存交接)与 V690(车间公共备货报工)各新增了不带 WHEN 的 UPDATE 路径,
-- HotTableTriggerHygieneContractTest 会拒绝。已发布到服务器的 V646 不能改字节, 故在此统一重建:
-- INSERT/DELETE 路径保持原名不带 WHEN, UPDATE 路径拆成 *_upd 并带 WHEN(与 V674 同一拆法)。
-- 触发器函数与校验语义不变, 只减少无关更新的排队; 这四个触发器原本都不是 ENABLE ALWAYS。

-- 1. stock_reservations: 委外子件交接目标预留的数量守恒(函数读 qty / released_qty / is_deleted)。
DROP TRIGGER trg_component_handoff_target_balance ON stock_reservations;
CREATE CONSTRAINT TRIGGER trg_component_handoff_target_balance
    AFTER INSERT ON stock_reservations
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    EXECUTE FUNCTION fn_assert_subcontract_component_handoff_balance();
CREATE CONSTRAINT TRIGGER trg_component_handoff_target_balance_upd
    AFTER UPDATE ON stock_reservations
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    WHEN (OLD.qty IS DISTINCT FROM NEW.qty
       OR OLD.released_qty IS DISTINCT FROM NEW.released_qty
       OR OLD.is_deleted IS DISTINCT FROM NEW.is_deleted)
    EXECUTE FUNCTION fn_assert_subcontract_component_handoff_balance();

-- 2. stock_document_items: 公共备货成品入库不超过已审核报工(函数读 执行段 / 销售分配 / 数量 / 单据 / 删除)。
DROP TRIGGER trg_assert_finished_in_segment_public_fact ON stock_document_items;
CREATE CONSTRAINT TRIGGER trg_assert_finished_in_segment_public_fact
    AFTER INSERT OR DELETE ON stock_document_items
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    EXECUTE FUNCTION fn_assert_execution_segment_public_surplus_row();
CREATE CONSTRAINT TRIGGER trg_assert_finished_in_segment_public_fact_upd
    AFTER UPDATE ON stock_document_items
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    WHEN (OLD.execution_segment_id IS DISTINCT FROM NEW.execution_segment_id
       OR OLD.execution_segment_sales_allocation_id IS DISTINCT FROM NEW.execution_segment_sales_allocation_id
       OR OLD.qty IS DISTINCT FROM NEW.qty
       OR OLD.doc_id IS DISTINCT FROM NEW.doc_id
       OR OLD.is_deleted IS DISTINCT FROM NEW.is_deleted)
    EXECUTE FUNCTION fn_assert_execution_segment_public_surplus_row();

-- 3. stock_documents: 入库单审核/作废/删除时复核公共备货上限。
DROP TRIGGER trg_assert_stock_document_segment_public_status ON stock_documents;
CREATE CONSTRAINT TRIGGER trg_assert_stock_document_segment_public_status
    AFTER UPDATE OF status, is_deleted, doc_type ON stock_documents
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    WHEN (OLD.status IS DISTINCT FROM NEW.status
       OR OLD.is_deleted IS DISTINCT FROM NEW.is_deleted
       OR OLD.doc_type IS DISTINCT FROM NEW.doc_type)
    EXECUTE FUNCTION fn_assert_stock_document_segment_public_status();

-- 4. production_execution_segments: 计划量变化时复核公共备货上限。
DROP TRIGGER trg_assert_execution_segment_public_capacity_change ON production_execution_segments;
CREATE CONSTRAINT TRIGGER trg_assert_execution_segment_public_capacity_change
    AFTER UPDATE OF planned_qty ON production_execution_segments
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    WHEN (OLD.planned_qty IS DISTINCT FROM NEW.planned_qty)
    EXECUTE FUNCTION fn_assert_execution_segment_public_capacity_change();
