package com.uten.imp.features.master.warehouse;

import com.uten.imp.application.port.LineSideWarehousePort;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.UUID;

/**
 * 线边仓自动配置(V595 / ADR-089)。
 *
 * <p>用户口径(2026-09-16)：「创建一个这种仓库总觉得不对，明明现实中没有，要么就做个虚拟的、
 * 不算在现实的。」线边仓仍然必须是一个真实叶仓(ADR-087 的四道硬闸没有变)，但它不再要求
 * 任何人去仓库资料里手工建：第一次直送时按「车间 × 收料主仓」自动配置一个，标记
 * {@code auto_created}，并由 {@code fn_line_side_stock_targets_demand} 把它排除在公共可用量、
 * 即时库存与物料分析之外——现实里它就是车间的料架，不是仓库。
 *
 * <p>同一车间在不同收料主仓下各自一个线边仓(同主仓分仓领料是 ADR-073 的硬前提)。
 * 手工建过的线边仓照旧被复用，不会重复建。
 */
@Service
@RequiredArgsConstructor
public class LineSideWarehouseService implements LineSideWarehousePort {

    private static final String CODE_PREFIX = "LS-";

    private final EntityManager em;
    private final WarehouseRepository repo;

    /**
     * 返回本车间与 {@code demandWarehouseId} 同主仓的线边仓，没有就在同一事务里建一个。
     *
     * @param workshopDepartmentId 车间部门(执行段的 workshop_department_id)
     * @param demandWarehouseId    收料需求所在仓(计划包的主仓或其叶仓)；线边仓挂在它的主仓下
     */
    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public UUID ensure(UUID workshopDepartmentId, UUID demandWarehouseId) {
        if (workshopDepartmentId == null || demandWarehouseId == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "线边仓配置缺少车间或收料仓");
        }
        List<UUID> existing = NativeQueryResults.typedRows(em.createNativeQuery("""
                        SELECT line_side.id
                        FROM warehouses line_side
                        WHERE line_side.is_line_side
                          AND line_side.is_deleted = FALSE
                          AND line_side.workshop_department_id = :workshopId
                          AND fn_warehouse_same_main(line_side.id, :warehouseId)
                        ORDER BY line_side.auto_created, line_side.created_at, line_side.id
                        """)
                .setParameter("workshopId", workshopDepartmentId)
                .setParameter("warehouseId", demandWarehouseId), UUID.class);
        if (!existing.isEmpty()) return existing.getFirst();

        // 同一车间的两笔直送可能并发首次配置：按车间取事务级建议锁，锁后再查一次。
        em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(:key, 595))")
                .setParameter("key", "LINE-SIDE-WAREHOUSE:" + workshopDepartmentId)
                .getSingleResult();
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT department.code, department.name,
                               main.id, main.name,
                               (SELECT line_side.id FROM warehouses line_side
                                 WHERE line_side.is_line_side
                                   AND line_side.is_deleted = FALSE
                                   AND line_side.workshop_department_id = department.id
                                   AND fn_warehouse_same_main(line_side.id, main.id)
                                 ORDER BY line_side.id LIMIT 1)
                        FROM departments department
                        JOIN warehouses main ON main.id = fn_warehouse_main_id(:warehouseId)
                        WHERE department.id = :workshopId
                          AND department.is_deleted = FALSE
                        """)
                .setParameter("workshopId", workshopDepartmentId)
                .setParameter("warehouseId", demandWarehouseId));
        if (rows.size() != 1 || rows.getFirst()[2] == null) {
            throw new ApiException(ErrorCode.CONFLICT, "车间或收料主仓不存在，无法配置线边仓");
        }
        Object[] row = rows.getFirst();
        if (row[4] != null) return (UUID) row[4];

        String departmentCode = (String) row[0];
        String departmentName = (String) row[1];
        UUID mainWarehouseId = (UUID) row[2];
        String mainWarehouseName = (String) row[3];
        Warehouse warehouse = new Warehouse();
        warehouse.setCode(uniqueCode(CODE_PREFIX + departmentCode));
        warehouse.setName(uniqueName(departmentName + "线边仓", mainWarehouseName));
        warehouse.setRemark("系统自动配置的车间线边仓(V595)：车间内部直送的料架，不参与公共可用量与即时库存");
        warehouse.setAccountable(true);
        warehouse.setDefective(false);
        warehouse.setLineSide(true);
        warehouse.setWorkshopDepartmentId(workshopDepartmentId);
        warehouse.setParentId(mainWarehouseId);
        warehouse.setStatus("使用");
        warehouse.setAutoCreated(true);
        repo.save(warehouse);
        em.flush();
        return warehouse.getId();
    }

    private String uniqueCode(String base) {
        String candidate = base;
        for (int suffix = 2; codeTaken(candidate); suffix++) {
            candidate = base + "-" + suffix;
        }
        return candidate;
    }

    private boolean codeTaken(String code) {
        Number count = (Number) em.createNativeQuery(
                        "SELECT COUNT(*) FROM warehouses WHERE code = :code")
                .setParameter("code", code)
                .getSingleResult();
        return count.longValue() > 0;
    }

    private String uniqueName(String base, String mainWarehouseName) {
        Number count = (Number) em.createNativeQuery(
                        "SELECT COUNT(*) FROM warehouses WHERE name = :name AND is_deleted = FALSE")
                .setParameter("name", base)
                .getSingleResult();
        if (count.longValue() == 0) return base;
        return base + "(" + (mainWarehouseName == null ? "" : mainWarehouseName) + ")";
    }
}
