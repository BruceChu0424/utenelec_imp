package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.application.port.LineSideWarehousePort;
import com.uten.imp.application.port.WorkshopMaterialChoicePort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialBinSupport.Period;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialBinSupport.Settings;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialCommandLedger.Outcome;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.PendingChoiceList;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.SettingsRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.SettingsView;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 车间整批领料设置 (ADR-131 §5.1 第 3 步): 开启与停用都是一个原子命令。
 *
 * <p>开启: 在选定主仓下取得或建出本车间的内料仓 → 写设置 → 建第 1 期 → 在同一对话框里给在产、
 * 还没认料的产品认完料 → 本车间正在生产的段中状态已明确的当场绑定 (起始日 = 启用日; 带未核清
 * 整批领料按单需求的段不绑定, 按工单做完为止)。开启后不存在"在产却没认料"的段。
 * 停用只用来撤销设错的开启: 本仓从未有过进出、从未有段绑定、没有待办领料单; 同时删掉那张空的第 1 期。
 */
@Service
public class WorkshopMaterialSettingsService {

    private final NamedParameterJdbcTemplate db;
    private final WorkshopMaterialBinSupport bins;
    private final WorkshopMaterialCommandLedger commands;
    private final WorkshopMaterialScope scope;
    private final WorkshopMaterialPermissions permissions;
    private final WorkshopMaterialChoiceAdapter choices;
    private final LineSideWarehousePort lineSide;
    private final SecurityContextCurrentUser currentUser;

    public WorkshopMaterialSettingsService(NamedParameterJdbcTemplate db, WorkshopMaterialBinSupport bins,
                                           WorkshopMaterialCommandLedger commands, WorkshopMaterialScope scope,
                                           WorkshopMaterialPermissions permissions,
                                           WorkshopMaterialChoiceAdapter choices, LineSideWarehousePort lineSide,
                                           SecurityContextCurrentUser currentUser) {
        this.db = db;
        this.bins = bins;
        this.commands = commands;
        this.scope = scope;
        this.permissions = permissions;
        this.choices = choices;
        this.lineSide = lineSide;
        this.currentUser = currentUser;
    }

    /** 生产部下每个车间一行 (没设置过的也列出, 供开启)。 */
    @Transactional(readOnly = true)
    public List<SettingsView> list() {
        MapSqlParameterSource params = new MapSqlParameterSource();
        String inScope = scope.predicate("workshop.id", params);
        List<UUID> workshops = db.queryForList("""
                SELECT workshop.id FROM departments workshop
                JOIN departments production ON production.id = workshop.parent_id AND production.code = 'DEPT_PROD'
                 AND NOT production.is_deleted
                WHERE NOT workshop.is_deleted AND """ + " " + inScope + " ORDER BY workshop.code, workshop.name",
                params, UUID.class);
        List<SettingsView> out = new ArrayList<>();
        for (UUID workshop : workshops) out.add(view(workshop));
        return out;
    }

    @Transactional(readOnly = true)
    public SettingsView detail(UUID workshopId) {
        scope.requireWorkshop(workshopId);
        return view(workshopId);
    }

    /** 开启前在产、需要认料的产品 (开启对话框里一次选完)。 */
    @Transactional(readOnly = true)
    public PendingChoiceList inProgressPending(UUID workshopId) {
        requireWorkshopDepartment(workshopId);
        return new PendingChoiceList(choices.inProgressPending(workshopId));
    }

