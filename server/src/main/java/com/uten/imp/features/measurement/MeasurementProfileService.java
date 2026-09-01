package com.uten.imp.features.measurement;

import com.uten.imp.common.validation.RequestLimits;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.measurement.MeasurementCaptureContracts.ClearOverrideRequest;
import com.uten.imp.features.measurement.MeasurementCaptureContracts.OverrideRequest;
import com.uten.imp.features.measurement.MeasurementCaptureContracts.ProfileResolution;
import com.uten.imp.features.measurement.MeasurementCaptureContracts.ResolveBatchRequest;
import com.uten.imp.features.measurement.MeasurementCaptureContracts.ResolveBatchResponse;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/** Resolution and append-only manual governance for capture preferences. */
@Service
@RequiredArgsConstructor
public class MeasurementProfileService {

    private final MeasurementCaptureStore store;
    private final MeasurementMassUnitRegistry massUnits;
    private final MeasurementLearningPolicyProvider policies;
    private final SecurityContextCurrentUser currentUser;

    @Transactional(readOnly = true)
    public ResolveBatchResponse resolveBatch(ResolveBatchRequest request) {
        if (request == null || request.goodsIds() == null
                || request.goodsIds().isEmpty()
                || request.goodsIds().size() > RequestLimits.LOOKUP_IDS
                || request.goodsIds().stream().anyMatch(java.util.Objects::isNull)) {
            throw validation("货品 ID 数量必须为 1-" + RequestLimits.LOOKUP_IDS);
        }
        MeasurementOperationFamily family = parseFamily(request.operationFamily());
        return new ResolveBatchResponse(resolve(family, request.goodsIds()));
    }

    @Transactional
    public ProfileResolution override(
            UUID goodsId, String operationFamily, OverrideRequest request) {
        if (request == null) throw validation("人工覆盖请求不能为空");
        MeasurementOperationFamily family = parseFamily(operationFamily);
        MeasurementCapturePreference preference = parsePreference(request.preference());
        validateOverrideWeightUnit(preference, request.actualWeightUnitId());
        MeasurementProfileKey key = key(goodsId, family);
        MeasurementCaptureStore.LockedProfile locked = lock(
                key, request.actualWeightUnitId());
        ensureSameWeightUnit(locked, request.actualWeightUnitId());
        MeasurementLearningAggregate aggregate = aggregate(locked);
        MeasurementLearningAggregate.MutationResult mutation;
        try {
            mutation = aggregate.override(
                    preference, request.expectedVersion(), request.commandId(),
                    currentUser.requireId(), request.reason(),
                    request.idempotencyKey(), OffsetDateTime.now(ZoneOffset.UTC));
        } catch (MeasurementLearningException ex) {
            throw conflict(ex.getMessage());
        } catch (IllegalArgumentException ex) {
            throw validation(ex.getMessage());
        }
        if (!mutation.replay()) {
            MeasurementDecision decision = aggregate.decisionEvents().getLast();
            store.insertDecision(
                    locked.profileId(), decision, aggregate.evidenceFingerprint());
            requireCas(store.updateProfile(
                    locked, mutation.profile(), request.actualWeightUnitId(),
                    aggregate.evidenceFingerprint(), false));
        }
        return resolveOne(family, goodsId);
    }

    @Transactional
    public ProfileResolution clearOverride(
            UUID goodsId, String operationFamily, ClearOverrideRequest request) {
        if (request == null) throw validation("清除人工覆盖请求不能为空");
        MeasurementOperationFamily family = parseFamily(operationFamily);
        MeasurementProfileKey key = key(goodsId, family);
        MeasurementCaptureStore.LockedProfile locked = lock(key, null);
        MeasurementLearningAggregate aggregate = aggregate(locked);
        MeasurementLearningAggregate.MutationResult mutation;
        try {
            mutation = aggregate.clearOverride(
                    request.expectedVersion(), request.commandId(),
                    currentUser.requireId(), request.reason(),
                    request.idempotencyKey(), OffsetDateTime.now(ZoneOffset.UTC));
        } catch (MeasurementLearningException ex) {
            throw conflict(ex.getMessage());
        } catch (IllegalArgumentException ex) {
            throw validation(ex.getMessage());
        }
        if (!mutation.replay()) {
            MeasurementDecision decision = aggregate.decisionEvents().getLast();
            store.insertDecision(
                    locked.profileId(), decision, aggregate.evidenceFingerprint());
            requireCas(store.updateProfile(
                    locked, mutation.profile(), null,
                    aggregate.evidenceFingerprint(), false));
        }
        return resolveOne(family, goodsId);
    }

