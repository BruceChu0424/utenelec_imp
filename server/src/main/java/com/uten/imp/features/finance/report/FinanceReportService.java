package com.uten.imp.features.finance.report;

import com.uten.imp.features.finance.report.dto.AccountStatementRow;
import com.uten.imp.features.finance.report.dto.ArApDetailReportRow;
import com.uten.imp.features.finance.report.dto.ArApSummaryRow;
import com.uten.imp.features.finance.report.dto.FinanceDocReportRow;
import com.uten.imp.features.finance.report.dto.FinanceDocSummaryRow;
import com.uten.imp.features.finance.report.dto.PartyAnnualStatementRow;
import com.uten.imp.features.finance.report.dto.PartyStatementRow;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.sql.Timestamp;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/**
 * 钱流报表查询服务（finance_report:view）。
 *
 * <p>23 张报表按 [26] §六 4 大类参数化：
 * <ol>
 *   <li><b>应收应付类（10）</b>：Z/B/D 走 finance_ar_ap_mv 上卷；A/C 走 ar_ap_ledger 明细；
 *       I/J/K/L 走单客户/供应商对账（立帐+收/付款流水合并，滚动余额）；X 年度对账（期初+本期立帐-本期核销=期末）。</li>
 *   <li><b>收付款单据类（4）</b>：E/F 销售收款（明细 + 按 client/month 汇总）；G/H 采购付款对称。</li>
 *   <li><b>费用收入类（5）</b>：M/N 一般费用（按 dept/style 汇总）；O/P 其它收入对称；费用冲销明细（同 M）。</li>
 *   <li><b>账户流水类（3）</b>：S 帐户进出流水帐（finance_reconciliations 滚动余额）；Q/R 银行存取款（空表，复用 bank_transfers 列表）。</li>
 * </ol>
 *
 * <p>报表参数化：日期范围 + 单位（client/supplier/account/dept）+ 维度（month/party/dept/style）。
 * 实现走 EntityManager 原生 SQL + 主档 LEFT JOIN 带名 + 分页 LIMIT。
 */
@Service
@RequiredArgsConstructor
public class FinanceReportService {

    private static final UUID NIL = UUID.fromString("00000000-0000-0000-0000-000000000000");

    private final EntityManager em;

    // ===================== A. 应收应付类 =====================

    /** Z/B/D 应收应付汇总（finance_ar_ap_mv 月度上卷）。direction 筛选 → AR 给 B / AP 给 D / null 给 Z 总览。 */
    @Transactional(readOnly = true)
    public List<ArApSummaryRow> arApSummary(String direction, String sourceDocType, UUID partyId,
                                            LocalDate dateFrom, LocalDate dateTo, int limit) {
        var q = em.createNativeQuery("""
                SELECT m.ym, m.direction, m.source_doc_type, m.party_id, p.name AS party_name,
                       m.currency_id, SUM(m.entry_cnt), SUM(m.original_local_sum),
                       SUM(m.settled_sum), SUM(m.balance_sum)
                FROM finance_ar_ap_mv m
                LEFT JOIN (
                    SELECT id, name FROM clients WHERE COALESCE(is_deleted, false) = false
                    UNION ALL
                    SELECT id, name FROM suppliers WHERE COALESCE(is_deleted, false) = false
                ) p ON p.id = m.party_id
                WHERE (CAST(:dir AS text) IS NULL OR m.direction = :dir)
                  AND (CAST(:src AS text) IS NULL OR m.source_doc_type = :src)
                  AND (CAST(:pid AS uuid) IS NULL OR m.party_id = :pid)
                  AND (CAST(:from AS date) IS NULL OR m.ym >= :from)
                  AND (CAST(:to AS date) IS NULL OR m.ym <= :to)
                GROUP BY m.ym, m.direction, m.source_doc_type, m.party_id, p.name, m.currency_id
                ORDER BY m.ym DESC, m.direction, m.party_id
                LIMIT :limit
                """);
        q.setParameter("dir", direction);
        q.setParameter("src", sourceDocType);
        q.setParameter("pid", partyId);
        q.setParameter("from", dateFrom);
        q.setParameter("to", dateTo);
        q.setParameter("limit", limit);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = q.getResultList();
        return rows.stream().map(r -> new ArApSummaryRow(
                ((java.sql.Date) r[0]).toLocalDate(),
                (String) r[1],
                (String) r[2],
                NIL.equals(r[3]) ? null : (UUID) r[3],
                (String) r[4],
                r[5] == null ? null : (UUID) r[5],
                ((Number) r[6]).longValue(),
                (BigDecimal) r[7],
                (BigDecimal) r[8],
                (BigDecimal) r[9]
        )).toList();
    }

