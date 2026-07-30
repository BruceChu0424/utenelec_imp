package com.uten.imp.features.production.schedule;

import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.plan.ProductionPlan;
import com.uten.imp.features.production.plan.ProductionPlanItem;
import com.uten.imp.features.production.plan.ProductionPlanItemRepository;
import com.uten.imp.features.production.plan.ProductionPlanRepository;
import com.uten.imp.features.production.plan.PlanOrderItemLink;
import com.uten.imp.features.production.plan.PlanOrderItemLinkRepository;
import com.uten.imp.features.production.schedule.dto.MergePlanRequest;
import com.uten.imp.features.production.schedule.dto.PendingPlanRow;
import com.uten.imp.features.production.schedule.dto.ScheduleOrderLine;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 生产调度工作台服务（业务链 · 排产段，V90 docs/07-业务链路/02）。
 *
 * <p>① 待排产列表：已审订单的链路行中"待生产缺口 = qty − 预留 − 已排产 > 0"的明细，
 * 交货越近越靠前，≤3 天 urgent 标红（SOP：距离交货日期越近排序越靠前）。
 *
 * <p>② 合并排产：勾选的订单行按 货品+颜色 合并成计划行（100+50=150 一次投产），
 * 每个订单行的分摊量<b>预写</b> plan_order_item_links；计划保存为草稿，
 * 调度确认后走既有 /approve（审核时按预建 links 校验 + 回写 planned_qty，见
 * ProductionPlanService.linkOrderItems 的预建分支）。
 */
@Service
@RequiredArgsConstructor
public class ProductionScheduleService {

    private final EntityManager em;
    private final ProductionPlanRepository planRepo;
    private final ProductionPlanItemRepository itemRepo;
    private final PlanOrderItemLinkRepository linkRepo;
    private final DocNumberService docNumberService;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;

