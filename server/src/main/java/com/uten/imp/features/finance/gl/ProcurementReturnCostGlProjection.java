package com.uten.imp.features.finance.gl;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;

/** Commercial supplier credits and actual company inventory value are distinct monetary facts. */
final class ProcurementReturnCostGlProjection {
    static final String SOURCE_TYPE="PROC_RETURN_VARIANCE";
    static final String ROLE="PROCUREMENT_RETURN_VARIANCE";
    private ProcurementReturnCostGlProjection(){}

    private static final String SOURCES="""
        WITH documents AS (
            SELECT id,bill_date,bill_no,total_local,'PURCHASE_RETURN'::text family FROM purchase_returns
            WHERE legacy_id IS NULL AND status=1 AND NOT is_deleted AND to_char(bill_date,'YYYY-MM')=:p
            UNION ALL SELECT id,bill_date,bill_no,total_local,'SUBCONTRACT_RETURN'::text FROM subcontract_returns
            WHERE legacy_id IS NULL AND status=1 AND NOT is_deleted AND to_char(bill_date,'YYYY-MM')=:p
        ), items AS (
            SELECT item.id,item.return_id document_id,'PURCHASE_RETURN'::text family,
                   CASE WHEN item.quantity_semantics='CHARGED_PLUS_GIFT_V1'
                        THEN item.charged_base_qty+item.gift_base_qty ELSE ROUND(item.qty*item.unit_rate,4) END base_qty
            FROM purchase_return_items item WHERE NOT item.is_deleted
            UNION ALL SELECT item.id,item.return_id,'SUBCONTRACT_RETURN',ROUND(item.qty*item.unit_rate,4)
            FROM subcontract_return_items item WHERE NOT item.is_deleted
        ), facts AS (
            SELECT document.*,
                   COALESCE(ap.amount,0) commercial_credit,
                   COALESCE(ap.rows,0) ap_rows,
                   line_cost.actual_cost,line_cost.complete,
                   line_cost.actual_cost-COALESCE(ap.amount,0) variance
            FROM documents document
            LEFT JOIN LATERAL (
                SELECT SUM(-ledger.amount_original_local) amount,COUNT(*) rows
                FROM ar_ap_ledger ledger WHERE ledger.source_doc_type=document.family
                  AND ledger.source_doc_id=document.id AND ledger.direction='AP'
                  AND ledger.status=1 AND NOT ledger.is_deleted
            ) ap ON TRUE
            LEFT JOIN LATERAL (
                SELECT SUM(actual.value) actual_cost,
                       COUNT(*)>0 AND BOOL_AND(actual.complete AND item.base_qty IS NOT NULL
                           AND actual.quantity=item.base_qty) complete
                FROM items item
                LEFT JOIN LATERAL (
                    SELECT COALESCE(SUM(value.amount),0) value,
                           SUM(created.qty_base) quantity,
                           COUNT(*)>0 AND BOOL_AND(node.pending_parents=0 AND node.source_final
                               AND NOT EXISTS(SELECT 1 FROM stock_value_tasks task
                                   JOIN stock_value_edges edge ON edge.id=task.edge_id
                                   WHERE edge.child_node_id=node.id AND task.status='PENDING')) complete
                    FROM stock_value_nodes node JOIN stock_value_events created ON created.id=node.creation_event_id
                    LEFT JOIN LATERAL (
                        SELECT SUM(posting.amount_delta_local) amount FROM stock_value_postings posting
                        WHERE posting.owner_kind='EXTERNAL' AND posting.owner_id=item.id AND posting.node_id=node.id
                    ) value ON TRUE
                    WHERE node.owner_kind='EXTERNAL' AND node.owner_id=item.id
                      AND created.operation='ISSUE' AND created.source_doc_type=document.family
                      AND created.source_doc_id=document.id AND created.source_item_id=item.id
                ) actual ON TRUE
                WHERE item.document_id=document.id AND item.family=document.family
            ) line_cost ON TRUE
        )
        """;

    static void assertConfiguration(EntityManager em,String period) {
        long invalid=((Number)em.createNativeQuery(SOURCES+"""
                SELECT COUNT(*) FROM facts WHERE complete IS DISTINCT FROM TRUE OR actual_cost IS NULL
                    OR actual_cost<0 OR total_local IS NULL OR commercial_credit<>total_local
                    OR (commercial_credit=0 AND ap_rows<>0) OR (commercial_credit>0 AND ap_rows<>1)
                    OR (variance<>0 AND (system_posting_style_id('PROCUREMENT_RETURN_VARIANCE') IS NULL
                        OR system_posting_style_id('INVENTORY_ASSET') IS NULL))
                """).setParameter("p",period).getSingleResult()).longValue();
        if(invalid>0)throw new ApiException(ErrorCode.CONFLICT,
                "采购/委外退货的实际库存成本、供应商贷项或退货价差科目未完整核定，禁止删除并重生成总账凭证");
    }

    static void assertProjectionOwnership(EntityManager em,String period) {
        long orphaned=((Number)em.createNativeQuery("""
                SELECT COUNT(*) FROM gl_vouchers voucher
                WHERE voucher.source='AUTO' AND voucher.period=:p AND voucher.source_type='PROC_RETURN_VARIANCE'
                  AND NOT EXISTS(SELECT 1 FROM purchase_returns document WHERE document.id=voucher.source_doc_id
                        AND document.legacy_id IS NULL AND to_char(document.bill_date,'YYYY-MM')=voucher.period
                      UNION ALL SELECT 1 FROM subcontract_returns document WHERE document.id=voucher.source_doc_id
                        AND document.legacy_id IS NULL AND to_char(document.bill_date,'YYYY-MM')=voucher.period)
                """).setParameter("p",period).getSingleResult()).longValue();
        if(orphaned>0)throw new ApiException(ErrorCode.CONFLICT,"退货价差凭证缺少可证明的原单身份，禁止重生成删除");
    }

    static void post(EntityManager em,String period) {
        em.createNativeQuery(SOURCES+"""
                INSERT INTO gl_vouchers(voucher_no,period,voucher_date,source,source_type,source_doc_id,remark)
                SELECT bill_no||'-VAR',:p,bill_date,'AUTO','PROC_RETURN_VARIANCE',id,
                       '采购/委外退货实际库存成本与供应商贷项差额'
                FROM facts WHERE variance<>0
                """).setParameter("p",period).executeUpdate();
        em.createNativeQuery(SOURCES+"""
                INSERT INTO gl_entries(voucher_id,line_no,style_id,direction,amount,entry_date,period,
                    source_doc_type,source_doc_id,source_bill_no,summary)
                SELECT voucher.id,leg.line_no,system_posting_style_id(leg.role),leg.direction,
                       facts.variance,facts.bill_date,:p,'PROC_RETURN_VARIANCE',facts.id,facts.bill_no,
                       '实际库存退回成本减供应商商业贷项，正数损失负数收益'
                FROM facts JOIN gl_vouchers voucher ON voucher.source='AUTO'
                  AND voucher.source_type='PROC_RETURN_VARIANCE' AND voucher.source_doc_id=facts.id AND voucher.period=:p
                CROSS JOIN (VALUES(1,1,'PROCUREMENT_RETURN_VARIANCE'),(2,-1,'INVENTORY_ASSET')) leg(line_no,direction,role)
                WHERE facts.variance<>0
                """).setParameter("p",period).executeUpdate();
    }
}
