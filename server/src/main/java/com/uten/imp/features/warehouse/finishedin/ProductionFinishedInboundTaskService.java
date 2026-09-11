package com.uten.imp.features.warehouse.finishedin;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.security.ProductionStockTaskAccessPolicy;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.PageRequest;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.sql.Timestamp;
import java.time.Instant;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.List;

/** Authoritative two-stage warehouse queue: pre-FQC registration and final count. */
@Service
@RequiredArgsConstructor
public class ProductionFinishedInboundTaskService {

    private static final String BASE_SQL = """
            WITH arrival_tasks AS (
                SELECT 'ARRIVAL_REGISTRATION'::text AS task_stage,
                       report.id AS task_id,
                       report.id AS report_id,
                       NULL::uuid AS document_id,
                       NULL::text AS document_no,
                       report.bill_date AS document_date,
                       NULL::uuid AS warehouse_id,
                       NULL::text AS warehouse_name,
                       plan.plan_id,
                       plan.plan_no,
                       report.bill_no AS report_nos,
                       string_agg(
                           DISTINCT COALESCE(
                               NULLIF(goods.name, ''),
                               NULLIF(goods.code, ''),
                               '未命名货品'),
                           '、') AS goods_summary,
                       COUNT(report_item.id)::integer AS line_count,
                       COALESCE(SUM(report_item.qty), 0) AS pending_qty,
                       report.created_at,
                       FALSE AS residual_task
                FROM production_daily_reports report
                JOIN production_daily_report_items report_item
                  ON report_item.report_id = report.id
                -- V548：待登记口径统一走视图（含撤回后重新可登记的行）。
                JOIN v_production_report_items_pending_registration pending
                  ON pending.report_item_id = report_item.id
                JOIN goods goods ON goods.id = report_item.goods_id
                LEFT JOIN LATERAL (
                    SELECT production_plan.id AS plan_id,
                           production_plan.bill_no AS plan_no
                    FROM production_daily_report_items source_item
                    JOIN production_plan_items plan_item
                      ON plan_item.id = source_item.plan_item_id
                     AND plan_item.is_deleted = FALSE
                    JOIN production_plans production_plan
                      ON production_plan.id = plan_item.plan_id
                     AND production_plan.is_deleted = FALSE
                    WHERE source_item.report_id = report.id
                      AND source_item.is_deleted = FALSE
                    ORDER BY production_plan.bill_no, production_plan.id
                    LIMIT 1
                ) plan ON TRUE
                WHERE report.status = 1
                  AND report.is_deleted = FALSE
                GROUP BY report.id, report.bill_no, report.bill_date,
                         plan.plan_id, plan.plan_no, report.created_at
            ), final_count_tasks AS (
                SELECT 'FINAL_COUNT'::text AS task_stage,
                       document.id AS task_id,
                       document.source_daily_report_id AS report_id,
                       document.id AS document_id,
                       document.bill_no AS document_no,
                       document.bill_date AS document_date,
                       document.warehouse_id,
                       warehouse.name AS warehouse_name,
                       plan.plan_id,
                       plan.plan_no,
                       reports.report_nos,
                       string_agg(
                           DISTINCT COALESCE(
                               NULLIF(item.goods_name_snapshot, ''),
                               NULLIF(item.goods_code_snapshot, ''),
                               '未命名货品'),
                           '、') AS goods_summary,
                       COUNT(item.id)::integer AS line_count,
                       COALESCE(SUM(item.qty), 0) AS pending_qty,
                       document.created_at,
                       EXISTS (
                           SELECT 1
                           FROM production_finished_in_confirmations confirmation
                           WHERE confirmation.residual_stock_document_id =
                                 document.id
                       ) AS residual_task
                FROM stock_documents document
                JOIN stock_document_items item
                  ON item.doc_id = document.id
                 AND item.is_deleted = FALSE
                 AND (
                     item.source_daily_report_item_id IS NOT NULL
                     OR item.execution_segment_id IS NOT NULL
                 )
                LEFT JOIN warehouses warehouse
                  ON warehouse.id = document.warehouse_id
                 AND warehouse.is_deleted = FALSE
                LEFT JOIN LATERAL (
                    SELECT production_plan.id AS plan_id,
                           production_plan.bill_no AS plan_no
                    FROM stock_document_items source_item
                    JOIN production_plan_items plan_item
                      ON plan_item.id = source_item.upstream_item_id
                     AND plan_item.is_deleted = FALSE
                    JOIN production_plans production_plan
                      ON production_plan.id = plan_item.plan_id
                     AND production_plan.is_deleted = FALSE
                    WHERE source_item.doc_id = document.id
                      AND source_item.is_deleted = FALSE
                    ORDER BY production_plan.bill_no, production_plan.id
                    LIMIT 1
                ) plan ON TRUE
                LEFT JOIN LATERAL (
                    SELECT string_agg(
                               DISTINCT report.bill_no, '、') AS report_nos
                    FROM stock_document_items source_item
                    JOIN production_daily_report_items report_item
                      ON report_item.id =
                         source_item.source_daily_report_item_id
                     AND report_item.is_deleted = FALSE
                    JOIN production_daily_reports report
                      ON report.id = report_item.report_id
                     AND report.is_deleted = FALSE
                    WHERE source_item.doc_id = document.id
                      AND source_item.is_deleted = FALSE
                ) reports ON TRUE
                WHERE document.doc_type = 'FINISHED_IN'
                  AND document.status = 0
                  AND document.is_deleted = FALSE
                GROUP BY document.id, document.source_daily_report_id,
                         document.bill_no,
                         document.bill_date, document.warehouse_id,
                         warehouse.name, plan.plan_id, plan.plan_no,
                         reports.report_nos, document.created_at
            ), task_documents AS (
                SELECT * FROM arrival_tasks
                UNION ALL
                SELECT * FROM final_count_tasks
            )
            """;

