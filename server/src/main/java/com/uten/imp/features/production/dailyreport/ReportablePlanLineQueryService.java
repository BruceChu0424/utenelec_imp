package com.uten.imp.features.production.dailyreport;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.production.dailyreport.dto.ReportablePlanLine;
import org.springframework.data.domain.PageRequest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.UUID;

/**
 * 生产报工来源 CQRS 读侧。
 *
 * <p>查询只展示当前可正向报工的已审计划。合并排产严格按订单行拆开；
 * 曾经存在销售联动但联动已失效的计划行不会降级成“内部计划”继续报工。
 */
@Service
public class ReportablePlanLineQueryService {

    private static final String BASE_SQL = """
            WITH segment_progress AS (
                SELECT item.execution_segment_id,
                       COALESCE(SUM(item.qty) FILTER (
                           WHERE report.status = 1), 0) AS reported_qty,
                       COALESCE(SUM(item.qty) FILTER (
                           WHERE report.status IN (0, 1)), 0) AS active_qty
                FROM production_daily_report_items item
                JOIN production_daily_reports report
                  ON report.id = item.report_id
                WHERE item.execution_segment_id IS NOT NULL
                  AND item.is_deleted = FALSE
                  AND report.is_deleted = FALSE
                  AND report.status IN (0, 1)
                GROUP BY item.execution_segment_id
            ), allocation_progress AS (
                SELECT item.execution_segment_sales_allocation_id,
                       COALESCE(SUM(item.qty) FILTER (
                           WHERE report.status = 1), 0) AS reported_qty,
                       COALESCE(SUM(item.qty) FILTER (
                           WHERE report.status IN (0, 1)), 0) AS active_qty
                FROM production_daily_report_items item
                JOIN production_daily_reports report
                  ON report.id = item.report_id
                WHERE item.execution_segment_sales_allocation_id IS NOT NULL
                  AND item.is_deleted = FALSE
                  AND report.is_deleted = FALSE
                  AND report.status IN (0, 1)
                GROUP BY item.execution_segment_sales_allocation_id
            ), reportable AS (
                SELECT
                    i.id AS plan_item_id,
                    segment.id AS execution_segment_id,
                    sales_allocation.id
                        AS execution_segment_sales_allocation_id,
                    segment.segment_code AS execution_segment_code,
                    segment.status AS execution_segment_status,
                    segment.lock_version AS execution_segment_version,
                    l.order_item_id,
                    p.bill_no AS plan_no,
                    i.product_no,
                    i.goods_id,
                    g.code AS goods_code,
                    g.name AS goods_name,
                    g.spec AS goods_spec,
                    i.color_id,
                    c.name AS color_name,
                    i.unit_id,
                    u.name AS unit_name,
                    COALESCE(i.unit_rate, 1) AS unit_rate,
                    COALESCE(segment.planned_qty, i.qty, 0) AS planned_qty,
                    CASE WHEN segment.id IS NULL
                         THEN COALESCE(i.fqty, 0)
                         ELSE COALESCE(segment_done.reported_qty, 0)
                    END AS produced_qty,
                    GREATEST(
                        COALESCE(segment.planned_qty, i.qty, 0)
                        - CASE WHEN segment.id IS NULL
                               THEN COALESCE(i.fqty, 0)
                               ELSE COALESCE(segment_done.active_qty, 0)
                          END, 0) AS remaining_plan_qty,
                    COALESCE(sales_allocation.allocated_qty, l.allocated_qty) AS allocated_qty,
                    CASE WHEN sales_allocation.id IS NOT NULL
                         THEN COALESCE(allocation_done.reported_qty, 0)
                         ELSE COALESCE(l.produced_qty, 0)
                    END AS linked_produced_qty,
                    CASE
                        WHEN l.id IS NULL
                            THEN GREATEST(
                                COALESCE(segment.planned_qty, i.qty, 0)
                                - CASE WHEN segment.id IS NULL
                                       THEN COALESCE(i.fqty, 0)
                                       ELSE COALESCE(segment_done.active_qty, 0)
                                  END, 0)
                        ELSE LEAST(
                            GREATEST(
                                COALESCE(segment.planned_qty, i.qty, 0)
                                - CASE WHEN segment.id IS NULL
                                       THEN COALESCE(i.fqty, 0)
                                       ELSE COALESCE(segment_done.active_qty, 0)
                                  END, 0),
                            GREATEST(
                                COALESCE(
                                    sales_allocation.allocated_qty,
                                    l.allocated_qty, 0)
                                - CASE WHEN sales_allocation.id IS NOT NULL
                                       THEN COALESCE(allocation_done.active_qty, 0)
                                       ELSE COALESCE(l.produced_qty, 0)
                                  END, 0)
                        )
                    END AS max_report_qty,
                    so.bill_no AS order_no,
                    oi.qty AS order_qty,
                    cl.name AS client_name,
                    COALESCE(segment.workshop_department_id, p.department_id) AS department_id,
                    COALESCE(segment_workshop.name, p.workshop_name) AS workshop_name,
                    COALESCE(segment.plan_begin_date, i.plan_begin_date) AS plan_begin_date,
                    COALESCE(segment.plan_end_date, i.plan_end_date) AS plan_end_date,
                    COALESCE(i.outbound_date, p.delivery_date, oi.deliver_date, so.deliver_date) AS delivery_date
                FROM production_plan_items i
                LEFT JOIN production_execution_segments segment
                  ON segment.source_plan_item_id = i.id
                 AND segment.is_deleted = FALSE
                 AND segment.status IN ('DISPATCHED', 'IN_PROGRESS')
                LEFT JOIN segment_progress segment_done
                  ON segment_done.execution_segment_id = segment.id
                LEFT JOIN departments segment_workshop
                  ON segment_workshop.id = segment.workshop_department_id
                 AND segment_workshop.is_deleted = FALSE
                JOIN production_plans p ON p.id = i.plan_id
                JOIN goods g ON g.id = i.goods_id
                LEFT JOIN colors c ON c.id = i.color_id
                LEFT JOIN units u ON u.id = i.unit_id
                LEFT JOIN execution_segment_sales_allocations sales_allocation
                  ON sales_allocation.execution_segment_id = segment.id
                LEFT JOIN allocation_progress allocation_done
                  ON allocation_done.execution_segment_sales_allocation_id =
                     sales_allocation.id
                LEFT JOIN plan_order_item_links l
                  ON (
                       (
                           segment.id IS NOT NULL
                           AND l.id =
                               sales_allocation.plan_order_item_link_id
                       )
                       OR (
                           segment.id IS NULL
                           AND l.plan_item_id = i.id
                       )
                  )
                 AND COALESCE(l.is_deleted, false) = false
                LEFT JOIN sales_order_items oi ON oi.id = l.order_item_id
                LEFT JOIN sales_orders so ON so.id = oi.order_id
                LEFT JOIN clients cl ON cl.id = so.client_id
                WHERE p.status = 1
                  AND COALESCE(p.is_deleted, false) = false
                  AND COALESCE(p.is_stopped, false) = false
                  AND COALESCE(p.is_canceled, false) = false
                  AND COALESCE(i.is_deleted, false) = false
                  AND COALESCE(segment.planned_qty, i.qty, 0) >
                      CASE WHEN segment.id IS NULL
                           THEN COALESCE(i.fqty, 0)
                           ELSE COALESCE(segment_done.active_qty, 0)
                      END
                  AND (
                      segment.id IS NOT NULL
                      OR NOT EXISTS (
                          SELECT 1
                          FROM production_execution_segments any_segment
                          JOIN production_planning_packages any_package
                            ON any_package.id = any_segment.package_id
                          WHERE any_segment.source_plan_item_id = i.id
                            AND any_segment.is_deleted = FALSE
                            AND any_package.is_deleted = FALSE
                            AND any_package.status = 'CONFIRMED'
                            AND any_package.execution_model_version = 1
                      )
                  )
                  AND (
                      l.id IS NOT NULL
                      OR NOT EXISTS (
                          SELECT 1
                          FROM plan_order_item_links historical
                          WHERE historical.plan_item_id = i.id
                      )
                  )
                  AND NOT EXISTS (
                      SELECT 1
                      FROM plan_order_item_links active_link
                      LEFT JOIN sales_order_items active_item
                        ON active_item.id = active_link.order_item_id
                      LEFT JOIN sales_orders active_order
                        ON active_order.id = active_item.order_id
                      WHERE active_link.plan_item_id = i.id
                        AND COALESCE(active_link.is_deleted, false) = false
                        AND (
                            active_item.id IS NULL
                            OR active_order.id IS NULL
                            OR COALESCE(active_item.is_deleted, false)
                            OR COALESCE(active_order.is_deleted, false)
                            OR active_order.status <> 1
                            OR COALESCE(active_order.is_stopped, false)
                            OR COALESCE(active_order.is_closed, false)
                            OR COALESCE(active_item.chain_status, 0) NOT BETWEEN 1 AND 8
                        )
                  )
            )
            """;

