package com.uten.imp.features.production.analysis;

import com.uten.imp.common.saleschain.SalesOrderChainSql;
import com.uten.imp.common.util.NativeValueConverters;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/**
 * 物料分析「关联销售订单 → 订单货品清单」只读投影(ADR-088)。
 *
 * <p>计划员从物料分析顶部卡片点订单编号进来，只是想核对"这张单到底订了些什么货"。
 * 因此本服务<b>不复用销售订单详情</b>：
 * <ul>
 *   <li>权限只要 {@code production_material_analysis:view}，不要求 {@code sales_order:view}；</li>
 *   <li>作为交换，<b>两道闸都要过</b>：先按物料分析的对象级范围判定调用方能不能读这张分析
 *       ({@link MaterialAnalysisService#requireReadableAnalysis}，按 maker_id 隔离，
 *       跨制单人需 {@code production_plan:view:all})，再判定 orderId 是不是真被这张分析引用。
 *       只做后者等于「拿别人的分析 id 当通行证」——分析详情 404 而附属只读页 200，是越权；</li>
 *   <li>一律不返回单价 / 金额 / 折扣——生产口径看不到销售价格。
 *       单头备注同样不返回：销售备注是自由文本，现实中常写折扣与付款条件。</li>
 * </ul>
 *
 * <p>返回的是订单的<b>全部</b>货品行(含已交付完的行)，因为"货品清单"要的是完整的单，
 * 不是待办队列；每行额外带链路数量，让计划员一眼看出哪几行还要生产。
 */
@Service
@RequiredArgsConstructor
public class AnalysisLinkedSalesOrderService {

    private final EntityManager em;
    private final MaterialAnalysisService analyses;

    /** 订单头 + 货品行(行按行号升序)。 */
    public record LinkedSalesOrderView(
            UUID orderId,
            String billNo,
            LocalDate billDate,
            LocalDate deliverDate,
            UUID clientId,
            String clientName,
            String sellerName,
            Short status,
            boolean financeConfirmed,
            boolean closed,
            boolean stopped,
            List<LinkedSalesOrderLine> lines) {
    }

    /** 订单货品行(纯数量口径，无任何价格字段)。 */
    public record LinkedSalesOrderLine(
            UUID orderItemId,
            Integer lineNo,
            UUID goodsId,
            String goodsCode,
            String goodsName,
            String spec,
            UUID colorId,
            String colorName,
            UUID unitId,
            String unitName,
            BigDecimal qty,
            BigDecimal shippedQty,
            BigDecimal returnedQty,
            BigDecimal flagQty,
            BigDecimal outstandingQty,
            BigDecimal reservedQty,
            BigDecimal plannedQty,
            BigDecimal producedQty,
            BigDecimal unplannedQty,
            LocalDate deliverDate,
            Short chainStatus,
            /** 本行是否就是当前这张物料分析的来源行(前端把这些行高亮出来)。 */
            boolean inAnalysis) {
    }

    /**
     * 取该分析关联的某张销售订单的货品清单。
     *
     * @throws ApiException NOT_FOUND 当分析不可读、订单不存在，或该订单并未被这张分析引用
     */
    @Transactional(readOnly = true)
    public LinkedSalesOrderView linkedOrder(UUID analysisId, UUID orderId) {
        // 闸一：本人能不能读这张分析(对象级范围)。闸二：这张订单属不属于这张分析。
        analyses.requireReadableAnalysis(analysisId);
        requireLinked(analysisId, orderId);
        Header head = header(orderId);
        return new LinkedSalesOrderView(
                orderId, head.billNo(), head.billDate(), head.deliverDate(),
                head.clientId(), head.clientName(), head.sellerName(),
                head.status(), head.financeConfirmed(), head.closed(), head.stopped(),
                lines(analysisId, orderId));
    }

    /**
     * 越权闸二：orderId 必须经 sales_order_items 反查回同一张分析的来源行。
     *
     * <p>刻意不过滤 {@code sales_item.is_deleted}：来源行事后被软删不改变
     * 「这张分析确实引用过这张订单」这个历史事实，历史分析页不应因此变 404。
     */
    private void requireLinked(UUID analysisId, UUID orderId) {
        Object hit = em.createNativeQuery("""
                SELECT COUNT(*)
                FROM production_material_analysis_items analysis_item
                JOIN production_material_analyses analysis
                  ON analysis.id = analysis_item.analysis_id
                 AND analysis.is_deleted = FALSE
                JOIN sales_order_items sales_item
                  ON sales_item.id = analysis_item.sales_order_item_id
                WHERE analysis_item.analysis_id = :analysisId
                  AND analysis_item.is_deleted = FALSE
                  AND sales_item.order_id = :orderId
                """)
                .setParameter("analysisId", analysisId)
                .setParameter("orderId", orderId)
                .getSingleResult();
        if (((Number) hit).intValue() == 0) {
            throw new ApiException(ErrorCode.NOT_FOUND, "该销售订货单不在本次物料分析的来源范围内");
        }
    }