    private final EntityManager em;
    private final ProductionStockTaskAccessPolicy access;

    @Transactional(readOnly = true)
    public PageResponse<ProductionFinishedInboundTask> list(
            String keyword, int requestedPage, int requestedSize) {
        PageRequest pageable = Pageables.of(
                requestedPage, requestedSize);
        int page = pageable.getPageNumber() + 1;
        int size = pageable.getPageSize();
        if (!access.canAccessWarehouseTasks()) {
            return new PageResponse<>(
                    List.of(), page, size, 0, 0);
        }
        String normalized = keyword == null
                ? ""
                : keyword.strip().toLowerCase();
        String filter = """
                 WHERE (
                     :keyword = ''
                     OR LOWER(
                         COALESCE(document_no, '') || ' ' ||
                         COALESCE(plan_no, '') || ' ' ||
                         COALESCE(report_nos, '') || ' ' ||
                         COALESCE(goods_summary, '')
                     ) LIKE :keyword_like
                 )
                """;

        Query countQuery = em.createNativeQuery(
                BASE_SQL + " SELECT COUNT(*) FROM task_documents " + filter);
        bindKeyword(countQuery, normalized);
        long total = ((Number) countQuery.getSingleResult()).longValue();

        Query rowsQuery = em.createNativeQuery(BASE_SQL + """
                SELECT task_stage, task_id, report_id,
                       document_id, document_no, document_date,
                       warehouse_id, warehouse_name, plan_id, plan_no,
                       report_nos, goods_summary, line_count,
                       pending_qty, created_at, residual_task
                FROM task_documents
                """ + filter + """
                ORDER BY created_at ASC, task_id ASC
                OFFSET :offset LIMIT :limit
                """);
        bindKeyword(rowsQuery, normalized);
        rowsQuery.setParameter("offset", pageable.getOffset());
        rowsQuery.setParameter("limit", size);
        List<ProductionFinishedInboundTask> items =
                NativeQueryResults.objectArrayRows(rowsQuery).stream()
                        .map(ProductionFinishedInboundTaskService::map)
                        .toList();
        int totalPages = total == 0
                ? 0
                : (int) ((total + size - 1) / size);
        return new PageResponse<>(
                items, page, size, total, totalPages);
    }

    @Transactional(readOnly = true)
    public long countPending() {
        if (!access.canAccessWarehouseTasks()) return 0;
        Number count = (Number) em.createNativeQuery(
                        BASE_SQL
                                + " SELECT COUNT(*) FROM task_documents")
                .getSingleResult();
        return count == null ? 0 : count.longValue();
    }

    private static void bindKeyword(Query query, String keyword) {
        query.setParameter("keyword", keyword);
        query.setParameter("keyword_like", "%" + keyword + "%");
    }

    private static ProductionFinishedInboundTask map(Object[] row) {
        return new ProductionFinishedInboundTask(
                (String) row[0],
                (java.util.UUID) row[1],
                (java.util.UUID) row[2],
                (java.util.UUID) row[3],
                (String) row[4],
                localDate(row[5]),
                (java.util.UUID) row[6],
                (String) row[7],
                (java.util.UUID) row[8],
                (String) row[9],
                (String) row[10],
                (String) row[11],
                ((Number) row[12]).intValue(),
                decimal(row[13]),
                offsetDateTime(row[14]),
                Boolean.TRUE.equals(row[15]));
    }

    private static BigDecimal decimal(Object value) {
        return value == null
                ? BigDecimal.ZERO
                : new BigDecimal(value.toString());
    }

    private static LocalDate localDate(Object value) {
        if (value == null) return null;
        if (value instanceof LocalDate date) return date;
        return ((java.sql.Date) value).toLocalDate();
    }

    private static OffsetDateTime offsetDateTime(Object value) {
        if (value == null) return null;
        if (value instanceof OffsetDateTime valueWithOffset) {
            return valueWithOffset.withOffsetSameInstant(ZoneOffset.UTC);
        }
        if (value instanceof Instant instant) {
            return instant.atOffset(ZoneOffset.UTC);
        }
        if (value instanceof Timestamp timestamp) {
            return timestamp.toInstant().atOffset(ZoneOffset.UTC);
        }
        throw new IllegalStateException(
                "Unsupported task timestamp: " + value.getClass());
    }
}
