package com.uten.imp.features.finance.gl;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.NativeValueConverters;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.application.concurrency.PaymentStyleHierarchyLock;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.security.access.prepost.PreAuthorize;

import java.time.LocalDate;
import java.time.YearMonth;
import java.util.List;
import java.util.UUID;

/**
 * 总账过账服务（C3）——从业务单据幂等生成 AUTO 凭证。
 *
 * <p>科目=payment_styles 树。系统自动过账科目只通过稳定 role_key 对应的持久化 UUID 定位；
 * 路径、名称和编号不参与运行时关联。
 * 收/付/费用/其它收入的对方账户科目只读取 accounts.style_id UUID 真源；
 * 缺少持久化关系时失败关闭，不再按 legacy id、账户类型或路径推断。</p>
 *
 * <p>过账规则（借贷平衡，负数业务=同向红字）：
 * 销售立帐 借113/贷031；采购+委外立帐（含退货与损耗扣款红字）借123/贷203；收款 借账户/贷113；付款 借203/贷账户；
 * 费用 借费用科目(行)/贷账户(单头合计=行合计)；其它收入 借账户/贷收入科目(行)；
 * 销售成本结转 借041/贷123（出货行 Σqty×goods.c_total，单号+“-CB”）。</p>
 *
 * <p>幂等：generate(period) 只重建本服务明确拥有的八类 AUTO 凭证；资产子账、工资等其它模块
 * 的自动凭证不属于本服务，禁止在这里删除。generateAll 逐期间重放。</p>
 */
@Service
@RequiredArgsConstructor
public class GlPostingService {

    /** Source types exclusively owned and rebuilt by this legacy regeneration job. */
    static final List<String> REGENERATED_SOURCE_TYPES = List.of(
            "AR_POST", "AP_POST", "RECEIPT", "PAYMENT",
            "EXPENSE", "INCOME", "COST_CARRY", "BANK_TRANSFER",
            "SUPPLIER_CLAIM_LEDGER", "SUPPLIER_CLAIM_OFFSET",
            "SUPPLIER_CLAIM_RECEIVABLE", "SUPPLIER_CLAIM_CASH",
            "CUSTOMER_PREPAYMENT_OFFSET",
            SubcontractWasteLossGlProjection.SOURCE_TYPE);

    private final EntityManager em;
    private final TxSessionVars tx;

    /** 重生成指定期间（YYYY-MM）的 AUTO 凭证。返回凭证数。 */
    @Transactional
    @PreAuthorize("hasAuthority('finance_post:execute')")
    public int generate(String period) {
        tx.bind();
        return generatePeriod(period);
    }

    private int generatePeriod(String period) {
        PaymentStyleHierarchyLock.lock(em);
        lockAutoProjectionPeriod(period);
        assertNoConfirmedExpenseVouchers(period);
        assertRequiredSystemPostingRoles(period);
        assertArPostingConfiguration(period);
        assertReceiptPostingConfiguration(period);
        assertCustomerPrepaymentPostingConfiguration(period);
        assertPaymentAmountsAuthoritative(period);
        assertPaymentPostingConfiguration(period);
        assertSupplierClaimPostingConfiguration(period);
        SubcontractWasteLossGlProjection.assertConfiguration(em, period);
        assertSupplierClaimProjectionOwnership(period);
        assertCustomerPrepaymentProjectionOwnership(period);
        SubcontractWasteLossGlProjection.assertProjectionOwnership(em, period);
        assertSourceDocumentIdentities(period);
        em.createNativeQuery("DELETE FROM gl_vouchers WHERE source='AUTO' AND period=:p AND source_type IN (:sourceTypes)")
                .setParameter("p", period)
                .setParameter("sourceTypes", REGENERATED_SOURCE_TYPES)
                .executeUpdate();

        postAr(period);
        postAp(period);
        SubcontractWasteLossGlProjection.post(em, period);
        postSupplierClaimLedger(period);
        postSupplierClaimOffsets(period);
        postSupplierClaimReceivables(period);
        postSupplierClaimCashReceipts(period);
        postReceipts(period);
        postCustomerPrepaymentOffsets(period);
        postPayments(period);
        postExpenses(period);
        postIncomes(period);
        postCostCarry(period);
        postBankTransfers(period);
        assertPeriodBalanced(period);

        return ((Number) em.createNativeQuery(
                "SELECT COUNT(*) FROM gl_vouchers WHERE source='AUTO' AND period=:p AND source_type IN (:sourceTypes)")
                .setParameter("p", period)
                .setParameter("sourceTypes", REGENERATED_SOURCE_TYPES)
                .getSingleResult()).intValue();
    }

    /** Remove one projected payment voucher under the same period lock used by regeneration. */
    @Transactional(propagation = Propagation.MANDATORY)
    public void removePaymentDoc(UUID paymentId, String billNo, LocalDate billDate) {
        removeAutoProjection("PAYMENT", "PAYMENT", paymentId, billNo, billDate);
    }