    /** A/C 应收/应付明细（ar_ap_ledger 明细，direction='AR' 给 A，'AP' 给 C）。 */
    @Transactional(readOnly = true)
    public List<ArApDetailReportRow> arApDetail(String direction, String sourceDocType, UUID partyId,
                                                UUID clientId, UUID supplierId, Boolean settled,
                                                LocalDate dateFrom, LocalDate dateTo, int limit) {
        var q = em.createNativeQuery("""
                SELECT l.id, l.direction, l.source_doc_type, l.source_doc_id, l.source_doc_no, l.bill_no,
                       l.bill_date, COALESCE(l.client_id, l.supplier_id) AS party_id, p.name AS party_name,
                       l.currency_id, l.amount_original_local, l.amount_settled, l.amount_balance,
                       l.is_settled, l.settled_date, l.status, l.remark
                FROM ar_ap_ledger l
                LEFT JOIN (
                    SELECT id, name FROM clients WHERE COALESCE(is_deleted, false) = false
                    UNION ALL
                    SELECT id, name FROM suppliers WHERE COALESCE(is_deleted, false) = false
                ) p ON p.id = COALESCE(l.client_id, l.supplier_id)
                WHERE l.is_deleted = false
                  AND (CAST(:dir AS text) IS NULL OR l.direction = :dir)
                  AND (CAST(:src AS text) IS NULL OR l.source_doc_type = :src)
                  AND (CAST(:pid AS uuid) IS NULL OR COALESCE(l.client_id, l.supplier_id) = :pid)
                  AND (CAST(:cid AS uuid) IS NULL OR l.client_id = :cid)
                  AND (CAST(:sid AS uuid) IS NULL OR l.supplier_id = :sid)
                  AND (CAST(:stl AS boolean) IS NULL OR l.is_settled = :stl)
                  AND (CAST(:from AS date) IS NULL OR l.bill_date >= :from)
                  AND (CAST(:to AS date) IS NULL OR l.bill_date <= :to)
                ORDER BY l.bill_date DESC, l.bill_no
                LIMIT :limit
                """);
        q.setParameter("dir", direction);
        q.setParameter("src", sourceDocType);
        q.setParameter("pid", partyId);
        q.setParameter("cid", clientId);
        q.setParameter("sid", supplierId);
        q.setParameter("stl", settled);
        q.setParameter("from", dateFrom);
        q.setParameter("to", dateTo);
        q.setParameter("limit", limit);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = q.getResultList();
        return rows.stream().map(r -> new ArApDetailReportRow(
                (UUID) r[0], (String) r[1], (String) r[2],
                (UUID) r[3], (String) r[4], (String) r[5],
                ((java.sql.Date) r[6]).toLocalDate(),
                r[7] == null ? null : (UUID) r[7],
                (String) r[8],
                r[9] == null ? null : (UUID) r[9],
                (BigDecimal) r[10], (BigDecimal) r[11], (BigDecimal) r[12],
                r[13] != null && (boolean) r[13],
                r[14] == null ? null : ((java.sql.Date) r[14]).toLocalDate(),
                r[15] == null ? null : ((Number) r[15]).shortValue(),
                (String) r[16]
        )).toList();
    }

