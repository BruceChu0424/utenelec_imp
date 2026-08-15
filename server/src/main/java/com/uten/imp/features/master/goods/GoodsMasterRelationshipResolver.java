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
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.UUID;

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
