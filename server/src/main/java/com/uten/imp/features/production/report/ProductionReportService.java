package com.uten.imp.features.production.report;

import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/**
 * 生产报表查询（design §6.2）：4 入口。
 *
 * <ol>
 *   <li><b>生产计划明细</b> → production_plan_items JOIN production_plans（参数化分页，<b>不走 MV</b>，实时性高）</li>
 *   <li><b>生产计划汇总</b> → production_monthly_mv WHERE doc_type='PLAN'（按 货品/月/客户 上卷）</li>
 *   <li><b>生产日报明细</b> → production_daily_report_items JOIN production_daily_reports（<b>本期 0 行</b>，结构留位）</li>
 *   <li><b>生产日报汇总</b> → production_monthly_mv WHERE doc_type='DAILY'（<b>本期 0 行</b>，结构留位）</li>
 * </ol>
 *
 * <p>老库 4 张报表视图 View_F_Plan / View_F_Plan2 / View_F_DateReport* 收敛为查 production_plan_items
 * + production_monthly_mv 的 2 个参数化查询（同采购 [15] §6.1）。
 *
 * <p><b>【本期后置】</b>View_F_PlanCostItem 三分支 CASE 需购量公式（MRP）归未来 MRP 模块，本期不实现。
 *
 * <p>MV 数据非严格实时：CONCURRENTLY 刷新由每日 cron + 单据审核接口触发（design §6.1）。
 */
@Service
@RequiredArgsConstructor
public class ProductionReportService {

    private static final UUID NIL = UUID.fromString("00000000-0000-0000-0000-000000000000");

    private final EntityManager em;

    // ====================== 1. 生产计划明细（参数化分页，不走 MV） ======================

    /** 生产计划明细：按 日期/货品/状态/单号 过滤，JOIN 主表带出 delivery_date/plan_status/plan_closed。 */
    @Transactional(readOnly = true)
    public List<PlanDetailRow> planDetail(LocalDate dateFrom, LocalDate dateTo, UUID goodsId,
                                          Short status, String billNo, int page, int size) {
        var q = em.createNativeQuery("""
                SELECT i.id, i.bill_no, i.bill_date, i.plan_id, i.line_no, i.product_no,
                       i.goods_id, i.color_id, i.mgoods_id, i.unit_id, i.unit_rate,
                       i.sales_order_item_id, i.sales_order_no, i.client_name, i.client_no,
                       i.oqty, i.qty, i.lqty, i.iqty, i.fqty, i.rqty,
                       i.bqty, i.tqty, i.paqty, i.isrqty, i.cpqty, i.poqty, i.piqty,
                       p.delivery_date, i.order_date, i.outbound_date, i.plan_begin_date, i.plan_end_date,
                       i.finished_weight, i.inbound_weight,
                       i.lstatus, i.cstatus, p.status AS plan_status, p.is_closed AS plan_closed,
                       i.legacy_id, i.remark
                FROM production_plan_items i
                JOIN production_plans p ON p.id = i.plan_id
                WHERE COALESCE(i.is_deleted, false) = false
                  AND COALESCE(p.is_deleted, false) = false
                  AND (:from    IS NULL OR i.bill_date >= :from)
                  AND (:to      IS NULL OR i.bill_date <= :to)
                  AND (:goodsId IS NULL OR i.goods_id = :goodsId)
                  AND (:status  IS NULL OR p.status   = :status)
                  AND (:billNo  IS NULL OR i.bill_no  = :billNo)
                ORDER BY i.bill_date DESC, i.line_no ASC
                LIMIT :limit OFFSET :offset
                """);
        q.setParameter("from", dateFrom);
        q.setParameter("to", dateTo);
        q.setParameter("goodsId", goodsId);
        q.setParameter("status", status);
        q.setParameter("billNo", billNo);
        q.setParameter("limit", size);
        q.setParameter("offset", Math.max(0, (page - 1) * size));
        @SuppressWarnings("unchecked")
        List<Object[]> rows = q.getResultList();
        return rows.stream().map(r -> new PlanDetailRow(
                (UUID) r[0],
                (String) r[1],
                ((java.sql.Date) r[2]).toLocalDate(),
                (UUID) r[3],
                (Integer) r[4],
                (String) r[5],
                (UUID) r[6],
                (UUID) r[7],
                (UUID) r[8],
                (UUID) r[9],
                (BigDecimal) r[10],
                (UUID) r[11],
                (String) r[12],
                (String) r[13],
                (String) r[14],
                (BigDecimal) r[15],
                (BigDecimal) r[16],
                (BigDecimal) r[17],
                (BigDecimal) r[18],
                (BigDecimal) r[19],
                (BigDecimal) r[20],
                (BigDecimal) r[21],
                (BigDecimal) r[22],
                (BigDecimal) r[23],
                (BigDecimal) r[24],
                (BigDecimal) r[25],
                (BigDecimal) r[26],
                (BigDecimal) r[27],
                r[28] == null ? null : ((java.sql.Date) r[28]).toLocalDate(),
                r[29] == null ? null : ((java.sql.Date) r[29]).toLocalDate(),
                r[30] == null ? null : ((java.sql.Date) r[30]).toLocalDate(),
                r[31] == null ? null : ((java.sql.Date) r[31]).toLocalDate(),
                r[32] == null ? null : ((java.sql.Date) r[32]).toLocalDate(),
                (BigDecimal) r[33],
                (BigDecimal) r[34],
                (Short) r[35],
                (Short) r[36],
                (Short) r[37],
                (Boolean) r[38],
                (Integer) r[39],
                (String) r[40]
        )).toList();
    }