    private final JdbcTemplate jdbc;

    public ReportablePlanLineQueryService(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    @Transactional(readOnly = true)
    public PageResponse<ReportablePlanLine> list(
            int requestedPage,
            int requestedSize,
            String keyword,
            UUID departmentId) {
        return list(
                requestedPage, requestedSize, keyword, departmentId, null);
    }

    @Transactional(readOnly = true)
    public PageResponse<ReportablePlanLine> list(
            int requestedPage,
            int requestedSize,
            String keyword,
            UUID departmentId,
            UUID executionSegmentId) {
        PageRequest pageable = Pageables.of(requestedPage, requestedSize);
        int page = pageable.getPageNumber() + 1;
        int size = pageable.getPageSize();

        String normalized = keyword == null || keyword.isBlank()
                ? null
                : "%" + keyword.trim().toLowerCase(Locale.ROOT) + "%";
        List<Object> args = new ArrayList<>();
        StringBuilder filter = new StringBuilder(" WHERE max_report_qty > 0");
        if (normalized != null) {
            filter.append("""
                     AND (
                         lower(COALESCE(plan_no, '')) LIKE ?
                         OR lower(COALESCE(product_no, '')) LIKE ?
                         OR lower(COALESCE(goods_code, '')) LIKE ?
                         OR lower(COALESCE(goods_name, '')) LIKE ?
                         OR lower(COALESCE(order_no, '')) LIKE ?
                         OR lower(COALESCE(client_name, '')) LIKE ?
                     )
                    """);
            for (int index = 0; index < 6; index++) {
                args.add(normalized);
            }
        }
        if (departmentId != null) {
            filter.append(" AND department_id = ?");
            args.add(departmentId);
        }
        if (executionSegmentId != null) {
            filter.append(" AND execution_segment_id = ?");
            args.add(executionSegmentId);
        }

        Long totalValue = jdbc.queryForObject(
                BASE_SQL + " SELECT COUNT(*) FROM reportable" + filter,
                Long.class,
                args.toArray());
        long total = totalValue == null ? 0 : totalValue;

        List<Object> dataArgs = new ArrayList<>(args);
        dataArgs.add(size);
        dataArgs.add(pageable.getOffset());
        List<ReportablePlanLine> items = jdbc.query(
                BASE_SQL + """
                         SELECT *
                         FROM reportable
                        """ + filter + """
                         ORDER BY delivery_date ASC NULLS LAST,
                                  plan_no ASC,
                                  product_no ASC,
                                  order_no ASC NULLS LAST,
                                  plan_item_id ASC,
                                  order_item_id ASC NULLS LAST,
                                  execution_segment_code ASC NULLS LAST,
                                  execution_segment_sales_allocation_id
                                      ASC NULLS LAST
                         LIMIT ? OFFSET ?
                        """,
                (rs, rowNum) -> new ReportablePlanLine(
                        rs.getObject("plan_item_id", UUID.class),
                        rs.getObject("execution_segment_id", UUID.class),
                        rs.getObject(
                                "execution_segment_sales_allocation_id",
                                UUID.class),
                        rs.getString("execution_segment_code"),
                        rs.getString("execution_segment_status"),
                        rs.getObject("execution_segment_version", Long.class),
                        rs.getObject("order_item_id", UUID.class),
                        rs.getString("plan_no"),
                        rs.getString("product_no"),
                        rs.getObject("goods_id", UUID.class),
                        rs.getString("goods_code"),
                        rs.getString("goods_name"),
                        rs.getString("goods_spec"),
                        rs.getObject("color_id", UUID.class),
                        rs.getString("color_name"),
                        rs.getObject("unit_id", UUID.class),
                        rs.getString("unit_name"),
                        rs.getBigDecimal("unit_rate"),
                        rs.getBigDecimal("planned_qty"),
                        rs.getBigDecimal("produced_qty"),
                        rs.getBigDecimal("remaining_plan_qty"),
                        rs.getBigDecimal("allocated_qty"),
                        rs.getBigDecimal("linked_produced_qty"),
                        rs.getBigDecimal("max_report_qty"),
                        rs.getString("order_no"),
                        rs.getBigDecimal("order_qty"),
                        rs.getString("client_name"),
                        rs.getObject("department_id", UUID.class),
                        rs.getString("workshop_name"),
                        rs.getObject("plan_begin_date", LocalDate.class),
                        rs.getObject("plan_end_date", LocalDate.class),
                        rs.getObject("delivery_date", LocalDate.class)),
                dataArgs.toArray());

        int totalPages = total == 0 ? 0 : (int) ((total + size - 1) / size);
        return new PageResponse<>(items, page, size, total, totalPages);
    }
}
