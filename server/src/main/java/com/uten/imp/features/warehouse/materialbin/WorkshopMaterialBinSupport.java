package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.PeriodRef;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Component;

import java.math.BigDecimal;
import java.sql.Date;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/**
 * 内料仓各服务共用的读与锁: 设置行、期间行、料的身份。锁序照 ADR-131 §10:
 * 发料/退回/其它耗用对设置行 FOR SHARE, 开始/撤回/提交/更正盘点与补录对设置行 FOR UPDATE, 再锁期间行。
 */
@Component
class WorkshopMaterialBinSupport {

    /** 一个车间的整批领料设置。 */
    record Settings(UUID workshopDepartmentId, String workshopName, boolean enabled, UUID binWarehouseId,
                    LocalDate goLiveDate, long rowVersion) {}

    /** 一期。 */
    record Period(UUID id, UUID binWarehouseId, UUID workshopDepartmentId, int no, LocalDate startDate,
                  LocalDate endDate, String status, String closeState, OffsetDateTime heldUntil, long rowVersion) {
        PeriodRef ref() {
            return new PeriodRef(id, no, startDate, endDate, status, closeState);
        }
    }

    /** 一种整批领料的料 (货品 + 颜色)。 */
    record Material(UUID goodsId, UUID colorId) {}

    /** 料的主档信息。 */
    record MaterialInfo(UUID goodsId, String code, String name, UUID unitId, String unitName, boolean periodic,
                        String costBasis, BigDecimal bulkPackageQty, UUID owningWarehouseId, boolean deleted) {
        String label() {
            return name == null || name.isBlank() ? (code == null ? "这种料" : code) : name;
        }
    }

    private static final String SETTINGS_COLUMNS = """
            settings.workshop_department_id, workshop.name AS workshop_name, settings.periodic_enabled,
            settings.periodic_bin_warehouse_id, settings.go_live_date, settings.row_version
            """;

    private static final String PERIOD_COLUMNS = """
            period.id, period.bin_warehouse_id, period.workshop_department_id, period.period_no,
            period.start_date, period.end_date, period.status, period.close_state, period.held_until,
            period.row_version
            """;

    private final NamedParameterJdbcTemplate db;

    WorkshopMaterialBinSupport(NamedParameterJdbcTemplate db) {
        this.db = db;
    }

    // ------------------------------------------------------------------ 设置

    Settings settings(UUID workshopDepartmentId) {
        return first(db.queryForList("SELECT " + SETTINGS_COLUMNS + """
                FROM workshop_material_settings settings
                JOIN departments workshop ON workshop.id = settings.workshop_department_id
                WHERE settings.workshop_department_id = :workshop
                """, Map.of("workshop", workshopDepartmentId)));
    }

    /** 已开启的设置, 对设置行加共享锁 (与开始盘点的排他锁互斥, 归期不会交错)。 */
    Settings enabledSettingsForShare(UUID workshopDepartmentId) {
        return requireEnabled(first(db.queryForList("SELECT " + SETTINGS_COLUMNS + """
                FROM workshop_material_settings settings
                JOIN departments workshop ON workshop.id = settings.workshop_department_id
                WHERE settings.workshop_department_id = :workshop
                FOR SHARE OF settings
                """, Map.of("workshop", workshopDepartmentId))));
    }

    Settings enabledSettingsForUpdate(UUID workshopDepartmentId) {
        return requireEnabled(settingsForUpdate(workshopDepartmentId));
    }

    Settings settingsForUpdate(UUID workshopDepartmentId) {
        return first(db.queryForList("SELECT " + SETTINGS_COLUMNS + """
                FROM workshop_material_settings settings
                JOIN departments workshop ON workshop.id = settings.workshop_department_id
                WHERE settings.workshop_department_id = :workshop
                FOR UPDATE OF settings
                """, Map.of("workshop", workshopDepartmentId)));
    }

    /** 按内料仓找已开启的设置 (期间、盘点单从内料仓回到车间)。 */
    Settings settingsByBin(UUID binWarehouseId) {
        return first(db.queryForList("SELECT " + SETTINGS_COLUMNS + """
                FROM workshop_material_settings settings
                JOIN departments workshop ON workshop.id = settings.workshop_department_id
                WHERE settings.periodic_bin_warehouse_id = :bin
                """, Map.of("bin", binWarehouseId)));
    }