    // ====================== 2. 生产计划/日报月度汇总（MV 上卷） ======================

    /** 月度汇总：按 docType(PLAN/DAILY) + 日期范围（ym）过滤，按 货品 上卷。 */
    @Transactional(readOnly = true)
    public List<MonthlySummaryRow> monthly(String docType, LocalDate dateFrom, LocalDate dateTo, int limit) {
        var q = em.createNativeQuery("""
                SELECT doc_type, ym, goods_id, client_id,
                       SUM(plan_qty_sum)      AS plan_qty,
                       SUM(order_qty_sum)     AS order_qty,
                       SUM(finished_qty_sum)  AS finished_qty,
                       SUM(inbound_qty_sum)   AS inbound_qty,
                       SUM(line_cnt)          AS lines
                FROM production_monthly_mv
                WHERE (:docType IS NULL OR doc_type = :docType)
                  AND (CAST(:from AS date) IS NULL OR ym >= :from)
                  AND (CAST(:to AS date) IS NULL OR ym <= :to)
                GROUP BY doc_type, ym, goods_id, client_id
                ORDER BY ym DESC, plan_qty DESC NULLS LAST
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
                (UUID) r[2],
                NIL.equals(r[3]) ? null : (UUID) r[3],
                (BigDecimal) r[4],
                (BigDecimal) r[5],
                (BigDecimal) r[6],
                (BigDecimal) r[7],
                ((Number) r[8]).longValue()
        )).toList();
    }

    // ====================== 3. 生产日报明细（本期 0 行，结构留位） ======================

    /** 生产日报明细：参数化分页，<b>本期 0 行</b>（F_DateReport 老库从未启用，design §3.4）。 */
    @Transactional(readOnly = true)
    public List<DailyDetailRow> dailyDetail(LocalDate dateFrom, LocalDate dateTo, UUID goodsId,
                                            Short status, String billNo, int page, int size) {
        var q = em.createNativeQuery("""
                SELECT i.id, i.bill_no, i.bill_date, i.report_id, i.line_no,
                       i.goods_id, i.color_id, i.unit_id, i.unit_rate,
                       i.qty, i.price, i.total, i.stotal,
                       i.sales_order_item_id, i.sales_order_no,
                       i.plan_item_id, i.plan_no, i.outbound_no, i.outbound_qty, i.order_qty,
                       i.step_legacy_id, i.order_date, i.boxes, i.per_box_qty, i.weight,
                       i.client_name, h.status, i.legacy_id, i.remark
                FROM production_daily_report_items i
                JOIN production_daily_reports h ON h.id = i.report_id
                WHERE COALESCE(i.is_deleted, false) = false
                  AND COALESCE(h.is_deleted, false) = false
                  AND (:from    IS NULL OR i.bill_date >= :from)
                  AND (:to      IS NULL OR i.bill_date <= :to)
                  AND (:goodsId IS NULL OR i.goods_id = :goodsId)
                  AND (:status  IS NULL OR h.status   = :status)
                  AND (:billNo  IS NULL OR i.bill_no  = :billNo)
                ORDER BY i.bill_date DESC, i.line_no ASC
                LIMIT :limit OFFSET :offset
                """);
        q.setParameter("from", dateFrom);
        q.setParameter("to", dateTo);
        q.setParameter("goodsId", goodsId);
        q.setParameter("status", status);
        q.setParameter("billNo", billNo);
        q.setParameter("limit", size);
        q.setParameter("offset", Math.max(0, (page - 1) * size));
        @SuppressWarnings("unchecked")
        List<Object[]> rows = q.getResultList();
        return rows.stream().map(r -> new DailyDetailRow(
                (UUID) r[0],
                (String) r[1],
                ((java.sql.Date) r[2]).toLocalDate(),
                (UUID) r[3],
                (Integer) r[4],
                (UUID) r[5],
                (UUID) r[6],
                (UUID) r[7],
                (BigDecimal) r[8],
                (BigDecimal) r[9],
                (BigDecimal) r[10],
                (BigDecimal) r[11],
                (BigDecimal) r[12],
                (UUID) r[13],
                (String) r[14],
                (UUID) r[15],
                (String) r[16],
                (String) r[17],
                (BigDecimal) r[18],
                (BigDecimal) r[19],
                (Integer) r[20],
                r[21] == null ? null : ((java.sql.Date) r[21]).toLocalDate(),
                (BigDecimal) r[22],
                (BigDecimal) r[23],
                (BigDecimal) r[24],
                (String) r[25],
                (Short) r[26],
                (Integer) r[27],
                (String) r[28]
        )).toList();
    }
}