    @Transactional
    public SettingsView update(UUID workshopId, SettingsRequest request) {
        requireWorkshopDepartment(workshopId);
        if (request.enabled() == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择开启还是停用");
        return commands.execute(request.enabled() ? "SETTINGS_ENABLE" : "SETTINGS_DISABLE", request.idempotencyKey(),
                List.of(workshopId, request), SettingsView.class, () -> {
                    Settings current = bins.settingsForUpdate(workshopId);
                    long version = current == null ? 0 : current.rowVersion();
                    if (request.expectedVersion() != null) {
                        WorkshopMaterialBinSupport.requireVersion(request.expectedVersion(), version, "整批领料设置");
                    }
                    if (request.enabled()) {
                        enable(workshopId, current, request);
                    } else {
                        disable(workshopId, current);
                    }
                    return new Outcome<>(workshopId, view(workshopId));
                });
    }

    private void enable(UUID workshopId, Settings current, SettingsRequest request) {
        if (current != null && current.enabled()) {
            throw new ApiException(ErrorCode.CONFLICT, "这个车间已经开启了整批领料");
        }
        if (request.mainWarehouseId() == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择内料仓放在哪个主仓下");
        }
        LocalDate goLive = request.goLiveDate();
        if (goLive == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择启用日");
        UUID bin = lineSide.ensure(workshopId, request.mainWarehouseId());
        UUID actor = currentUser.requireId();
        MapSqlParameterSource params = new MapSqlParameterSource("workshop", workshopId).addValue("bin", bin)
                .addValue("goLive", goLive).addValue("actor", actor);
        if (current == null) {
            WorkshopMaterialGuards.guarded(() -> db.update("""
                    INSERT INTO workshop_material_settings(
                        workshop_department_id, periodic_enabled, periodic_bin_warehouse_id, go_live_date,
                        enabled_by, enabled_at, created_by)
                    VALUES (:workshop, TRUE, :bin, :goLive, :actor, now(), :actor)
                    """, params));
        } else {
            WorkshopMaterialGuards.guarded(() -> db.update("""
                    UPDATE workshop_material_settings
                    SET periodic_enabled = TRUE, periodic_bin_warehouse_id = :bin, go_live_date = :goLive,
                        enabled_by = :actor, enabled_at = now(), disabled_by = NULL, disabled_at = NULL,
                        row_version = row_version + 1
                    WHERE workshop_department_id = :workshop
                    """, params));
        }
        WorkshopMaterialGuards.guarded(() -> db.update("""
                INSERT INTO workshop_material_periods(bin_warehouse_id, workshop_department_id, period_no, start_date,
                                                     created_by)
                VALUES (:bin, :workshop, 1, :goLive, :actor)
                """, params));
        List<WorkshopMaterialChoicePort.ProductChoice> inProgress = request.inProgressChoices() == null
                ? List.of() : request.inProgressChoices();
        if (!inProgress.isEmpty()) {
            choices.chooseWithinCommand(inProgress, workshopId);
        }
        List<String> unchosen = db.queryForList("""
                SELECT DISTINCT product.name FROM (""" + WorkshopMaterialChoiceAdapter.IN_PROGRESS_NEED_CHOICE_SQL
                + ") pending JOIN goods product ON product.id = pending.product_goods_id ORDER BY product.name",
                Map.of("workshop", workshopId), String.class);
        if (!unchosen.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "这些正在生产的产品还没认料, 请在开启时一起选好: "
                    + String.join("、", unchosen.subList(0, Math.min(10, unchosen.size())))
                    + (unchosen.size() > 10 ? " 等 " + unchosen.size() + " 个" : ""));
        }
        bindInProgress(workshopId, bin, goLive, actor);
    }

    /**
     * 本车间正在生产、状态已明确的段当场绑定 (同开工时的绑定规则): 来源段有有效用料行的复制为继承行,
     * 否则按产品 BOM 期间边建 BOM 行, 否则按有效用料认料建认料行。起始日 = 启用日。
     */
    private void bindInProgress(UUID workshopId, UUID bin, LocalDate goLive, UUID actor) {
        List<UUID> segments = db.queryForList("""
                SELECT segment.id FROM production_execution_segments segment
                WHERE segment.workshop_department_id = :workshop AND segment.status = 'IN_PROGRESS'
                  AND NOT segment.is_deleted
                  AND NOT EXISTS (SELECT 1 FROM production_execution_periodic_materials material_row
                                  WHERE material_row.execution_segment_id = segment.id)
                  AND fn_segment_bin_material_state(segment.id) = 'KNOWN'
                ORDER BY segment.source_segment_id NULLS FIRST, segment.id
                """, Map.of("workshop", workshopId), UUID.class);
        for (UUID segment : segments) {
            MapSqlParameterSource params = new MapSqlParameterSource("segment", segment).addValue("bin", bin)
                    .addValue("from", goLive).addValue("actor", actor);
            int inherited = WorkshopMaterialGuards.guarded(() -> db.update("""
                    INSERT INTO production_execution_periodic_materials(
                        execution_segment_id, bin_warehouse_id, material_goods_id, material_color_id, unit_id, origin,
                        source_row_id, effective_from, created_by)
                    SELECT :segment, :bin, source_row.material_goods_id, source_row.material_color_id,
                           source_row.unit_id, 'INHERITED', source_row.id, :from, :actor
                    FROM production_execution_segments segment
                    JOIN production_execution_periodic_materials source_row
                      ON source_row.execution_segment_id = COALESCE(segment.source_segment_id, (
                             SELECT proof.source_execution_segment_id FROM production_actual_output_supplement_proofs proof
                             WHERE proof.supplement_execution_segment_id = segment.id
                             ORDER BY proof.created_at, proof.id LIMIT 1))
                     AND source_row.effective_to IS NULL
                    WHERE segment.id = :segment
                    ORDER BY source_row.created_at, source_row.id
                    """, params));
            if (inherited > 0) continue;
            int fromBom = WorkshopMaterialGuards.guarded(() -> db.update("""
                    INSERT INTO production_execution_periodic_materials(
                        execution_segment_id, bin_warehouse_id, material_goods_id, material_color_id, unit_id, origin,
                        bom_item_id, design_qty_snapshot, effective_from, created_by)
                    SELECT :segment, :bin, bom.component_goods_id, COALESCE(bom.color_id, component.color_id),
                           component.unit_id, 'BOM', bom.id, bom.qty, :from, :actor
                    FROM production_execution_segments segment
                    JOIN goods_bom_items bom ON bom.goods_id = segment.product_goods_id AND NOT bom.is_deleted
                    JOIN goods component ON component.id = bom.component_goods_id AND component.issue_method = 'PERIODIC'
                    WHERE segment.id = :segment
                    ORDER BY bom.sort_order, bom.id
                    """, params));
            if (fromBom > 0) continue;
            WorkshopMaterialGuards.guarded(() -> db.update("""
                    INSERT INTO production_execution_periodic_materials(
                        execution_segment_id, bin_warehouse_id, material_goods_id, material_color_id, unit_id, origin,
                        choice_id, effective_from, created_by)
                    SELECT :segment, :bin, choice.material_goods_id, choice.material_color_id, material.unit_id,
                           'CHOICE', choice.id, :from, :actor
                    FROM production_execution_segments segment
                    JOIN goods_periodic_material_choices choice
                      ON choice.product_goods_id = segment.product_goods_id AND choice.superseded_at IS NULL
                     AND choice.kind = 'MATERIAL'
                    JOIN goods material ON material.id = choice.material_goods_id
                    WHERE segment.id = :segment
                    ORDER BY choice.chosen_at, choice.id
                    """, params));
        }
    }

    private void disable(UUID workshopId, Settings current) {
        if (current == null || !current.enabled()) {
            throw new ApiException(ErrorCode.CONFLICT, "这个车间还没有开启整批领料");
        }
        UUID bin = current.binWarehouseId();
        Integer used = db.queryForObject("""
                SELECT (SELECT count(*) FROM v_workshop_material_bin_ledger WHERE bin_warehouse_id = :bin)
                     + (SELECT count(*) FROM production_execution_periodic_materials WHERE bin_warehouse_id = :bin)
                     + (SELECT count(*) FROM workshop_material_requisitions WHERE bin_warehouse_id = :bin
                                                                              AND status = 'PENDING')
                     + (SELECT count(*) FROM workshop_material_periods WHERE bin_warehouse_id = :bin
                                                                         AND (period_no > 1 OR status <> 'OPEN'))
                """, Map.of("bin", bin), Integer.class);
        if (used != null && used > 0) {
            throw new ApiException(ErrorCode.CONFLICT, "这个车间的内料仓已经在用, 不能停用");
        }
        for (Period period : bins.periodsOf(bin)) {
            db.update("DELETE FROM workshop_material_counts WHERE period_id = :id AND status = 'DRAFT'",
                    Map.of("id", period.id()));
            WorkshopMaterialGuards.guarded(() -> db.update("DELETE FROM workshop_material_periods WHERE id = :id",
                    Map.of("id", period.id())));
        }
        WorkshopMaterialGuards.guarded(() -> db.update("""
                UPDATE workshop_material_settings
                SET periodic_enabled = FALSE, disabled_by = :actor, disabled_at = now(), row_version = row_version + 1
                WHERE workshop_department_id = :workshop
                """, new MapSqlParameterSource("actor", currentUser.requireId()).addValue("workshop", workshopId)));
    }

    private SettingsView view(UUID workshopId) {
        Map<String, Object> row = db.queryForMap("""
                SELECT workshop.id, workshop.name, COALESCE(settings.periodic_enabled, FALSE) AS enabled,
                       settings.periodic_bin_warehouse_id, bin.name AS bin_name,
                       CASE WHEN settings.periodic_bin_warehouse_id IS NULL THEN NULL
                            ELSE fn_warehouse_main_id(settings.periodic_bin_warehouse_id) END AS main_id,
                       settings.go_live_date, COALESCE(settings.row_version, 0) AS row_version
                FROM departments workshop
                LEFT JOIN workshop_material_settings settings ON settings.workshop_department_id = workshop.id
                LEFT JOIN warehouses bin ON bin.id = settings.periodic_bin_warehouse_id
                WHERE workshop.id = :workshop
                """, Map.of("workshop", workshopId));
        UUID bin = (UUID) row.get("periodic_bin_warehouse_id");
        boolean enabled = Boolean.TRUE.equals(row.get("enabled"));
        Period open = null;
        Period pending = null;
        if (enabled && bin != null) {
            for (Period period : bins.periodsOf(bin)) {
                if ("OPEN".equals(period.status())) open = period;
                if (pending == null && ("COUNTING".equals(period.status()) || "COUNTED".equals(period.status()))) {
                    pending = period;
                }
            }
        }
        UUID main = (UUID) row.get("main_id");
        List<String> actions = new ArrayList<>();
        if (permissions.has(WorkshopMaterialPermissions.SETUP)) actions.add("SETUP");
        return new SettingsView(workshopId, (String) row.get("name"), enabled, bin, (String) row.get("bin_name"),
                main, bins.warehouseName(main), WorkshopMaterialBinSupport.date(row.get("go_live_date")),
                WorkshopMaterialBinSupport.number(row.get("row_version")).longValue(),
                open == null ? null : open.ref(), pending == null ? null : pending.ref(), actions);
    }

    private void requireWorkshopDepartment(UUID workshopId) {
        if (workshopId == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择车间");
        Integer found = db.queryForObject("""
                SELECT count(*) FROM departments workshop
                JOIN departments production ON production.id = workshop.parent_id AND production.code = 'DEPT_PROD'
                WHERE workshop.id = :id AND NOT workshop.is_deleted
                """, Map.of("id", workshopId), Integer.class);
        if (found == null || found == 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "整批领料只能在生产部下的车间开启");
        }
        scope.requireWorkshop(workshopId);
    }
}