    private record Header(String billNo, LocalDate billDate, LocalDate deliverDate,
                          UUID clientId, String clientName, String sellerName,
                          Short status, boolean financeConfirmed,
                          boolean closed, boolean stopped) {
    }

    /** 单头事实(无备注、无金额)。跟单员按老库回落：迁移单据只有 seller_legacy_id。 */
    private Header header(UUID orderId) {
        @SuppressWarnings("unchecked")
        List<Object[]> rs = em.createNativeQuery("""
                SELECT o.bill_no, o.bill_date, o.deliver_date, o.client_id, c.name,
                       seller.full_name, o.status, COALESCE(o.finance_confirmed, FALSE),
                       COALESCE(o.is_closed, FALSE), COALESCE(o.is_stopped, FALSE)
                FROM sales_orders o
                LEFT JOIN clients c ON c.id = o.client_id
                LEFT JOIN employees seller
                       ON seller.id = o.seller_id
                       OR (o.seller_id IS NULL AND seller.legacy_id = o.seller_legacy_id)
                WHERE o.id = :orderId AND o.is_deleted = FALSE
                """)
                .setParameter("orderId", orderId)
                .getResultList();
        if (rs.isEmpty()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "销售订货单不存在");
        }
        Object[] r = rs.getFirst();
        return new Header((String) r[0], date(r[1]), date(r[2]), (UUID) r[3], (String) r[4],
                (String) r[5], r[6] == null ? null : ((Number) r[6]).shortValue(),
                Boolean.TRUE.equals(r[7]), Boolean.TRUE.equals(r[8]), Boolean.TRUE.equals(r[9]));
    }

    private List<LinkedSalesOrderLine> lines(UUID analysisId, UUID orderId) {
        @SuppressWarnings("unchecked")
        List<Object[]> rs = em.createNativeQuery("""
                SELECT i.id, i.line_no, i.goods_id, g.code, g.name, g.spec,
                       i.color_id, col.name, i.unit_id, u.name,
                       COALESCE(i.qty,0), COALESCE(i.shipped_qty,0),
                       COALESCE(i.returned_qty,0), COALESCE(i.flag_qty,0),
                       %s AS outstanding,
                       COALESCE(i.reserved_qty,0), COALESCE(i.planned_qty,0),
                       COALESCE(i.produced_qty,0),
                       %s AS unplanned,
                       COALESCE(i.deliver_date, o.deliver_date) AS deliver,
                       i.chain_status,
                       EXISTS (
                           SELECT 1 FROM production_material_analysis_items analysis_item
                           WHERE analysis_item.analysis_id = :analysisId
                             AND analysis_item.sales_order_item_id = i.id
                             AND analysis_item.is_deleted = FALSE) AS in_analysis
                FROM sales_order_items i
                JOIN sales_orders o ON o.id = i.order_id
                JOIN goods g ON g.id = i.goods_id
                LEFT JOIN colors col ON col.id = i.color_id
                LEFT JOIN units u ON u.id = i.unit_id
                WHERE i.order_id = :orderId AND i.is_deleted = FALSE
                ORDER BY i.line_no NULLS LAST, g.code, i.id
                """.formatted(SalesOrderChainSql.outstandingSql("i"),
                        SalesOrderChainSql.unplannedQtySql("i")))
                .setParameter("analysisId", analysisId)
                .setParameter("orderId", orderId)
                .getResultList();
        List<LinkedSalesOrderLine> out = new ArrayList<>(rs.size());
        for (Object[] r : rs) {
            out.add(new LinkedSalesOrderLine(
                    (UUID) r[0], r[1] == null ? null : ((Number) r[1]).intValue(),
                    (UUID) r[2], (String) r[3], (String) r[4], (String) r[5],
                    (UUID) r[6], (String) r[7], (UUID) r[8], (String) r[9],
                    bd(r[10]), bd(r[11]), bd(r[12]), bd(r[13]), bd(r[14]),
                    bd(r[15]), bd(r[16]), bd(r[17]), bd(r[18]),
                    date(r[19]), r[20] == null ? null : ((Number) r[20]).shortValue(),
                    Boolean.TRUE.equals(r[21])));
        }
        return out;
    }

    private static BigDecimal bd(Object value) {
        return value == null ? BigDecimal.ZERO : new BigDecimal(value.toString());
    }

    private static LocalDate date(Object value) {
        return value == null ? null : NativeValueConverters.toLocalDate(value);
    }
}