    /**
     * Serialize a business-document mutation with the AUTO projection rebuild for its period.
     * Callers must already own the surrounding business transaction.
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void lockAutoProjectionPeriod(LocalDate billDate) {
        if (billDate == null) {
            throw new ApiException(ErrorCode.CONFLICT, "总账投影期间缺失，禁止继续处理");
        }
        lockAutoProjectionPeriod(YearMonth.from(billDate).toString());
    }

    /**
     * Remove one unconfirmed AUTO projection under the same period lock as regeneration.
     * The source type is restricted to this service's owned projections and the delete is
     * narrowed by period plus the persisted document identity.
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void removeAutoProjection(
            String sourceType,
            UUID sourceDocId,
            String billNo,
            LocalDate billDate) {
        removeAutoProjection(sourceType, sourceType, sourceDocId, billNo, billDate);
    }

    /**
     * Variant for AR/AP projections, whose voucher source type differs from the originating
     * document type stored on each entry.
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void removeAutoProjection(
            String sourceType,
            String entrySourceType,
            UUID sourceDocId,
            String billNo,
            LocalDate billDate) {
        if (!REGENERATED_SOURCE_TYPES.contains(sourceType)
                || entrySourceType == null
                || entrySourceType.isBlank()
                || sourceDocId == null
                || billNo == null
                || billNo.isBlank()
                || billDate == null) {
            throw new ApiException(ErrorCode.CONFLICT, "总账投影标识不完整，禁止红冲");
        }
        String period = YearMonth.from(billDate).toString();
        String reversalPeriod = YearMonth.from(BusinessTime.today()).toString();
        if (!period.equals(reversalPeriod)) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "当前总账架构不支持跨会计期间红冲：原期间 " + period
                            + "，当前期间 " + reversalPeriod
                            + "。请在原期间处理，或待通用会计期间与反向凭证能力上线后操作");
        }
        lockAutoProjectionPeriod(period);
        if ("EXPENSE".equals(sourceType)) {
            assertExpenseProjectionUnconfirmed(sourceDocId, period);
        }
        long foreignProjection = ((Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM gl_vouchers voucher
                        WHERE voucher.source='AUTO'
                          AND voucher.source_type=:sourceType
                          AND voucher.source_doc_id=:sourceDocId
                          AND voucher.period=:period
                          AND voucher.status=1
                          AND COALESCE(voucher.is_deleted,false)=false
                          AND (
                              NOT EXISTS (
                                  SELECT 1
                                  FROM gl_entries entry
                                  WHERE entry.voucher_id=voucher.id
                                    AND COALESCE(entry.is_deleted,false)=false
                                    AND entry.source_doc_type=:entrySourceType
                                    AND entry.source_doc_id=:sourceDocId
                                    AND entry.period=:period
                              )
                              OR EXISTS (
                                  SELECT 1
                                  FROM gl_entries entry
                                  WHERE entry.voucher_id=voucher.id
                                    AND COALESCE(entry.is_deleted,false)=false
                                    AND (
                                        entry.source_doc_type IS DISTINCT FROM :entrySourceType
                                        OR entry.source_doc_id IS DISTINCT FROM :sourceDocId
                                        OR entry.period IS DISTINCT FROM :period
                                    )
                              )
                          )
                        """)
                .setParameter("sourceType", sourceType)
                .setParameter("entrySourceType", entrySourceType)
                .setParameter("period", period)
                .setParameter("sourceDocId", sourceDocId)
                .getSingleResult()).longValue();
        if (foreignProjection > 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "总账投影与业务单据归属不一致，禁止物理删除");
        }
        em.createNativeQuery("""
                        DELETE FROM gl_vouchers voucher
                        WHERE voucher.source='AUTO'
                          AND voucher.source_type=:sourceType
                          AND voucher.source_doc_id=:sourceDocId
                          AND voucher.period=:period
                          AND voucher.status=1
                          AND COALESCE(voucher.is_deleted,false)=false
                          AND EXISTS (
                              SELECT 1 FROM gl_entries entry
                              WHERE entry.voucher_id=voucher.id
                                AND COALESCE(entry.is_deleted,false)=false
                                AND entry.source_doc_type=:entrySourceType
                                AND entry.source_doc_id=:sourceDocId
                                AND entry.period=:period
                          )
                          AND NOT EXISTS (
                              SELECT 1 FROM gl_entries entry
                              WHERE entry.voucher_id=voucher.id
                                AND COALESCE(entry.is_deleted,false)=false
                                AND (
                                    entry.source_doc_type IS DISTINCT FROM :entrySourceType
                                    OR entry.source_doc_id IS DISTINCT FROM :sourceDocId
                                    OR entry.period IS DISTINCT FROM :period
                                )
                          )
                        """)
                .setParameter("sourceType", sourceType)
                .setParameter("entrySourceType", entrySourceType)
                .setParameter("period", period)
                .setParameter("sourceDocId", sourceDocId)
                .executeUpdate();
    }

    /**
     * Verify the exact expense voucher before the business document becomes financially confirmed.
     * The period lock prevents regeneration from changing the voucher between validation and commit.
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void requireConfirmableExpenseVoucher(
            UUID expenseId,
            UUID voucherId,
            String billNo,
            LocalDate billDate) {
        if (expenseId == null
                || voucherId == null
                || billNo == null
                || billNo.isBlank()
                || billDate == null) {
            throw new ApiException(ErrorCode.CONFLICT, "一般费用总账凭证标识不完整，禁止财务确认");
        }
        String period = YearMonth.from(billDate).toString();
        lockAutoProjectionPeriod(period);
        long valid = ((Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM gl_vouchers voucher
                        WHERE voucher.id=:voucherId
                          AND voucher.source_doc_id=:expenseId
                          AND voucher.period=:period
                          AND voucher.source='AUTO'
                          AND voucher.source_type='EXPENSE'
                          AND voucher.status=1
                          AND COALESCE(voucher.is_deleted,false)=false
                          AND (
                              SELECT COUNT(*)
                              FROM gl_entries entry
                              WHERE entry.voucher_id=voucher.id
                                AND COALESCE(entry.is_deleted,false)=false
                          ) >= 2
                          AND NOT EXISTS (
                              SELECT 1
                              FROM gl_entries entry
                              WHERE entry.voucher_id=voucher.id
                                AND COALESCE(entry.is_deleted,false)=false
                                AND (
                                    entry.source_doc_type IS DISTINCT FROM 'EXPENSE'
                                    OR entry.source_doc_id IS DISTINCT FROM :expenseId
                                    OR entry.period IS DISTINCT FROM :period
                                )
                          )
                          AND EXISTS (
                              SELECT 1
                              FROM gl_entries entry
                              WHERE entry.voucher_id=voucher.id
                                AND COALESCE(entry.is_deleted,false)=false
                                AND entry.direction=1
                          )
                          AND EXISTS (
                              SELECT 1
                              FROM gl_entries entry
                              WHERE entry.voucher_id=voucher.id
                                AND COALESCE(entry.is_deleted,false)=false
                                AND entry.direction=-1
                          )
                          AND NOT EXISTS (
                              SELECT 1
                              FROM gl_entries entry
                              WHERE entry.voucher_id=voucher.id
                                AND COALESCE(entry.is_deleted,false)=false
                                AND entry.direction NOT IN (-1,1)
                          )
                          AND COALESCE((
                              SELECT SUM(ABS(entry.amount))
                              FROM gl_entries entry
                              WHERE entry.voucher_id=voucher.id
                                AND COALESCE(entry.is_deleted,false)=false
                          ),0)>0
                          AND ROUND(COALESCE((
                              SELECT SUM(entry.direction * entry.amount)
                              FROM gl_entries entry
                              WHERE entry.voucher_id=voucher.id
                                AND COALESCE(entry.is_deleted,false)=false
                          ),0),4)=0
                        """)
                .setParameter("voucherId", voucherId)
                .setParameter("period", period)
                .setParameter("expenseId", expenseId)
                .getSingleResult()).longValue();
        if (valid != 1) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "一般费用总账凭证不存在、归属不符、已失效或借贷不平，禁止财务确认");
        }
    }

    private void assertExpenseProjectionUnconfirmed(UUID expenseId, String period) {
        long confirmed = ((Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM finance_expenses expense
                        WHERE expense.id=:expenseId
                          AND expense.status=1
                          AND expense.gl_status=2
                          AND COALESCE(expense.is_deleted,false)=false
                          AND to_char(expense.bill_date,'YYYY-MM')=:period
                        """)
                .setParameter("expenseId", expenseId)
                .setParameter("period", period)
                .getSingleResult()).longValue();
        if (confirmed > 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "一般费用已财务确认，禁止物理删除总账凭证");
        }
    }

    private void lockAutoProjectionPeriod(String period) {
        em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(:key, 0))")
                .setParameter("key", "uten:gl:auto-period:" + period)
                .getSingleResult();
    }

    /** A financially confirmed expense voucher is immutable until an explicit reversal policy exists. */
    private void assertNoConfirmedExpenseVouchers(String period) {
        long confirmed = ((Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM finance_expenses expense
                        WHERE expense.status=1
                          AND expense.gl_status=2
                          AND COALESCE(expense.is_deleted,false)=false
                          AND to_char(expense.bill_date,'YYYY-MM')=:p
                        """)
                .setParameter("p", period)
                .getSingleResult()).longValue();
        if (confirmed > 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "本期间存在 " + confirmed
                            + " 张已财务确认的一般费用凭证，禁止物理删除或重生成");
        }
    }

    /** 重放全部历史期间（ar_ap_ledger 出现过的所有月份）。返回期间数。 */
    @Transactional
    @PreAuthorize("hasAuthority('finance_post:execute')")
    public int generateAll() {
        tx.bind();
        @SuppressWarnings("unchecked")
        List<String> periods = em.createNativeQuery("""
                SELECT DISTINCT to_char(d, 'YYYY-MM') FROM (
                    SELECT bill_date AS d FROM ar_ap_ledger WHERE is_deleted=false
                    UNION SELECT bill_date FROM finance_receipts WHERE COALESCE(is_deleted,false)=false
                    UNION SELECT bill_date FROM finance_payments WHERE COALESCE(is_deleted,false)=false
                    UNION SELECT bill_date FROM finance_expenses WHERE COALESCE(is_deleted,false)=false
                    UNION SELECT bill_date FROM finance_other_incomes WHERE COALESCE(is_deleted,false)=false
                    UNION SELECT bill_date FROM finance_bank_transfers WHERE COALESCE(is_deleted,false)=false
                    UNION SELECT effective_date FROM customer_open_item_offset_batches WHERE status='APPLIED'
                ) t ORDER BY 1
                """).getResultList();
        for (String p : periods) generatePeriod(p);
        return periods.size();
    }

    // ======================== 各源单过账 ========================

    /** Resolve every system posting relation by its persisted UUID before deleting a projection. */
    private void assertRequiredSystemPostingRoles(String period) {
        long missing = ((Number) em.createNativeQuery("""
                        WITH required_role(role_key) AS (
                            SELECT 'AR_CONTROL' WHERE EXISTS (
                                SELECT 1 FROM ar_ap_ledger ledger
                                WHERE ledger.source_doc_type IN ('SALES_SHIPMENT','SALES_RETURN')
                                  AND ledger.status=1 AND COALESCE(ledger.is_deleted,false)=false
                                  AND to_char(ledger.bill_date,'YYYY-MM')=:p
                                UNION ALL
                                SELECT 1 FROM finance_receipts receipt
                                WHERE receipt.receipt_kind='AR_SETTLEMENT'
                                  AND receipt.status=1 AND COALESCE(receipt.is_deleted,false)=false
                                  AND to_char(receipt.bill_date,'YYYY-MM')=:p
                                UNION ALL
                                SELECT 1 FROM customer_open_item_offset_batches batch
                                WHERE batch.status='APPLIED'
                                  AND to_char(batch.effective_date,'YYYY-MM')=:p)
                            UNION SELECT 'SALES_REVENUE' WHERE EXISTS (
                                SELECT 1 FROM ar_ap_ledger ledger
                                WHERE ledger.source_doc_type IN ('SALES_SHIPMENT','SALES_RETURN')
                                  AND ledger.status=1 AND COALESCE(ledger.is_deleted,false)=false
                                  AND to_char(ledger.bill_date,'YYYY-MM')=:p)
                            UNION SELECT 'INVENTORY_ASSET' WHERE EXISTS (
                                SELECT 1 FROM ar_ap_ledger ledger
                                WHERE ledger.source_doc_type IN (
                                    'PURCHASE_RECEIPT','PURCHASE_RETURN','SUBCONTRACT_RECEIPT',
                                    'SUBCONTRACT_RETURN','SUBCONTRACT_WASTE')
                                  AND ledger.status=1 AND COALESCE(ledger.is_deleted,false)=false
                                  AND to_char(ledger.bill_date,'YYYY-MM')=:p
                                UNION ALL
                                SELECT 1 FROM sales_shipments shipment
                                WHERE shipment.status=1 AND COALESCE(shipment.is_deleted,false)=false
                                  AND to_char(shipment.bill_date,'YYYY-MM')=:p
                                  AND EXISTS (
                                      SELECT 1 FROM sales_shipment_items item
                                      JOIN goods goods ON goods.id=item.goods_id
                                      WHERE item.shipment_id=shipment.id
                                        AND COALESCE(item.is_deleted,false)=false
                                        AND COALESCE(item.qty,0)<>0
                                        AND COALESCE(goods.c_total,0)<>0))
                            UNION SELECT 'AP_CONTROL' WHERE EXISTS (
                                SELECT 1 FROM ar_ap_ledger ledger
                                WHERE ledger.source_doc_type IN (
                                    'PURCHASE_RECEIPT','PURCHASE_RETURN','SUBCONTRACT_RECEIPT',
                                    'SUBCONTRACT_RETURN','SUBCONTRACT_WASTE')
                                  AND ledger.status=1 AND COALESCE(ledger.is_deleted,false)=false
                                  AND to_char(ledger.bill_date,'YYYY-MM')=:p
                                UNION ALL
                                SELECT 1 FROM finance_payments payment
                                WHERE payment.status=1 AND payment.amount_authority_version=1
                                  AND COALESCE(payment.is_deleted,false)=false
                                  AND to_char(payment.bill_date,'YYYY-MM')=:p)
                            UNION SELECT 'SALES_COST' WHERE EXISTS (
                                SELECT 1 FROM sales_shipments shipment
                                WHERE shipment.status=1 AND COALESCE(shipment.is_deleted,false)=false
                                  AND to_char(shipment.bill_date,'YYYY-MM')=:p
                                  AND EXISTS (
                                      SELECT 1 FROM sales_shipment_items item
                                      JOIN goods goods ON goods.id=item.goods_id
                                      WHERE item.shipment_id=shipment.id
                                        AND COALESCE(item.is_deleted,false)=false
                                        AND COALESCE(item.qty,0)<>0
                                        AND COALESCE(goods.c_total,0)<>0))
                            UNION SELECT 'CUSTOMER_ADVANCE' WHERE EXISTS (
                                SELECT 1 FROM finance_receipts receipt
                                WHERE receipt.receipt_kind='CUSTOMER_PREPAYMENT'
                                  AND receipt.status=1 AND COALESCE(receipt.is_deleted,false)=false
                                  AND to_char(receipt.bill_date,'YYYY-MM')=:p
                                UNION ALL
                                SELECT 1 FROM customer_open_item_offset_batches batch
                                WHERE batch.status='APPLIED'
                                  AND to_char(batch.effective_date,'YYYY-MM')=:p)
                            UNION SELECT 'BANK_FEE_EXPENSE' WHERE EXISTS (
                                SELECT 1 FROM finance_receipts receipt
                                WHERE receipt.status=1 AND COALESCE(receipt.is_deleted,false)=false
                                  AND to_char(receipt.bill_date,'YYYY-MM')=:p
                                  AND COALESCE(receipt.bank_fee,0)<>0)
                            UNION SELECT 'FX_GAIN_LOSS' WHERE EXISTS (
                                SELECT 1 FROM finance_receipt_lines line
                                JOIN finance_receipts receipt ON receipt.id=line.receipt_id
                                WHERE receipt.status=1 AND COALESCE(receipt.is_deleted,false)=false
                                  AND COALESCE(line.is_deleted,false)=false
                                  AND to_char(receipt.bill_date,'YYYY-MM')=:p
                                GROUP BY receipt.id HAVING COALESCE(SUM(line.exchange_diff),0)<>0
                                UNION ALL
                                SELECT 1 FROM finance_payment_lines line
                                JOIN finance_payments payment ON payment.id=line.payment_id
                                WHERE payment.status=1 AND payment.amount_authority_version=1
                                  AND COALESCE(payment.is_deleted,false)=false
                                  AND COALESCE(line.is_deleted,false)=false
                                  AND to_char(payment.bill_date,'YYYY-MM')=:p
                                GROUP BY payment.id HAVING COALESCE(SUM(line.exchange_diff),0)<>0
                                UNION ALL
                                SELECT 1 FROM customer_open_item_offsets allocation
                                WHERE allocation.status='APPLIED'
                                  AND to_char(allocation.effective_date,'YYYY-MM')=:p
                                GROUP BY allocation.offset_batch_id
                                HAVING COALESCE(SUM(allocation.exchange_difference),0)<>0)
                        )
                        SELECT COUNT(*) FROM required_role required
                        WHERE system_posting_style_id(required.role_key) IS NULL
                        """)
                .setParameter("p", period)
                .getSingleResult()).longValue();
        if (missing > 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "本期间所需的系统过账角色有 " + missing
                            + " 个未配置有效科目 UUID，禁止删除并重生成总账凭证");
        }
    }

    /**
     * AR/AP ledger is the only regenerated source whose polymorphic business UUID is nullable in
     * the historical schema. Refuse to delete an existing period projection when ownership cannot
     * be proven; bill numbers are display snapshots and must never be used as an identity fallback.
     */
    private void assertSourceDocumentIdentities(String period) {
        long missing = ((Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM ar_ap_ledger ledger
                        WHERE ledger.source_doc_type IN (
                            'SALES_SHIPMENT', 'SALES_RETURN',
                            'PURCHASE_RECEIPT', 'PURCHASE_RETURN', 'SUBCONTRACT_RECEIPT',
                            'SUBCONTRACT_RETURN', 'SUBCONTRACT_WASTE'
                        )
                          AND ledger.status=1
                          AND COALESCE(ledger.is_deleted,false)=false
                          AND to_char(ledger.bill_date,'YYYY-MM')=:p
                          AND ledger.source_doc_id IS NULL
                        """)
                .setParameter("p", period)
                .getSingleResult()).longValue();
        if (missing > 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "本期间存在 " + missing
                            + " 条无法证明来源 UUID 的应收应付立账，禁止按单号猜测并重生成总账凭证");
        }
    }

    /**
     * 销售立帐：借 113 应收账款 / 贷 031 销售收入。
     *
     * <p><b>红字约定（FIN-P2-3，非 bug 不改值）</b>：SALES_RETURN（销售退货）立帐时
     * {@code ar_ap_ledger.amount_original_local} 为负，本方法将其原样写入 {@code gl_entries.amount}，
     * 与 列注释「正数；负值业务用红字（同向负金额）不反向」一致——即<b>不取绝对值、不反向 direction</b>。
     * 报表侧（{@link GlReportService}）以 {@code SUM(direction*amount)} 聚合，负 amount 同向累加
     * 即正确抵减借/贷，构成显式的红字表达。如改为绝对值会破坏所有 SUM(direction*amount) 报表
     * 与 opening_net/debit/credit 拆分（见 GlReportService L65-67）。
     */
    private void postAr(String period) {
        String vouchers = """
                INSERT INTO gl_vouchers
                    (voucher_no, period, voucher_date, source, source_type, source_doc_id, remark)
                SELECT l.bill_no, to_char(l.bill_date,'YYYY-MM'), l.bill_date, 'AUTO', 'AR_POST', l.source_doc_id,
                       '销售立帐 ' || l.source_doc_type
                FROM ar_ap_ledger l
                WHERE l.source_doc_type IN ('SALES_SHIPMENT','SALES_RETURN') AND l.status=1 AND l.is_deleted=false
                  AND to_char(l.bill_date,'YYYY-MM') = :p
                """;
        String entries = """
                INSERT INTO gl_entries (voucher_id, line_no, style_id, direction, amount, entry_date, period,
                                        source_doc_type, source_doc_id, source_bill_no, summary)
                SELECT v.id, 1, s113.id, 1, l.amount_original_local, l.bill_date, v.period,
                       l.source_doc_type, l.source_doc_id, l.bill_no, COALESCE(l.remark,'销售立帐')
                FROM ar_ap_ledger l
                JOIN gl_vouchers v
                  ON v.source_doc_id = l.source_doc_id
                 AND v.source_type = 'AR_POST'
                 AND v.source = 'AUTO'
                 AND v.status = 1
                 AND COALESCE(v.is_deleted,false)=false
                CROSS JOIN (
                  SELECT system_posting_style_id('AR_CONTROL') AS id
                ) s113
                WHERE l.source_doc_type IN ('SALES_SHIPMENT','SALES_RETURN') AND l.status=1 AND l.is_deleted=false
                  AND to_char(l.bill_date,'YYYY-MM') = :p
                UNION ALL
                SELECT v.id, 2, s031.id, -1, l.amount_original_local, l.bill_date, v.period,
                       l.source_doc_type, l.source_doc_id, l.bill_no, COALESCE(l.remark,'销售立帐')
                FROM ar_ap_ledger l
                JOIN gl_vouchers v
                  ON v.source_doc_id = l.source_doc_id
                 AND v.source_type = 'AR_POST'
                 AND v.source = 'AUTO'
                 AND v.status = 1
                 AND COALESCE(v.is_deleted,false)=false
                CROSS JOIN (
                  SELECT system_posting_style_id('SALES_REVENUE') AS id
                ) s031
                WHERE l.source_doc_type IN ('SALES_SHIPMENT','SALES_RETURN') AND l.status=1 AND l.is_deleted=false
                  AND to_char(l.bill_date,'YYYY-MM') = :p
                """;
        run(vouchers, period);
        run(entries, period);
    }

    /** 正式销售 AR 存在时，应收与销售收入科目必须在任何重建写入前可用。 */
    private void assertArPostingConfiguration(String period) {
        long invalid = ((Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM ar_ap_ledger ledger
                        WHERE ledger.source_doc_type IN ('SALES_SHIPMENT','SALES_RETURN')
                          AND ledger.status=1
                          AND COALESCE(ledger.is_deleted,false)=false
                          AND to_char(ledger.bill_date,'YYYY-MM')=:p
                          AND (system_posting_style_id('AR_CONTROL') IS NULL
                            OR system_posting_style_id('SALES_REVENUE') IS NULL)
                        """)
                .setParameter("p", period)
                .getSingleResult()).longValue();
        if (invalid > 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "销售立账总账科目缺失或已停用，请先启用应收账款与销售收入科目");
        }
    }

    /**
     * 采购/委外立帐：借 123 库存商品 / 贷 203 应付账款。
     * PURCHASE_RETURN、SUBCONTRACT_RETURN 使用负金额同向红字，分别抵减库存价值和应付余额。
     * SUBCONTRACT_WASTE 仅保留历史负应付兼容；新超耗使用独立异常损失和索赔投影。
     */
    private void postAp(String period) {
        String vouchers = """
                INSERT INTO gl_vouchers
                    (voucher_no, period, voucher_date, source, source_type, source_doc_id, remark)
                SELECT l.bill_no, to_char(l.bill_date,'YYYY-MM'), l.bill_date, 'AUTO', 'AP_POST', l.source_doc_id,
                       '采购/委外立帐 ' || l.source_doc_type
                FROM ar_ap_ledger l
                WHERE l.source_doc_type IN (
                    'PURCHASE_RECEIPT','PURCHASE_RETURN','SUBCONTRACT_RECEIPT',
                    'SUBCONTRACT_RETURN','SUBCONTRACT_WASTE')
                  AND l.status=1 AND l.is_deleted=false AND to_char(l.bill_date,'YYYY-MM') = :p
                """;
        String entries = """
                INSERT INTO gl_entries (voucher_id, line_no, style_id, direction, amount, entry_date, period,
                                        source_doc_type, source_doc_id, source_bill_no, summary)
                SELECT v.id, 1, s123.id, 1, l.amount_original_local, l.bill_date, v.period,
                       l.source_doc_type, l.source_doc_id, l.bill_no, COALESCE(l.remark,'采购/委外立帐')
                FROM ar_ap_ledger l
                JOIN gl_vouchers v
                  ON v.source_doc_id = l.source_doc_id
                 AND v.source_type = 'AP_POST'
                 AND v.source = 'AUTO'
                 AND v.status = 1
                 AND COALESCE(v.is_deleted,false)=false
                CROSS JOIN (
                  SELECT system_posting_style_id('INVENTORY_ASSET') AS id
                ) s123
                WHERE l.source_doc_type IN (
                    'PURCHASE_RECEIPT','PURCHASE_RETURN','SUBCONTRACT_RECEIPT',
                    'SUBCONTRACT_RETURN','SUBCONTRACT_WASTE')
                  AND l.status=1 AND l.is_deleted=false AND to_char(l.bill_date,'YYYY-MM') = :p
                UNION ALL
                SELECT v.id, 2, s203.id, -1, l.amount_original_local, l.bill_date, v.period,
                       l.source_doc_type, l.source_doc_id, l.bill_no, COALESCE(l.remark,'采购/委外立帐')
                FROM ar_ap_ledger l
                JOIN gl_vouchers v
                  ON v.source_doc_id = l.source_doc_id
                 AND v.source_type = 'AP_POST'
                 AND v.source = 'AUTO'
                 AND v.status = 1
                 AND COALESCE(v.is_deleted,false)=false
                CROSS JOIN (
                  SELECT system_posting_style_id('AP_CONTROL') AS id
                ) s203
                WHERE l.source_doc_type IN (
                    'PURCHASE_RECEIPT','PURCHASE_RETURN','SUBCONTRACT_RECEIPT',
                    'SUBCONTRACT_RETURN','SUBCONTRACT_WASTE')
                  AND l.status=1 AND l.is_deleted=false AND to_char(l.bill_date,'YYYY-MM') = :p
                """;
        run(vouchers, period);
        run(entries, period);
    }

    /** Fail before deleting any existing claim projection when a source or stable relation is invalid. */
    private void assertSupplierClaimPostingConfiguration(String period) {
        long invalid = ((Number) em.createNativeQuery("""
                SELECT
                    (SELECT COUNT(*)
                     FROM ar_ap_ledger ledger
                     WHERE ledger.source_doc_type='SUBCONTRACT_LOSS_OFFSET'
                       AND ledger.status=1 AND COALESCE(ledger.is_deleted,false)=false
                       AND to_char(ledger.bill_date,'YYYY-MM')=:p
                       AND (ledger.source_doc_id IS NULL OR ledger.amount_original_local>=0
                            OR system_posting_style_id('SUPPLIER_CLAIM_RECEIVABLE') IS NULL
                            OR system_posting_style_id('SUBCONTRACT_LOSS_RECOVERY') IS NULL))
                  + (SELECT COUNT(*)
                     FROM supplier_open_item_offsets allocation
                     LEFT JOIN ar_ap_ledger source ON source.id=allocation.source_ledger_id
                     LEFT JOIN ar_ap_ledger target ON target.id=allocation.target_ledger_id
                     WHERE allocation.resolution_id IS NOT NULL
                       AND allocation.status='APPLIED'
                       AND to_char(allocation.effective_date,'YYYY-MM')=:p
                       AND (allocation.offset_batch_id IS NULL
                            OR source.id IS NULL OR target.id IS NULL
                            OR source.direction<>'AP'
                            OR source.source_doc_type<>'SUBCONTRACT_LOSS_OFFSET'
                            OR source.source_doc_id IS DISTINCT FROM allocation.resolution_id
                            OR source.amount_original_local>=0
                            OR target.direction<>'AP'
                            OR allocation.source_rate<>allocation.target_rate
                            OR allocation.source_amount_local<>allocation.target_amount_local
                            OR system_posting_style_id('AP_CONTROL') IS NULL
                            OR system_posting_style_id('SUPPLIER_CLAIM_RECEIVABLE') IS NULL))
                  + (SELECT COUNT(*)
                     FROM supplier_claim_receivables claim
                     WHERE claim.status IN ('OPEN','PARTIAL','SETTLED')
                       AND COALESCE(claim.is_deleted,false)=false
                       AND to_char(claim.claim_date,'YYYY-MM')=:p
                       AND (claim.amount_local<=0
                            OR system_posting_style_id('SUPPLIER_CLAIM_RECEIVABLE') IS NULL
                            OR system_posting_style_id('SUBCONTRACT_LOSS_RECOVERY') IS NULL))
                  + (SELECT COUNT(*)
                     FROM supplier_claim_cash_receipts receipt
                     JOIN supplier_claim_receivables claim ON claim.id=receipt.claim_receivable_id
                     WHERE receipt.status='APPROVED'
                       AND to_char(receipt.receipt_date,'YYYY-MM')=:p
                       AND (receipt.amount_local<=0 OR receipt.book_applied_local<=0
                            OR receipt.resolution_id<>claim.resolution_id
                            OR receipt.case_id<>claim.case_id
                            OR receipt.supplier_id<>claim.supplier_id
                            OR receipt.currency_id<>claim.currency_id
                            OR NOT EXISTS (
                                SELECT 1 FROM payment_styles style
                                WHERE style.id=account_style_id(receipt.account_id)
                                  AND style.status='使用'
                                  AND COALESCE(style.is_deleted,false)=false)
                            OR system_posting_style_id('SUPPLIER_CLAIM_RECEIVABLE') IS NULL
                            OR (receipt.exchange_difference<>0
                                AND system_posting_style_id('FX_GAIN_LOSS') IS NULL)))
                """).setParameter("p", period).getSingleResult()).longValue();
        if (invalid > 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "供应商索赔总账来源、金额、账户或稳定科目关系不完整，禁止重生成并删除既有凭证");
        }
    }

    /** Existing AUTO claim vouchers must still be traceable to their durable business source. */
    private void assertSupplierClaimProjectionOwnership(String period) {
        long orphaned = ((Number) em.createNativeQuery("""
                SELECT COUNT(*)
                FROM gl_vouchers voucher
                WHERE voucher.source='AUTO' AND voucher.period=:p
                  AND voucher.source_type IN (
                      'SUPPLIER_CLAIM_LEDGER','SUPPLIER_CLAIM_OFFSET',
                      'SUPPLIER_CLAIM_RECEIVABLE','SUPPLIER_CLAIM_CASH')
                  AND (
                      (voucher.source_type='SUPPLIER_CLAIM_LEDGER' AND NOT EXISTS (
                          SELECT 1 FROM ar_ap_ledger ledger
                          WHERE ledger.source_doc_type='SUBCONTRACT_LOSS_OFFSET'
                            AND ledger.source_doc_id=voucher.source_doc_id))
                      OR (voucher.source_type='SUPPLIER_CLAIM_OFFSET' AND NOT EXISTS (
                          SELECT 1 FROM supplier_open_item_offsets allocation
                          WHERE allocation.offset_batch_id=voucher.source_doc_id
                            AND allocation.resolution_id IS NOT NULL))
                      OR (voucher.source_type='SUPPLIER_CLAIM_RECEIVABLE' AND NOT EXISTS (
                          SELECT 1 FROM supplier_claim_receivables claim
                          WHERE claim.id=voucher.source_doc_id))
                      OR (voucher.source_type='SUPPLIER_CLAIM_CASH' AND NOT EXISTS (
                          SELECT 1 FROM supplier_claim_cash_receipts receipt
                          WHERE receipt.id=voucher.source_doc_id))
                  )
                """).setParameter("p", period).getSingleResult()).longValue();
        if (orphaned > 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "存在无法证明业务来源的供应商索赔 AUTO 凭证，禁止重生成删除");
        }
    }

    /** Accepted AP-offset claim: Dr supplier claim receivable / Cr loss recovery. */
    private void postSupplierClaimLedger(String period) {
        String vouchers = """
                INSERT INTO gl_vouchers
                    (voucher_no, period, voucher_date, source,
                     source_type, source_doc_id, remark)
                SELECT ledger.bill_no,to_char(ledger.bill_date,'YYYY-MM'),ledger.bill_date,
                       'AUTO','SUPPLIER_CLAIM_LEDGER',ledger.source_doc_id,'委外异常损失索赔确认'
                FROM ar_ap_ledger ledger
                WHERE ledger.source_doc_type='SUBCONTRACT_LOSS_OFFSET'
                  AND ledger.amount_original_local<0
                  AND ledger.status=1 AND COALESCE(ledger.is_deleted,false)=false
                  AND to_char(ledger.bill_date,'YYYY-MM')=:p
                """;
        String entries = """
                INSERT INTO gl_entries
                    (voucher_id,line_no,style_id,direction,amount,entry_date,period,
                     source_doc_type,source_doc_id,source_bill_no,summary)
                SELECT voucher.id,1,claim_style.id,1,ABS(ledger.amount_original_local),
                       ledger.bill_date,voucher.period,'SUBCONTRACT_LOSS_OFFSET',
                       ledger.source_doc_id,ledger.bill_no,'确认供应商索赔应收'
                FROM ar_ap_ledger ledger
                JOIN gl_vouchers voucher ON voucher.source='AUTO'
                 AND voucher.source_type='SUPPLIER_CLAIM_LEDGER'
                 AND voucher.source_doc_id=ledger.source_doc_id
                 AND voucher.period=to_char(ledger.bill_date,'YYYY-MM')
                CROSS JOIN LATERAL (
                    SELECT system_posting_style_id('SUPPLIER_CLAIM_RECEIVABLE') AS id) claim_style
                WHERE ledger.source_doc_type='SUBCONTRACT_LOSS_OFFSET'
                  AND ledger.amount_original_local<0
                  AND ledger.status=1 AND COALESCE(ledger.is_deleted,false)=false
                  AND to_char(ledger.bill_date,'YYYY-MM')=:p
                UNION ALL
                SELECT voucher.id,2,recovery_style.id,-1,ABS(ledger.amount_original_local),
                       ledger.bill_date,voucher.period,'SUBCONTRACT_LOSS_OFFSET',
                       ledger.source_doc_id,ledger.bill_no,'确认委外异常损失追回'
                FROM ar_ap_ledger ledger
                JOIN gl_vouchers voucher ON voucher.source='AUTO'
                 AND voucher.source_type='SUPPLIER_CLAIM_LEDGER'
                 AND voucher.source_doc_id=ledger.source_doc_id
                 AND voucher.period=to_char(ledger.bill_date,'YYYY-MM')
                CROSS JOIN LATERAL (
                    SELECT system_posting_style_id('SUBCONTRACT_LOSS_RECOVERY') AS id) recovery_style
                WHERE ledger.source_doc_type='SUBCONTRACT_LOSS_OFFSET'
                  AND ledger.amount_original_local<0
                  AND ledger.status=1 AND COALESCE(ledger.is_deleted,false)=false
                  AND to_char(ledger.bill_date,'YYYY-MM')=:p
                """;
        run(vouchers,period);
        run(entries,period);
    }

    /** Claim allocation to AP: Dr AP control / Cr supplier claim receivable. */
    private void postSupplierClaimOffsets(String period) {
        String vouchers = """
                INSERT INTO gl_vouchers
                    (voucher_no, period, voucher_date, source,
                     source_type, source_doc_id, remark)
                SELECT 'SCO-'||replace(allocation.offset_batch_id::text,'-',''),
                       to_char(MIN(allocation.effective_date),'YYYY-MM'),MIN(allocation.effective_date),
                       'AUTO','SUPPLIER_CLAIM_OFFSET',allocation.offset_batch_id,'供应商索赔抵销应付'
                FROM supplier_open_item_offsets allocation
                WHERE allocation.resolution_id IS NOT NULL AND allocation.status='APPLIED'
                  AND to_char(allocation.effective_date,'YYYY-MM')=:p
                GROUP BY allocation.offset_batch_id
                """;
        String entries = """
                WITH batch AS (
                    SELECT allocation.offset_batch_id,MIN(allocation.effective_date) AS effective_date,
                           SUM(allocation.target_amount_local) AS target_local,
                           SUM(allocation.source_amount_local) AS source_local
                    FROM supplier_open_item_offsets allocation
                    WHERE allocation.resolution_id IS NOT NULL AND allocation.status='APPLIED'
                      AND to_char(allocation.effective_date,'YYYY-MM')=:p
                    GROUP BY allocation.offset_batch_id)
                INSERT INTO gl_entries
                    (voucher_id,line_no,style_id,direction,amount,entry_date,period,
                     source_doc_type,source_doc_id,source_bill_no,summary)
                SELECT voucher.id,1,ap_style.id,1,batch.target_local,batch.effective_date,
                       voucher.period,'SUPPLIER_CLAIM_OFFSET',batch.offset_batch_id,
                       voucher.voucher_no,'索赔抵销应付账款'
                FROM batch
                JOIN gl_vouchers voucher ON voucher.source='AUTO'
                 AND voucher.source_type='SUPPLIER_CLAIM_OFFSET'
                 AND voucher.source_doc_id=batch.offset_batch_id
                CROSS JOIN LATERAL (
                    SELECT system_posting_style_id('AP_CONTROL') AS id) ap_style
                UNION ALL
                SELECT voucher.id,2,claim_style.id,-1,batch.source_local,batch.effective_date,
                       voucher.period,'SUPPLIER_CLAIM_OFFSET',batch.offset_batch_id,
                       voucher.voucher_no,'结转供应商索赔应收'
                FROM batch
                JOIN gl_vouchers voucher ON voucher.source='AUTO'
                 AND voucher.source_type='SUPPLIER_CLAIM_OFFSET'
                 AND voucher.source_doc_id=batch.offset_batch_id
                CROSS JOIN LATERAL (
                    SELECT system_posting_style_id('SUPPLIER_CLAIM_RECEIVABLE') AS id) claim_style
                """;
        run(vouchers,period);
        run(entries,period);
    }

    /** Cash-compensation claim recognition: Dr claim receivable / Cr recovery. */
    private void postSupplierClaimReceivables(String period) {
        String vouchers = """
                INSERT INTO gl_vouchers
                    (voucher_no, period, voucher_date, source,
                     source_type, source_doc_id, remark)
                SELECT claim.bill_no,to_char(claim.claim_date,'YYYY-MM'),claim.claim_date,
                       'AUTO','SUPPLIER_CLAIM_RECEIVABLE',claim.id,'供应商现金赔偿应收确认'
                FROM supplier_claim_receivables claim
                WHERE claim.status IN ('OPEN','PARTIAL','SETTLED')
                  AND COALESCE(claim.is_deleted,false)=false
                  AND to_char(claim.claim_date,'YYYY-MM')=:p
                """;
        String entries = """
                INSERT INTO gl_entries
                    (voucher_id,line_no,style_id,direction,amount,entry_date,period,
                     source_doc_type,source_doc_id,source_bill_no,summary)
                SELECT voucher.id,1,claim_style.id,1,claim.amount_local,claim.claim_date,
                       voucher.period,'SUPPLIER_CLAIM_RECEIVABLE',claim.id,claim.bill_no,
                       '确认供应商赔偿应收'
                FROM supplier_claim_receivables claim
                JOIN gl_vouchers voucher ON voucher.source='AUTO'
                 AND voucher.source_type='SUPPLIER_CLAIM_RECEIVABLE'
                 AND voucher.source_doc_id=claim.id
                CROSS JOIN LATERAL (
                    SELECT system_posting_style_id('SUPPLIER_CLAIM_RECEIVABLE') AS id) claim_style
                WHERE claim.status IN ('OPEN','PARTIAL','SETTLED')
                  AND COALESCE(claim.is_deleted,false)=false
                  AND to_char(claim.claim_date,'YYYY-MM')=:p
                UNION ALL
                SELECT voucher.id,2,recovery_style.id,-1,claim.amount_local,claim.claim_date,
                       voucher.period,'SUPPLIER_CLAIM_RECEIVABLE',claim.id,claim.bill_no,
                       '确认委外异常损失追回'
                FROM supplier_claim_receivables claim
                JOIN gl_vouchers voucher ON voucher.source='AUTO'
                 AND voucher.source_type='SUPPLIER_CLAIM_RECEIVABLE'
                 AND voucher.source_doc_id=claim.id
                CROSS JOIN LATERAL (
                    SELECT system_posting_style_id('SUBCONTRACT_LOSS_RECOVERY') AS id) recovery_style
                WHERE claim.status IN ('OPEN','PARTIAL','SETTLED')
                  AND COALESCE(claim.is_deleted,false)=false
                  AND to_char(claim.claim_date,'YYYY-MM')=:p
                """;
        run(vouchers,period);
        run(entries,period);
    }

    /** Bank-backed claim collection, including an explicit FX balancing line when needed. */
    private void postSupplierClaimCashReceipts(String period) {
        String vouchers = """
                INSERT INTO gl_vouchers
                    (voucher_no, period, voucher_date, source,
                     source_type, source_doc_id, remark)
                SELECT receipt.bill_no,to_char(receipt.receipt_date,'YYYY-MM'),receipt.receipt_date,
                       'AUTO','SUPPLIER_CLAIM_CASH',receipt.id,'供应商现金赔偿到账'
                FROM supplier_claim_cash_receipts receipt
                WHERE receipt.status='APPROVED'
                  AND to_char(receipt.receipt_date,'YYYY-MM')=:p
                """;
        String entries = """
                INSERT INTO gl_entries
                    (voucher_id,line_no,style_id,direction,amount,entry_date,period,
                     source_doc_type,source_doc_id,source_bill_no,summary)
                SELECT voucher.id,1,account_style.id,1,receipt.amount_local,receipt.receipt_date,
                       voucher.period,'SUPPLIER_CLAIM_CASH',receipt.id,receipt.bill_no,
                       '供应商赔偿现金到账'
                FROM supplier_claim_cash_receipts receipt
                JOIN gl_vouchers voucher ON voucher.source='AUTO'
                 AND voucher.source_type='SUPPLIER_CLAIM_CASH'
                 AND voucher.source_doc_id=receipt.id
                JOIN LATERAL (
                    SELECT style.id
                    FROM payment_styles style
                    WHERE style.id=account_style_id(receipt.account_id)
                      AND style.status='使用' AND COALESCE(style.is_deleted,false)=false
                    LIMIT 1) account_style ON TRUE
                WHERE receipt.status='APPROVED'
                  AND to_char(receipt.receipt_date,'YYYY-MM')=:p
                UNION ALL
                SELECT voucher.id,2,claim_style.id,-1,receipt.book_applied_local,receipt.receipt_date,
                       voucher.period,'SUPPLIER_CLAIM_CASH',receipt.id,receipt.bill_no,
                       '冲减供应商索赔应收'
                FROM supplier_claim_cash_receipts receipt
                JOIN gl_vouchers voucher ON voucher.source='AUTO'
                 AND voucher.source_type='SUPPLIER_CLAIM_CASH'
                 AND voucher.source_doc_id=receipt.id
                CROSS JOIN LATERAL (
                    SELECT system_posting_style_id('SUPPLIER_CLAIM_RECEIVABLE') AS id) claim_style
                WHERE receipt.status='APPROVED'
                  AND to_char(receipt.receipt_date,'YYYY-MM')=:p
                UNION ALL
                SELECT voucher.id,3,fx_style.id,
                       CASE WHEN receipt.exchange_difference>0 THEN -1 ELSE 1 END,
                       ABS(receipt.exchange_difference),receipt.receipt_date,voucher.period,
                       'SUPPLIER_CLAIM_CASH',receipt.id,receipt.bill_no,'供应商赔偿汇兑损益'
                FROM supplier_claim_cash_receipts receipt
                JOIN gl_vouchers voucher ON voucher.source='AUTO'
                 AND voucher.source_type='SUPPLIER_CLAIM_CASH'
                 AND voucher.source_doc_id=receipt.id
                CROSS JOIN LATERAL (
                    SELECT system_posting_style_id('FX_GAIN_LOSS') AS id) fx_style
                WHERE receipt.status='APPROVED' AND receipt.exchange_difference<>0
                  AND to_char(receipt.receipt_date,'YYYY-MM')=:p
                """;
        run(vouchers,period);
        run(entries,period);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void removeSubcontractWasteLossDoc(
            UUID wasteId, String billNo, LocalDate billDate) {
        removeAutoProjection(SubcontractWasteLossGlProjection.SOURCE_TYPE,
                wasteId, billNo + "-LOSS", billDate);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void removeSupplierClaimOffsetBatch(UUID batchId, LocalDate effectiveDate) {
        removeAutoProjection(
                "SUPPLIER_CLAIM_OFFSET",batchId,claimOffsetVoucherNo(batchId),effectiveDate);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void removeSupplierClaimReceivableDoc(UUID id,String billNo,LocalDate claimDate) {
        removeAutoProjection("SUPPLIER_CLAIM_RECEIVABLE",id,billNo,claimDate);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void removeSupplierClaimCashReceiptDoc(UUID id,String billNo,LocalDate receiptDate) {
        removeAutoProjection("SUPPLIER_CLAIM_CASH",id,billNo,receiptDate);
    }

    private static String claimOffsetVoucherNo(UUID batchId) {
        if (batchId==null) throw new ApiException(ErrorCode.CONFLICT,"索赔抵销批次 UUID 缺失");
        return "SCO-"+batchId.toString().replace("-","");
    }

    /** 收款：借 收款账户科目 / 贷 113 应收账款。 */
    private void postReceipts(String period) {
        String vouchers = """
                INSERT INTO gl_vouchers
                    (voucher_no, period, voucher_date, source, source_type, source_doc_id, remark)
                SELECT t.bill_no, to_char(t.bill_date,'YYYY-MM'), t.bill_date,
                       'AUTO', 'RECEIPT', t.id, '销售收款'
                FROM finance_receipts t
                WHERE t.status=1 AND COALESCE(t.is_deleted,false)=false AND to_char(t.bill_date,'YYYY-MM') = :p
                """;
        String entries = """
                INSERT INTO gl_entries (voucher_id, line_no, style_id, direction, amount, entry_date, period,
                                        source_doc_type, source_doc_id, source_bill_no, summary)
                SELECT v.id, 1, acct.style_id, 1, t.amount_local, t.bill_date, v.period,
                       'RECEIPT', t.id, t.bill_no, COALESCE(t.remark,'销售收款')
                FROM finance_receipts t
                JOIN gl_vouchers v
                  ON v.source_doc_id = t.id AND v.source_type = 'RECEIPT'
                 AND v.source = 'AUTO' AND v.status = 1 AND COALESCE(v.is_deleted,false)=false
                JOIN LATERAL (
                  SELECT style.id AS style_id
                  FROM payment_styles style
                  WHERE style.id=account_style_id(t.account_id)
                    AND style.status='使用'
                    AND COALESCE(style.is_deleted,false)=false
                  LIMIT 1
                ) acct ON TRUE
                WHERE t.status=1 AND COALESCE(t.is_deleted,false)=false AND to_char(t.bill_date,'YYYY-MM') = :p
                UNION ALL
                SELECT v.id, 2, counter_style.id, -1,
                       CASE WHEN EXISTS (SELECT 1 FROM finance_receipt_lines i
                                         WHERE i.receipt_id=t.id AND COALESCE(i.is_deleted,false)=false)
                            THEN (SELECT COALESCE(SUM(i.applied_amount_local),0)
                                  FROM finance_receipt_lines i
                                  WHERE i.receipt_id=t.id AND COALESCE(i.is_deleted,false)=false)
                            ELSE t.amount_local END,
                       t.bill_date, v.period,
                       'RECEIPT', t.id, t.bill_no, COALESCE(t.remark,'销售收款')
                FROM finance_receipts t
                JOIN gl_vouchers v
                  ON v.source_doc_id = t.id AND v.source_type = 'RECEIPT'
                 AND v.source = 'AUTO' AND v.status = 1 AND COALESCE(v.is_deleted,false)=false
                CROSS JOIN LATERAL (
                  SELECT CASE WHEN t.receipt_kind='CUSTOMER_PREPAYMENT'
                              THEN system_posting_style_id('CUSTOMER_ADVANCE')
                              ELSE system_posting_style_id('AR_CONTROL') END AS id
                ) counter_style
                WHERE t.status=1 AND COALESCE(t.is_deleted,false)=false AND to_char(t.bill_date,'YYYY-MM') = :p
                UNION ALL
                SELECT v.id, 3, fee.id, 1, t.bank_fee, t.bill_date, v.period,
                       'RECEIPT', t.id, t.bill_no, '收款手续费'
                FROM finance_receipts t
                JOIN gl_vouchers v
                  ON v.source_doc_id=t.id AND v.source_type='RECEIPT'
                 AND v.source='AUTO' AND v.status=1 AND COALESCE(v.is_deleted,false)=false
                CROSS JOIN LATERAL (
                  SELECT system_posting_style_id('BANK_FEE_EXPENSE') AS id
                ) fee
                WHERE t.status=1 AND COALESCE(t.is_deleted,false)=false
                  AND to_char(t.bill_date,'YYYY-MM')=:p AND COALESCE(t.bank_fee,0)<>0
                UNION ALL
                SELECT v.id, 4, t.other_fee_style_id, 1, t.other_fee, t.bill_date, v.period,
                       'RECEIPT', t.id, t.bill_no, '收款其它费用冲销'
                FROM finance_receipts t
                JOIN gl_vouchers v
                  ON v.source_doc_id=t.id AND v.source_type='RECEIPT'
                 AND v.source='AUTO' AND v.status=1 AND COALESCE(v.is_deleted,false)=false
                WHERE t.status=1 AND COALESCE(t.is_deleted,false)=false
                  AND to_char(t.bill_date,'YYYY-MM')=:p AND COALESCE(t.other_fee,0)<>0
                  AND t.other_fee_style_id IS NOT NULL
                UNION ALL
                SELECT v.id, 5, fx.id,
                       CASE WHEN x.diff>0 THEN -1 ELSE 1 END,
                       ABS(x.diff), t.bill_date, v.period,
                       'RECEIPT', t.id, t.bill_no, '收款汇兑损益'
                FROM finance_receipts t
                JOIN gl_vouchers v
                  ON v.source_doc_id=t.id AND v.source_type='RECEIPT'
                 AND v.source='AUTO' AND v.status=1 AND COALESCE(v.is_deleted,false)=false
                JOIN LATERAL (
                  SELECT COALESCE(SUM(i.exchange_diff),0) AS diff
                  FROM finance_receipt_lines i
                  WHERE i.receipt_id=t.id AND COALESCE(i.is_deleted,false)=false
                ) x ON TRUE
                CROSS JOIN LATERAL (
                  SELECT system_posting_style_id('FX_GAIN_LOSS') AS id
                ) fx
                WHERE t.status=1 AND COALESCE(t.is_deleted,false)=false
                  AND to_char(t.bill_date,'YYYY-MM')=:p AND x.diff<>0
                """;
        run(vouchers, period);
        run(entries, period);
    }

    /** Customer advance application: Dr advance liability / Cr AR, with FX balancing. */
    private void postCustomerPrepaymentOffsets(String period) {
        String vouchers = """
                INSERT INTO gl_vouchers(
                    voucher_no, period, voucher_date, source, source_type, source_doc_id, remark)
                SELECT 'CPA-'||replace(batch.id::text,'-',''),
                       to_char(batch.effective_date,'YYYY-MM'),batch.effective_date,
                       'AUTO','CUSTOMER_PREPAYMENT_OFFSET',batch.id,'客户预收转销'
                FROM customer_open_item_offset_batches batch
                WHERE batch.status='APPLIED'
                  AND to_char(batch.effective_date,'YYYY-MM')=:p
                """;
        String entries = """
                INSERT INTO gl_entries(
                    voucher_id,line_no,style_id,direction,amount,entry_date,period,
                    source_doc_type,source_doc_id,source_bill_no,summary)
                SELECT voucher.id,1,advance_style.id,1,SUM(allocation.source_amount_local),
                       batch.effective_date,voucher.period,'CUSTOMER_PREPAYMENT_OFFSET',
                       batch.id,voucher.voucher_no,'客户预收负债转销'
                FROM customer_open_item_offset_batches batch
                JOIN customer_open_item_offsets allocation
                  ON allocation.offset_batch_id=batch.id AND allocation.status='APPLIED'
                JOIN gl_vouchers voucher ON voucher.source='AUTO'
                  AND voucher.source_type='CUSTOMER_PREPAYMENT_OFFSET'
                  AND voucher.source_doc_id=batch.id AND voucher.status=1
                  AND COALESCE(voucher.is_deleted,FALSE)=FALSE
                CROSS JOIN LATERAL(
                    SELECT system_posting_style_id('CUSTOMER_ADVANCE') id) advance_style
                WHERE batch.status='APPLIED' AND to_char(batch.effective_date,'YYYY-MM')=:p
                GROUP BY voucher.id,advance_style.id,batch.id,batch.effective_date,voucher.period,voucher.voucher_no
                UNION ALL
                SELECT voucher.id,2,ar_style.id,-1,SUM(allocation.target_amount_local),
                       batch.effective_date,voucher.period,'CUSTOMER_PREPAYMENT_OFFSET',
                       batch.id,voucher.voucher_no,'冲减正式应收'
                FROM customer_open_item_offset_batches batch
                JOIN customer_open_item_offsets allocation
                  ON allocation.offset_batch_id=batch.id AND allocation.status='APPLIED'
                JOIN gl_vouchers voucher ON voucher.source='AUTO'
                  AND voucher.source_type='CUSTOMER_PREPAYMENT_OFFSET'
                  AND voucher.source_doc_id=batch.id AND voucher.status=1
                  AND COALESCE(voucher.is_deleted,FALSE)=FALSE
                CROSS JOIN LATERAL(SELECT system_posting_style_id('AR_CONTROL') id) ar_style
                WHERE batch.status='APPLIED' AND to_char(batch.effective_date,'YYYY-MM')=:p
                GROUP BY voucher.id,ar_style.id,batch.id,batch.effective_date,voucher.period,voucher.voucher_no
                UNION ALL
                SELECT voucher.id,3,fx_style.id,
                       CASE WHEN SUM(allocation.exchange_difference)>0 THEN -1 ELSE 1 END,
                       ABS(SUM(allocation.exchange_difference)),batch.effective_date,voucher.period,
                       'CUSTOMER_PREPAYMENT_OFFSET',batch.id,voucher.voucher_no,'客户预收转销汇兑损益'
                FROM customer_open_item_offset_batches batch
                JOIN customer_open_item_offsets allocation
                  ON allocation.offset_batch_id=batch.id AND allocation.status='APPLIED'
                JOIN gl_vouchers voucher ON voucher.source='AUTO'
                  AND voucher.source_type='CUSTOMER_PREPAYMENT_OFFSET'
                  AND voucher.source_doc_id=batch.id AND voucher.status=1
                  AND COALESCE(voucher.is_deleted,FALSE)=FALSE
                CROSS JOIN LATERAL(SELECT system_posting_style_id('FX_GAIN_LOSS') id) fx_style
                WHERE batch.status='APPLIED' AND to_char(batch.effective_date,'YYYY-MM')=:p
                GROUP BY voucher.id,fx_style.id,batch.id,batch.effective_date,voucher.period,voucher.voucher_no
                HAVING SUM(allocation.exchange_difference)<>0
                """;
        run(vouchers, period);
        run(entries, period);
    }

    private void assertCustomerPrepaymentPostingConfiguration(String period) {
        long invalid = ((Number) em.createNativeQuery("""
                SELECT
                  (SELECT COUNT(*) FROM finance_receipts receipt
                   WHERE receipt.receipt_kind='CUSTOMER_PREPAYMENT'
                     AND receipt.status=1 AND COALESCE(receipt.is_deleted,FALSE)=FALSE
                     AND to_char(receipt.bill_date,'YYYY-MM')=:p
                     AND (receipt.amount_local<=0
                          OR system_posting_style_id('CUSTOMER_ADVANCE') IS NULL))
                + (SELECT COUNT(*) FROM customer_open_item_offset_batches batch
                   WHERE batch.status='APPLIED' AND to_char(batch.effective_date,'YYYY-MM')=:p
                     AND (system_posting_style_id('CUSTOMER_ADVANCE') IS NULL
                          OR system_posting_style_id('AR_CONTROL') IS NULL
                          OR NOT EXISTS(SELECT 1 FROM customer_open_item_offsets allocation
                                        WHERE allocation.offset_batch_id=batch.id
                                          AND allocation.status='APPLIED')
                          OR (EXISTS(SELECT 1 FROM customer_open_item_offsets allocation
                                     WHERE allocation.offset_batch_id=batch.id
                                       AND allocation.status='APPLIED'
                                     GROUP BY allocation.offset_batch_id
                                     HAVING SUM(allocation.exchange_difference)<>0)
                              AND system_posting_style_id('FX_GAIN_LOSS') IS NULL)))
                """).setParameter("p",period).getSingleResult()).longValue();
        if(invalid>0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "客户预收总账来源、金额或客户预收/应收/汇兑稳定科目关系不完整，禁止重生成");
        }
    }

    private void assertCustomerPrepaymentProjectionOwnership(String period) {
        long orphaned=((Number)em.createNativeQuery("""
                SELECT COUNT(*) FROM gl_vouchers voucher
                WHERE voucher.source='AUTO' AND voucher.period=:p
                  AND voucher.source_type='CUSTOMER_PREPAYMENT_OFFSET'
                  AND NOT EXISTS(SELECT 1 FROM customer_open_item_offset_batches batch
                                 WHERE batch.id=voucher.source_doc_id)
                """).setParameter("p",period).getSingleResult()).longValue();
        if(orphaned>0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "存在无法证明转销批次 UUID 的客户预收 AUTO 凭证，禁止重生成删除");
        }
    }

    /** Historical client-era payment amounts must be verified before period regeneration. */
    private void assertPaymentAmountsAuthoritative(String period) {
        long unverified = ((Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM finance_payments payment
                        WHERE payment.status=1
                          AND COALESCE(payment.is_deleted,false)=false
                          AND to_char(payment.bill_date,'YYYY-MM')=:p
                          AND payment.amount_authority_version<>1
                        """)
                .setParameter("p", period)
                .getSingleResult()).longValue();
        if (unverified > 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "本期间存在 " + unverified
                            + " 张历史付款的金额尚未经过服务端核验，禁止重生成总账凭证");
        }
    }

    /**
     * Receipt entry joins intentionally produce no row when a configured
     * accounting style is missing or inactive. Detect that situation before
     * inserting a partial voucher, so a disabled account/AR/fee/FX style
     * cannot silently drop a required debit or credit line.
     */
    private void assertReceiptPostingConfiguration(String period) {
        long invalid = ((Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM finance_receipts receipt
                        WHERE receipt.status=1
                          AND COALESCE(receipt.is_deleted,false)=false
                          AND to_char(receipt.bill_date,'YYYY-MM')=:p
                          AND (
                              NOT EXISTS (
                                  SELECT 1 FROM payment_styles style
                                  WHERE style.id=account_style_id(receipt.account_id)
                                    AND style.status='使用'
                                    AND COALESCE(style.is_deleted,false)=false
                              )
                              OR (receipt.receipt_kind='AR_SETTLEMENT'
                                  AND system_posting_style_id('AR_CONTROL') IS NULL)
                              OR (receipt.receipt_kind='CUSTOMER_PREPAYMENT'
                                  AND system_posting_style_id('CUSTOMER_ADVANCE') IS NULL)
                              OR (COALESCE(receipt.bank_fee,0)<>0
                                  AND system_posting_style_id('BANK_FEE_EXPENSE') IS NULL)
                              OR
                              (COALESCE(receipt.other_fee,0)<>0 AND NOT EXISTS (
                                  SELECT 1 FROM payment_styles style
                                  WHERE style.id=receipt.other_fee_style_id
                                    AND style.category='EXPENSE' AND style.status='使用'
                                    AND COALESCE(style.is_deleted,false)=false
                              ))
                              OR
                              (COALESCE((
                                  SELECT SUM(line.exchange_diff)
                                  FROM finance_receipt_lines line
                                  WHERE line.receipt_id=receipt.id
                                    AND COALESCE(line.is_deleted,false)=false
                              ),0)<>0
                                  AND system_posting_style_id('FX_GAIN_LOSS') IS NULL)
                          )
                        """)
                .setParameter("p", period)
                .getSingleResult()).longValue();
        if (invalid > 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "销售收款总账科目缺失或已停用，请先启用收款账户、应收账款、手续费、其它费用或汇兑损益科目");
        }
    }

    /** 每个本服务重建的凭证必须至少有借贷两行且方向金额净额为零。 */
    private void assertPeriodBalanced(String period) {
        long invalid = ((Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM (
                            SELECT voucher.id
                            FROM gl_vouchers voucher
                            LEFT JOIN gl_entries entry ON entry.voucher_id=voucher.id
                            WHERE voucher.source='AUTO'
                              AND voucher.period=:p
                              AND voucher.source_type IN (:sourceTypes)
                            GROUP BY voucher.id
                            HAVING COUNT(entry.id)<2
                               OR ROUND(COALESCE(SUM(entry.direction*entry.amount),0),4)<>0
                        ) invalid_voucher
                        """)
                .setParameter("p", period)
                .setParameter("sourceTypes", REGENERATED_SOURCE_TYPES)
                .getSingleResult()).longValue();
        if (invalid > 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "总账重生成发现 " + invalid + " 张缺行或借贷不平凭证，已回滚本期间过账");
        }
    }

    /** 付款：借 203 应付账款 / 贷付款账户；汇率差额单列汇兑损益。 */
    private void postPayments(String period) {
        String vouchers = """
                INSERT INTO gl_vouchers
                    (voucher_no, period, voucher_date, source, source_type, source_doc_id, remark)
                SELECT t.bill_no, to_char(t.bill_date,'YYYY-MM'), t.bill_date,
                       'AUTO', 'PAYMENT', t.id, '采购付款'
                FROM finance_payments t
                WHERE t.status=1 AND t.amount_authority_version=1
                  AND COALESCE(t.is_deleted,false)=false AND to_char(t.bill_date,'YYYY-MM') = :p
                """;
        String entries = """
                INSERT INTO gl_entries (voucher_id, line_no, style_id, direction, amount, entry_date, period,
                                        source_doc_type, source_doc_id, source_bill_no, summary)
                SELECT v.id, 1, s203.id, 1,
                       CASE WHEN EXISTS (
                                  SELECT 1 FROM finance_payment_lines line
                                  WHERE line.payment_id=t.id
                                    AND COALESCE(line.is_deleted,false)=false)
                            THEN (SELECT COALESCE(SUM(
                                       line.amount_local-COALESCE(line.exchange_diff,0)),0)
                                  FROM finance_payment_lines line
                                  WHERE line.payment_id=t.id
                                    AND COALESCE(line.is_deleted,false)=false)
                            ELSE t.amount_local END,
                       t.bill_date, v.period,
                       'PAYMENT', t.id, t.bill_no, COALESCE(t.remark,'采购付款')
                FROM finance_payments t
                JOIN gl_vouchers v
                  ON v.source_doc_id = t.id AND v.source_type = 'PAYMENT'
                 AND v.source = 'AUTO' AND v.status = 1 AND COALESCE(v.is_deleted,false)=false
                CROSS JOIN (
                  SELECT system_posting_style_id('AP_CONTROL') AS id
                ) s203
                WHERE t.status=1 AND t.amount_authority_version=1
                  AND COALESCE(t.is_deleted,false)=false AND to_char(t.bill_date,'YYYY-MM') = :p
                UNION ALL
                SELECT v.id, 2, acct.style_id, -1, t.amount_local, t.bill_date, v.period,
                       'PAYMENT', t.id, t.bill_no, COALESCE(t.remark,'采购付款')
                FROM finance_payments t
                JOIN gl_vouchers v
                  ON v.source_doc_id = t.id AND v.source_type = 'PAYMENT'
                 AND v.source = 'AUTO' AND v.status = 1 AND COALESCE(v.is_deleted,false)=false
                JOIN LATERAL (
                  SELECT style.id AS style_id
                  FROM payment_styles style
                  WHERE style.id=account_style_id(t.account_id)
                    AND style.status='使用'
                    AND COALESCE(style.is_deleted,false)=false
                  LIMIT 1
                ) acct ON TRUE
                WHERE t.status=1 AND t.amount_authority_version=1
                  AND COALESCE(t.is_deleted,false)=false AND to_char(t.bill_date,'YYYY-MM') = :p
                UNION ALL
                SELECT v.id, 3, fx.id,
                       CASE WHEN x.diff>0 THEN 1 ELSE -1 END,
                       ABS(x.diff), t.bill_date, v.period,
                       'PAYMENT', t.id, t.bill_no, '付款汇兑损益'
                FROM finance_payments t
                JOIN gl_vouchers v
                  ON v.source_doc_id=t.id AND v.source_type='PAYMENT'
                 AND v.source='AUTO' AND v.status=1 AND COALESCE(v.is_deleted,false)=false
                JOIN LATERAL (
                  SELECT COALESCE(SUM(line.exchange_diff),0) AS diff
                  FROM finance_payment_lines line
                  WHERE line.payment_id=t.id
                    AND COALESCE(line.is_deleted,false)=false
                ) x ON TRUE
                CROSS JOIN LATERAL (
                  SELECT system_posting_style_id('FX_GAIN_LOSS') AS id
                ) fx
                WHERE t.status=1 AND t.amount_authority_version=1
                  AND COALESCE(t.is_deleted,false)=false
                  AND to_char(t.bill_date,'YYYY-MM')=:p AND x.diff<>0
                """;
        run(vouchers, period);
        run(entries, period);
    }

    /** Required payment styles are checked before period vouchers are deleted. */
    private void assertPaymentPostingConfiguration(String period) {
        long invalid = ((Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM finance_payments payment
                        WHERE payment.status=1
                          AND payment.amount_authority_version=1
                          AND COALESCE(payment.is_deleted,false)=false
                          AND to_char(payment.bill_date,'YYYY-MM')=:p
                          AND (
                              NOT EXISTS (
                                  SELECT 1 FROM payment_styles style
                                  WHERE style.id=account_style_id(payment.account_id)
                                    AND style.status='使用'
                                    AND COALESCE(style.is_deleted,false)=false
                              )
                              OR system_posting_style_id('AP_CONTROL') IS NULL
                              OR
                              (COALESCE((
                                  SELECT SUM(line.exchange_diff)
                                  FROM finance_payment_lines line
                                  WHERE line.payment_id=payment.id
                                    AND COALESCE(line.is_deleted,false)=false
                              ),0)<>0
                                  AND system_posting_style_id('FX_GAIN_LOSS') IS NULL)
                          )
                        """)
                .setParameter("p", period)
                .getSingleResult()).longValue();
        if (invalid > 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "采购付款总账科目缺失或已停用，请先启用付款账户、应付账款或汇兑损益科目");
        }
    }

    /** 费用：借 费用科目(按行 expense_style_id) / 贷 账户(单头，金额=行合计保平衡)。 */
    private void postExpenses(String period) {
        String vouchers = """
                INSERT INTO gl_vouchers
                    (voucher_no, period, voucher_date, source, source_type, source_doc_id, remark)
                SELECT t.bill_no, to_char(t.bill_date,'YYYY-MM'), t.bill_date,
                       'AUTO', 'EXPENSE', t.id, '一般费用'
                FROM finance_expenses t
                WHERE t.status=1 AND COALESCE(t.is_deleted,false)=false AND to_char(t.bill_date,'YYYY-MM') = :p
                """;
        String debits = """
                INSERT INTO gl_entries (voucher_id, line_no, style_id, direction, amount, entry_date, period,
                                        source_doc_type, source_doc_id, source_bill_no, summary)
                SELECT v.id, i.line_no, i.expense_style_id, 1, i.amount_local, i.bill_date, v.period,
                       'EXPENSE', t.id, t.bill_no, COALESCE(i.summary, t.remark, '一般费用')
                FROM finance_expense_items i
                JOIN finance_expenses t ON t.id = i.expense_id
                JOIN gl_vouchers v
                  ON v.source_doc_id = t.id AND v.source_type = 'EXPENSE'
                 AND v.source = 'AUTO' AND v.status = 1 AND COALESCE(v.is_deleted,false)=false
                WHERE t.status=1 AND COALESCE(t.is_deleted,false)=false AND COALESCE(i.is_deleted,false)=false
                  AND to_char(t.bill_date,'YYYY-MM') = :p AND i.expense_style_id IS NOT NULL
                """;
        String credit = """
                INSERT INTO gl_entries (voucher_id, line_no, style_id, direction, amount, entry_date, period,
                                        source_doc_type, source_doc_id, source_bill_no, summary)
                SELECT v.id, 9000, acct.style_id, -1, x.total, t.bill_date, v.period,
                       'EXPENSE', t.id, t.bill_no, COALESCE(t.remark,'一般费用')
                FROM finance_expenses t
                JOIN gl_vouchers v
                  ON v.source_doc_id = t.id AND v.source_type = 'EXPENSE'
                 AND v.source = 'AUTO' AND v.status = 1 AND COALESCE(v.is_deleted,false)=false
                JOIN LATERAL (SELECT account_style_id(t.account_id) AS style_id) acct ON TRUE
                JOIN LATERAL (SELECT COALESCE(SUM(i.amount_local),0) AS total FROM finance_expense_items i
                              WHERE i.expense_id = t.id AND COALESCE(i.is_deleted,false)=false
                                AND i.expense_style_id IS NOT NULL) x ON TRUE
                WHERE t.status=1 AND COALESCE(t.is_deleted,false)=false AND to_char(t.bill_date,'YYYY-MM') = :p
                  AND x.total <> 0
                """;
        run(vouchers, period);
        run(debits, period);
        run(credit, period);
        // FIN-P1-3：重生成路径 DELETE+INSERT 用 gen_random_uuid() 建新 voucher id，
        // 旧 finance_expenses.gl_voucher_id 指向已删 voucher → 按来源 UUID 同步到新 id。
        // 与实时路径 postExpenseDoc 返回 voucherId 由 FinanceExpenseService 落库 互补：
        // 本重生成路径无 Java 端 voucherId 句柄，只能 SQL JOIN 回写。
        em.createNativeQuery("""
                UPDATE finance_expenses e
                SET gl_voucher_id = v.id, updated_at = now()
                FROM gl_vouchers v
                WHERE e.id = v.source_doc_id
                  AND v.source_type = 'EXPENSE' AND v.source = 'AUTO'
                  AND v.status = 1 AND COALESCE(v.is_deleted,false)=false
                  AND e.status = 1 AND COALESCE(e.is_deleted,false) = false
                  AND to_char(e.bill_date,'YYYY-MM') = :p
                """).setParameter("p", period).executeUpdate();
    }

    /** 其它收入：借 账户(行合计) / 贷 收入科目(按行 income_style_id)。 */
    private void postIncomes(String period) {
        String vouchers = """
                INSERT INTO gl_vouchers
                    (voucher_no, period, voucher_date, source, source_type, source_doc_id, remark)
                SELECT t.bill_no, to_char(t.bill_date,'YYYY-MM'), t.bill_date,
                       'AUTO', 'INCOME', t.id, '其它收入'
                FROM finance_other_incomes t
                WHERE t.status=1 AND COALESCE(t.is_deleted,false)=false AND to_char(t.bill_date,'YYYY-MM') = :p
                """;
        String credits = """
                INSERT INTO gl_entries (voucher_id, line_no, style_id, direction, amount, entry_date, period,
                                        source_doc_type, source_doc_id, source_bill_no, summary)
                SELECT v.id, i.line_no, i.income_style_id, -1, i.amount_local, i.bill_date, v.period,
                       'INCOME', t.id, t.bill_no, COALESCE(i.summary, t.remark, '其它收入')
                FROM finance_other_income_items i
                JOIN finance_other_incomes t ON t.id = i.income_id
                JOIN gl_vouchers v
                  ON v.source_doc_id = t.id AND v.source_type = 'INCOME'
                 AND v.source = 'AUTO' AND v.status = 1 AND COALESCE(v.is_deleted,false)=false
                WHERE t.status=1 AND COALESCE(t.is_deleted,false)=false AND COALESCE(i.is_deleted,false)=false
                  AND to_char(t.bill_date,'YYYY-MM') = :p AND i.income_style_id IS NOT NULL
                """;
        String debit = """
                INSERT INTO gl_entries (voucher_id, line_no, style_id, direction, amount, entry_date, period,
                                        source_doc_type, source_doc_id, source_bill_no, summary)
                SELECT v.id, 9000, acct.style_id, 1, x.total, t.bill_date, v.period,
                       'INCOME', t.id, t.bill_no, COALESCE(t.remark,'其它收入')
                FROM finance_other_incomes t
                JOIN gl_vouchers v
                  ON v.source_doc_id = t.id AND v.source_type = 'INCOME'
                 AND v.source = 'AUTO' AND v.status = 1 AND COALESCE(v.is_deleted,false)=false
                JOIN LATERAL (SELECT account_style_id(t.account_id) AS style_id) acct ON TRUE
                JOIN LATERAL (SELECT COALESCE(SUM(i.amount_local),0) AS total FROM finance_other_income_items i
                              WHERE i.income_id = t.id AND COALESCE(i.is_deleted,false)=false
                                AND i.income_style_id IS NOT NULL) x ON TRUE
                WHERE t.status=1 AND COALESCE(t.is_deleted,false)=false AND to_char(t.bill_date,'YYYY-MM') = :p
                  AND x.total <> 0
                """;
        run(vouchers, period);
        run(credits, period);
        run(debit, period);
    }

    /** 销售成本结转：借 041 销售成本 / 贷 123 库存商品（出货行 Σqty×c_total；退货单不结转——成本口径同 C4）。 */
    private void postCostCarry(String period) {
        String vouchers = """
                INSERT INTO gl_vouchers
                    (voucher_no, period, voucher_date, source, source_type, source_doc_id, remark)
                SELECT d.bill_no || '-CB', to_char(d.bill_date,'YYYY-MM'), d.bill_date,
                       'AUTO', 'COST_CARRY', d.id, '销售成本结转'
                FROM sales_shipments d
                WHERE d.status=1 AND d.is_deleted=false AND to_char(d.bill_date,'YYYY-MM') = :p
                  AND EXISTS (SELECT 1 FROM sales_shipment_items i JOIN goods g ON g.id=i.goods_id
                              WHERE i.shipment_id=d.id AND i.is_deleted=false AND COALESCE(g.c_total,0)<>0 AND COALESCE(i.qty,0)<>0)
                """;
        String entries = """
                INSERT INTO gl_entries (voucher_id, line_no, style_id, direction, amount, entry_date, period,
                                        source_doc_type, source_doc_id, source_bill_no, summary)
                SELECT v.id, 1, s041.id, 1, x.cost, d.bill_date, v.period,
                       'COST_CARRY', d.id, d.bill_no, '销售成本结转'
                FROM sales_shipments d
                JOIN gl_vouchers v
                  ON v.source_doc_id = d.id AND v.source_type = 'COST_CARRY'
                 AND v.source = 'AUTO' AND v.status = 1 AND COALESCE(v.is_deleted,false)=false
                CROSS JOIN (
                  SELECT system_posting_style_id('SALES_COST') AS id
                ) s041
                JOIN LATERAL (SELECT SUM(i.qty * g.c_total) AS cost FROM sales_shipment_items i
                              JOIN goods g ON g.id = i.goods_id
                              WHERE i.shipment_id = d.id AND i.is_deleted=false AND COALESCE(g.c_total,0)<>0) x ON TRUE
                WHERE d.status=1 AND d.is_deleted=false AND to_char(d.bill_date,'YYYY-MM') = :p AND x.cost <> 0
                UNION ALL
                SELECT v.id, 2, s123.id, -1, x.cost, d.bill_date, v.period,
                       'COST_CARRY', d.id, d.bill_no, '销售成本结转'
                FROM sales_shipments d
                JOIN gl_vouchers v
                  ON v.source_doc_id = d.id AND v.source_type = 'COST_CARRY'
                 AND v.source = 'AUTO' AND v.status = 1 AND COALESCE(v.is_deleted,false)=false
                CROSS JOIN (
                  SELECT system_posting_style_id('INVENTORY_ASSET') AS id
                ) s123
                JOIN LATERAL (SELECT SUM(i.qty * g.c_total) AS cost FROM sales_shipment_items i
                              JOIN goods g ON g.id = i.goods_id
                              WHERE i.shipment_id = d.id AND i.is_deleted=false AND COALESCE(g.c_total,0)<>0) x ON TRUE
                WHERE d.status=1 AND d.is_deleted=false AND to_char(d.bill_date,'YYYY-MM') = :p AND x.cost <> 0
                """;
        run(vouchers, period);
        run(entries, period);
    }

    /**
     * 银行存取款：借 每个转入账户科目(按行) / 贷 转出账户科目(单头合计=行合计保平衡)。
     *
     * <p>镜像 {@link #postExpenses} 的"按行借 / 单头贷(9000)"模式。入账金额取
     * {@code finance_bank_transfer_lines.amount_local}（本币，审核时 FinanceBankTransferService
     * 已固化跨币种换算），借/贷都用 amount_local 故凭证平衡。0 金额跳过。
     *
     * <p>背景（FIN-P1-2）：审核 {@code FinanceBankTransferService.approve} 仅更新
     * {@code accounts.balance_current}+{@code finance_reconciliations}，从未写 GL，
     * 导致按账户聚合的 GL 银行余额与 {@code accounts.balance_current} 长期漂移。
     */
    private void postBankTransfers(String period) {
        String vouchers = """
                INSERT INTO gl_vouchers
                    (voucher_no, period, voucher_date, source, source_type, source_doc_id, remark)
                SELECT t.bill_no, to_char(t.bill_date,'YYYY-MM'), t.bill_date,
                       'AUTO', 'BANK_TRANSFER', t.id, '银行存取款'
                FROM finance_bank_transfers t
                WHERE t.status=1 AND COALESCE(t.is_deleted,false)=false AND to_char(t.bill_date,'YYYY-MM') = :p
                """;
        String debits = """
                INSERT INTO gl_entries (voucher_id, line_no, style_id, direction, amount, entry_date, period,
                                        source_doc_type, source_doc_id, source_bill_no, summary)
                SELECT v.id, i.line_no, acct.style_id, 1, i.amount_local, i.bill_date, v.period,
                       'BANK_TRANSFER', t.id, t.bill_no, COALESCE(i.summary, t.remark, '银行存取款')
                FROM finance_bank_transfer_lines i
                JOIN finance_bank_transfers t ON t.id = i.transfer_id
                JOIN gl_vouchers v
                  ON v.source_doc_id = t.id AND v.source_type = 'BANK_TRANSFER'
                 AND v.source = 'AUTO' AND v.status = 1 AND COALESCE(v.is_deleted,false)=false
                JOIN LATERAL (SELECT account_style_id(i.in_account_id) AS style_id) acct ON TRUE
                WHERE t.status=1 AND COALESCE(t.is_deleted,false)=false AND COALESCE(i.is_deleted,false)=false
                  AND to_char(t.bill_date,'YYYY-MM') = :p AND COALESCE(i.amount_local,0) <> 0
                """;
        String credit = """
                INSERT INTO gl_entries (voucher_id, line_no, style_id, direction, amount, entry_date, period,
                                        source_doc_type, source_doc_id, source_bill_no, summary)
                SELECT v.id, 9000, acct.style_id, -1, x.total, t.bill_date, v.period,
                       'BANK_TRANSFER', t.id, t.bill_no, COALESCE(t.remark,'银行存取款')
                FROM finance_bank_transfers t
                JOIN gl_vouchers v
                  ON v.source_doc_id = t.id AND v.source_type = 'BANK_TRANSFER'
                 AND v.source = 'AUTO' AND v.status = 1 AND COALESCE(v.is_deleted,false)=false
                JOIN LATERAL (SELECT account_style_id(t.out_account_id) AS style_id) acct ON TRUE
                JOIN LATERAL (SELECT COALESCE(SUM(i.amount_local),0) AS total FROM finance_bank_transfer_lines i
                              WHERE i.transfer_id = t.id AND COALESCE(i.is_deleted,false)=false
                                AND COALESCE(i.amount_local,0) <> 0) x ON TRUE
                WHERE t.status=1 AND COALESCE(t.is_deleted,false)=false AND to_char(t.bill_date,'YYYY-MM') = :p
                  AND x.total <> 0
                """;
        run(vouchers, period);
        run(debits, period);
        run(credit, period);
    }

    // ======================== C6 单张开票钩子（报销审核实时过账） ========================

    /** 费用单审核钩子：该单幂等过账（先删同单号 AUTO EXPENSE 凭证再重建），返回 voucher_id。 */
    @Transactional(propagation = Propagation.MANDATORY)
    public UUID postExpenseDoc(UUID expenseId) {
        tx.bind();
        PaymentStyleHierarchyLock.lock(em);
        @SuppressWarnings("unchecked")
        List<Object[]> docs = em.createNativeQuery(
                "SELECT bill_no, bill_date, account_id, remark FROM finance_expenses WHERE id = :id")
                .setParameter("id", expenseId).getResultList();
        if (docs.isEmpty()) return null;
        Object[] d = docs.get(0);
        String billNo = (String) d[0];
        LocalDate billDate = NativeValueConverters.toLocalDate(d[1]);
        String period = billDate.toString().substring(0, 7);

        removeAutoProjection("EXPENSE", expenseId, billNo, billDate);
        UUID voucherId = UUID.randomUUID();
        em.createNativeQuery("""
                INSERT INTO gl_vouchers
                    (id, voucher_no, period, voucher_date, source, source_type, source_doc_id, remark)
                VALUES (:id, :no, :p, :d, 'AUTO', 'EXPENSE', :doc, '一般费用（审核实时过账）')
                """)
                .setParameter("id", voucherId).setParameter("no", billNo)
                .setParameter("p", period).setParameter("d", billDate)
                .setParameter("doc", expenseId).executeUpdate();
        em.createNativeQuery("""
                INSERT INTO gl_entries (voucher_id, line_no, style_id, direction, amount, entry_date, period,
                                        source_doc_type, source_doc_id, source_bill_no, summary)
                SELECT :v, i.line_no, i.expense_style_id, 1, i.amount_local, i.bill_date, :p,
                       'EXPENSE', :doc, i.bill_no, COALESCE(i.summary, :rm, '一般费用')
                FROM finance_expense_items i
                WHERE i.expense_id = :doc AND COALESCE(i.is_deleted,false)=false AND i.expense_style_id IS NOT NULL
                """)
                .setParameter("v", voucherId).setParameter("p", period)
                .setParameter("doc", expenseId).setParameter("rm", d[3]).executeUpdate();
        em.createNativeQuery("""
                INSERT INTO gl_entries (voucher_id, line_no, style_id, direction, amount, entry_date, period,
                                        source_doc_type, source_doc_id, source_bill_no, summary)
                SELECT :v, 9000, account_style_id(:acct), -1, x.total, :bd, :p, 'EXPENSE', :doc, :no, COALESCE(:rm,'一般费用')
                FROM (SELECT COALESCE(SUM(i.amount_local),0) AS total FROM finance_expense_items i
                      WHERE i.expense_id = :doc AND COALESCE(i.is_deleted,false)=false
                        AND i.expense_style_id IS NOT NULL) x
                WHERE x.total <> 0
                """)
                .setParameter("v", voucherId).setParameter("acct", d[2]).setParameter("bd", billDate)
                .setParameter("p", period).setParameter("doc", expenseId)
                .setParameter("no", billNo).setParameter("rm", d[3]).executeUpdate();
        return voucherId;
    }

    /** 费用单红冲钩子：删该单 AUTO EXPENSE 凭证（级联分录）。 */
    @Transactional(propagation = Propagation.MANDATORY)
    public void removeExpenseDoc(UUID expenseId, String billNo, LocalDate billDate) {
        tx.bind();
        removeAutoProjection("EXPENSE", expenseId, billNo, billDate);
    }

    private void run(String sql, String period) {
        em.createNativeQuery(sql).setParameter("p", period).executeUpdate();
    }
}