    private static Settings requireEnabled(Settings settings) {
        if (settings == null || !settings.enabled()) {
            throw new ApiException(ErrorCode.CONFLICT, "这个车间还没有开启整批领料");
        }
        return settings;
    }

    private static Settings first(List<Map<String, Object>> rows) {
        if (rows.isEmpty()) return null;
        Map<String, Object> row = rows.getFirst();
        return new Settings((UUID) row.get("workshop_department_id"), (String) row.get("workshop_name"),
                Boolean.TRUE.equals(row.get("periodic_enabled")), (UUID) row.get("periodic_bin_warehouse_id"),
                date(row.get("go_live_date")), number(row.get("row_version")).longValue());
    }

    // ------------------------------------------------------------------ 期间

    Period period(UUID periodId) {
        List<Period> rows = periods("period.id = :period", new MapSqlParameterSource("period", periodId), "");
        if (rows.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, "这一期不存在");
        return rows.getFirst();
    }

    Period periodForUpdate(UUID periodId) {
        List<Period> rows = periods("period.id = :period", new MapSqlParameterSource("period", periodId),
                " FOR UPDATE");
        if (rows.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, "这一期不存在");
        return rows.getFirst();
    }

    /** 本仓开着的那一期; 没有时说明设置异常。 */
    Period openPeriod(UUID binWarehouseId) {
        List<Period> rows = periods("period.bin_warehouse_id = :bin AND period.status = 'OPEN'",
                new MapSqlParameterSource("bin", binWarehouseId), "");
        if (rows.isEmpty()) throw new ApiException(ErrorCode.CONFLICT, "这个内料仓没有开着的期间, 请联系仓库核对设置");
        return rows.getFirst();
    }

    Period periodByNo(UUID binWarehouseId, int periodNo) {
        List<Period> rows = periods("period.bin_warehouse_id = :bin AND period.period_no = :no",
                new MapSqlParameterSource("bin", binWarehouseId).addValue("no", periodNo), "");
        return rows.isEmpty() ? null : rows.getFirst();
    }

    /** 最早一张正在盘点或已盘点、还没结算的期间。 */
    Period pendingPeriod(UUID binWarehouseId) {
        List<Period> rows = periods("period.bin_warehouse_id = :bin AND period.status IN ('COUNTING', 'COUNTED')",
                new MapSqlParameterSource("bin", binWarehouseId), "");
        return rows.isEmpty() ? null : rows.getFirst();
    }

    List<Period> periodsOf(UUID binWarehouseId) {
        return periods("period.bin_warehouse_id = :bin", new MapSqlParameterSource("bin", binWarehouseId), "");
    }

    private List<Period> periods(String where, MapSqlParameterSource params, String lock) {
        List<Period> out = new ArrayList<>();
        for (Map<String, Object> row : db.queryForList("SELECT " + PERIOD_COLUMNS
                + " FROM workshop_material_periods period WHERE " + where
                + " ORDER BY period.period_no" + lock, params)) {
            out.add(new Period((UUID) row.get("id"), (UUID) row.get("bin_warehouse_id"),
                    (UUID) row.get("workshop_department_id"), number(row.get("period_no")).intValue(),
                    date(row.get("start_date")), date(row.get("end_date")), (String) row.get("status"),
                    (String) row.get("close_state"), offset(row.get("held_until")),
                    number(row.get("row_version")).longValue()));
        }
        return out;
    }

    static void requireVersion(Long expected, long actual, String what) {
        if (expected == null || expected != actual) {
            throw new ApiException(ErrorCode.CONFLICT, what + "已被别人改过, 请刷新后再试");
        }
    }

    // ------------------------------------------------------------------ 料

