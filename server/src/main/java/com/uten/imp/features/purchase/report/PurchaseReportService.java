package com.uten.imp.features.purchase.report;

import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/**
 * 采购报表查询：月度汇总（查 purchase_monthly_mv 上卷）+ 待交货汇总（查 purchase_order_pending_v）。
 *
 * <p>明细报表复用 /api/purchase/{doc} 列表（已支持日期/供应商/状态过滤）。名称前端解析。
 * MV 需定期刷新（refresh_purchase_monthly_mv()），数据非严格实时；明细列表兜底实时。
 */
@Service
@RequiredArgsConstructor
public class PurchaseReportService {

    private static final UUID NIL = UUID.fromString("00000000-0000-0000-0000-000000000000");

    private final EntityManager em;

    /** 月度汇总：按 货品×供应商×类型 上卷，过滤 docType + 日期范围（ym）。 */
    @Transactional(readOnly = true)
    public List<MonthlySummaryRow> monthly(String docType, LocalDate dateFrom, LocalDate dateTo, int limit) {
        var q = em.createNativeQuery("""
                SELECT doc_type, ym, goods_id, supplier_id,
                       SUM(qty_sum) AS qty, SUM(amt_local) AS amt, SUM(line_cnt) AS lines
                FROM purchase_monthly_mv
                WHERE (:docType IS NULL OR doc_type = :docType)
                  AND (:from IS NULL OR ym >= :from)
                  AND (:to IS NULL OR ym <= :to)
                GROUP BY doc_type, goods_id, supplier_id
                ORDER BY amt DESC NULLS LAST
                LIMIT :limit
                """);
        q.setParameter("docType", docType);
        q.setParameter("from", dateFrom);
        q.setParameter("to", dateTo);
        q.setParameter("limit", limit);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = q.getResultList();
        return rows.stream().map(r -> new MonthlySummaryRow(
                (String) r[0],
                ((java.sql.Date) r[1]).toLocalDate(),
                (java.util.UUID) r[2],
                NIL.equals(r[3]) ? null : (java.util.UUID) r[3],
                (BigDecimal) r[4],
                (BigDecimal) r[5],
                ((Number) r[6]).longValue()
        )).toList();
    }

    /** 待交货订货汇总（订货-已收+已退>0），按货品×颜色。 */
    @Transactional(readOnly = true)
    public List<PendingRow> pending(int limit) {
        var q = em.createNativeQuery("""
                SELECT goods_id, color_id, pending_qty, pending_amt
                FROM purchase_order_pending_v
                ORDER BY pending_qty DESC
                LIMIT :limit
                """);
        q.setParameter("limit", limit);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = q.getResultList();
        return rows.stream().map(r -> new PendingRow(
                (java.util.UUID) r[0],
                (java.util.UUID) r[1],
                (BigDecimal) r[2],
                (BigDecimal) r[3]
        )).toList();
    }
}
