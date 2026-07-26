package com.uten.imp.features.sales.report;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.UUID;

/**
 * 销售报表查询（销售管理）。
 *
 * <p>三类入口（参数化覆盖 5 单据类型）：
 * <ol>
 *   <li>{@link #detail} 明细报表：按 docType 路由到对应明细表（报价/订货/出货/其它出货/退货），
 *       带日期/客户/货品/单号/状态过滤 + 分页。命中明细表 bill_date 索引，毫秒级。</li>
 *   <li>{@link #monthly} 月度汇总：查 {@code sales_monthly_mv} 物化视图，按 docType/clientId/goodsId/ym 过滤，
 *       上卷到货品×客户×类型×月。MV 需定期刷新（{@code refresh_sales_monthly_mv()}），非严格实时。</li>
 *   <li>{@link #pending} 待交货订货汇总：查 {@code sales_order_pending_v} 视图
 *       （未发数量 = qty - shipped_qty + returned_qty - flag_qty > 0），生产计划/采购驱动入口。</li>
 * </ol>
 *
 * <p>所有名称（货品/客户/分类）由前端解析（与采购报表同范式），后端只返 id + 量 + 额。
 */
@Service
@RequiredArgsConstructor
public class SalesReportService {

    private static final UUID NIL = UUID.fromString("00000000-0000-0000-0000-000000000000");

    /** doc_type 字典（与 V52 sales_monthly_mv 对齐）。 */
    public static final String DOC_QUOTE = "QUOTE";
    public static final String DOC_ORDER = "ORDER";
    public static final String DOC_SHIPMENT = "SHIPMENT";
    public static final String DOC_OTHER_SHIPMENT = "OTHER_SHIPMENT";
    public static final String DOC_RETURN = "RETURN";

    private static final Set<String> DOC_TYPES = Set.of(
            DOC_QUOTE, DOC_ORDER, DOC_SHIPMENT, DOC_OTHER_SHIPMENT, DOC_RETURN);

    private final EntityManager em;

    // ======================== 明细报表 ========================

    /**
     * 明细报表：按 docType 路由到对应明细表。5 类共用同结构返回（{@link SalesDetailRow}）。
     *
     * @param docType QUOTE / ORDER / SHIPMENT / OTHER_SHIPMENT / RETURN（不区分大小写）
     */
    @Transactional(readOnly = true)
    public PageResponse<SalesDetailRow> detail(String docType, String billNo, UUID clientId, UUID goodsId,
                                                Short status, LocalDate dateFrom, LocalDate dateTo,
                                                int page, int size) {
        String dt = normalizeDocType(docType);
        int safePage = Math.max(1, page);
        int safeSize = Math.min(Math.max(1, size), 500);
        long offset = (long) (safePage - 1) * safeSize;

        DetailTables tbl = tablesOf(dt);
        StringBuilder where = new StringBuilder(
                "WHERE COALESCE(i.is_deleted, false) = false AND COALESCE(o.is_deleted, false) = false");
        if (billNo != null && !billNo.isBlank()) where.append(" AND i.bill_no LIKE :billNo");
        if (clientId != null) where.append(" AND o.client_id = :clientId");
        if (goodsId != null) where.append(" AND i.goods_id = :goodsId");
        if (status != null) where.append(" AND o.status = :status");
        if (dateFrom != null) where.append(" AND i.bill_date >= :dateFrom");
        if (dateTo != null) where.append(" AND i.bill_date <= :dateTo");
        String whereSql = where.toString();

        String baseSelect = """
                SELECT i.id, i.bill_no, i.bill_date, o.client_id, i.goods_id, i.color_id, i.unit_id,
                       i.line_no, i.qty, i.price, i.amount_original, i.amount_local, i.remark
                FROM %s i JOIN %s o ON o.id = i.%s
                """.formatted(tbl.item(), tbl.header(), tbl.fk());

        var dataQ = em.createNativeQuery(baseSelect + whereSql + " ORDER BY i.bill_date DESC, i.line_no NULLS LAST LIMIT :limit OFFSET :offset");
        var countQ = em.createNativeQuery("SELECT COUNT(*) FROM %s i JOIN %s o ON o.id = i.%s ".formatted(tbl.item(), tbl.header(), tbl.fk()) + whereSql);

        if (billNo != null && !billNo.isBlank()) {
            dataQ.setParameter("billNo", "%" + billNo + "%");
            countQ.setParameter("billNo", "%" + billNo + "%");
        }
        if (clientId != null) { dataQ.setParameter("clientId", clientId); countQ.setParameter("clientId", clientId); }
        if (goodsId != null)  { dataQ.setParameter("goodsId", goodsId);   countQ.setParameter("goodsId", goodsId); }
        if (status != null)   { dataQ.setParameter("status", status);     countQ.setParameter("status", status); }
        if (dateFrom != null) { dataQ.setParameter("dateFrom", dateFrom); countQ.setParameter("dateFrom", dateFrom); }
        if (dateTo != null)   { dataQ.setParameter("dateTo", dateTo);     countQ.setParameter("dateTo", dateTo); }
        dataQ.setParameter("limit", safeSize);
        dataQ.setParameter("offset", offset);

        @SuppressWarnings("unchecked")
        List<Object[]> rows = dataQ.getResultList();
        long total = ((Number) countQ.getSingleResult()).longValue();
        int totalPages = safeSize == 0 ? 0 : (int) ((total + safeSize - 1) / safeSize);

        List<SalesDetailRow> items = rows.stream().map(r -> new SalesDetailRow(
                (UUID) r[0],
                (String) r[1],
                ((java.sql.Date) r[2]).toLocalDate(),
                r[3] == null ? null : (UUID) r[3],
                (UUID) r[4],
                r[5] == null ? null : (UUID) r[5],
                r[6] == null ? null : (UUID) r[6],
                r[7] == null ? null : ((Number) r[7]).intValue(),
                (BigDecimal) r[8],
                (BigDecimal) r[9],
                (BigDecimal) r[10],
                (BigDecimal) r[11],
                (String) r[12]
        )).toList();
        return new PageResponse<>(items, safePage, safeSize, total, totalPages);
    }

