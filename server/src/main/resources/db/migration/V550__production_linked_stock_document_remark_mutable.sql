-- V550 生产链仓库单据备注可追加（2026-09-10）
-- 背景：V164/V232 的 fn_guard_production_linked_stock_document 把 remark 列入生产链
-- 仓库单据（生产领料/退料/完工入库等）的「身份不可变」集合。2026-09-10 出库弹窗
-- 与领料任务中心批量出库把「出库备注」追加到 stock_documents.remark
-- （StockDocService.appendIssueRemark：按「；」拼接、整条相同去重、单条 ≤200/总长 ≤500），
-- 触发器对生产链单据直接 23514 拒绝——FullChainEndToEndTest 批量出库场景坐实。
-- 决策：备注是描述性字段不是单据身份，从不可变集合移除；其余身份列
-- （单据类型/单号/日期/仓库/供应商/客户/人员/计划号/来源单号/部门/班组/金额/删除标记）
-- 与 V232 完全一致，删除守卫与清理授权分支原样保留。
-- 前向自包含：CREATE OR REPLACE 整个函数体（复制自 V232，仅去掉 remark 一行），
-- 不改 V164/V232 已应用文件。无表结构变更，无数据回填。

CREATE OR REPLACE FUNCTION fn_guard_production_linked_stock_document()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF fn_is_production_linked_stock_document(OLD.id) THEN
            RAISE EXCEPTION
                'production-linked stock document cannot be deleted by generic CRUD'
                USING ERRCODE = '23514',
                      CONSTRAINT =
                          'production_linked_stock_document_delete_guard';
        END IF;
        RETURN OLD;
    END IF;

    IF fn_is_production_report_cleanup_authorized(OLD.id)
       AND OLD.is_deleted = FALSE
       AND NEW.is_deleted = TRUE
       AND NEW.deleted_at IS NOT NULL
       AND (
           to_jsonb(NEW) - ARRAY[
               'is_deleted', 'deleted_at', 'updated_at', 'updated_by']
       ) = (
           to_jsonb(OLD) - ARRAY[
               'is_deleted', 'deleted_at', 'updated_at', 'updated_by']
       ) THEN
        RETURN NEW;
    END IF;
    IF fn_is_production_stock_cleanup_authorized(OLD.id)
       AND OLD.is_deleted = FALSE
       AND NEW.is_deleted = TRUE
       AND NEW.deleted_at IS NOT NULL
       AND NEW.status IN (0, -1)
       AND (
           to_jsonb(NEW) - ARRAY[
               'status', 'is_deleted', 'deleted_at',
               'updated_at', 'updated_by']
       ) = (
           to_jsonb(OLD) - ARRAY[
               'status', 'is_deleted', 'deleted_at',
               'updated_at', 'updated_by']
       ) THEN
        RETURN NEW;
    END IF;
    -- 注意：is_closed 不在此清单内——它是 recomputeIssueStatus 派生的生命周期字段，
    -- 领料全部出完(true)/反出库(false)均需合法翻转。身份与软删字段仍不可变。
    IF fn_is_production_linked_stock_document(OLD.id)
       AND (
           NEW.doc_type IS DISTINCT FROM OLD.doc_type
           OR NEW.bill_no IS DISTINCT FROM OLD.bill_no
           OR NEW.bill_date IS DISTINCT FROM OLD.bill_date
           OR NEW.warehouse_id IS DISTINCT FROM OLD.warehouse_id
           OR NEW.to_warehouse_id IS DISTINCT FROM OLD.to_warehouse_id
           OR NEW.supplier_id IS DISTINCT FROM OLD.supplier_id
           OR NEW.client_id IS DISTINCT FROM OLD.client_id
           OR NEW.worker_id IS DISTINCT FROM OLD.worker_id
           OR NEW.maker_id IS DISTINCT FROM OLD.maker_id
           OR NEW.plan_no IS DISTINCT FROM OLD.plan_no
           OR NEW.source_doc_no IS DISTINCT FROM OLD.source_doc_no
           OR NEW.department_id IS DISTINCT FROM OLD.department_id
           OR NEW.ass_team IS DISTINCT FROM OLD.ass_team
           OR NEW.total_original IS DISTINCT FROM OLD.total_original
           OR NEW.total_local IS DISTINCT FROM OLD.total_local
           OR NEW.is_deleted IS DISTINCT FROM OLD.is_deleted
           OR NEW.deleted_at IS DISTINCT FROM OLD.deleted_at
       ) THEN
        RAISE EXCEPTION
            'production-linked stock document identity is immutable'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_linked_stock_document_update_guard';
    END IF;
    RETURN NEW;
END;
$$;
