package com.uten.imp.features.finance.gl;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;

/** Dedicated GL projection for physical excess subcontract material loss. */
final class SubcontractWasteLossGlProjection {
    static final String SOURCE_TYPE = "SUBCONTRACT_ABNORMAL_LOSS";

    private SubcontractWasteLossGlProjection() {}

    static void assertConfiguration(EntityManager em, String period) {
        long invalid = ((Number) em.createNativeQuery("""
                SELECT COUNT(*)
                FROM subcontract_loss_cases loss
                JOIN subcontract_wastes waste ON waste.id=loss.waste_id
                WHERE waste.status=1 AND COALESCE(waste.is_deleted,FALSE)=FALSE
                  AND to_char(waste.bill_date,'YYYY-MM')=:p
                  AND EXISTS(
                      SELECT 1 FROM subcontract_loss_case_lines line
                      WHERE line.case_id=loss.id AND line.excess_loss_qty>0)
                  AND (
                      loss.waste_bill_no IS NULL
                      OR loss.loss_book_value_local<=0
                      OR EXISTS(
                          SELECT 1 FROM subcontract_loss_case_lines line
                          WHERE line.case_id=loss.id AND line.excess_loss_qty>0
                            AND (line.valuation_status<>'VALUED'
                                 OR line.unit_book_value_local<=0
                                 OR line.loss_book_value_local<=0))
                      OR loss.loss_book_value_local IS DISTINCT FROM (
                          SELECT COALESCE(SUM(line.loss_book_value_local),0)
                          FROM subcontract_loss_case_lines line
                          WHERE line.case_id=loss.id AND line.excess_loss_qty>0)
                      OR system_posting_style_id('SUBCONTRACT_ABNORMAL_LOSS') IS NULL
                      OR system_posting_style_id('INVENTORY_ASSET') IS NULL)
                """).setParameter("p", period).getSingleResult()).longValue();
        if (invalid != 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "委外超耗损失来源成本、金额或稳定科目不完整，禁止删除并重生成总账凭证");
        }
    }

    static void assertProjectionOwnership(EntityManager em, String period) {
        long orphaned = ((Number) em.createNativeQuery("""
                SELECT COUNT(*) FROM gl_vouchers voucher
                WHERE voucher.source='AUTO' AND voucher.period=:p
                  AND voucher.source_type='SUBCONTRACT_ABNORMAL_LOSS'
                  AND NOT EXISTS(
                      SELECT 1 FROM subcontract_loss_cases loss
                      JOIN subcontract_wastes waste ON waste.id=loss.waste_id
                      WHERE loss.waste_id=voucher.source_doc_id
                        AND to_char(waste.bill_date,'YYYY-MM')=voucher.period)
                """).setParameter("p", period).getSingleResult()).longValue();
        if (orphaned != 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "存在无法证明委外损耗来源的 AUTO 凭证，禁止重生成删除");
        }
    }

    static void post(EntityManager em, String period) {
        em.createNativeQuery("""
                INSERT INTO gl_vouchers
                    (voucher_no,period,voucher_date,source,source_type,source_doc_id,remark)
                SELECT loss.waste_bill_no||'-LOSS',to_char(waste.bill_date,'YYYY-MM'),waste.bill_date,
                       'AUTO','SUBCONTRACT_ABNORMAL_LOSS',loss.waste_id,'委外超耗材料异常损失'
                FROM subcontract_loss_cases loss
                JOIN subcontract_wastes waste ON waste.id=loss.waste_id
                WHERE waste.status=1 AND COALESCE(waste.is_deleted,FALSE)=FALSE
                  AND loss.loss_book_value_local>0
                  AND to_char(waste.bill_date,'YYYY-MM')=:p
                """).setParameter("p", period).executeUpdate();

        em.createNativeQuery("""
                INSERT INTO gl_entries
                    (voucher_id,line_no,style_id,direction,amount,entry_date,period,
                     source_doc_type,source_doc_id,source_bill_no,summary)
                SELECT voucher.id,1,loss_style.id,1,loss.loss_book_value_local,waste.bill_date,
                       voucher.period,'SUBCONTRACT_ABNORMAL_LOSS',loss.waste_id,
                       loss.waste_bill_no,'确认委外超耗异常损失'
                FROM subcontract_loss_cases loss
                JOIN subcontract_wastes waste ON waste.id=loss.waste_id
                JOIN gl_vouchers voucher ON voucher.source='AUTO'
                 AND voucher.source_type='SUBCONTRACT_ABNORMAL_LOSS'
                 AND voucher.source_doc_id=loss.waste_id
                 AND voucher.period=to_char(waste.bill_date,'YYYY-MM')
                CROSS JOIN LATERAL(
                    SELECT system_posting_style_id('SUBCONTRACT_ABNORMAL_LOSS') AS id) loss_style
                WHERE waste.status=1 AND COALESCE(waste.is_deleted,FALSE)=FALSE
                  AND loss.loss_book_value_local>0
                  AND to_char(waste.bill_date,'YYYY-MM')=:p
                UNION ALL
                SELECT voucher.id,2,inventory_style.id,-1,loss.loss_book_value_local,waste.bill_date,
                       voucher.period,'SUBCONTRACT_ABNORMAL_LOSS',loss.waste_id,
                       loss.waste_bill_no,'转出委外超耗材料库存资产'
                FROM subcontract_loss_cases loss
                JOIN subcontract_wastes waste ON waste.id=loss.waste_id
                JOIN gl_vouchers voucher ON voucher.source='AUTO'
                 AND voucher.source_type='SUBCONTRACT_ABNORMAL_LOSS'
                 AND voucher.source_doc_id=loss.waste_id
                 AND voucher.period=to_char(waste.bill_date,'YYYY-MM')
                CROSS JOIN LATERAL(
                    SELECT system_posting_style_id('INVENTORY_ASSET') AS id) inventory_style
                WHERE waste.status=1 AND COALESCE(waste.is_deleted,FALSE)=FALSE
                  AND loss.loss_book_value_local>0
                  AND to_char(waste.bill_date,'YYYY-MM')=:p
                """).setParameter("p", period).executeUpdate();
    }
}
