package com.uten.imp.features.master.reference;

import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.OwnerVisibility;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

import java.math.BigDecimal;
import java.util.List;
import java.util.Objects;
import java.util.UUID;

/** Master-data-side implementation of the neutral document reference boundary. */
@Service
@RequiredArgsConstructor
public class MasterReferenceValidationAdapter implements MasterReferenceValidationPort {

    private static final BigDecimal MIN_STORABLE_RATE = new BigDecimal("0.000001");

    private final EntityManager em;
    private final OwnerVisibility ownerVisibility;

    @Value("${uten.features.goods-owner-scope-enabled:false}")
    private boolean goodsOwnerScopeEnabled;

    @Override
    public void requireVisibleGoods(UUID goodsId) {
        if (!canViewGoods(goodsId)) {
            throw notFound("货品不存在");
        }
    }

    @Override
    public boolean canViewGoods(UUID goodsId) {
        if (goodsId == null) return false;
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT g.id, g.owner_employee_id
                FROM goods g
                WHERE g.id = :id
                """).setParameter("id", goodsId));
        if (rows.size() != 1) return false;
        if (!goodsOwnerScopeEnabled) return true;
        Object[] row = rows.getFirst();
        return isVisibleOwner(
                (UUID) row[1],
                ownerVisibility.evaluate("goods", "goods:view:all"));
    }

    @Override
    public void requireVisibleActiveGoods(UUID goodsId) {
        requireGoods(goodsId);
    }

    @Override
    public void requireVisibleActiveClient(UUID clientId) {
        if (clientId == null) throw validation("缺少客户");
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT is_deleted, owner_employee_id, status
                FROM clients
                WHERE id = :id
                """).setParameter("id", clientId));
        if (rows.size() != 1) {
            throw notFound("客户不存在");
        }
        Object[] row = rows.getFirst();
        requireVisibleOwner(
                (UUID) row[1],
                ownerVisibility.evaluate("client", "client:view:all"),
                "客户不存在");
        if (Boolean.TRUE.equals(row[0]) || !"使用".equals(row[2])) {
            throw conflict("客户已删除或停用，不能用于新业务");
        }
    }

    @Override
    public ResolvedLineUnit resolveVisibleActiveGoodsUnit(
            UUID goodsId,
            UUID unitId,
            BigDecimal unitRate,
            int lineNo) {
        GoodsReference goods = requireGoods(goodsId);
        if (goods.baseUnitId() == null || goods.baseUnitDeleted() || goods.baseUnitDisabled()) {
            throw conflict(prefix(lineNo) + "货品未维护有效基本单位");
        }

        if (unitId == null) {
            if (unitRate != null && unitRate.compareTo(BigDecimal.ONE) != 0) {
                throw validation(prefix(lineNo) + "单位缺失且换算率不为 1");
            }
            return new ResolvedLineUnit(goods.baseUnitId(), BigDecimal.ONE);
        }

        if (Objects.equals(unitId, goods.baseUnitId())) {
            BigDecimal normalizedRate = unitRate == null ? BigDecimal.ONE : unitRate;
            if (normalizedRate.compareTo(BigDecimal.ONE) != 0) {
                throw validation(prefix(lineNo) + "使用货品基本单位时换算率必须为 1");
            }
            return new ResolvedLineUnit(unitId, BigDecimal.ONE);
        }

        Number activeUnitCount = (Number) em.createNativeQuery("""
                SELECT COUNT(*)
                FROM units
                WHERE id = :unitId
                  AND is_deleted = FALSE
                  AND COALESCE(status, '') <> '禁用'
                """).setParameter("unitId", unitId).getSingleResult();
        if (activeUnitCount.longValue() != 1L) {
            throw conflict(prefix(lineNo) + "单位不存在或已删除");
        }
        if (unitRate == null) {
            throw validation(prefix(lineNo) + "使用非基本单位时必须提供单位换算率");
        }
        BigDecimal canonicalRate = unitRate.stripTrailingZeros();
        int integerDigits = Math.max(0, canonicalRate.precision() - canonicalRate.scale());
        if (unitRate.compareTo(MIN_STORABLE_RATE) < 0
                || canonicalRate.scale() > 6
                || integerDigits > 12) {
            throw validation(prefix(lineNo) + "单位换算率必须是可存储的大于 0 的 NUMERIC(18,6)");
        }
        return new ResolvedLineUnit(unitId, unitRate);
    }

    private GoodsReference requireGoods(UUID goodsId) {
        if (goodsId == null) throw validation("缺少货品");
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT g.is_deleted,
                       g.owner_employee_id,
                       COALESCE(current_unit.id, legacy_unit.id),
                       COALESCE(current_unit.is_deleted, legacy_unit.is_deleted, TRUE),
                       g.status,
                       g.auto_created,
                       COALESCE(current_unit.status, legacy_unit.status)
                FROM goods g
                LEFT JOIN units current_unit ON current_unit.id = g.unit_id
                LEFT JOIN units legacy_unit
                  ON g.unit_id IS NULL
                 AND legacy_unit.legacy_id = g.unit_legacy_id
                WHERE g.id = :id
                """).setParameter("id", goodsId));
        if (rows.size() != 1) {
            throw notFound("货品不存在");
        }
        Object[] row = rows.getFirst();
        if (goodsOwnerScopeEnabled) {
            requireVisibleOwner(
                    (UUID) row[1],
                    ownerVisibility.evaluate("goods", "goods:view:all"),
                    "货品不存在");
        }
        if (Boolean.TRUE.equals(row[0]) || Boolean.TRUE.equals(row[5]) || "禁用".equals(row[4])) {
            throw conflict("货品已删除、停用或仅为迁移占位，不能用于新业务");
        }
        return new GoodsReference(
                (UUID) row[2],
                Boolean.TRUE.equals(row[3]),
                "禁用".equals(row[6]));
    }

    private static void requireVisibleOwner(
            UUID ownerEmployeeId,
            OwnerVisibility.OwnerScope scope,
            String notFoundMessage) {
        if (isVisibleOwner(ownerEmployeeId, scope)) return;
        throw notFound(notFoundMessage);
    }

    private static boolean isVisibleOwner(
            UUID ownerEmployeeId,
            OwnerVisibility.OwnerScope scope) {
        return scope.seeAll() || ownerEmployeeId == null
                || scope.visibleOwners().contains(ownerEmployeeId);
    }

    private static String prefix(int lineNo) {
        return "第 " + lineNo + " 行";
    }

    private static ApiException notFound(String message) {
        return new ApiException(ErrorCode.NOT_FOUND, message);
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }

    private static ApiException validation(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    private record GoodsReference(UUID baseUnitId, boolean baseUnitDeleted, boolean baseUnitDisabled) {
    }
}