    // ======================== 月度汇总（MV） ========================

    /** 月度汇总：按 货品×客户×类型 上卷，过滤 docType + 日期范围（ym）+ 客户/货品。 */
    @Transactional(readOnly = true)
    public List<MonthlySummaryRow> monthly(String docType, UUID clientId, UUID goodsId,
                                           LocalDate dateFrom, LocalDate dateTo, int limit) {
        String dt = docType == null ? null : docType.trim().toUpperCase(Locale.ROOT);
        if (dt != null && !DOC_TYPES.contains(dt)) {
            throw new ApiException(ErrorCode.BUSINESS, "未知 docType：" + docType);
        }
        int safeLimit = Math.min(Math.max(1, limit), 2000);

        var q = em.createNativeQuery("""
                SELECT doc_type, ym, goods_id, client_id,
                       SUM(qty_sum) AS qty, SUM(amt_local) AS amt, SUM(line_cnt) AS lines
                FROM sales_monthly_mv
                WHERE (:docType IS NULL OR doc_type = :docType)
                  AND (CAST(:from AS date) IS NULL OR ym >= :from)
                  AND (CAST(:to AS date) IS NULL OR ym <= :to)
                  AND (CAST(:clientId AS uuid) IS NULL OR client_id = :clientId)
                  AND (CAST(:goodsId AS uuid) IS NULL OR goods_id = :goodsId)
                GROUP BY doc_type, ym, goods_id, client_id
                ORDER BY amt DESC NULLS LAST
                LIMIT :limit
                """);
        q.setParameter("docType", dt);
        q.setParameter("from", dateFrom);
        q.setParameter("to", dateTo);
        q.setParameter("clientId", clientId);
        q.setParameter("goodsId", goodsId);
        q.setParameter("limit", safeLimit);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = q.getResultList();
        return rows.stream().map(r -> new MonthlySummaryRow(
                (String) r[0],
                ((java.sql.Date) r[1]).toLocalDate(),
                (UUID) r[2],
                NIL.equals(r[3]) ? null : (UUID) r[3],
                (BigDecimal) r[4],
                (BigDecimal) r[5],
                ((Number) r[6]).longValue()
        )).toList();
    }

    // ======================== 待交货订货汇总 ========================

    /** 待交货订货汇总（订-发+退-扣>0），按货品×颜色×客户；可按 clientId 过滤。 */
    @Transactional(readOnly = true)
    public List<PendingRow> pending(UUID clientId, int limit) {
        int safeLimit = Math.min(Math.max(1, limit), 2000);
        String sql = """
                SELECT goods_id, color_id, client_id, pending_qty, pending_amt
                FROM sales_order_pending_v
                """;
        if (clientId != null) sql += " WHERE client_id = :clientId";
        sql += " ORDER BY pending_qty DESC LIMIT :limit";
        var q = em.createNativeQuery(sql);
        if (clientId != null) q.setParameter("clientId", clientId);
        q.setParameter("limit", safeLimit);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = q.getResultList();
        return rows.stream().map(r -> new PendingRow(
                (UUID) r[0],
                r[1] == null ? null : (UUID) r[1],
                r[2] == null ? null : (UUID) r[2],
                (BigDecimal) r[3],
                (BigDecimal) r[4]
        )).toList();
    }

    // ======================== 内部辅助 ========================

    private static String normalizeDocType(String docType) {
        if (docType == null) throw new ApiException(ErrorCode.BUSINESS, "docType 必填");
        String dt = docType.trim().toUpperCase(Locale.ROOT);
        if (!DOC_TYPES.contains(dt)) throw new ApiException(ErrorCode.BUSINESS, "未知 docType：" + docType);
        return dt;
    }

    /** 明细表 + 主表 + FK 列名（按 docType 路由；表名为代码常量，无注入风险）。 */
    private static DetailTables tablesOf(String dt) {
        return switch (dt) {
            case DOC_QUOTE -> new DetailTables("sales_quote_items", "sales_quotes", "quote_id");
            case DOC_ORDER -> new DetailTables("sales_order_items", "sales_orders", "order_id");
            case DOC_SHIPMENT -> new DetailTables("sales_shipment_items", "sales_shipments", "shipment_id");
            case DOC_OTHER_SHIPMENT -> new DetailTables("sales_other_shipment_items", "sales_other_shipments", "shipment_id");
            case DOC_RETURN -> new DetailTables("sales_return_items", "sales_returns", "return_id");
            default -> throw new ApiException(ErrorCode.BUSINESS, "未知 docType：" + dt);
        };
    }

    private record DetailTables(String item, String header, String fk) {}
}
