package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.PositionRow;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.PositionView;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.stream.Collectors;

/** Task-level estimate only: stock neither reserves material nor gates starting or requesting more. */
@Service
public class WorkshopTaskMaterialStockQueryService {
    private final NamedParameterJdbcTemplate db;
    private final WorkshopMaterialScope scope;
    private final WorkshopMaterialBinSupport bins;
    private final WorkshopMaterialPositionQueryService positions;
    private final WorkshopMaterialPermissions permissions;

    public WorkshopTaskMaterialStockQueryService(NamedParameterJdbcTemplate db, WorkshopMaterialScope scope,
            WorkshopMaterialBinSupport bins, WorkshopMaterialPositionQueryService positions,
            WorkshopMaterialPermissions permissions) {
        this.db = db;
        this.scope = scope;
        this.bins = bins;
        this.positions = positions;
        this.permissions = permissions;
    }

    @Transactional(readOnly = true)
    public StockReadiness readiness(UUID segmentId) {
        if (segmentId == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择工单");
        List<Map<String, Object>> segments = db.queryForList("""
                SELECT segment.workshop_department_id, department.name AS workshop_name, segment.status,
                       GREATEST(task.remaining_qty - COALESCE((
                           SELECT sum(GREATEST(balance.available_qty, 0))
                           FROM v_production_fqc_recovery_balance balance
                           JOIN production_fqc_recovery_authorizations recovery ON recovery.id = balance.authorization_id
                           WHERE balance.execution_segment_id = segment.id AND NOT balance.cancelled
                             AND recovery.disposition_code = 'REWORK'), 0), 0)
                           * segment.product_unit_rate AS remaining_output_qty
                FROM production_execution_segments segment
                JOIN v_production_execution_workbench_segments task ON task.segment_id = segment.id
                LEFT JOIN departments department ON department.id = segment.workshop_department_id
                WHERE segment.id = :segment AND NOT segment.is_deleted
                """, Map.of("segment", segmentId));
        if (segments.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, "工单不存在或已撤回");
        Map<String, Object> segment = segments.getFirst();
        UUID workshop = (UUID) segment.get("workshop_department_id");
        scope.requireWorkshop(workshop);
        var settings = bins.settings(workshop);
        UUID bin = settings == null || !settings.enabled() ? null : settings.binWarehouseId();
        BigDecimal remainingOutput = WorkshopMaterialBinSupport.decimal(segment.get("remaining_output_qty"));
        PositionView position = bin == null ? null : positions.position(bin);
        Map<MaterialKey, PositionRow> stock = position == null ? Map.of() : position.rows().stream()
                .collect(Collectors.toMap(row -> new MaterialKey(row.goodsId(), row.colorId()), row -> row));
        List<StockRow> rows = new ArrayList<>();
        for (Map<String, Object> material : db.queryForList("""
                SELECT material.material_goods_id AS goods_id, goods.code AS goods_code, goods.name AS goods_name,
                       material.material_color_id AS color_id, color.name AS color_name,
                       unit.name AS unit_name, goods.bulk_package_qty, material.bin_warehouse_id,
                       (fn_workshop_material_unit_weight(material.id)).unit_weight AS unit_weight
                FROM production_execution_periodic_materials material
                JOIN goods ON goods.id = material.material_goods_id
                LEFT JOIN colors color ON color.id = material.material_color_id
                LEFT JOIN units unit ON unit.id = material.unit_id
                WHERE material.execution_segment_id = :segment
                  AND material.effective_from <= :today
                  AND (material.effective_to IS NULL OR material.effective_to >= :today)
                ORDER BY goods.code, color.name NULLS FIRST, material.id
                """, new MapSqlParameterSource("segment", segmentId).addValue("today", BusinessTime.today()))) {
            PositionRow quantity = stock.get(new MaterialKey((UUID) material.get("goods_id"),
                    (UUID) material.get("color_id")));
            // A row bound elsewhere must never borrow this bin's stock estimate.
            if (bin == null || !bin.equals(material.get("bin_warehouse_id"))) quantity = null;
            rows.add(stockRow(material, remainingOutput, quantity));
        }
        String reason = bin == null ? "本车间尚未开启整批领料" : rows.isEmpty()
                ? "这张工单还没有今天生效的内料仓用料记录，暂不能估算用量" : null;
        boolean incomplete = reason != null || rows.stream().anyMatch(StockRow::estimateIncomplete);
        List<String> actions = bin != null && "IN_PROGRESS".equals(segment.get("status"))
                && permissions.has(WorkshopMaterialPermissions.REQUEST) ? List.of("REQUEST") : List.of();
        return new StockReadiness(segmentId, bin, workshop, (String) segment.get("workshop_name"),
                remainingOutput, rows, incomplete, reason, actions);
    }

    static StockRow stockRow(Map<String, Object> material, BigDecimal remainingOutput, PositionRow stock) {
        BigDecimal weight = WorkshopMaterialBinSupport.decimal(material.get("unit_weight"));
        BigDecimal required = remainingOutput == null || weight == null ? null
                : remainingOutput.multiply(weight);
        BigDecimal estimated = stock == null ? null : stock.estimatedRemainingQty();
        String reason = required == null ? "缺少单个重量，暂不能估算本任务需要的材料"
                : stock == null || estimated == null ? "尚无这类材料的内料仓估计余量"
                : stock.missingWeightProducts() > 0 ? "本期有产品缺少单个重量，估计余量不完整"
                : stock.draftReportCount() > 0 ? "本期还有未审核报工，估计余量不完整" : null;
        BigDecimal shortage = reason == null ? required.subtract(estimated).max(BigDecimal.ZERO) : null;
        String status = shortage == null ? "UNKNOWN" : shortage.signum() > 0 ? "ESTIMATED_SHORT" : "ESTIMATED_ENOUGH";
        return new StockRow((UUID) material.get("goods_id"), (String) material.get("goods_code"),
                (String) material.get("goods_name"), (UUID) material.get("color_id"),
                (String) material.get("color_name"), (String) material.get("unit_name"),
                WorkshopMaterialBinSupport.decimal(material.get("bulk_package_qty")),
                stock == null ? null : stock.bookQty(), stock == null ? null : stock.warehouseAvailableQty(),
                estimated, required, shortage, status, reason != null, reason == null, reason);
    }

    private record MaterialKey(UUID goodsId, UUID colorId) {}

    /** Output is in the product base unit; all row quantities are in the material base unit. */
    public record StockReadiness(UUID segmentId, UUID binWarehouseId, UUID workshopDepartmentId, String workshopName,
            BigDecimal remainingOutputQty, List<StockRow> rows, boolean estimateIncomplete, String reason,
            List<String> allowedActions) {}

    public record StockRow(UUID goodsId, String goodsCode, String goodsName, UUID colorId, String colorName,
            String unitName, BigDecimal bulkPackageQty, BigDecimal bookQty, BigDecimal warehouseAvailableQty,
            BigDecimal estimatedRemainingQty, BigDecimal requiredQty, BigDecimal shortageQty, String status,
            boolean estimateIncomplete, boolean estimatedReliable, String reason) {}
}