    /** 待排产订单行（服务端分页；交货升序，urgent=距交货 ≤3 天或已逾期）。
     *  keyword 模糊 订单号/客户/货品名/货品编码；dateFrom/dateTo 交货日期范围（行级优先、缺省取单头）。
     *  页码越界自动回退到最后一页。 */
    @Transactional(readOnly = true)
    public com.uten.imp.common.web.PageResponse<PendingPlanRow> pending(
            int page, int size, String keyword, LocalDate dateFrom, LocalDate dateTo) {
        int p = Math.max(1, page);
        int sz = Math.min(Math.max(1, size), 100);
        String kw = keyword == null ? "" : keyword.trim().toLowerCase();
        String filters = """
                FROM sales_order_items i
                JOIN sales_orders o ON o.id = i.order_id
                LEFT JOIN clients c ON c.id = o.client_id
                JOIN goods g ON g.id = i.goods_id
                LEFT JOIN colors col ON col.id = i.color_id
                LEFT JOIN units u ON u.id = i.unit_id
                WHERE o.is_deleted = false AND o.status = 1
                  AND o.is_closed = false AND o.is_stopped = false
                  AND i.is_deleted = false
                  AND COALESCE(i.chain_status,0) > 0 AND i.chain_status < 8
                  AND i.qty - COALESCE(i.reserved_qty,0) - COALESCE(i.planned_qty,0) > 0
                """
                + (kw.isEmpty() ? ""
                        : "  AND (LOWER(o.bill_no) LIKE :kw OR LOWER(COALESCE(c.name,'')) LIKE :kw"
                          + " OR LOWER(g.name) LIKE :kw OR LOWER(g.code) LIKE :kw)\n")
                + (dateFrom == null ? ""
                        : "  AND COALESCE(i.deliver_date, o.deliver_date) >= :dateFrom\n")
                + (dateTo == null ? ""
                        : "  AND COALESCE(i.deliver_date, o.deliver_date) <= :dateTo\n");

        var countQ = em.createNativeQuery("SELECT COUNT(*) " + filters);
        bindPendingFilters(countQ, kw, dateFrom, dateTo);
        long total = ((Number) countQ.getSingleResult()).longValue();
        int totalPages = total == 0 ? 0 : (int) ((total + sz - 1) / sz);
        if (totalPages > 0 && p > totalPages) p = totalPages; // 页码越界回退

        var dataQ = em.createNativeQuery("""
                SELECT i.id, o.id, o.bill_no, o.client_id, c.name,
                       i.goods_id, g.code, g.name, g.spec,
                       i.color_id, col.name, i.unit_id, u.name,
                       i.qty, COALESCE(i.reserved_qty,0), COALESCE(i.planned_qty,0),
                       i.qty - COALESCE(i.reserved_qty,0) - COALESCE(i.planned_qty,0) AS need,
                       COALESCE(i.deliver_date, o.deliver_date) AS deliver,
                       i.chain_status
                """ + filters
                + " ORDER BY deliver ASC NULLS LAST, o.bill_date LIMIT :lim OFFSET :off");
        bindPendingFilters(dataQ, kw, dateFrom, dateTo);
        @SuppressWarnings("unchecked")
        List<Object[]> rs = (List<Object[]>) dataQ
                .setParameter("lim", sz).setParameter("off", (p - 1) * sz)
                .getResultList();

        LocalDate warn = LocalDate.now().plusDays(3);
        List<PendingPlanRow> out = new ArrayList<>(rs.size());
        for (Object[] r : rs) {
            LocalDate deliver = r[17] == null ? null : ((java.sql.Date) r[17]).toLocalDate();
            out.add(new PendingPlanRow(
                    (UUID) r[0], (UUID) r[1], (String) r[2], (UUID) r[3], (String) r[4],
                    (UUID) r[5], (String) r[6], (String) r[7], (String) r[8],
                    (UUID) r[9], (String) r[10], (UUID) r[11], (String) r[12],
                    bd(r[13]), bd(r[14]), bd(r[15]), bd(r[16]),
                    deliver, r[18] == null ? null : ((Number) r[18]).shortValue(),
                    deliver != null && !deliver.isAfter(warn)));
        }
        return new com.uten.imp.common.web.PageResponse<>(out, p, sz, total, totalPages);
    }

    /** 绑定 pending 过滤参数（未出现的条件不绑）。 */
    private static void bindPendingFilters(jakarta.persistence.Query q, String kw,
                                           LocalDate dateFrom, LocalDate dateTo) {
        if (!kw.isEmpty()) q.setParameter("kw", "%" + kw + "%");
        if (dateFrom != null) q.setParameter("dateFrom", dateFrom);
        if (dateTo != null) q.setParameter("dateTo", dateTo);
    }

