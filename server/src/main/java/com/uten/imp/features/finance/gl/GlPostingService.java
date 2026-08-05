package com.uten.imp.features.finance.gl;

import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.security.access.prepost.PreAuthorize;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/**
 * 总账过账服务（C3）——从业务单据幂等生成 AUTO 凭证。
 *
 * <p>科目=payment_styles 树。根科目按 path 定位：/031/ 销售收入 /041/ 销售成本 /123/ 库存商品
 * /113/ 应收账款 /203/ 应付账款 /101/ 现金 /102/ 银行存款。
 * 收/付/费用/其它收入 的对方账户：accounts.style_legacy_id→payment_styles.legacy_id，
 * 无挂接按 account_type（CASH→/101/，其余→/102/）。</p>
 *
 * <p>过账规则（借贷平衡，负数业务=同向红字）：
 * 销售立帐 借113/贷031；采购+委外立帐 借123/贷203；收款 借账户/贷113；付款 借203/贷账户；
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
            "EXPENSE", "INCOME", "COST_CARRY", "BANK_TRANSFER");

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
        em.createNativeQuery("DELETE FROM gl_vouchers WHERE source='AUTO' AND period=:p AND source_type IN (:sourceTypes)")
                .setParameter("p", period)
                .setParameter("sourceTypes", REGENERATED_SOURCE_TYPES)
                .executeUpdate();

        postAr(period);
        postAp(period);
        postReceipts(period);
        postPayments(period);
        postExpenses(period);
        postIncomes(period);
        postCostCarry(period);
        postBankTransfers(period);

        return ((Number) em.createNativeQuery(
                "SELECT COUNT(*) FROM gl_vouchers WHERE source='AUTO' AND period=:p AND source_type IN (:sourceTypes)")
                .setParameter("p", period)
                .setParameter("sourceTypes", REGENERATED_SOURCE_TYPES)
                .getSingleResult()).intValue();
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
                ) t ORDER BY 1
                """).getResultList();
        for (String p : periods) generatePeriod(p);
        return periods.size();
    }

    // ======================== 各源单过账 ========================

    /**
     * 销售立帐：借 113 应收账款 / 贷 031 销售收入。
     *
     * <p><b>红字约定（FIN-P2-3，非 bug 不改值）</b>：SALES_RETURN（销售退货）立帐时
     * {@code ar_ap_ledger.amount_original_local} 为负，本方法将其原样写入 {@code gl_entries.amount}，
     * 与 V122 列注释「正数；负值业务用红字（同向负金额）不反向」一致——即<b>不取绝对值、不反向 direction</b>。
     * 报表侧（{@link GlReportService}）以 {@code SUM(direction*amount)} 聚合，负 amount 同向累加
     * 即正确抵减借/贷，构成显式的红字表达。如改为绝对值会破坏所有 SUM(direction*amount) 报表
     * 与 opening_net/debit/credit 拆分（见 GlReportService L65-67）。
     */
    private void postAr(String period) {
        String vouchers = """
                INSERT INTO gl_vouchers (voucher_no, period, voucher_date, source, source_type, remark)
                SELECT l.bill_no, to_char(l.bill_date,'YYYY-MM'), l.bill_date, 'AUTO', 'AR_POST',
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
                JOIN gl_vouchers v ON v.voucher_no = l.bill_no AND v.source_type = 'AR_POST'
                CROSS JOIN (SELECT id FROM payment_styles WHERE path='/113/') s113
                WHERE l.source_doc_type IN ('SALES_SHIPMENT','SALES_RETURN') AND l.status=1 AND l.is_deleted=false
                  AND to_char(l.bill_date,'YYYY-MM') = :p
                UNION ALL
                SELECT v.id, 2, s031.id, -1, l.amount_original_local, l.bill_date, v.period,
                       l.source_doc_type, l.source_doc_id, l.bill_no, COALESCE(l.remark,'销售立帐')
                FROM ar_ap_ledger l
                JOIN gl_vouchers v ON v.voucher_no = l.bill_no AND v.source_type = 'AR_POST'
                CROSS JOIN (SELECT id FROM payment_styles WHERE path='/031/') s031
                WHERE l.source_doc_type IN ('SALES_SHIPMENT','SALES_RETURN') AND l.status=1 AND l.is_deleted=false
                  AND to_char(l.bill_date,'YYYY-MM') = :p
                """;
        run(vouchers, period);
        run(entries, period);
    }

    /** 采购/委外立帐：借 123 库存商品 / 贷 203 应付账款（PURCHASE_RETURN 负=红字）。 */
    private void postAp(String period) {
        String vouchers = """
                INSERT INTO gl_vouchers (voucher_no, period, voucher_date, source, source_type, remark)
                SELECT l.bill_no, to_char(l.bill_date,'YYYY-MM'), l.bill_date, 'AUTO', 'AP_POST',
                       '采购立帐 ' || l.source_doc_type
                FROM ar_ap_ledger l
                WHERE l.source_doc_type IN ('PURCHASE_RECEIPT','PURCHASE_RETURN','SUBCONTRACT_RECEIPT')
                  AND l.status=1 AND l.is_deleted=false AND to_char(l.bill_date,'YYYY-MM') = :p
                """;
        String entries = """
                INSERT INTO gl_entries (voucher_id, line_no, style_id, direction, amount, entry_date, period,
                                        source_doc_type, source_doc_id, source_bill_no, summary)
                SELECT v.id, 1, s123.id, 1, l.amount_original_local, l.bill_date, v.period,
                       l.source_doc_type, l.source_doc_id, l.bill_no, COALESCE(l.remark,'采购立帐')
                FROM ar_ap_ledger l
                JOIN gl_vouchers v ON v.voucher_no = l.bill_no AND v.source_type = 'AP_POST'
                CROSS JOIN (SELECT id FROM payment_styles WHERE path='/123/') s123
                WHERE l.source_doc_type IN ('PURCHASE_RECEIPT','PURCHASE_RETURN','SUBCONTRACT_RECEIPT')
                  AND l.status=1 AND l.is_deleted=false AND to_char(l.bill_date,'YYYY-MM') = :p
                UNION ALL
                SELECT v.id, 2, s203.id, -1, l.amount_original_local, l.bill_date, v.period,
                       l.source_doc_type, l.source_doc_id, l.bill_no, COALESCE(l.remark,'采购立帐')
                FROM ar_ap_ledger l
                JOIN gl_vouchers v ON v.voucher_no = l.bill_no AND v.source_type = 'AP_POST'
                CROSS JOIN (SELECT id FROM payment_styles WHERE path='/203/') s203
                WHERE l.source_doc_type IN ('PURCHASE_RECEIPT','PURCHASE_RETURN','SUBCONTRACT_RECEIPT')
                  AND l.status=1 AND l.is_deleted=false AND to_char(l.bill_date,'YYYY-MM') = :p
                """;
        run(vouchers, period);
        run(entries, period);
    }

    /** 收款：借 收款账户科目 / 贷 113 应收账款。 */
    private void postReceipts(String period) {
        String vouchers = """
                INSERT INTO gl_vouchers (voucher_no, period, voucher_date, source, source_type, remark)
                SELECT t.bill_no, to_char(t.bill_date,'YYYY-MM'), t.bill_date, 'AUTO', 'RECEIPT', '销售收款'
                FROM finance_receipts t
                WHERE t.status=1 AND COALESCE(t.is_deleted,false)=false AND to_char(t.bill_date,'YYYY-MM') = :p
                """;
        String entries = """
                INSERT INTO gl_entries (voucher_id, line_no, style_id, direction, amount, entry_date, period,
                                        source_doc_type, source_doc_id, source_bill_no, summary)
                SELECT v.id, 1, acct.style_id, 1, t.amount_local, t.bill_date, v.period,
                       'RECEIPT', t.id, t.bill_no, COALESCE(t.remark,'销售收款')
                FROM finance_receipts t
                JOIN gl_vouchers v ON v.voucher_no = t.bill_no AND v.source_type = 'RECEIPT'
                JOIN LATERAL (SELECT account_style_id(t.account_id) AS style_id) acct ON TRUE
                WHERE t.status=1 AND COALESCE(t.is_deleted,false)=false AND to_char(t.bill_date,'YYYY-MM') = :p
                UNION ALL
                SELECT v.id, 2, s113.id, -1, t.amount_local, t.bill_date, v.period,
                       'RECEIPT', t.id, t.bill_no, COALESCE(t.remark,'销售收款')
                FROM finance_receipts t
                JOIN gl_vouchers v ON v.voucher_no = t.bill_no AND v.source_type = 'RECEIPT'
                CROSS JOIN (SELECT id FROM payment_styles WHERE path='/113/') s113
                WHERE t.status=1 AND COALESCE(t.is_deleted,false)=false AND to_char(t.bill_date,'YYYY-MM') = :p
                """;
        run(vouchers, period);
        run(entries, period);
    }

    /** 付款：借 203 应付账款 / 贷 付款账户科目。 */
    private void postPayments(String period) {
        String vouchers = """
                INSERT INTO gl_vouchers (voucher_no, period, voucher_date, source, source_type, remark)
                SELECT t.bill_no, to_char(t.bill_date,'YYYY-MM'), t.bill_date, 'AUTO', 'PAYMENT', '采购付款'
                FROM finance_payments t
                WHERE t.status=1 AND COALESCE(t.is_deleted,false)=false AND to_char(t.bill_date,'YYYY-MM') = :p
                """;
        String entries = """
                INSERT INTO gl_entries (voucher_id, line_no, style_id, direction, amount, entry_date, period,
                                        source_doc_type, source_doc_id, source_bill_no, summary)
                SELECT v.id, 1, s203.id, 1, t.amount_local, t.bill_date, v.period,
                       'PAYMENT', t.id, t.bill_no, COALESCE(t.remark,'采购付款')
                FROM finance_payments t
                JOIN gl_vouchers v ON v.voucher_no = t.bill_no AND v.source_type = 'PAYMENT'
                CROSS JOIN (SELECT id FROM payment_styles WHERE path='/203/') s203
                WHERE t.status=1 AND COALESCE(t.is_deleted,false)=false AND to_char(t.bill_date,'YYYY-MM') = :p
                UNION ALL
                SELECT v.id, 2, acct.style_id, -1, t.amount_local, t.bill_date, v.period,
                       'PAYMENT', t.id, t.bill_no, COALESCE(t.remark,'采购付款')
                FROM finance_payments t
                JOIN gl_vouchers v ON v.voucher_no = t.bill_no AND v.source_type = 'PAYMENT'
                JOIN LATERAL (SELECT account_style_id(t.account_id) AS style_id) acct ON TRUE
                WHERE t.status=1 AND COALESCE(t.is_deleted,false)=false AND to_char(t.bill_date,'YYYY-MM') = :p
                """;
        run(vouchers, period);
        run(entries, period);
    }

    /** 费用：借 费用科目(按行 expense_style_id) / 贷 账户(单头，金额=行合计保平衡)。 */
    private void postExpenses(String period) {
        String vouchers = """
                INSERT INTO gl_vouchers (voucher_no, period, voucher_date, source, source_type, remark)
                SELECT t.bill_no, to_char(t.bill_date,'YYYY-MM'), t.bill_date, 'AUTO', 'EXPENSE', '一般费用'
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
                JOIN gl_vouchers v ON v.voucher_no = t.bill_no AND v.source_type = 'EXPENSE'
                WHERE t.status=1 AND COALESCE(t.is_deleted,false)=false AND COALESCE(i.is_deleted,false)=false
                  AND to_char(t.bill_date,'YYYY-MM') = :p AND i.expense_style_id IS NOT NULL
                """;
        String credit = """
                INSERT INTO gl_entries (voucher_id, line_no, style_id, direction, amount, entry_date, period,
                                        source_doc_type, source_doc_id, source_bill_no, summary)
                SELECT v.id, 9000, acct.style_id, -1, x.total, t.bill_date, v.period,
                       'EXPENSE', t.id, t.bill_no, COALESCE(t.remark,'一般费用')
                FROM finance_expenses t
                JOIN gl_vouchers v ON v.voucher_no = t.bill_no AND v.source_type = 'EXPENSE'
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
        // 旧 finance_expenses.gl_voucher_id 指向已删 voucher → 同步到新 id（按 bill_no + EXPENSE + 期间）。
        // 与实时路径 postExpenseDoc 返回 voucherId 由 FinanceExpenseService 落库 互补：
        // 本重生成路径无 Java 端 voucherId 句柄，只能 SQL JOIN 回写。
        em.createNativeQuery("""
                UPDATE finance_expenses e
                SET gl_voucher_id = v.id, updated_at = now()
                FROM gl_vouchers v
                WHERE e.bill_no = v.voucher_no
                  AND v.source_type = 'EXPENSE' AND v.source = 'AUTO'
                  AND e.status = 1 AND COALESCE(e.is_deleted,false) = false
                  AND to_char(e.bill_date,'YYYY-MM') = :p
                """).setParameter("p", period).executeUpdate();
    }

    /** 其它收入：借 账户(行合计) / 贷 收入科目(按行 income_style_id)。 */
    private void postIncomes(String period) {
        String vouchers = """
                INSERT INTO gl_vouchers (voucher_no, period, voucher_date, source, source_type, remark)
                SELECT t.bill_no, to_char(t.bill_date,'YYYY-MM'), t.bill_date, 'AUTO', 'INCOME', '其它收入'
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
                JOIN gl_vouchers v ON v.voucher_no = t.bill_no AND v.source_type = 'INCOME'
                WHERE t.status=1 AND COALESCE(t.is_deleted,false)=false AND COALESCE(i.is_deleted,false)=false
                  AND to_char(t.bill_date,'YYYY-MM') = :p AND i.income_style_id IS NOT NULL
                """;
        String debit = """
                INSERT INTO gl_entries (voucher_id, line_no, style_id, direction, amount, entry_date, period,
                                        source_doc_type, source_doc_id, source_bill_no, summary)
                SELECT v.id, 9000, acct.style_id, 1, x.total, t.bill_date, v.period,
                       'INCOME', t.id, t.bill_no, COALESCE(t.remark,'其它收入')
                FROM finance_other_incomes t
                JOIN gl_vouchers v ON v.voucher_no = t.bill_no AND v.source_type = 'INCOME'
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
                INSERT INTO gl_vouchers (voucher_no, period, voucher_date, source, source_type, remark)
                SELECT d.bill_no || '-CB', to_char(d.bill_date,'YYYY-MM'), d.bill_date, 'AUTO', 'COST_CARRY', '销售成本结转'
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
                JOIN gl_vouchers v ON v.voucher_no = d.bill_no || '-CB' AND v.source_type = 'COST_CARRY'
                CROSS JOIN (SELECT id FROM payment_styles WHERE path='/041/') s041
                JOIN LATERAL (SELECT SUM(i.qty * g.c_total) AS cost FROM sales_shipment_items i
                              JOIN goods g ON g.id = i.goods_id
                              WHERE i.shipment_id = d.id AND i.is_deleted=false AND COALESCE(g.c_total,0)<>0) x ON TRUE
                WHERE d.status=1 AND d.is_deleted=false AND to_char(d.bill_date,'YYYY-MM') = :p AND x.cost <> 0
                UNION ALL
                SELECT v.id, 2, s123.id, -1, x.cost, d.bill_date, v.period,
                       'COST_CARRY', d.id, d.bill_no, '销售成本结转'
                FROM sales_shipments d
                JOIN gl_vouchers v ON v.voucher_no = d.bill_no || '-CB' AND v.source_type = 'COST_CARRY'
                CROSS JOIN (SELECT id FROM payment_styles WHERE path='/123/') s123
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
                INSERT INTO gl_vouchers (voucher_no, period, voucher_date, source, source_type, remark)
                SELECT t.bill_no, to_char(t.bill_date,'YYYY-MM'), t.bill_date, 'AUTO', 'BANK_TRANSFER', '银行存取款'
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
                JOIN gl_vouchers v ON v.voucher_no = t.bill_no AND v.source_type = 'BANK_TRANSFER'
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
                JOIN gl_vouchers v ON v.voucher_no = t.bill_no AND v.source_type = 'BANK_TRANSFER'
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
    @Transactional
    public UUID postExpenseDoc(UUID expenseId) {
        tx.bind();
        @SuppressWarnings("unchecked")
        List<Object[]> docs = em.createNativeQuery(
                "SELECT bill_no, bill_date, account_id, remark FROM finance_expenses WHERE id = :id")
                .setParameter("id", expenseId).getResultList();
        if (docs.isEmpty()) return null;
        Object[] d = docs.get(0);
        String billNo = (String) d[0];
        LocalDate billDate = ((java.sql.Date) d[1]).toLocalDate();
        String period = billDate.toString().substring(0, 7);

        removeExpenseDocInternal(billNo);
        UUID voucherId = UUID.randomUUID();
        em.createNativeQuery("""
                INSERT INTO gl_vouchers (id, voucher_no, period, voucher_date, source, source_type, remark)
                VALUES (:id, :no, :p, :d, 'AUTO', 'EXPENSE', '一般费用（审核实时过账）')
                """)
                .setParameter("id", voucherId).setParameter("no", billNo)
                .setParameter("p", period).setParameter("d", billDate).executeUpdate();
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
    @Transactional
    public void removeExpenseDoc(String billNo) {
        tx.bind();
        removeExpenseDocInternal(billNo);
    }

    private void removeExpenseDocInternal(String billNo) {
        em.createNativeQuery("DELETE FROM gl_vouchers WHERE source='AUTO' AND source_type='EXPENSE' AND voucher_no = :no")
                .setParameter("no", billNo).executeUpdate();
    }

    private void run(String sql, String period) {
        em.createNativeQuery(sql).setParameter("p", period).executeUpdate();
    }
}