    /**
     * I/J/K/L 单客户/供应商对账（AR/AP 立帐 + 收款/付款核销流水合并，滚动余额）。
     *
     * <p>{@code side='AR'} 走 client_id（立帐 + receipt_lines）；{@code side='AP'} 走 supplier_id（立帐 + payment_lines）。
     */
    @Transactional(readOnly = true)
    public List<PartyStatementRow> partyStatement(UUID partyId, String side,
                                                  LocalDate dateFrom, LocalDate dateTo, int limit) {
        if (partyId == null) return List.of();
        boolean isAR = "AR".equals(side);
        String postedSql = isAR
                ? "SELECT l.bill_date, l.bill_no, 'POSTED', l.source_doc_type, l.remark, " +
                  "l.amount_original_local, 0 FROM ar_ap_ledger l " +
                  "WHERE l.is_deleted=false AND l.direction='AR' AND l.client_id=:pid"
                : "SELECT l.bill_date, l.bill_no, 'POSTED', l.source_doc_type, l.remark, " +
                  "0, l.amount_original_local FROM ar_ap_ledger l " +
                  "WHERE l.is_deleted=false AND l.direction='AP' AND l.supplier_id=:pid";
        String settledSql = isAR
                ? "SELECT rl.bill_date, rl.bill_no, 'SETTLED', 'DIRECT_RECEIPT', rl.remark, " +
                  "0, rl.amount_local FROM finance_receipt_lines rl " +
                  "JOIN finance_receipts rt ON rt.id = rl.receipt_id " +
                  "WHERE rl.client_id=:pid AND rt.status=1 AND rt.is_deleted=false"
                : "SELECT pl.bill_date, pl.bill_no, 'SETTLED', 'DIRECT_PAYMENT', pl.remark, " +
                  "0, pl.amount_local FROM finance_payment_lines pl " +
                  "JOIN finance_payments pm ON pm.id = pl.payment_id " +
                  "WHERE pl.supplier_id=:pid AND pm.status=1 AND pm.is_deleted=false";
        String filter = " AND (CAST(:from AS date) IS NULL OR t.bill_date >= :from) AND (CAST(:to AS date) IS NULL OR t.bill_date <= :to) ";
        String wrapped = "SELECT * FROM (" + postedSql + " UNION ALL " + settledSql + ") t WHERE TRUE "
                + filter + "ORDER BY t.bill_date ASC, t.bill_no ASC LIMIT :limit";

        var q = em.createNativeQuery(wrapped)
                .setParameter("pid", partyId)
                .setParameter("from", dateFrom)
                .setParameter("to", dateTo)
                .setParameter("limit", limit);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = q.getResultList();
        // 滚动余额：AR 立帐+应收（in），收款-应收（out）；AP 反之。balance = in - out。
        List<PartyStatementRow> out = new ArrayList<>(rows.size());
        BigDecimal running = BigDecimal.ZERO;
        for (Object[] r : rows) {
            BigDecimal inAmt = r[5] == null ? BigDecimal.ZERO : (BigDecimal) r[5];
            BigDecimal outAmt = r[6] == null ? BigDecimal.ZERO : (BigDecimal) r[6];
            running = running.add(inAmt).subtract(outAmt);
            out.add(new PartyStatementRow(
                    ((java.sql.Date) r[0]).toLocalDate(),
                    (String) r[1], (String) r[2], (String) r[3], (String) r[4],
                    inAmt, outAmt, running));
        }
        return out;
    }

