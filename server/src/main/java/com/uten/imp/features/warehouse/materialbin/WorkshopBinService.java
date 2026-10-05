package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.application.port.LineSideWarehousePort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

/**
 * 车间内料仓开通记录(ADR-147, V800 {@code workshop_bins})的唯一读写点。
 *
 * <p>内料仓这个仓库行只能由这里建出(开通命令), 一个车间一个, 挂在唯一主仓下; 数据库延迟约束保证
 * 每个未删除的内料仓恰有一条开通行。车间直送只经 {@link LineSideWarehousePort#openedBinOf} 只读取用,
 * 不再第一次直送时自动建仓。撤销开通只用来撤销设错的开通: 内料仓从来没有进出、余额、直送和单据
 * 引用时才允许, 软删仓库行(同一事务先删开通行)。
 *
 * <p>所有写方法运行在调用方(批量开通/撤销命令)的事务里, 调用方已按车间 UUID 排序取得建议锁。
 */
@Service
public class WorkshopBinService implements LineSideWarehousePort {

    /** 开通行(没开通时调用方拿到 null)。 */
    record OpenedBin(UUID workshopDepartmentId, UUID binWarehouseId, UUID sourceWarehouseId, long rowVersion) {}

    private static final String CODE_PREFIX = "LS-";
    private static final String REMARK =
            "车间内料仓(在「车间内料仓」里开通): 车间直送与整批领料的料放在这里, 不参与公共可用量与即时库存";
    private static final String BIN_SUFFIX = "内料仓";

    private final NamedParameterJdbcTemplate db;

    public WorkshopBinService(NamedParameterJdbcTemplate db) {
        this.db = db;
    }

    @Override
    @Transactional(propagation = Propagation.SUPPORTS, readOnly = true)
    public Optional<UUID> openedBinOf(UUID workshopDepartmentId) {
        if (workshopDepartmentId == null) return Optional.empty();
        List<UUID> rows = db.queryForList("""
                SELECT opened.bin_warehouse_id FROM workshop_bins opened
                JOIN warehouses bin ON bin.id = opened.bin_warehouse_id AND NOT bin.is_deleted
                WHERE opened.workshop_department_id = :workshop
                """, Map.of("workshop", workshopDepartmentId), UUID.class);
        return rows.isEmpty() ? Optional.empty() : Optional.of(rows.getFirst());
    }

    /** 读开通行并加行锁; 没开通返回 null。 */
    OpenedBin openedForUpdate(UUID workshopDepartmentId) {
        List<Map<String, Object>> rows = db.queryForList("""
                SELECT workshop_department_id, bin_warehouse_id, source_warehouse_id, row_version
                FROM workshop_bins WHERE workshop_department_id = :workshop
                FOR UPDATE
                """, Map.of("workshop", workshopDepartmentId));
        if (rows.isEmpty()) return null;
        Map<String, Object> row = rows.getFirst();
        return new OpenedBin((UUID) row.get("workshop_department_id"), (UUID) row.get("bin_warehouse_id"),
                (UUID) row.get("source_warehouse_id"),
                WorkshopMaterialBinSupport.number(row.get("row_version")).longValue());
    }

    /** 本车间内料仓的名字(「{车间名}内料仓」)已被别的未删除仓占用时返回占用者的名字; 没冲突返回 null。 */
    String nameConflict(UUID workshopDepartmentId) {
        List<String> rows = db.queryForList("""
                SELECT warehouse.name FROM departments workshop
                JOIN warehouses warehouse
                  ON NOT warehouse.is_deleted
                 AND fn_warehouse_name_key(warehouse.name) = fn_warehouse_name_key(workshop.name || :suffix)
                 AND NOT (warehouse.is_line_side AND warehouse.workshop_department_id = workshop.id)
                WHERE workshop.id = :workshop
                ORDER BY warehouse.code NULLS LAST, warehouse.id
                LIMIT 1
                """, Map.of("workshop", workshopDepartmentId, "suffix", BIN_SUFFIX), String.class);
        return rows.isEmpty() ? null : rows.getFirst();
    }

