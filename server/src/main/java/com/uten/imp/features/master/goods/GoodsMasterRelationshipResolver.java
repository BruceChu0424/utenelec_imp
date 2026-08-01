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
 * Resolves live goods/BOM master references without using mutable names.
 *
 * <p>A supplied UUID is authoritative. Legacy IDs are consulted only when the UUID is absent;
 * repository legacy lookups are safe because every referenced master has a unique legacy_id.</p>
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

    public Unit unit(UUID id, Integer legacyId) {
        Unit target = id != null
                ? unitRepo.findById(id).orElseThrow(() -> notFound("单位不存在"))
                : unitRepo.findByLegacyId(nonZero(legacyId)).orElseThrow(() -> notFound("单位不存在"));
        requireActive(target.isDeleted(), target.getStatus(), "单位已删除或停用");
        return target;
    }

    public Color color(UUID id, Integer legacyId) {
        Color target = id != null
                ? colorRepo.findById(id).orElseThrow(() -> notFound("颜色不存在"))
                : colorRepo.findByLegacyId(nonZero(legacyId)).orElseThrow(() -> notFound("颜色不存在"));
        requireActive(target.isDeleted(), target.getStatus(), "颜色已删除或停用");
        return target;
    }

    public Mould mould(UUID id, Integer legacyId) {
        Mould target = id != null
                ? mouldRepo.findById(id).orElseThrow(() -> notFound("模具不存在"))
                : mouldRepo.findByLegacyId(nonZero(legacyId)).orElseThrow(() -> notFound("模具不存在"));
        requireActive(target.isDeleted(), target.getStatus(), "模具已删除或停用");
        return target;
    }

    public Client client(UUID id, Integer legacyId) {
        Client target;
        if (id != null) {
            references.requireVisibleActiveClient(id);
            target = clientRepo.findById(id).orElseThrow(() -> notFound("客户不存在"));
        } else {
            target = clientRepo.findByLegacyId(nonZero(legacyId))
                    .orElseThrow(() -> notFound("客户不存在"));
            references.requireVisibleActiveClient(target.getId());
        }
        return target;
    }

    public Supplier supplier(UUID id, Integer legacyId) {
        Supplier target = id != null
                ? supplierRepo.findById(id).orElseThrow(() -> notFound("供应商不存在"))
                : supplierRepo.findByLegacyId(nonZero(legacyId))
                        .orElseThrow(() -> notFound("供应商不存在"));
        requireActive(target.isDeleted(), target.getStatus(), "供应商已删除或停用");
        return target;
    }

    private static Integer nonZero(Integer legacyId) {
        if (legacyId == null || legacyId == 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "缺少主档 UUID 或 legacy_id");
        }
        return legacyId;
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