    /**
     * X 客户/供应商年度对账单（期初 + 本期立帐 - 本期核销 = 期末）。
     *
     * <p>{@code side='AR'} 单客户 / {@code side='AP'} 单供应商；按 year 取年度首末日。
     */
    @Transactional(readOnly = true)
    public PartyAnnualStatementRow partyAnnualStatement(UUID partyId, String side, int year) {
        if (partyId == null) return null;
        LocalDate yearStart = LocalDate.of(year, 1, 1);
        LocalDate yearEnd = LocalDate.of(year, 12, 31);
        boolean isAR = "AR".equals(side);
        String postedUnion = isAR
                ? "SELECT l.bill_date, l.amount_original_local AS posted, 0 AS settled FROM ar_ap_ledger l " +
                  "WHERE l.is_deleted=false AND l.direction='AR' AND l.client_id=:pid"
                : "SELECT l.bill_date, l.amount_original_local AS posted, 0 AS settled FROM ar_ap_ledger l " +
                  "WHERE l.is_deleted=false AND l.direction='AP' AND l.supplier_id=:pid";
        String settledUnion = isAR
                ? "SELECT rl.bill_date, 0 AS posted, rl.amount_local AS settled FROM finance_receipt_lines rl " +
                  "JOIN finance_receipts rt ON rt.id = rl.receipt_id " +
                  "WHERE rl.client_id=:pid AND rt.status=1 AND rt.is_deleted=false"
                : "SELECT pl.bill_date, 0 AS posted, pl.amount_local AS settled FROM finance_payment_lines pl " +
                  "JOIN finance_payments pm ON pm.id = pl.payment_id " +
                  "WHERE pl.supplier_id=:pid AND pm.status=1 AND pm.is_deleted=false";
        String partyTable = isAR ? "clients" : "suppliers";
        String sql = "WITH party_ledger AS (" + postedUnion + " UNION ALL " + settledUnion + ")\n" +
                "SELECT COALESCE(SUM(CASE WHEN pl.bill_date < :ys THEN pl.posted - pl.settled ELSE 0 END), 0),\n" +
                "       COALESCE(SUM(CASE WHEN pl.bill_date BETWEEN :ys AND :ye THEN pl.posted ELSE 0 END), 0),\n" +
                "       COALESCE(SUM(CASE WHEN pl.bill_date BETWEEN :ys AND :ye THEN pl.settled ELSE 0 END), 0),\n" +
                "       COALESCE(SUM(CASE WHEN pl.bill_date <= :ye THEN pl.posted - pl.settled ELSE 0 END), 0),\n" +
                "       (SELECT name FROM " + partyTable + " WHERE id = :pid AND COALESCE(is_deleted, false) = false)\n" +
                "FROM party_ledger pl";
        Object[] r = (Object[]) em.createNativeQuery(sql)
                .setParameter("pid", partyId)
                .setParameter("ys", yearStart)
                .setParameter("ye", yearEnd)
                .getSingleResult();
        return new PartyAnnualStatementRow(
                partyId,
                r[4] == null ? null : r[4].toString(),
                (BigDecimal) r[0],
                (BigDecimal) r[1],
                (BigDecimal) r[2],
                (BigDecimal) r[3]);
    }

    // ===================== B. 收付款单据类 =====================

    /** E 销售收款明细（receipts + clients + accounts）。 */
    @Transactional(readOnly = true)
    public List<FinanceDocReportRow> receiptsDetail(UUID clientId, UUID accountId, Short status,
                                                    LocalDate dateFrom, LocalDate dateTo, int limit) {
        return docDetail("finance_receipts", "client_id", clientId, accountId, status, dateFrom, dateTo, limit, true);
    }

    /** G 采购付款明细（payments + suppliers + accounts）。 */
    @Transactional(readOnly = true)
    public List<FinanceDocReportRow> paymentsDetail(UUID supplierId, UUID accountId, Short status,
                                                    LocalDate dateFrom, LocalDate dateTo, int limit) {
        return docDetail("finance_payments", "supplier_id", supplierId, accountId, status, dateFrom, dateTo, limit, false);
    }

