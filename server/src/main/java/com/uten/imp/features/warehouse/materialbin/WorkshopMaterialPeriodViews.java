package com.uten.imp.features.warehouse.materialbin;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.PeriodView;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 期间的读模型: 状态、自动结算状态与"差什么、谁来补", 以及当前主体能做的操作。
 *
 * <p>操作只按权限码与期间状态给出; 真正能不能做仍由各命令在锁内复核。
 */
@Component
class WorkshopMaterialPeriodViews {

    private static final TypeReference<List<Map<String, Object>>> BLOCKERS = new TypeReference<>() {};

    private final NamedParameterJdbcTemplate db;
    private final ObjectMapper json;
    private final WorkshopMaterialPermissions permissions;

    WorkshopMaterialPeriodViews(NamedParameterJdbcTemplate db, ObjectMapper json,
                                WorkshopMaterialPermissions permissions) {
        this.db = db;
        this.json = json;
        this.permissions = permissions;
    }

    PeriodView view(UUID periodId) {
        List<PeriodView> views = views("period.id = :id", Map.of("id", periodId));
        return views.isEmpty() ? null : views.getFirst();
    }

    List<PeriodView> ofBin(UUID binWarehouseId) {
        return views("period.bin_warehouse_id = :id", Map.of("id", binWarehouseId));
    }

    private List<PeriodView> views(String where, Map<String, Object> params) {
        boolean canCount = permissions.has(WorkshopMaterialPermissions.COUNT);
        boolean canReopen = permissions.has(WorkshopMaterialPermissions.REOPEN);
        List<PeriodView> out = new ArrayList<>();
        for (Map<String, Object> row : db.queryForList("""
                SELECT period.id, period.bin_warehouse_id, period.workshop_department_id, period.period_no,
                       period.start_date, period.end_date, period.status, period.close_state,
                       CAST(period.close_blockers AS text) AS close_blockers, period.close_attempts,
                       period.close_failures, period.held_until, period.row_version,
                       (SELECT counted.id FROM workshop_material_counts counted
                         WHERE counted.period_id = period.id AND counted.status = 'DRAFT') AS draft_count_id,
                       (SELECT counted.id FROM workshop_material_counts counted
                         WHERE counted.period_id = period.id AND counted.status = 'SUBMITTED') AS submitted_count_id,
                       (SELECT previous.status FROM workshop_material_periods previous
                         WHERE previous.bin_warehouse_id = period.bin_warehouse_id
                           AND previous.period_no = period.period_no - 1) AS previous_status,
                       (SELECT following.status FROM workshop_material_periods following
                         WHERE following.bin_warehouse_id = period.bin_warehouse_id
                           AND following.period_no = period.period_no + 1) AS next_status,
                       NOT EXISTS (SELECT 1 FROM workshop_material_periods later
                                   WHERE later.bin_warehouse_id = period.bin_warehouse_id
                                     AND later.period_no > period.period_no AND later.status = 'CLOSED')
                           AS latest_closed_candidate
                FROM workshop_material_periods period
                """ + " WHERE " + where + " ORDER BY period.period_no", params)) {
            String status = (String) row.get("status");
            UUID draft = (UUID) row.get("draft_count_id");
            UUID submitted = (UUID) row.get("submitted_count_id");
            String previous = (String) row.get("previous_status");
            String next = (String) row.get("next_status");
            List<String> actions = new ArrayList<>();
            if (canCount) {
                if ("OPEN".equals(status) && (previous == null || "COUNTED".equals(previous)
                        || "CLOSED".equals(previous))) actions.add("START_COUNT");
                if (draft != null) {
                    actions.add("EDIT_COUNT");
                    actions.add("SUBMIT_COUNT");
                }
                if ("COUNTING".equals(status) && "OPEN".equals(next)) actions.add("WITHDRAW_COUNT");
                if ("COUNTED".equals(status) && draft == null
                        && (next == null || "OPEN".equals(next) || "COUNTING".equals(next))) {
                    actions.add("CORRECT_COUNT");
                }
                if ("COUNTED".equals(status)) actions.add("CLOSE_RETRY");
            }
            if (canReopen && "CLOSED".equals(status) && Boolean.TRUE.equals(row.get("latest_closed_candidate"))
                    && ("OPEN".equals(next) || "COUNTING".equals(next))) {
                actions.add("REOPEN");
            }
            out.add(new PeriodView((UUID) row.get("id"), (UUID) row.get("bin_warehouse_id"),
                    (UUID) row.get("workshop_department_id"),
                    WorkshopMaterialBinSupport.number(row.get("period_no")).intValue(),
                    WorkshopMaterialBinSupport.date(row.get("start_date")),
                    WorkshopMaterialBinSupport.date(row.get("end_date")), status, (String) row.get("close_state"),
                    blockers((String) row.get("close_blockers")),
                    WorkshopMaterialBinSupport.number(row.get("close_attempts")).intValue(),
                    WorkshopMaterialBinSupport.number(row.get("close_failures")).intValue(),
                    WorkshopMaterialBinSupport.offset(row.get("held_until")),
                    WorkshopMaterialBinSupport.number(row.get("row_version")).longValue(), draft, submitted,
                    draft != null ? draft : submitted, draft != null ? "DRAFT" : submitted != null ? "SUBMITTED" : null,
                    actions));
        }
        return out;
    }

    List<Map<String, Object>> blockers(String stored) {
        if (stored == null || stored.isBlank()) return List.of();
        try {
            return json.readValue(stored, BLOCKERS);
        } catch (Exception error) {
            return List.of();
        }
    }
}