    /** 来源仓不能选的原因(给人看); 可以选或没选返回 null。与开通行守卫同一判定。 */
    String sourceRefusal(UUID sourceWarehouseId) {
        if (sourceWarehouseId == null) return null;
        List<Map<String, Object>> rows = db.queryForList("""
                SELECT warehouse.name, fn_warehouse_is_good_stock_leaf(warehouse.id) AS selectable
                FROM warehouses warehouse WHERE warehouse.id = :id
                """, Map.of("id", sourceWarehouseId));
        if (rows.isEmpty()) return "所选的发料来源仓不存在, 请刷新后重新选择";
        if (Boolean.TRUE.equals(rows.getFirst().get("selectable"))) return null;
        return "「" + rows.getFirst().get("name") + "」不能作发料来源仓: 只能选启用中的良品子仓"
                + " (不能是主仓、停用仓、不良品仓或车间内料仓)";
    }

    /**
     * 开通: 建出(或复用本车间撤销时留下的)内料仓仓库行, 写开通行。返回内料仓 id。
     * 调用方已校验车间、来源仓、名字冲突, 并持有本车间的建议锁。
     */
    UUID open(UUID workshopDepartmentId, UUID sourceWarehouseId, UUID actor) {
        Map<String, Object> workshop = db.queryForMap("""
                SELECT code, name FROM departments WHERE id = :workshop
                """, Map.of("workshop", workshopDepartmentId));
        String name = workshop.get("name") + BIN_SUFFIX;
        // 内料仓挂在发料来源仓的主仓下; 没选来源仓时挂唯一主仓(ADR-145 单主仓下两者恒为主仓 001)。
        UUID root = db.queryForObject("""
                SELECT COALESCE(CASE WHEN CAST(:source AS uuid) IS NULL THEN NULL
                                     ELSE fn_warehouse_main_id(CAST(:source AS uuid)) END,
                                fn_warehouse_root_id())
                """, new MapSqlParameterSource("source", sourceWarehouseId == null ? null : sourceWarehouseId.toString()),
                UUID.class);
        if (root == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "仓库资料里没有唯一的主仓, 请先选发料来源仓再开通内料仓");
        }
        // 撤销开通时软删的内料仓(从未用过)原样复用: 编号终身占用, 复用原行即保留原编号。
        List<UUID> revived = db.queryForList("""
                UPDATE warehouses SET is_deleted = FALSE, deleted_at = NULL, status = '使用', name = :name,
                                      parent_id = :root, remark = :remark, updated_by = :actor, updated_at = now()
                WHERE id = (SELECT candidate.id FROM warehouses candidate
                            WHERE candidate.is_line_side AND candidate.is_deleted
                              AND candidate.workshop_department_id = :workshop
                            ORDER BY candidate.deleted_at DESC NULLS LAST, candidate.created_at DESC, candidate.id
                            LIMIT 1)
                RETURNING id
                """, new MapSqlParameterSource("workshop", workshopDepartmentId).addValue("name", name)
                .addValue("root", root).addValue("remark", REMARK).addValue("actor", actor), UUID.class);
        UUID bin = revived.isEmpty() ? insertBin(workshopDepartmentId, (String) workshop.get("code"), name, root, actor)
                : revived.getFirst();
        db.update("""
                INSERT INTO workshop_bins(workshop_department_id, bin_warehouse_id, source_warehouse_id,
                                          opened_by, updated_by)
                VALUES (:workshop, :bin, CAST(:source AS uuid), :actor, :actor)
                """, new MapSqlParameterSource("workshop", workshopDepartmentId).addValue("bin", bin)
                .addValue("source", sourceWarehouseId == null ? null : sourceWarehouseId.toString())
                .addValue("actor", actor));
        return bin;
    }

    private UUID insertBin(UUID workshopDepartmentId, String workshopCode, String name, UUID root, UUID actor) {
        String base = CODE_PREFIX + (workshopCode == null || workshopCode.isBlank()
                ? workshopDepartmentId.toString().substring(0, 8) : workshopCode.strip());
        String code = base;
        for (int suffix = 2; codeTaken(code); suffix++) code = base + "-" + suffix;
        return db.queryForObject("""
                INSERT INTO warehouses(code, name, remark, is_accountable, is_defective, is_line_side,
                                       workshop_department_id, parent_id, status, auto_created, created_by, updated_by)
                VALUES (:code, :name, :remark, TRUE, FALSE, TRUE, :workshop, :root, '使用', FALSE, :actor, :actor)
                RETURNING id
                """, new MapSqlParameterSource("code", code).addValue("name", name).addValue("remark", REMARK)
                .addValue("workshop", workshopDepartmentId).addValue("root", root).addValue("actor", actor), UUID.class);
    }

    /** 编号终身占用(V276): 现有仓库行或历史占号里有过这个编号都不能再用。 */
    private boolean codeTaken(String code) {
        Boolean taken = db.queryForObject("""
                SELECT EXISTS (SELECT 1 FROM warehouses WHERE upper(btrim(code)) = upper(:code))
                    OR EXISTS (SELECT 1 FROM master_code_reservation_members member
                               WHERE member.master_domain = 'WAREHOUSE' AND member.normalized_code = upper(:code))
                """, Map.of("code", code), Boolean.class);
        return Boolean.TRUE.equals(taken);
    }

    /** 改来源仓(开通状态版本加一)。 */
    void changeSource(OpenedBin opened, UUID sourceWarehouseId, UUID actor) {
        db.update("""
                UPDATE workshop_bins
                SET source_warehouse_id = CAST(:source AS uuid), updated_by = :actor, row_version = row_version + 1
                WHERE workshop_department_id = :workshop
                """, new MapSqlParameterSource("workshop", opened.workshopDepartmentId())
                .addValue("source", sourceWarehouseId == null ? null : sourceWarehouseId.toString())
                .addValue("actor", actor));
    }

    /** 开启/撤销整批领料也是开通状态的变化: 开通行版本加一(页面据此判断有没有被别人改过)。 */
    void touch(OpenedBin opened, UUID actor) {
        db.update("""
                UPDATE workshop_bins SET updated_by = :actor, row_version = row_version + 1
                WHERE workshop_department_id = :workshop
                """, new MapSqlParameterSource("workshop", opened.workshopDepartmentId()).addValue("actor", actor));
    }

    /** 撤销开通的前置条件(给人看); 空 = 可以撤销。与 {@code fn_workshop_bin_revoke_blockers} 同一定义。 */
    List<String> revokeBlockers(UUID binWarehouseId) {
        String joined = db.queryForObject("""
                SELECT array_to_string(fn_workshop_bin_revoke_blockers(:bin), CHR(10))
                """, Map.of("bin", binWarehouseId), String.class);
        if (joined == null || joined.isBlank()) return List.of();
        return Arrays.asList(joined.split("\n"));
    }

    /**
     * 撤销开通: 删掉停用状态的整批领料设置行(它引用开通行)、删开通行、软删内料仓仓库行。
     * 调用方已确认 {@link #revokeBlockers} 为空。
     */
    void revoke(OpenedBin opened, UUID actor) {
        db.update("""
                DELETE FROM workshop_material_settings
                WHERE workshop_department_id = :workshop AND NOT periodic_enabled
                """, Map.of("workshop", opened.workshopDepartmentId()));
        db.update("DELETE FROM workshop_bins WHERE workshop_department_id = :workshop",
                Map.of("workshop", opened.workshopDepartmentId()));
        db.update("""
                UPDATE warehouses SET is_deleted = TRUE, deleted_at = now(), updated_by = :actor, updated_at = now()
                WHERE id = :bin
                """, new MapSqlParameterSource("bin", opened.binWarehouseId()).addValue("actor", actor));
    }
}