    private List<FinanceDocReportRow> docDetail(String table, String partyCol, UUID partyValue,
                                                UUID accountId, Short status,
                                                LocalDate dateFrom, LocalDate dateTo, int limit, boolean isClient) {
        String partyTable = isClient ? "clients" : "suppliers";
        String sql = """
                SELECT r.id, r.bill_no, r.bill_date, r.%col% AS party_id, p.name AS party_name,
                       r.account_id, a.name AS account_name, r.amount_original, r.amount_local, r.status, r.remark
                FROM %tbl% r
                LEFT JOIN %ptbl% p ON p.id = r.%col%
                LEFT JOIN accounts a ON a.id = r.account_id
                WHERE r.is_deleted = false
                  AND (CAST(:pv AS uuid) IS NULL OR r.%col% = :pv)
                  AND (CAST(:acc AS uuid) IS NULL OR r.account_id = :acc)
                  AND (CAST(:st AS smallint) IS NULL OR r.status = :st)
                  AND (CAST(:from AS date) IS NULL OR r.bill_date >= :from)
                  AND (CAST(:to AS date) IS NULL OR r.bill_date <= :to)
                ORDER BY r.bill_date DESC, r.bill_no
                LIMIT :limit
                """.replace("%tbl%", table).replace("%col%", partyCol).replace("%ptbl%", partyTable);
        var q = em.createNativeQuery(sql)
                .setParameter("pv", partyValue)
                .setParameter("acc", accountId)
                .setParameter("st", status)
                .setParameter("from", dateFrom)
                .setParameter("to", dateTo)
                .setParameter("limit", limit);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = q.getResultList();
        return rows.stream().map(r -> new FinanceDocReportRow(
                (UUID) r[0], (String) r[1], ((java.sql.Date) r[2]).toLocalDate(),
                r[3] == null ? null : (UUID) r[3], (String) r[4],
                r[5] == null ? null : (UUID) r[5], (String) r[6],
                (BigDecimal) r[7], (BigDecimal) r[8],
                r[9] == null ? null : ((Number) r[9]).shortValue(),
                (String) r[10]
        )).toList();
    }

    /** F 销售收款汇总（按 client/月 上卷）。 */
    @Transactional(readOnly = true)
    public List<FinanceDocSummaryRow> receiptsSummary(UUID clientId, LocalDate dateFrom, LocalDate dateTo, int limit) {
        return docSummary("finance_receipts", "client_id", clientId, dateFrom, dateTo, limit, true);
    }

    /** H 采购付款汇总（按 supplier/月）。 */
    @Transactional(readOnly = true)
    public List<FinanceDocSummaryRow> paymentsSummary(UUID supplierId, LocalDate dateFrom, LocalDate dateTo, int limit) {
        return docSummary("finance_payments", "supplier_id", supplierId, dateFrom, dateTo, limit, false);
    }

    private List<FinanceDocSummaryRow> docSummary(String table, String partyCol, UUID partyValue,
                                                  LocalDate dateFrom, LocalDate dateTo, int limit,
                                                  boolean isClient) {
        String partyTable = isClient ? "clients" : "suppliers";
        String sql = """
                SELECT date_trunc('month', r.bill_date)::date AS ym,
                       r.%col% AS party_id, p.name AS party_name,
                       COUNT(*) AS cnt, SUM(r.amount_original), SUM(r.amount_local)
                FROM %tbl% r LEFT JOIN %ptbl% p ON p.id = r.%col%
                WHERE r.is_deleted = false
                  AND (CAST(:pv AS uuid) IS NULL OR r.%col% = :pv)
                  AND (CAST(:from AS date) IS NULL OR r.bill_date >= :from)
                  AND (CAST(:to AS date) IS NULL OR r.bill_date <= :to)
                GROUP BY 1, 2, 3
                ORDER BY 1 DESC, 2
                LIMIT :limit
                """.replace("%tbl%", table).replace("%col%", partyCol).replace("%ptbl%", partyTable);
        var q = em.createNativeQuery(sql)
                .setParameter("pv", partyValue)
                .setParameter("from", dateFrom)
                .setParameter("to", dateTo)
                .setParameter("limit", limit);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = q.getResultList();
        return rows.stream().map(r -> new FinanceDocSummaryRow(
                r[0] == null ? null : ((java.sql.Date) r[0]).toLocalDate(),
                r[1] == null ? null : (UUID) r[1],
                (String) r[2],
                null, null, null, null,
                ((Number) r[3]).longValue(),
                (BigDecimal) r[4], (BigDecimal) r[5]
        )).toList();
    }

    // ===================== C. 费用收入类 =====================

