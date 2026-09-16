package com.uten.imp.features.master.goods;

import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.client.Client;
import com.uten.imp.features.master.client.ClientRepository;
import com.uten.imp.features.master.color.Color;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.mould.Mould;
import com.uten.imp.features.master.mould.MouldRepository;
import com.uten.imp.features.master.supplier.Supplier;
import com.uten.imp.features.master.supplier.SupplierRepository;
import com.uten.imp.features.master.unit.Unit;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.features.master.warehouse.Warehouse;
import com.uten.imp.features.master.warehouse.WarehouseRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.Collection;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

/**
 * Resolves live goods/BOM master references without using mutable names or legacy IDs.
 *
 * <p>A UUID is the only live relationship key. Legacy IDs remain on entities as migration
 * snapshots, but must never be resolved into a new relation.</p>
 */
@Component
@RequiredArgsConstructor
public class GoodsMasterRelationshipResolver {

    private final UnitRepository unitRepo;
    private final ColorRepository colorRepo;
    private final MouldRepository mouldRepo;
    private final ClientRepository clientRepo;
    private final SupplierRepository supplierRepo;
    private final WarehouseRepository warehouseRepo;
    private final com.uten.imp.features.org.department.DepartmentRepository departmentRepo;
    private final MasterReferenceValidationPort references;

    public Unit unit(UUID id) {
        Unit target = unitRepo.findById(requiredUuid(id))
                .orElseThrow(() -> notFound("单位不存在"));
        requireActive(target.isDeleted(), target.getStatus(), "单位已删除或停用");
        return target;
    }

    public Color color(UUID id) {
        Color target = colorRepo.findById(requiredUuid(id))
                .orElseThrow(() -> notFound("颜色不存在"));
        requireActive(target.isDeleted(), target.getStatus(), "颜色已删除或停用");
        return target;
    }

    public Mould mould(UUID id) {
        Mould target = mouldRepo.findById(requiredUuid(id))
                .orElseThrow(() -> notFound("模具不存在"));
        requireActive(target.isDeleted(), target.getStatus(), "模具已删除或停用");
        return target;
    }

    public Client client(UUID id) {
        UUID targetId = requiredUuid(id);
        references.requireVisibleActiveClient(targetId);
        return clientRepo.findById(targetId)
                .orElseThrow(() -> notFound("客户不存在"));
    }

    public Supplier supplier(UUID id) {
        Supplier target = supplierRepo.findById(requiredUuid(id))
                .orElseThrow(() -> notFound("供应商不存在"));
        requireActive(target.isDeleted(), target.getStatus(), "供应商已删除或停用");
        return target;
    }

    /**
     * 所属仓库 (V587)：这批货平时归哪个仓管的主档归属，不是单据落点仓，也不是物料分析范围仓。
     *
     * <p>按 V587 口径只要求仓库存在且未软删：不限叶子仓，也不按「禁用」状态拦截
     * (仓库停用后，货品的历史归属仍应保留得住)。UUID 是唯一关系键，没有 legacy 回退。
     */
    public Warehouse owningWarehouse(UUID id) {
        Warehouse target = warehouseRepo.findById(requiredUuid(id))
                .orElseThrow(() -> notFound("仓库不存在"));
        if (target.isDeleted()) {
            throw new ApiException(ErrorCode.CONFLICT, "仓库已删除");
        }
        return target;
    }

    /**
     * 批量解析仓库 id → 名称，供列表/字典等批量场景一次取名，避免逐行触发懒加载造成 N+1。
     *
     * <p>软删仓库不入 map；调用方对缺省键按「未解析」展示 null，绝不据此建立新关系。
     */
    public Map<UUID, String> warehouseNames(Collection<UUID> ids) {
        if (ids == null || ids.isEmpty()) return Map.of();
        Set<UUID> distinct = ids.stream().filter(Objects::nonNull).collect(Collectors.toSet());
        if (distinct.isEmpty()) return Map.of();
        return warehouseRepo.findAllById(distinct).stream()
                .filter(w -> !w.isDeleted() && w.getName() != null)
                .collect(Collectors.toMap(Warehouse::getId, Warehouse::getName, (a, b) -> a));
    }

    /**
     * 批量解析部门 id → 名称（V590 归属生产车间展示用）。软删部门不入 map，
     * 调用方对缺省键按「未解析」展示 null。
     */
    public Map<UUID, String> departmentNames(Collection<UUID> ids) {
        if (ids == null || ids.isEmpty()) return Map.of();
        Set<UUID> distinct = ids.stream().filter(Objects::nonNull).collect(Collectors.toSet());
        if (distinct.isEmpty()) return Map.of();
        return departmentRepo.findAllById(distinct).stream()
                .filter(d -> !d.isDeleted() && d.getName() != null)
                .collect(Collectors.toMap(
                        com.uten.imp.features.org.department.Department::getId,
                        com.uten.imp.features.org.department.Department::getName,
                        (a, b) -> a));
    }

    private static UUID requiredUuid(UUID id) {
        if (id == null) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "当前关联必须提供主档 UUID；legacy_id 仅保留为历史快照");
        }
        return id;
    }

    private static void requireActive(boolean deleted, String status, String message) {
        if (deleted || "禁用".equals(status) || "报废".equals(status)) {
            throw new ApiException(ErrorCode.CONFLICT, message);
        }
    }

    private static ApiException notFound(String message) {
        return new ApiException(ErrorCode.NOT_FOUND, message);
    }
}