    /**
     * 合并排产：勾选订单行 → 一张草稿生产计划（同货+同色合并行）+ 预建 links。
     *
     * <p>硬校验（每行）：订单已审未结案未中止、链路行、0 < 排产量 ≤ 待生产缺口。
     * 主表交货日缺省取所选行最早交货日；product_no 自动生成（billNo-行号）。
     *
     * @return 新计划 id（前端跳详情页，调度确认后审核生效）
     */
    @Transactional
    public UUID createMergePlan(MergePlanRequest req) {
        tx.bind();

        // 1) 逐行校验并取快照（订单行 + 订单头 + 货品/单位）
        record Snap(UUID orderItemId, UUID orderId, String orderBillNo, LocalDate orderDate,
                    UUID clientId, String clientName, UUID goodsId, UUID colorId,
                    UUID unitId, BigDecimal unitRate, BigDecimal orderQty, BigDecimal need,
                    LocalDate deliver, BigDecimal planQty) {}
        List<Snap> snaps = new ArrayList<>();
        for (MergePlanRequest.Line line : req.getItems()) {
            if (line.getQty() == null || line.getQty().signum() <= 0) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "排产量必须大于 0");
            }
            Object[] r;
            try {
                r = (Object[]) em.createNativeQuery("""
                        SELECT i.id, o.id, o.bill_no, o.bill_date, o.client_id, c.name,
                               i.goods_id, i.color_id, i.unit_id, i.unit_rate, i.qty,
                               i.qty - COALESCE(i.reserved_qty,0) - COALESCE(i.planned_qty,0) AS need,
                               COALESCE(i.deliver_date, o.deliver_date)
                        FROM sales_order_items i
                        JOIN sales_orders o ON o.id = i.order_id
                        LEFT JOIN clients c ON c.id = o.client_id
                        WHERE i.id = :id AND i.is_deleted = false
                          AND o.is_deleted = false AND o.status = 1
                          AND o.is_closed = false AND o.is_stopped = false
                          AND COALESCE(i.chain_status,0) > 0
                        """).setParameter("id", line.getOrderItemId()).getSingleResult();
            } catch (jakarta.persistence.NoResultException e) {
                throw new ApiException(ErrorCode.BUSINESS,
                        "订单行不可排产（不存在/未审核/已结案/已中止）: " + line.getOrderItemId());
            }
            BigDecimal need = bd(r[11]);
            if (line.getQty().compareTo(need) > 0) {
                throw new ApiException(ErrorCode.BUSINESS,
                        "订单 " + r[2] + " 排产量超过待生产缺口（剩 "
                                + need.stripTrailingZeros().toPlainString() + "）");
            }
            snaps.add(new Snap((UUID) r[0], (UUID) r[1], (String) r[2],
                    ((java.sql.Date) r[3]).toLocalDate(), (UUID) r[4], (String) r[5],
                    (UUID) r[6], (UUID) r[7], (UUID) r[8],
                    r[9] == null ? BigDecimal.ONE : (BigDecimal) r[9], bd(r[10]), need,
                    r[12] == null ? null : ((java.sql.Date) r[12]).toLocalDate(),
                    line.getQty()));
        }

        // 2) 主表（草稿）
        LocalDate earliest = snaps.stream().map(Snap::deliver).filter(d -> d != null)
                .min(LocalDate::compareTo).orElse(null);
        ProductionPlan p = new ProductionPlan();
        p.setBillNo(docNumberService.nextNumber(DocNumberPrefix.PRODUCTION_PLAN));
        p.setBillDate(LocalDate.now());
        p.setDeliveryDate(req.getDeliveryDate() != null ? req.getDeliveryDate() : earliest);
        p.setDepartmentId(req.getDepartmentId());
        p.setWorkshopName(req.getWorkshopName());
        p.setWorkerName(req.getWorkerName());
        p.setRemark(req.getRemark());
        p.setSourceDocNo(snaps.stream().map(Snap::orderBillNo).distinct()
                .reduce((a, b) -> a + "," + b).orElse(null));
        p.setMakerId(currentUser.requireEmployeeId());
        p.setStatus((short) 0);
        planRepo.save(p);

        // 3) 按 货品+颜色 合并计划行；每订单行预建 link
        Map<String, ProductionPlanItem> byGoods = new LinkedHashMap<>();
        int auto = 0;
        for (Snap s : snaps) {
            String key = s.goodsId() + "|" + (s.colorId() == null ? "" : s.colorId());
            ProductionPlanItem it = byGoods.get(key);
            if (it == null) {
                auto++;
                it = new ProductionPlanItem();
                it.setPlanId(p.getId());
                it.setBillNo(p.getBillNo());
                it.setBillDate(p.getBillDate());
                it.setLineNo(auto);
                it.setProductNo(p.getBillNo() + "-" + auto); // 业务主键自动生成
                it.setGoodsId(s.goodsId());
                it.setColorId(s.colorId());
                it.setUnitId(s.unitId());
                it.setUnitRate(s.unitRate());
                it.setQty(BigDecimal.ZERO);
                it.setOqty(BigDecimal.ZERO);
                it.setOrderDate(s.orderDate());
                it.setOutboundDate(s.deliver());
                it.setPlanBeginDate(req.getPlanBeginDate());
                it.setPlanEndDate(req.getPlanEndDate());
                // 多来源合并行不挂单值 salesOrderItemId（N:N 走 links 表）
                byGoods.put(key, it);
            }
            it.setQty(it.getQty().add(s.planQty()));
            it.setOqty(it.getOqty().add(s.orderQty()));
            if (s.orderDate() != null && (it.getOrderDate() == null || s.orderDate().isBefore(it.getOrderDate()))) {
                it.setOrderDate(s.orderDate());
            }
            if (s.deliver() != null && (it.getOutboundDate() == null || s.deliver().isBefore(it.getOutboundDate()))) {
                it.setOutboundDate(s.deliver());
            }
            // 溯源文本：订单号去重拼接
            String no = s.orderBillNo();
            it.setSalesOrderNo(it.getSalesOrderNo() == null ? no
                    : it.getSalesOrderNo().contains(no) ? it.getSalesOrderNo()
                    : it.getSalesOrderNo() + "," + no);
            itemRepo.save(it);

            PlanOrderItemLink link = new PlanOrderItemLink();
            link.setPlanItemId(it.getId());
            link.setOrderItemId(s.orderItemId());
            link.setAllocatedQty(s.planQty());
            link.setSource(PlanOrderItemLink.SOURCE_NORMAL);
            linkRepo.save(link);
        }
        return p.getId();
    }

    // ======================== 工作台徽标：待排产计数 ========================

    /** 缺料待备料计数（PMC 采购管理徽标）：链路行状态=3 待物料（计划已审但 BOM 净需求不足）的行数。 */
    @Transactional(readOnly = true)
    public Map<String, Long> shortageCount() {
        // 单列原生查询返回标量（Long），不能当 Object[] 强转（多列才返回 Object[]）。
        Number n = (Number) em.createNativeQuery("""
                SELECT COUNT(*)
                FROM sales_order_items i
                JOIN sales_orders o ON o.id = i.order_id
                WHERE o.is_deleted = false AND o.status = 1
                  AND o.is_closed = false AND o.is_stopped = false
                  AND i.is_deleted = false AND i.chain_status = 3
                """).getSingleResult();
        return Map.of("count", n.longValue());
    }

    /** 待排产计数（生产部工作台徽标）：待排产行数 + 其中紧急（交货 ≤3 天/含逾期）+ 已逾期（交货 < 今天）行数。口径同 PENDING_SQL。 */
    @Transactional(readOnly = true)
    public Map<String, Long> pendingCount() {
        Object[] r = (Object[]) em.createNativeQuery("""
                SELECT COUNT(*),
                       COUNT(*) FILTER (WHERE COALESCE(i.deliver_date, o.deliver_date) <= CURRENT_DATE + 3),
                       COUNT(*) FILTER (WHERE COALESCE(i.deliver_date, o.deliver_date) < CURRENT_DATE)
                FROM sales_order_items i
                JOIN sales_orders o ON o.id = i.order_id
                WHERE o.is_deleted = false AND o.status = 1
                  AND o.is_closed = false AND o.is_stopped = false
                  AND i.is_deleted = false
                  AND COALESCE(i.chain_status,0) > 0 AND i.chain_status < 8
                  AND i.qty - COALESCE(i.reserved_qty,0) - COALESCE(i.planned_qty,0) > 0
                """).getSingleResult();
        return Map.of("count", ((Number) r[0]).longValue(),
                "urgent", ((Number) r[1]).longValue(),
                "overdue", ((Number) r[2]).longValue());
    }

    // ======================== 新建计划单：从订单带明细（含 BOM 零件） ========================

    /**
     * 已审订单明细 + 每行货品一层 BOM 零件清单。
     * 前端「来源订单→选行带入计划明细」弹窗数据源：勾选行带 salesOrderItemId 入计划，
     * 审核时走 ProductionPlanService.linkOrderItems 手工 1:1 link 分支，业务链闭合。
     */
    @Transactional(readOnly = true)
    public List<ScheduleOrderLine> orderLines(UUID orderId) {
        Object n = em.createNativeQuery(
                "SELECT COUNT(*) FROM sales_orders WHERE id=:id AND status=1 AND is_deleted=false")
                .setParameter("id", orderId).getSingleResult();
        if (((Number) n).intValue() == 0) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核的销售订货单可带入计划明细");
        }
        @SuppressWarnings("unchecked")
        List<Object[]> rs = em.createNativeQuery("""
                SELECT i.id, i.line_no, i.goods_id, g.code, g.name, g.spec,
                       i.color_id, col.name, i.unit_id, u.name,
                       i.qty, COALESCE(i.planned_qty,0),
                       i.qty - COALESCE(i.reserved_qty,0) - COALESCE(i.planned_qty,0) AS need,
                       COALESCE(i.deliver_date, o.deliver_date) AS deliver,
                       o.bill_no, c.name, COALESCE(i.unit_rate, 1)
                FROM sales_order_items i
                JOIN sales_orders o ON o.id = i.order_id
                LEFT JOIN clients c ON c.id = o.client_id
                JOIN goods g ON g.id = i.goods_id
                LEFT JOIN colors col ON col.id = i.color_id
                LEFT JOIN units u ON u.id = i.unit_id
                WHERE i.order_id = :orderId AND i.is_deleted = false
                ORDER BY i.line_no NULLS LAST, i.id
                """).setParameter("orderId", orderId).getResultList();
        List<ScheduleOrderLine> out = new ArrayList<>(rs.size());
        for (Object[] r : rs) {
            UUID goodsId = (UUID) r[2];
            BigDecimal need = bd(r[12]);
            BigDecimal rate = bd(r[16]).signum() > 0 ? bd(r[16]) : BigDecimal.ONE;
            out.add(new ScheduleOrderLine(
                    (UUID) r[0], r[1] == null ? null : ((Number) r[1]).intValue(),
                    goodsId, (String) r[3], (String) r[4], (String) r[5],
                    (UUID) r[6], (String) r[7], (UUID) r[8], (String) r[9],
                    bd(r[10]), bd(r[11]), need, rate,
                    r[13] == null ? null : ((java.sql.Date) r[13]).toLocalDate(),
                    (String) r[14], (String) r[15],
                    // 零件需求按基本单位折算：缺口(销售单位) × unit_rate
                    bomOf(goodsId, need.multiply(rate))));
        }
        return out;
    }

    /** 一层 BOM 零件（需求小计 = 单件用量 × 待排产缺口；onhand 全仓即时库存；selfMade=零件本身还有 BOM）。 */
    private List<ScheduleOrderLine.BomComponent> bomOf(UUID goodsId, BigDecimal need) {
        @SuppressWarnings("unchecked")
        List<Object[]> rs = em.createNativeQuery("""
                SELECT b.component_goods_id, g.code, g.name, g.spec, b.qty,
                       COALESCE(sb.onhand, 0),
                       EXISTS (SELECT 1 FROM goods_bom_items c
                               WHERE c.goods_id = b.component_goods_id AND c.is_deleted = false)
                FROM goods_bom_items b
                JOIN goods g ON g.id = b.component_goods_id
                LEFT JOIN (SELECT goods_id, SUM(qty) AS onhand FROM stock_balances GROUP BY goods_id) sb
                       ON sb.goods_id = b.component_goods_id
                WHERE b.goods_id = :g AND b.is_deleted = false
                ORDER BY g.code
                """).setParameter("g", goodsId).getResultList();
        List<ScheduleOrderLine.BomComponent> out = new ArrayList<>(rs.size());
        for (Object[] r : rs) {
            BigDecimal per = bd(r[4]);
            out.add(new ScheduleOrderLine.BomComponent(
                    (UUID) r[0], (String) r[1], (String) r[2], (String) r[3],
                    per, per.multiply(need), bd(r[5]), Boolean.TRUE.equals(r[6])));
        }
        return out;
    }

    // ======================== D2 建议完工日期 ========================

    /** 建议完工日期（韩焕超）：按 历史日均完工(近 180 天报工) 推天数 + BOM 层级缓冲（每多一层 +1 天）。
     *  items=[{goodsId, qty}]；返回 suggestedDate + 每货品依据（无历史的行 days=null 不参与取最大）。 */
    @Transactional(readOnly = true)
    public Map<String, Object> suggestFinish(List<Map<String, Object>> items, LocalDate startDate) {
        LocalDate start = startDate != null ? startDate : LocalDate.now();
        List<Map<String, Object>> lines = new ArrayList<>();
        int maxDays = 0;
        int maxDepth = 1;
        boolean anyHistory = false;
        for (Map<String, Object> it : items) {
            UUID goodsId = UUID.fromString(it.get("goodsId").toString());
            BigDecimal qty = new BigDecimal(it.get("qty").toString());
            // 历史日均完工 = 近 180 天报工量 / 报工天数（ DISTINCT bill_date ）
            Object avg = em.createNativeQuery("""
                    SELECT SUM(i.qty) / NULLIF(COUNT(DISTINCT i.bill_date),0)
                    FROM production_daily_report_items i
                    JOIN production_daily_reports d ON d.id = i.report_id
                    WHERE i.goods_id = :g AND d.status = 1 AND i.is_deleted = false
                      AND i.bill_date >= CURRENT_DATE - 180
                    """).setParameter("g", goodsId).getSingleResult();
            BigDecimal dailyAvg = avg == null ? null : (BigDecimal) avg;
            Integer days = null;
            if (dailyAvg != null && dailyAvg.signum() > 0) {
                days = qty.divide(dailyAvg, 0, java.math.RoundingMode.CEILING).intValue();
                maxDays = Math.max(maxDays, days);
                anyHistory = true;
            }
            int depth = bomDepth(goodsId);
            maxDepth = Math.max(maxDepth, depth);
            Map<String, Object> line = new LinkedHashMap<>();
            line.put("goodsId", goodsId.toString());
            line.put("qty", qty);
            line.put("dailyAvg", dailyAvg);
            line.put("days", days);
            line.put("bomDepth", depth);
            lines.add(line);
        }
        // BOM 层级缓冲：多层 BOM 的半成品需先行投产，每多一层 +1 天
        int buffer = anyHistory ? Math.max(0, maxDepth - 1) : 0;
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("startDate", start.toString());
        out.put("suggestedDate", anyHistory ? start.plusDays(maxDays + buffer).toString() : null);
        out.put("planDays", anyHistory ? maxDays + buffer : null);
        out.put("bomBufferDays", buffer);
        out.put("lines", lines);
        out.put("note", anyHistory ? null : "所选货品近 180 天无报工记录，无法推算（给出各行 dailyAvg 为空）");
        return out;
    }

    /** BOM 最大层级（防环上限 5）。 */
    private int bomDepth(UUID goodsId) {
        Object d = em.createNativeQuery("""
                WITH RECURSIVE bom AS (
                    SELECT b.component_goods_id AS gid, 1 AS depth
                    FROM goods_bom_items b WHERE b.goods_id = :g AND b.is_deleted = false
                    UNION ALL
                    SELECT b.component_goods_id, bom.depth + 1
                    FROM goods_bom_items b JOIN bom ON b.goods_id = bom.gid
                    WHERE b.is_deleted = false AND bom.depth < 5
                )
                SELECT COALESCE(MAX(depth), 1) FROM bom
                """).setParameter("g", goodsId).getSingleResult();
        return d == null ? 1 : ((Number) d).intValue();
    }

    private static BigDecimal bd(Object v) {
        return v == null ? BigDecimal.ZERO : (BigDecimal) v;
    }
}