    /** M 一般费用明细（expenses + accounts；明细按部门/项目见 items）。 */
    @Transactional(readOnly = true)
    public List<FinanceDocReportRow> expensesDetail(UUID accountId, UUID departmentId, Short status,
                                                    LocalDate dateFrom, LocalDate dateTo, int limit) {
        String sql = """
                SELECT e.id, e.bill_no, e.bill_date, NULL AS party_id, NULL AS party_name,
                       e.account_id, a.name AS account_name, e.amount_original, e.amount_local, e.status, e.remark
                FROM finance_expenses e LEFT JOIN accounts a ON a.id = e.account_id
                WHERE e.is_deleted = false
                  AND (CAST(:acc AS uuid) IS NULL OR e.account_id = :acc)
                  AND (CAST(:st AS smallint) IS NULL OR e.status = :st)
                  AND (CAST(:from AS date) IS NULL OR e.bill_date >= :from)
                  AND (CAST(:to AS date) IS NULL OR e.bill_date <= :to)
                ORDER BY e.bill_date DESC, e.bill_no
                LIMIT :limit
                """;
        var q = em.createNativeQuery(sql)
                .setParameter("acc", accountId)
                .setParameter("st", status)
                .setParameter("from", dateFrom)
                .setParameter("to", dateTo)
                .setParameter("limit", limit);
        return mapDocRows(q.getResultList(), departmentId == null);
    }

    /** O 其它收入明细。 */
    @Transactional(readOnly = true)
    public List<FinanceDocReportRow> incomesDetail(UUID accountId, UUID departmentId, Short status,
                                                   LocalDate dateFrom, LocalDate dateTo, int limit) {
        String sql = """
                SELECT o.id, o.bill_no, o.bill_date, NULL AS party_id, NULL AS party_name,
                       o.account_id, a.name AS account_name, o.amount_original, o.amount_local, o.status, o.remark
                FROM finance_other_incomes o LEFT JOIN accounts a ON a.id = o.account_id
                WHERE o.is_deleted = false
                  AND (CAST(:acc AS uuid) IS NULL OR o.account_id = :acc)
                  AND (CAST(:st AS smallint) IS NULL OR o.status = :st)
                  AND (CAST(:from AS date) IS NULL OR o.bill_date >= :from)
                  AND (CAST(:to AS date) IS NULL OR o.bill_date <= :to)
                ORDER BY o.bill_date DESC, o.bill_no
                LIMIT :limit
                """;
        var q = em.createNativeQuery(sql)
                .setParameter("acc", accountId)
                .setParameter("st", status)
                .setParameter("from", dateFrom)
                .setParameter("to", dateTo)
                .setParameter("limit", limit);
        return mapDocRows(q.getResultList(), departmentId == null);
    }

    @SuppressWarnings("unchecked")
    private List<FinanceDocReportRow> mapDocRows(List<Object[]> rows, boolean ignoreDepartment) {
        return rows.stream().map(r -> new FinanceDocReportRow(
                (UUID) r[0], (String) r[1], ((java.sql.Date) r[2]).toLocalDate(),
                r[3] == null ? null : (UUID) r[3], (String) r[4],
                r[5] == null ? null : (UUID) r[5], (String) r[6],
                (BigDecimal) r[7], (BigDecimal) r[8],
                r[9] == null ? null : ((Number) r[9]).shortValue(),
                (String) r[10]
        )).toList();
    }

    /** N 一般费用汇总（按 月 × 部门 × 费用项目 上卷；查 items 表）。 */
    @Transactional(readOnly = true)
    public List<FinanceDocSummaryRow> expensesSummary(UUID departmentId, UUID expenseStyleId,
                                                      LocalDate dateFrom, LocalDate dateTo, int limit) {
        return itemsSummary("finance_expense_items", "expense_style_id",
                departmentId, expenseStyleId, dateFrom, dateTo, limit);
    }

    /** P 其它收入汇总（按 月 × 部门 × 收入项目 上卷）。 */
    @Transactional(readOnly = true)
    public List<FinanceDocSummaryRow> incomesSummary(UUID departmentId, UUID incomeStyleId,
                                                     LocalDate dateFrom, LocalDate dateTo, int limit) {
        return itemsSummary("finance_other_income_items", "income_style_id",
                departmentId, incomeStyleId, dateFrom, dateTo, limit);
    }