    private MeasurementLearningAggregate aggregate(
            MeasurementCaptureStore.LockedProfile locked) {
        return MeasurementLearningAggregate.rehydrate(
                locked.key(), policies.policy(),
                store.loadEvidence(locked.profileId()),
                store.loadDecisions(locked.profileId()), locked.version());
    }

    private void validateOverrideWeightUnit(
            MeasurementCapturePreference preference, UUID actualWeightUnitId) {
        if (preference == MeasurementCapturePreference.QUANTITY) {
            if (actualWeightUnitId != null) {
                throw validation("仅数量偏好不能同时提交实际重量单位");
            }
            return;
        }
        if (actualWeightUnitId == null) {
            throw validation("数量及实际重量偏好必须选择重量单位");
        }
        if (!massUnits.isMassUnit(actualWeightUnitId)) {
            throw validation("实际重量单位未治理为 MASS 维度");
        }
    }

    private static void ensureSameWeightUnit(
            MeasurementCaptureStore.LockedProfile locked, UUID candidate) {
        if (candidate != null && locked.actualWeightUnitId() != null
                && !candidate.equals(locked.actualWeightUnitId())) {
            throw conflict("该货品场景已绑定另一实际重量单位，不能静默替换");
        }
    }

    private ProfileResolution resolveOne(
            MeasurementOperationFamily family, UUID goodsId) {
        List<ProfileResolution> rows = resolve(family, Set.of(goodsId));
        if (rows.size() != 1) throw notFound();
        return rows.getFirst();
    }

    private List<ProfileResolution> resolve(
            MeasurementOperationFamily family, Set<UUID> goodsIds) {
        List<UUID> ordered = goodsIds.stream()
                .sorted(Comparator.comparing(UUID::toString)).toList();
        List<ProfileResolution> rows = store.resolveBatch(family, goodsIds);
        if (rows.size() != ordered.size()) throw notFound();
        Map<UUID, ProfileResolution> byGoodsId = new HashMap<>();
        for (ProfileResolution row : rows) {
            if (row == null || row.goodsId() == null
                    || byGoodsId.putIfAbsent(row.goodsId(), row) != null) {
                throw new IllegalStateException(
                        "measurement resolution contains duplicate or null goodsId");
            }
        }
        if (!byGoodsId.keySet().equals(goodsIds)) throw notFound();
        return ordered.stream().map(byGoodsId::get).toList();
    }

    private static MeasurementCaptureStore.LockedProfile lock(
            MeasurementProfileKey key, UUID proposedWeightUnitId,
            MeasurementCaptureStore store) {
        try {
            return store.lockOrCreate(key, proposedWeightUnitId);
        } catch (IllegalArgumentException ex) {
            throw notFound();
        }
    }

    private MeasurementCaptureStore.LockedProfile lock(
            MeasurementProfileKey key, UUID proposedWeightUnitId) {
        return lock(key, proposedWeightUnitId, store);
    }

    private static MeasurementProfileKey key(
            UUID goodsId, MeasurementOperationFamily family) {
        if (goodsId == null) throw validation("goodsId 必填");
        return new MeasurementProfileKey(goodsId, family.name());
    }

    private static MeasurementOperationFamily parseFamily(String value) {
        try {
            return MeasurementOperationFamily.parse(value);
        } catch (IllegalArgumentException ex) {
            throw validation(ex.getMessage());
        }
    }

    private static MeasurementCapturePreference parsePreference(String value) {
        try {
            return MeasurementCapturePreference.fromStorageCode(value);
        } catch (IllegalArgumentException ex) {
            throw validation("preference 必须使用稳定 storageCode");
        }
    }

    private static void requireCas(boolean updated) {
        if (!updated) throw conflict("计量配置已被其他操作修改，请刷新后重试");
    }

    private static ApiException validation(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }

    private static ApiException notFound() {
        return new ApiException(ErrorCode.NOT_FOUND, "货品不存在或已删除");
    }
}
