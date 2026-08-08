-- V232: 修正 V164 守卫对 is_closed 的误判。
--
-- 背景：生产链自动生成的领料单（DRAW，如执行分段「自动备料」）由生产流程建为草稿，
-- 交仓库走 approve → issue(分轮出库) 履约。DRAW 的库存只在 issue 时产生（不在审核时），
-- 当全部明细出完，StockDocService#recomputeIssueStatus 派生 issue_status=2 并将 is_closed 置 true。
--
-- V164 的 fn_guard_production_linked_stock_document 把 is_closed 列入了「不可变身份列」清单，
-- 导致最后一轮出库把 is_closed 由 false→true 时触发 23514
-- "production-linked stock document identity is immutable"，仓库无法完成领料出库。
--
-- 服务层契约（ProductionLinkedStockDocumentServiceContractTest）只要求 update()/delete() 拒绝
-- 生产链单据；approve()/issue()/reverseIssue() 本就被允许操作其生命周期。is_closed 是派生生命周期
-- 字段（非身份、非明细），不应纳入不可变清单。通用 update()/delete() 仍由服务层
-- rejectGenericMutationOfProductionDocument 在到达 DB 前拦截，身份列（doc_type/bill_no/仓库/计划号…）
-- 仍受本触发器保护。仅放行 is_closed 的翻转。

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
           OR NEW.remark IS DISTINCT FROM OLD.remark
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