    MaterialInfo material(UUID goodsId) {
        List<Map<String, Object>> rows = db.queryForList("""
                SELECT goods.id, goods.code, goods.name, goods.unit_id, unit.name AS unit_name,
                       goods.issue_method = 'PERIODIC' AS periodic, goods.periodic_cost_basis,
                       goods.bulk_package_qty, goods.owning_warehouse_id, COALESCE(goods.is_deleted, FALSE) AS deleted
                FROM goods LEFT JOIN units unit ON unit.id = goods.unit_id
                WHERE goods.id = :goods
                """, Map.of("goods", goodsId));
        if (rows.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, "货品不存在");
        Map<String, Object> row = rows.getFirst();
        return new MaterialInfo((UUID) row.get("id"), (String) row.get("code"), (String) row.get("name"),
                (UUID) row.get("unit_id"), (String) row.get("unit_name"), Boolean.TRUE.equals(row.get("periodic")),
                (String) row.get("periodic_cost_basis"), (BigDecimal) row.get("bulk_package_qty"),
                (UUID) row.get("owning_warehouse_id"), Boolean.TRUE.equals(row.get("deleted")));
    }

    /** 必须是整批领料的料 (进出内料仓、盘点只认它)。 */
    MaterialInfo periodicMaterial(UUID goodsId) {
        if (goodsId == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择料");
        MaterialInfo info = material(goodsId);
        if (!info.periodic() || info.deleted()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "「" + info.label() + "」不是整批领到车间内料仓的料");
        }
        if (info.unitId() == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "「" + info.label() + "」没有基本单位, 请先在基础资料里补上");
        }
        return info;
    }

    void requireColor(UUID colorId) {
        if (colorId == null) return;
        Integer found = db.queryForObject("SELECT count(*) FROM colors WHERE id = :color",
                Map.of("color", colorId), Integer.class);
        if (found == null || found == 0) throw new ApiException(ErrorCode.VALIDATION_FAILED, "颜色不存在");
    }

    String employeeName(UUID employeeId) {
        if (employeeId == null) return null;
        List<String> names = db.queryForList("SELECT full_name FROM employees WHERE id = :id",
                Map.of("id", employeeId), String.class);
        return names.isEmpty() ? null : names.getFirst();
    }

    /**
     * 车间内料仓发料的默认出库仓 (ADR-147 唯一定义 {@code fn_workshop_bin_default_source}): 来源仓有可发量 ->
     * 货品所属仓库 (可选良品子仓) -> 可发量最大的良品子仓; 车间没开通内料仓时从第二步起算。都没有返回 null。
     */
    UUID defaultSource(UUID workshopDepartmentId, UUID goodsId, UUID colorId) {
        return db.queryForObject("""
                SELECT fn_workshop_bin_default_source(
                    (SELECT opened.bin_warehouse_id FROM workshop_bins opened
                     WHERE opened.workshop_department_id = :workshop), :goods, CAST(:color AS uuid))
                """, new MapSqlParameterSource("workshop", workshopDepartmentId).addValue("goods", goodsId)
                .addValue("color", colorId == null ? null : colorId.toString()), UUID.class);
    }

    String warehouseName(UUID warehouseId) {
        if (warehouseId == null) return null;
        List<String> names = db.queryForList("SELECT name FROM warehouses WHERE id = :id",
                Map.of("id", warehouseId), String.class);
        return names.isEmpty() ? null : names.getFirst();
    }

    // ------------------------------------------------------------------ 取值

    static LocalDate date(Object value) {
        if (value == null) return null;
        if (value instanceof LocalDate local) return local;
        if (value instanceof Date sql) return sql.toLocalDate();
        return LocalDate.parse(value.toString());
    }

    static OffsetDateTime offset(Object value) {
        if (value == null) return null;
        if (value instanceof OffsetDateTime time) return time;
        if (value instanceof java.sql.Timestamp stamp) {
            return stamp.toInstant().atOffset(java.time.ZoneOffset.UTC);
        }
        if (value instanceof java.time.Instant instant) return instant.atOffset(java.time.ZoneOffset.UTC);
        return OffsetDateTime.parse(value.toString());
    }

    static Number number(Object value) {
        return value == null ? 0 : (Number) value;
    }

    static BigDecimal decimal(Object value) {
        if (value == null) return null;
        if (value instanceof BigDecimal decimal) return decimal;
        return new BigDecimal(value.toString());
    }

    static BigDecimal zero(Object value) {
        BigDecimal decimal = decimal(value);
        return decimal == null ? BigDecimal.ZERO : decimal;
    }

    static boolean same(UUID left, UUID right) {
        return Objects.equals(left, right);
    }
}
