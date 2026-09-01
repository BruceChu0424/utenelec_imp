package com.uten.imp.features.measurement;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/**
 * Internal-only bridge from reviewed/posted business facts to learning events.
 * No controller accepts evidence from a client.
 */
@Service
@RequiredArgsConstructor
public class MeasurementEvidenceRecorder {

    private final MeasurementCaptureStore store;
    private final MeasurementMassUnitRegistry massUnits;
    private final MeasurementLearningPolicyProvider policies;

    @Transactional
    public RecordResult record(RecordCommand command) {
        requireRecordCommand(command);
        MeasurementCapturePreference preference = parsePreference(
                command.declaredPreferenceStorageCode());
        if (command.actualWeight() != null) {
            requireMassUnit(command.actualWeightUnitId());
        }
        MeasurementProfileKey key = key(command.goodsId(), command.operationFamily());
        MeasurementEvidence candidate;
        try {
            candidate = new MeasurementEvidence(
                    command.eventId(), key, command.idempotencyKey(), command.stage(),
                    command.sourceDocumentType(), command.sourceDocumentId(),
                    command.sourceItemId(), command.businessUnitId(),
                    command.businessQty(), command.unitRate(),
                    command.actualWeightUnitId(), command.actualWeight(), preference,
                    command.weightCaptureAvailable(), true,
                    command.businessDate(), null);
        } catch (IllegalArgumentException ex) {
            throw validation(ex.getMessage());
        }
        MeasurementCaptureStore.LockedProfile locked = lock(
                key, candidate.actualWeightUnitId());
        ensureSameWeightUnit(locked, candidate.actualWeightUnitId());
        MeasurementLearningAggregate aggregate = aggregate(locked);
        MeasurementLearningAggregate.MutationResult mutation;
        try {
            mutation = aggregate.appendEvidence(candidate, locked.version());
        } catch (MeasurementLearningException ex) {
            throw conflict(ex.getMessage());
        }
        if (!mutation.replay()) {
            store.insertEvidence(
                    locked.profileId(), candidate,
                    command.reliability(), command.recordedBy());
            requireCas(store.updateProfile(
                    locked, mutation.profile(), candidate.actualWeightUnitId(),
                    aggregate.evidenceFingerprint(), true));
        }
        return new RecordResult(
                locked.profileId(), mutation.profile(), mutation.replay(),
                aggregate.evidenceFingerprint());
    }

    @Transactional
    public RecordResult reverse(ReversalCommand command) {
        requireReversalCommand(command);
        MeasurementProfileKey key = key(command.goodsId(), command.operationFamily());
        MeasurementCaptureStore.LockedProfile locked = lock(key, null);
        List<MeasurementEvidence> existingEvidence =
                store.loadEvidence(locked.profileId());
        MeasurementEvidence original = existingEvidence.stream()
                .filter(item -> item.eventId().equals(command.originalEventId()))
                .findFirst()
                .orElseThrow(() -> conflict(
                        "待红冲的计量证据不存在或不属于该货品场景"));
        MeasurementEvidence reversal;
        try {
            reversal = MeasurementEvidence.reversalOf(
                    original, command.eventId(), command.idempotencyKey(),
                    command.businessDate());
        } catch (IllegalArgumentException ex) {
            throw validation(ex.getMessage());
        }
        MeasurementLearningAggregate aggregate = aggregate(
                locked, existingEvidence);
        MeasurementLearningAggregate.MutationResult mutation;
        try {
            mutation = aggregate.appendEvidence(reversal, locked.version());
        } catch (MeasurementLearningException ex) {
            throw conflict(ex.getMessage());
        }
        if (!mutation.replay()) {
            store.insertEvidence(
                    locked.profileId(), reversal,
                    command.reliability(), command.recordedBy());
            requireCas(store.updateProfile(
                    locked, mutation.profile(), original.actualWeightUnitId(),
                    aggregate.evidenceFingerprint(), true));
        }
        return new RecordResult(
                locked.profileId(), mutation.profile(), mutation.replay(),
                aggregate.evidenceFingerprint());
    }

    private MeasurementLearningAggregate aggregate(
            MeasurementCaptureStore.LockedProfile locked) {
        return aggregate(locked, store.loadEvidence(locked.profileId()));
    }

