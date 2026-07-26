package com.uten.imp.features.subcontract.report;

import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/**
 * 委外报表查询（design doc 22 §6.1，17 张老库报表收敛为参数化查询）。
 *
 * <ul>
 *   <li>月度汇总（{@link #monthly}）：查 {@code subcontract_monthly_mv} 按维度上卷（涵盖 8 类单据）。
 *       覆盖老库"汇总报表 ×8"。docType 取值：INQUIRY/APPLICATION/ORDER/RECEIPT/RETURN/
 *       MATERIAL_ISSUE/MATERIAL_RETURN/WASTE。</li>
 *   <li>委外出入状况表（{@link #inOutStatus}）：按 委外商×货品 汇总发料/收回/退/损耗/净额
 *       （design doc 22 §6.3，复刻老库 View_E_InOutStatus）。</li>
 * </ul>
 *
 * <p><b>明细报表 ×8</b> 复用 {@code /api/subcontract/{doc}} 列表（已支持日期/供应商/状态过滤），
 * 不在本服务重复。MV 由 V54 建，需定期 REFRESH MATERIALIZED VIEW CONCURRENTLY
 * （{@code refresh_subcontract_monthly_mv()}）；数据非严格实时，明细列表兜底实时。
 *
 * <p>权限点：{@code subcontract_report:view}（V53 seed，全员可查）。
 */
@Service
@RequiredArgsConstructor
public class SubcontractReportService {

    private static final UUID NIL = UUID.fromString("00000000-0000-0000-0000-000000000000");

    private final EntityManager em;

    /**
     * 月度汇总：按 货品×供应商×类型 上卷，过滤 docType + 日期范围（ym）。
     * 覆盖老库 8 张汇总报表（按 docType 切换）。
     */
    @Transactional(readOnly = true)
    public List<SubcontractMonthlyRow> monthly(String docType, LocalDate dateFrom, LocalDate dateTo, int limit) {
        var q = em.createNativeQuery("""
                SELECT doc_type, ym, goods_id, supplier_id,
                       SUM(qty_sum) AS qty, SUM(amt_local) AS amt, SUM(line_cnt) AS lines
                FROM subcontract_monthly_mv
                WHERE (:docType IS NULL OR doc_type = :docType)
                  AND (CAST(:from AS date) IS NULL OR ym >= :from)
                  AND (CAST(:to AS date) IS NULL OR ym <= :to)
                GROUP BY doc_type, ym, goods_id, supplier_id
                ORDER BY amt DESC NULLS LAST
                LIMIT :limit
                """);
        q.setParameter("docType", docType);
        q.setParameter("from", dateFrom);
        q.setParameter("to", dateTo);
        q.setParameter("limit", limit);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = q.getResultList();
        return rows.stream().map(r -> new SubcontractMonthlyRow(
                (String) r[0],
                ((java.sql.Date) r[1]).toLocalDate(),
                (java.util.UUID) r[2],
                NIL.equals(r[3]) ? null : (java.util.UUID) r[3],
                (BigDecimal) r[4],
                (BigDecimal) r[5],
                ((Number) r[6]).longValue()
        )).toList();
    }

    /**
     * 委外出入状况表（综合 O · design doc 22 §6.3）：按 委外商×货品 汇总
     * 发料(15)/材料退(16)/收回成品(17)/成品退(18)/损耗(19) 数量。
     *
     * <p>实现：JOIN stock_movements 与各委外单据主表带出 supplier_id（流水本身不存），
     * 按 supplier × goods 维度 SUM(CASE WHEN movement_type=N THEN qty ELSE 0 END)。
     */
    @Transactional(readOnly = true)
    public List<SubcontractInOutRow> inOutStatus(UUID supplierId, LocalDate dateFrom, LocalDate dateTo, int limit) {
        var q = em.createNativeQuery("""
                SELECT supplier_id, goods_id,
                       SUM(CASE WHEN movement_type = 15 THEN signed_qty ELSE 0 END) AS issue_qty,
                       SUM(CASE WHEN movement_type = 16 THEN signed_qty ELSE 0 END) AS m_return_qty,
                       SUM(CASE WHEN movement_type = 17 THEN signed_qty ELSE 0 END) AS receipt_qty,
                       SUM(CASE WHEN movement_type = 18 THEN signed_qty ELSE 0 END) AS return_qty,
                       SUM(CASE WHEN movement_type = 19 THEN signed_qty ELSE 0 END) AS waste_qty
                FROM (
                    SELECT m.movement_type, m.goods_id, m.transaction_date,
                           m.qty * CAST(m.direction AS NUMERIC) AS signed_qty, d.supplier_id
                    FROM stock_movements m
                    JOIN (
                        SELECT id, supplier_id FROM subcontract_material_issues  WHERE COALESCE(is_deleted,false)=false
                        UNION ALL
                        SELECT id, supplier_id FROM subcontract_material_returns  WHERE COALESCE(is_deleted,false)=false
                        UNION ALL
                        SELECT id, supplier_id FROM subcontract_receipts         WHERE COALESCE(is_deleted,false)=false
                        UNION ALL
                        SELECT id, supplier_id FROM subcontract_returns           WHERE COALESCE(is_deleted,false)=false
                        UNION ALL
                        SELECT id, supplier_id FROM subcontract_wastes            WHERE COALESCE(is_deleted,false)=false
                    ) d ON d.id = m.source_doc_id
                    WHERE m.movement_type BETWEEN 15 AND 19
                ) s
                WHERE (:supplierId IS NULL OR supplier_id = :supplierId)
                  AND (:from IS NULL OR transaction_date >= CAST(:from AS timestamptz))
                  AND (:to   IS NULL OR transaction_date <  CAST(:to AS timestamptz) + interval '1 day')
                GROUP BY supplier_id, goods_id
                ORDER BY issue_qty DESC NULLS LAST, receipt_qty DESC NULLS LAST
                LIMIT :limit
                """);
        q.setParameter("supplierId", supplierId);
        q.setParameter("from", dateFrom);
        q.setParameter("to", dateTo);
        q.setParameter("limit", limit);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = q.getResultList();
        return rows.stream().map(r -> new SubcontractInOutRow(
                NIL.equals(r[0]) ? null : (java.util.UUID) r[0],
                (java.util.UUID) r[1],
                toBd(r[2]), toBd(r[3]), toBd(r[4]), toBd(r[5]), toBd(r[6])
        )).toList();
    }

    private static BigDecimal toBd(Object o) {
        return o == null ? BigDecimal.ZERO : (BigDecimal) o;
    }
}
