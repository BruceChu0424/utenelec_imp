package com.uten.imp.features.production.execution;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.fulfillment.ProductionPlanningPackage;
import com.uten.imp.features.production.fulfillment.ProductionPlanningPackageRepository;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.Instant;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Builds an A4-work-card projection without creating or mutating business facts. */
@Service
@RequiredArgsConstructor
public class ProductionWorkCardService {

    private final ProductionPlanningPackageRepository packageRepository;
    private final EntityManager em;

    @Transactional
    public ProductionWorkCardView view(UUID planId, UUID packageId) {
        ProductionPlanningPackage planningPackage = packageRepository
                .lockConfirmedExecutionPackage(planId, packageId)
                .orElseThrow(() -> new ApiException(
                        ErrorCode.NOT_FOUND,
                        "已确认的生产计划包不存在或已失效"));

        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT plan.bill_no,
                                       plan.bill_date,
                                       plan.delivery_date,
                                       approver.full_name,
                                       package.created_at,
                                       warehouse.id,
                                       warehouse.code,
                                       warehouse.name,
                                       segment.id,
                                       segment.segment_code,
                                       segment.source_plan_item_id,
                                       plan_item.line_no,
                                       plan_item.product_no,
                                       segment.product_goods_id,
                                       product.code,
                                       product.name,
                                       product.spec,
                                       product.model,
                                       product_color.name,
                                       product_unit.name,
                                       segment.planned_qty,
                                       segment.status,
                                       workshop.name,
                                       team.name,
                                       responsible.full_name,
                                       segment.plan_begin_date,
                                       segment.plan_end_date,
                                       plan_item.sales_order_no,
                                       plan_item.request_note,
                                       plan_item.remark,
                                       (
                                           SELECT string_agg(
                                                      document.document_no,
                                                      ', ' ORDER BY document.created_at, document.id)
                                           FROM production_planning_package_documents document
                                           WHERE document.package_id = package.id
                                             AND document.execution_segment_id = segment.id
                                             AND document.document_type = 'DRAW'
                                       ) AS draw_bill_nos,
                                       demand.id,
                                       demand.goods_id,
                                       material.code,
                                       material.name,
                                       material.spec,
                                       material_color.name,
                                       material_unit.name,
                                       demand.per_product_qty,
                                       demand.required_qty,
                                       COALESCE((
                                           SELECT SUM(reservation.qty - reservation.released_qty)
                                           FROM stock_reservations reservation
                                           WHERE reservation.demand_id = demand.id
                                             AND reservation.is_deleted = FALSE
                                       ), 0) AS stock_allocated_qty,
                                       GREATEST(
                                           demand.required_qty - COALESCE((
                                               SELECT SUM(reservation.qty - reservation.released_qty)
                                               FROM stock_reservations reservation
                                               WHERE reservation.demand_id = demand.id
                                                 AND reservation.is_deleted = FALSE
                                           ), 0),
                                           0) AS shortage_qty,
                                       demand.supply_route,
                                       demand.status,
                                       segment.auto_promote_when_ready,
                                       demand.requirement_mode,
                                       segment.material_requirement_mode,
                                       segment.zero_material_reason
                                FROM production_planning_packages package
                                JOIN production_plans plan
                                  ON plan.id = package.plan_id
                                 AND plan.is_deleted = FALSE
                                JOIN warehouses warehouse
                                  ON warehouse.id = package.warehouse_id
                                 AND warehouse.is_deleted = FALSE
                                JOIN production_execution_segments segment
                                  ON segment.package_id = package.id
                                 AND segment.plan_id = plan.id
                                 AND segment.is_deleted = FALSE
                                JOIN production_plan_items plan_item
                                  ON plan_item.id = segment.source_plan_item_id
                                 AND plan_item.plan_id = plan.id
                                 AND plan_item.is_deleted = FALSE
                                JOIN goods product
                                  ON product.id = segment.product_goods_id
                                LEFT JOIN colors product_color
                                  ON product_color.id = segment.product_color_id
                                JOIN units product_unit
                                  ON product_unit.id = segment.product_unit_id
                                LEFT JOIN departments workshop
                                  ON workshop.id = segment.workshop_department_id
                                 AND workshop.is_deleted = FALSE
                                LEFT JOIN departments team
                                  ON team.id = segment.team_department_id
                                 AND team.is_deleted = FALSE
                                LEFT JOIN employees responsible
                                  ON responsible.id = segment.responsible_employee_id
                                 AND responsible.is_deleted = FALSE
                                LEFT JOIN employees approver
                                  ON approver.id = plan.approver_id
                                 AND approver.is_deleted = FALSE
                                LEFT JOIN production_material_demands demand
                                  ON demand.package_id = package.id
                                 AND demand.execution_segment_id = segment.id
                                 AND demand.is_deleted = FALSE
                                LEFT JOIN goods material
                                  ON material.id = demand.goods_id
                                LEFT JOIN colors material_color
                                  ON material_color.id = demand.color_id
                                LEFT JOIN units material_unit
                                  ON material_unit.id = demand.unit_id
                                WHERE package.id = :packageId
                                  AND package.plan_id = :planId
                                  AND package.status = 'CONFIRMED'
                                  AND package.execution_model_version = 1
                                  AND package.is_deleted = FALSE
                                ORDER BY segment.segment_no,
                                         segment.id,
                                         material.code NULLS LAST,
                                         demand.goods_id,
                                         demand.id
                                """)
                        .setParameter("packageId", packageId)
                        .setParameter("planId", planId));
        if (rows.isEmpty()) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "计划包没有可打印的生产执行分段");
        }
        return assemble(planningPackage, rows, Instant.now());
    }

    static ProductionWorkCardView assemble(
            ProductionPlanningPackage planningPackage,
            List<Object[]> rows,
            Instant generatedAt) {
        Object[] first = rows.getFirst();
        Map<UUID, CardBuilder> cards = new LinkedHashMap<>();
        for (Object[] row : rows) {
            UUID segmentId = uuid(row[8]);
            CardBuilder card = cards.computeIfAbsent(segmentId, ignored ->
                    new CardBuilder(row));
            if (row[31] != null) {
                card.materials.add(new ProductionWorkCardView.Material(
                        uuid(row[31]),
                        uuid(row[32]),
                        text(row[33]),
                        text(row[34]),
                        text(row[35]),
                        text(row[36]),
                        text(row[37]),
                        decimal(row[38]),
                        decimal(row[39]),
                        decimal(row[40]),
                        decimal(row[41]),
                        text(row[42]),
                        text(row[43]),
                        text(row[45])));
            }
        }
        return new ProductionWorkCardView(
                planningPackage.getPlanId(),
                text(first[0]),
                date(first[1]),
                date(first[2]),
                planningPackage.getId(),
                planningPackage.getStatus(),
                planningPackage.getExecutionModelVersion(),
                planningPackage.getLockVersion(),
                instant(first[4]),
                text(first[3]),
                uuid(first[5]),
                text(first[6]),
                text(first[7]),
                generatedAt,
                ProductionWorkCardView.CURRENT_MASTER_DATA,
                cards.values().stream().map(CardBuilder::build).toList());
    }

    private static final class CardBuilder {
        private final Object[] row;
        private final List<ProductionWorkCardView.Material> materials =
                new ArrayList<>();

        private CardBuilder(Object[] row) {
            this.row = row;
        }

        private ProductionWorkCardView.Card build() {
            return new ProductionWorkCardView.Card(
                    uuid(row[8]),
                    text(row[9]),
                    uuid(row[10]),
                    row[11] == null ? null : ((Number) row[11]).intValue(),
                    text(row[12]),
                    uuid(row[13]),
                    text(row[14]),
                    text(row[15]),
                    text(row[16]),
                    text(row[17]),
                    text(row[18]),
                    text(row[19]),
                    decimal(row[20]),
                    text(row[21]),
                    Boolean.TRUE.equals(row[44]),
                    text(row[46]),
                    text(row[47]),
                    text(row[22]),
                    text(row[23]),
                    text(row[24]),
                    date(row[25]),
                    date(row[26]),
                    text(row[27]),
                    text(row[28]),
                    text(row[29]),
                    text(row[30]),
                    List.copyOf(materials));
        }
    }

    private static UUID uuid(Object value) {
        return value instanceof UUID id ? id : UUID.fromString(value.toString());
    }

    private static String text(Object value) {
        return value == null ? null : value.toString();
    }

    private static BigDecimal decimal(Object value) {
        if (value instanceof BigDecimal decimal) return decimal;
        if (value instanceof Number number) {
            return new BigDecimal(number.toString());
        }
        return new BigDecimal(value.toString());
    }

    private static LocalDate date(Object value) {
        if (value == null) return null;
        if (value instanceof LocalDate localDate) return localDate;
        if (value instanceof java.sql.Date sqlDate) return sqlDate.toLocalDate();
        return LocalDate.parse(value.toString());
    }

    private static Instant instant(Object value) {
        if (value instanceof Instant instant) return instant;
        if (value instanceof OffsetDateTime offset) return offset.toInstant();
        if (value instanceof java.sql.Timestamp timestamp) {
            return timestamp.toInstant();
        }
        return OffsetDateTime.parse(value.toString())
                .withOffsetSameInstant(ZoneOffset.UTC)
                .toInstant();
    }
}