    private List<FinanceDocSummaryRow> itemsSummary(String itemsTable, String styleCol,
                                                    UUID departmentId, UUID styleId,
                                                    LocalDate dateFrom, LocalDate dateTo, int limit) {
        String sql = """
                SELECT date_trunc('month', i.bill_date)::date AS ym,
                       i.department_id, d.name AS dept_name,
                       i.%style% AS style_id, ps.name AS style_name,
                       COUNT(*) AS cnt, SUM(i.amount_original), SUM(i.amount_local)
                FROM %tbl% i
                LEFT JOIN departments d ON d.id = i.department_id
                LEFT JOIN payment_styles ps ON ps.id = i.%style%
                WHERE COALESCE(i.is_deleted, false) = false
                  AND (CAST(:dept AS uuid) IS NULL OR i.department_id = :dept)
                  AND (CAST(:style AS uuid) IS NULL OR i.%style% = :style)
                  AND (CAST(:from AS date) IS NULL OR i.bill_date >= :from)
                  AND (CAST(:to AS date) IS NULL OR i.bill_date <= :to)
                GROUP BY 1, 2, 3, 4, 5
                ORDER BY 1 DESC, 2, 4
                LIMIT :limit
                """.replace("%tbl%", itemsTable).replace("%style%", styleCol);
        var q = em.createNativeQuery(sql)
                .setParameter("dept", departmentId)
                .setParameter("style", styleId)
                .setParameter("from", dateFrom)
                .setParameter("to", dateTo)
                .setParameter("limit", limit);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = q.getResultList();
        return rows.stream().map(r -> new FinanceDocSummaryRow(
                r[0] == null ? null : ((java.sql.Date) r[0]).toLocalDate(),
                null, null,
                r[1] == null ? null : (UUID) r[1], (String) r[2],
                r[3] == null ? null : (UUID) r[3], (String) r[4],
                ((Number) r[5]).longValue(),
                (BigDecimal) r[6], (BigDecimal) r[7]
        )).toList();
    }

    // ===================== D. 账户流水类 =====================

    /** S 帐户进出流水帐（finance_reconciliations 滚动余额，必填 accountId）。 */
    @Transactional(readOnly = true)
    public List<AccountStatementRow> accountStatement(UUID accountId,
                                                      OffsetDateTime dateFrom, OffsetDateTime dateTo, int limit) {
        if (accountId == null) return List.of();
        var q = em.createNativeQuery("""
                SELECT r.id, r.bill_date, r.bill_no, r.source_doc_type, r.counterpart_name, r.check_no,
                       r.in_amount, r.out_amount
                FROM finance_reconciliations r
                WHERE r.is_deleted = false
                  AND r.account_id = :acc
                  AND (CAST(:from AS date) IS NULL OR r.bill_date >= :from)
                  AND (CAST(:to AS date) IS NULL OR r.bill_date <= :to)
                ORDER BY r.bill_date ASC, r.bill_no ASC
                LIMIT :limit
                """)
                .setParameter("acc", accountId)
                .setParameter("from", dateFrom)
                .setParameter("to", dateTo)
                .setParameter("limit", limit);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = q.getResultList();
        List<AccountStatementRow> out = new ArrayList<>(rows.size());
        BigDecimal running = BigDecimal.ZERO;
        for (Object[] r : rows) {
            BigDecimal inAmt = r[6] == null ? BigDecimal.ZERO : (BigDecimal) r[6];
            BigDecimal outAmt = r[7] == null ? BigDecimal.ZERO : (BigDecimal) r[7];
            running = running.add(inAmt).subtract(outAmt);
            out.add(new AccountStatementRow(
                    (UUID) r[0], toOdt(r[1]), (String) r[2], (String) r[3], (String) r[4], (String) r[5],
                    inAmt, outAmt, running));
        }
        return out;
    }

    /** TIMESTAMPTZ 列在 Hibernate 中常返回为 OffsetDateTime；某些驱动返回 Timestamp，统一兼容。 */
    private static OffsetDateTime toOdt(Object v) {
        if (v == null) return null;
        if (v instanceof OffsetDateTime odt) return odt;
        if (v instanceof Timestamp ts) return ts.toInstant().atOffset(OffsetDateTime.now().getOffset());
        if (v instanceof java.util.Date d) return d.toInstant().atOffset(OffsetDateTime.now().getOffset());
        return null;
    }
}
