package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.common.finance.MoneyPolicy;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialCommandLedger.Outcome;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.ContainerBatchUpdate;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.ContainerEdit;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.ContainerSpec;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.ContainerView;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.MachineBatchCreate;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.MachineBatchUpdate;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.MachineEdit;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.MachineList;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.MachineView;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * 车间机台与机台容器 (ADR-131 §5.1 第 4 步): 盘点按机台录料斗、储料桶。
 *
 * <p>批量新增 (台数、编号前缀、每台容器)、勾选多行改一格即批量生效、单独增删改; 盘点用过的机台
 * 与容器只能停用不能删除 (数据库守卫兜底)。
 */
@Service
public class WorkshopMachineService {

    private static final int MAX_BATCH = 200;

    private final NamedParameterJdbcTemplate db;
    private final WorkshopMaterialCommandLedger commands;
    private final WorkshopMaterialScope scope;
    private final SecurityContextCurrentUser currentUser;

    public WorkshopMachineService(NamedParameterJdbcTemplate db, WorkshopMaterialCommandLedger commands,
                                  WorkshopMaterialScope scope, SecurityContextCurrentUser currentUser) {
        this.db = db;
        this.commands = commands;
        this.scope = scope;
        this.currentUser = currentUser;
    }

    @Transactional(readOnly = true)
    public MachineList list(UUID workshopId) {
        if (workshopId == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择车间");
        scope.requireWorkshop(workshopId);
        return new MachineList(machines(workshopId, null));
    }

    @Transactional
    public MachineList createBatch(MachineBatchCreate request) {
        UUID workshop = request.workshopDepartmentId();
        if (workshop == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择车间");
        scope.requireWorkshop(workshop);
        requireWorkshopDepartment(workshop);
        int count = request.count() == null ? 0 : request.count();
        if (count < 1 || count > MAX_BATCH) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "一次新增 1 到 " + MAX_BATCH + " 台");
        }
        int start = request.startNo() == null ? 1 : request.startNo();
        if (start < 0) throw new ApiException(ErrorCode.VALIDATION_FAILED, "起始编号不能小于 0");
        String prefix = request.codePrefix() == null ? "" : request.codePrefix().strip();
        List<ContainerSpec> containers = request.containers() == null ? List.of() : request.containers();
        Set<String> containerNames = new LinkedHashSet<>();
        for (ContainerSpec container : containers) {
            if (container == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "容器信息不完整");
            String name = containerName(container.name());
            requireCapacity(container.capacityQty());
            if (!containerNames.add(name)) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "同一台机的容器名称不能重复: " + name);
            }
        }
        return commands.execute("MACHINE_BATCH_CREATE", request.idempotencyKey(), request, MachineList.class, () -> {
            UUID actor = currentUser.requireId();
            List<UUID> created = new ArrayList<>();
            for (int index = 0; index < count; index++) {
                int number = start + index;
                String code = prefix + number;
                if (code.length() > 40) throw new ApiException(ErrorCode.VALIDATION_FAILED, "机台编号太长: " + code);
                Integer taken = db.queryForObject("""
                        SELECT count(*) FROM workshop_machines
                        WHERE workshop_department_id = :workshop AND code = :code AND NOT is_deleted
                        """, Map.of("workshop", workshop, "code", code), Integer.class);
                if (taken != null && taken > 0) {
                    throw new ApiException(ErrorCode.CONFLICT, "机台编号 " + code + " 已经有了, 请换一个起始编号");
                }
                UUID machine = UUID.randomUUID();
                WorkshopMaterialGuards.guarded(() -> db.update("""
                        INSERT INTO workshop_machines(id, workshop_department_id, code, name, sort_order, created_by)
                        VALUES (:id, :workshop, :code, :name, :sort, :actor)
                        """, new MapSqlParameterSource("id", machine).addValue("workshop", workshop)
                        .addValue("code", code).addValue("name", prefix.isEmpty() ? number + " 号机" : code)
                        .addValue("sort", number).addValue("actor", actor)));
                int sort = 0;
                for (ContainerSpec container : containers) {
                    int order = sort++;
                    WorkshopMaterialGuards.guarded(() -> db.update("""
                            INSERT INTO workshop_machine_containers(id, machine_id, name, capacity_qty, sort_order,
                                                                    created_by)
                            VALUES (:id, :machine, :name, :capacity, :sort, :actor)
                            """, new MapSqlParameterSource("id", UUID.randomUUID()).addValue("machine", machine)
                            .addValue("name", containerName(container.name()))
                            .addValue("capacity", MoneyPolicy.quantity(container.capacityQty()))
                            .addValue("sort", order).addValue("actor", actor)));
                }
                created.add(machine);
            }
            return new Outcome<>(null, new MachineList(machines(workshop, created)));
        });
    }

    /** 批量改机台 (勾选多行改一格即批量生效); 每行带自己的版本。 */
    @Transactional
    public MachineList updateBatch(MachineBatchUpdate request) {
        if (request.items() == null || request.items().isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请至少改一台机台");
        }
        return commands.execute("MACHINE_BATCH_UPDATE", request.idempotencyKey(), request, MachineList.class, () -> {
            UUID actor = currentUser.requireId();
            List<UUID> ids = new ArrayList<>();
            UUID workshop = null;
            for (MachineEdit edit : request.items()) {
                if (edit == null || edit.id() == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "机台不完整");
                Map<String, Object> row = lockMachine(edit.id());
                workshop = (UUID) row.get("workshop_department_id");
                scope.requireWorkshop(workshop);
                WorkshopMaterialBinSupport.requireVersion(edit.expectedVersion(),
                        WorkshopMaterialBinSupport.number(row.get("row_version")).longValue(), "机台 " + row.get("code"));
                String name = edit.name() == null ? (String) row.get("name") : edit.name().strip();
                if (name.isEmpty() || name.length() > 100) {
                    throw new ApiException(ErrorCode.VALIDATION_FAILED, "机台名称 1 到 100 个字");
                }
                String model = edit.model() == null ? (String) row.get("model")
                        : edit.model().isBlank() ? null : edit.model().strip();
                if (model != null && model.length() > 100) {
                    throw new ApiException(ErrorCode.VALIDATION_FAILED, "机台型号最多 100 个字");
                }
                BigDecimal tonnage = edit.tonnage() == null ? (BigDecimal) row.get("tonnage") : edit.tonnage();
                if (tonnage != null && tonnage.signum() <= 0) {
                    throw new ApiException(ErrorCode.VALIDATION_FAILED, "吨位必须大于 0");
                }
                WorkshopMaterialGuards.guarded(() -> db.update("""
                        UPDATE workshop_machines
                        SET name = :name, model = :model, tonnage = :tonnage, enabled = :enabled, sort_order = :sort,
                            remark = :remark, row_version = row_version + 1, updated_by = :actor, updated_at = now()
                        WHERE id = :id
                        """, new MapSqlParameterSource("name", name).addValue("model", model)
                        .addValue("tonnage", tonnage)
                        .addValue("enabled", edit.enabled() == null ? row.get("enabled") : edit.enabled())
                        .addValue("sort", edit.sortOrder() == null ? row.get("sort_order") : edit.sortOrder())
                        .addValue("remark", edit.remark() == null ? row.get("remark")
                                : edit.remark().isBlank() ? null : edit.remark().strip())
                        .addValue("actor", actor).addValue("id", edit.id())));
                ids.add(edit.id());
            }
            return new Outcome<>(null, new MachineList(machines(workshop, ids)));
        });
    }

    /** 批量新增或修改容器 (id 为空 = 新增)。 */
    @Transactional
    public MachineList updateContainers(ContainerBatchUpdate request) {
        if (request.items() == null || request.items().isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请至少改一个容器");
        }
        return commands.execute("CONTAINER_BATCH_UPDATE", request.idempotencyKey(), request, MachineList.class, () -> {
            UUID actor = currentUser.requireId();
            Set<UUID> machines = new LinkedHashSet<>();
            UUID workshop = null;
            for (ContainerEdit edit : request.items()) {
                if (edit == null || edit.machineId() == null) {
                    throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择容器所在的机台");
                }
                Map<String, Object> machine = lockMachine(edit.machineId());
                workshop = (UUID) machine.get("workshop_department_id");
                scope.requireWorkshop(workshop);
                if (Boolean.TRUE.equals(machine.get("is_deleted"))) {
                    throw new ApiException(ErrorCode.CONFLICT, "机台 " + machine.get("code") + " 已删除");
                }
                String name = containerName(edit.name());
                requireCapacity(edit.capacityQty());
                if (edit.id() == null) {
                    WorkshopMaterialGuards.guarded(() -> db.update("""
                            INSERT INTO workshop_machine_containers(id, machine_id, name, capacity_qty, enabled,
                                                                    sort_order, created_by)
                            VALUES (:id, :machine, :name, :capacity, :enabled, :sort, :actor)
                            """, new MapSqlParameterSource("id", UUID.randomUUID()).addValue("machine", edit.machineId())
                            .addValue("name", name).addValue("capacity", MoneyPolicy.quantity(edit.capacityQty()))
                            .addValue("enabled", edit.enabled() == null || edit.enabled())
                            .addValue("sort", edit.sortOrder() == null ? 0 : edit.sortOrder())
                            .addValue("actor", actor)));
                } else {
                    List<Map<String, Object>> rows = db.queryForList("""
                            SELECT row_version, enabled, sort_order FROM workshop_machine_containers
                            WHERE id = :id AND machine_id = :machine AND NOT is_deleted FOR UPDATE
                            """, Map.of("id", edit.id(), "machine", edit.machineId()));
                    if (rows.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, "容器不存在或已删除");
                    WorkshopMaterialBinSupport.requireVersion(edit.expectedVersion(),
                            WorkshopMaterialBinSupport.number(rows.getFirst().get("row_version")).longValue(),
                            "容器 " + name);
                    WorkshopMaterialGuards.guarded(() -> db.update("""
                            UPDATE workshop_machine_containers
                            SET name = :name, capacity_qty = :capacity, enabled = :enabled, sort_order = :sort,
                                row_version = row_version + 1, updated_by = :actor, updated_at = now()
                            WHERE id = :id
                            """, new MapSqlParameterSource("name", name)
                            .addValue("capacity", MoneyPolicy.quantity(edit.capacityQty()))
                            .addValue("enabled", edit.enabled() == null ? rows.getFirst().get("enabled") : edit.enabled())
                            .addValue("sort", edit.sortOrder() == null ? rows.getFirst().get("sort_order")
                                    : edit.sortOrder())
                            .addValue("actor", actor).addValue("id", edit.id())));
                }
                machines.add(edit.machineId());
            }
            return new Outcome<>(null, new MachineList(machines(workshop, List.copyOf(machines))));
        });
    }

    /** 删机台 (连同它的容器); 盘点用过的只能停用。 */
    @Transactional
    public void deleteMachine(UUID machineId, Long expectedVersion) {
        Map<String, Object> machine = lockMachine(machineId);
        scope.requireWorkshop((UUID) machine.get("workshop_department_id"));
        if (Boolean.TRUE.equals(machine.get("is_deleted"))) return;
        WorkshopMaterialBinSupport.requireVersion(expectedVersion,
                WorkshopMaterialBinSupport.number(machine.get("row_version")).longValue(), "机台");
        requireNeverCounted("machine_id", machineId);
        UUID actor = currentUser.requireId();
        for (UUID container : db.queryForList("""
                SELECT id FROM workshop_machine_containers WHERE machine_id = :machine AND NOT is_deleted
                """, Map.of("machine", machineId), UUID.class)) {
            requireNeverCounted("container_id", container);
            softDelete("workshop_machine_containers", container, actor);
        }
        softDelete("workshop_machines", machineId, actor);
    }

    @Transactional
    public void deleteContainer(UUID containerId, Long expectedVersion) {
        List<Map<String, Object>> rows = db.queryForList("""
                SELECT container.row_version, container.is_deleted, machine.workshop_department_id
                FROM workshop_machine_containers container
                JOIN workshop_machines machine ON machine.id = container.machine_id
                WHERE container.id = :id FOR UPDATE OF container
                """, Map.of("id", containerId));
        if (rows.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, "容器不存在");
        Map<String, Object> row = rows.getFirst();
        scope.requireWorkshop((UUID) row.get("workshop_department_id"));
        if (Boolean.TRUE.equals(row.get("is_deleted"))) return;
        WorkshopMaterialBinSupport.requireVersion(expectedVersion,
                WorkshopMaterialBinSupport.number(row.get("row_version")).longValue(), "容器");
        requireNeverCounted("container_id", containerId);
        softDelete("workshop_machine_containers", containerId, currentUser.requireId());
    }

    private void requireNeverCounted(String column, UUID id) {
        // column 只取本类里写死的两个列名, 不是请求输入。
        if (!Set.of("machine_id", "container_id").contains(column)) throw new IllegalArgumentException(column);
        Integer used = db.queryForObject("SELECT count(*) FROM workshop_material_count_lines WHERE " + column + " = :id",
                Map.of("id", id), Integer.class);
        if (used != null && used > 0) {
            throw new ApiException(ErrorCode.CONFLICT, "盘点用过的机台或容器只能停用, 不能删除");
        }
    }

    private void softDelete(String table, UUID id, UUID actor) {
        if (!Set.of("workshop_machines", "workshop_machine_containers").contains(table)) {
            throw new IllegalArgumentException(table);
        }
        WorkshopMaterialGuards.guarded(() -> db.update("UPDATE " + table + """
                 SET is_deleted = TRUE, deleted_at = now(), row_version = row_version + 1, updated_by = :actor,
                     updated_at = now()
                WHERE id = :id
                """, new MapSqlParameterSource("actor", actor).addValue("id", id)));
    }

    private Map<String, Object> lockMachine(UUID machineId) {
        List<Map<String, Object>> rows = db.queryForList("""
                SELECT id, workshop_department_id, code, name, model, tonnage, enabled, sort_order, remark,
                       is_deleted, row_version
                FROM workshop_machines WHERE id = :id FOR UPDATE
                """, Map.of("id", machineId));
        if (rows.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, "机台不存在");
        return rows.getFirst();
    }

    private List<MachineView> machines(UUID workshop, List<UUID> only) {
        if (workshop == null) return List.of();
        MapSqlParameterSource params = new MapSqlParameterSource("workshop", workshop);
        String filter = "";
        if (only != null) {
            if (only.isEmpty()) return List.of();
            filter = " AND machine.id IN (:only)";
            params.addValue("only", only);
        }
        Map<UUID, List<ContainerView>> containers = new LinkedHashMap<>();
        for (Map<String, Object> row : db.queryForList("""
                SELECT container.id, container.machine_id, container.name, container.capacity_qty, container.enabled,
                       container.sort_order, container.row_version
                FROM workshop_machine_containers container
                JOIN workshop_machines machine ON machine.id = container.machine_id
                WHERE machine.workshop_department_id = :workshop AND NOT machine.is_deleted
                  AND NOT container.is_deleted""" + filter + """

                ORDER BY container.sort_order, container.name
                """, params)) {
            containers.computeIfAbsent((UUID) row.get("machine_id"), key -> new ArrayList<>())
                    .add(new ContainerView((UUID) row.get("id"), (UUID) row.get("machine_id"), (String) row.get("name"),
                            WorkshopMaterialBinSupport.decimal(row.get("capacity_qty")),
                            Boolean.TRUE.equals(row.get("enabled")),
                            WorkshopMaterialBinSupport.number(row.get("sort_order")).intValue(),
                            WorkshopMaterialBinSupport.number(row.get("row_version")).longValue()));
        }
        List<MachineView> out = new ArrayList<>();
        for (Map<String, Object> row : db.queryForList("""
                SELECT machine.id, machine.workshop_department_id, machine.code, machine.name, machine.model,
                       machine.tonnage, machine.enabled, machine.sort_order, machine.remark, machine.row_version
                FROM workshop_machines machine
                WHERE machine.workshop_department_id = :workshop AND NOT machine.is_deleted""" + filter + """

                ORDER BY machine.sort_order, machine.code
                """, params)) {
            UUID id = (UUID) row.get("id");
            out.add(new MachineView(id, (UUID) row.get("workshop_department_id"), (String) row.get("code"),
                    (String) row.get("name"), (String) row.get("model"),
                    WorkshopMaterialBinSupport.decimal(row.get("tonnage")), Boolean.TRUE.equals(row.get("enabled")),
                    WorkshopMaterialBinSupport.number(row.get("sort_order")).intValue(), (String) row.get("remark"),
                    WorkshopMaterialBinSupport.number(row.get("row_version")).longValue(),
                    containers.getOrDefault(id, List.of())));
        }
        return out;
    }

    private void requireWorkshopDepartment(UUID workshopId) {
        Integer found = db.queryForObject("""
                SELECT count(*) FROM departments workshop
                JOIN departments production ON production.id = workshop.parent_id AND production.code = 'DEPT_PROD'
                WHERE workshop.id = :id AND NOT workshop.is_deleted
                """, Map.of("id", workshopId), Integer.class);
        if (found == null || found == 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "机台只能挂在生产部下的车间");
        }
    }

    private static String containerName(String raw) {
        String name = raw == null ? "" : raw.strip();
        if (name.isEmpty() || name.length() > 40) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "容器名称 1 到 40 个字 (例如干燥机料斗、储料桶)");
        }
        return name;
    }

    private static void requireCapacity(BigDecimal capacity) {
        if (capacity == null || capacity.signum() <= 0
                || capacity.stripTrailingZeros().scale() > MoneyPolicy.QUANTITY_SCALE) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "容器容量 (公斤) 必须大于 0, 最多 4 位小数");
        }
    }
}