    private MeasurementLearningAggregate aggregate(
            MeasurementCaptureStore.LockedProfile locked,
            List<MeasurementEvidence> evidence) {
        return MeasurementLearningAggregate.rehydrate(
                locked.key(), policies.policy(), evidence,
                store.loadDecisions(locked.profileId()), locked.version());
    }

    private MeasurementCaptureStore.LockedProfile lock(
            MeasurementProfileKey key, UUID proposedWeightUnitId) {
        try {
            return store.lockOrCreate(key, proposedWeightUnitId);
        } catch (IllegalArgumentException ex) {
            throw new ApiException(ErrorCode.NOT_FOUND, "货品不存在或已删除");
        }
    }

    private void requireMassUnit(UUID unitId) {
        if (unitId == null) {
            throw validation("实际重量有值时必须显式提供重量单位 UUID");
        }
        if (!massUnits.isMassUnit(unitId)) {
            throw validation("实际重量单位未治理为 MASS 维度");
        }
    }

    private static void requireRecordCommand(RecordCommand command) {
        if (command == null) throw validation("计量证据不能为空");
        if (command.stage() != MeasurementEvidenceStage.APPROVED
                && command.stage() != MeasurementEvidenceStage.POSTED) {
            throw validation("只有已审核或已过账事实可以进入计量学习");
        }
        requireReliability(command.reliability());
        if ((command.actualWeight() == null)
                != (command.actualWeightUnitId() == null)) {
            throw validation("实际重量及其单位必须同时提供或同时为空");
        }
    }

    private static void requireReversalCommand(ReversalCommand command) {
        if (command == null || command.eventId() == null
                || command.originalEventId() == null
                || command.businessDate() == null) {
            throw validation("计量证据红冲信息不完整");
        }
        requireReliability(command.reliability());
    }

    private static void requireReliability(BigDecimal reliability) {
        if (reliability == null || reliability.signum() < 0
                || reliability.compareTo(BigDecimal.ONE) > 0) {
            throw validation("计量证据可靠度必须在 0 到 1 之间");
        }
    }

    private static MeasurementProfileKey key(UUID goodsId, String family) {
        if (goodsId == null) throw validation("goodsId 必填");
        try {
            return new MeasurementProfileKey(
                    goodsId, MeasurementOperationFamily.parse(family).name());
        } catch (IllegalArgumentException ex) {
            throw validation(ex.getMessage());
        }
    }

    private static MeasurementCapturePreference parsePreference(String value) {
        try {
            return MeasurementCapturePreference.fromStorageCode(value);
        } catch (IllegalArgumentException ex) {
            throw validation("declaredPreference 必须使用稳定 storageCode");
        }
    }

    private static void ensureSameWeightUnit(
            MeasurementCaptureStore.LockedProfile locked, UUID candidate) {
        if (candidate != null && locked.actualWeightUnitId() != null
                && !candidate.equals(locked.actualWeightUnitId())) {
            throw conflict("该货品场景已绑定另一实际重量单位，不能混入证据");
        }
    }

    private static void requireCas(boolean updated) {
        if (!updated) throw conflict("计量配置已被其他操作修改，请重试");
    }

    private static ApiException validation(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }

    public record RecordCommand(
            UUID eventId,
            UUID goodsId,
            String operationFamily,
            String idempotencyKey,
            MeasurementEvidenceStage stage,
            String sourceDocumentType,
            UUID sourceDocumentId,
            UUID sourceItemId,
            UUID businessUnitId,
            BigDecimal businessQty,
            BigDecimal unitRate,
            BigDecimal actualWeight,
            UUID actualWeightUnitId,
            String declaredPreferenceStorageCode,
            boolean weightCaptureAvailable,
            BigDecimal reliability,
            LocalDate businessDate,
            UUID recordedBy) {
    }

    public record ReversalCommand(
            UUID eventId,
            UUID goodsId,
            String operationFamily,
            String idempotencyKey,
            UUID originalEventId,
            BigDecimal reliability,
            LocalDate businessDate,
            UUID recordedBy) {
    }

    public record RecordResult(
            UUID profileId,
            MeasurementProfile profile,
            boolean replay,
            String evidenceFingerprint) {
    }
}
