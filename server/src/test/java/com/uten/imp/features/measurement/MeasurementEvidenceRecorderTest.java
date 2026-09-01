package com.uten.imp.features.measurement;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyBoolean;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class MeasurementEvidenceRecorderTest {

    private static final UUID PROFILE_ID =
            UUID.fromString("10000000-0000-0000-0000-000000000001");
    private static final UUID GOODS_ID =
            UUID.fromString("10000000-0000-0000-0000-000000000002");
    private static final UUID BUSINESS_UNIT_ID =
            UUID.fromString("10000000-0000-0000-0000-000000000003");
    private static final UUID WEIGHT_UNIT_ID =
            UUID.fromString("10000000-0000-0000-0000-000000000004");
    private static final UUID ACTOR_ID =
            UUID.fromString("10000000-0000-0000-0000-000000000005");
    private static final UUID DOCUMENT_ID =
            UUID.fromString("10000000-0000-0000-0000-000000000006");
    private static final UUID ITEM_ID =
            UUID.fromString("10000000-0000-0000-0000-000000000007");
    private static final UUID EVENT_ID =
            UUID.fromString("10000000-0000-0000-0000-000000000008");
    private static final LocalDate BUSINESS_DATE = LocalDate.of(2026, 8, 31);

    private MeasurementCaptureStore store;
    private MeasurementMassUnitRegistry massUnits;
    private MeasurementEvidenceRecorder recorder;

    @BeforeEach
    void setUp() {
        store = mock(MeasurementCaptureStore.class);
        massUnits = mock(MeasurementMassUnitRegistry.class);
        recorder = new MeasurementEvidenceRecorder(
                store, massUnits, new MeasurementLearningPolicyProvider(3, 2));
    }

    @Test
    void exactRetryRehydratesAsReplayWithoutAnotherInsertOrProfileUpdate() {
        MeasurementEvidence existing = evidence();
        MeasurementCaptureStore.LockedProfile locked = locked(1, WEIGHT_UNIT_ID);
        when(massUnits.isMassUnit(WEIGHT_UNIT_ID)).thenReturn(true);
        when(store.lockOrCreate(existing.key(), WEIGHT_UNIT_ID)).thenReturn(locked);
        when(store.loadEvidence(PROFILE_ID)).thenReturn(List.of(existing));
        when(store.loadDecisions(PROFILE_ID)).thenReturn(List.of());

        MeasurementEvidenceRecorder.RecordResult result = recorder.record(command(
                new BigDecimal("2.5000"), WEIGHT_UNIT_ID));

        assertThat(result.replay()).isTrue();
        assertThat(result.profileId()).isEqualTo(PROFILE_ID);
        assertThat(result.profile().version()).isEqualTo(1);
        verify(store, never()).insertEvidence(any(), any(), any(), any());
        verify(store, never()).updateProfile(
                any(), any(), any(), anyString(), anyBoolean());
    }

    @Test
    void rejectsWeightWithoutExplicitUnitBeforeTouchingPersistence() {
        MeasurementEvidenceRecorder.RecordCommand invalid = command(
                new BigDecimal("2.5000"), null);

        assertThatThrownBy(() -> recorder.record(invalid))
                .isInstanceOfSatisfying(ApiException.class, error -> {
                    assertThat(error.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED);
                    assertThat(error.getMessage()).contains("必须同时提供");
                });
        verifyNoInteractions(store, massUnits);
    }

    @Test
    void rejectsUnitThatIsNotGovernedAsMassBeforeLockingProfile() {
        when(massUnits.isMassUnit(WEIGHT_UNIT_ID)).thenReturn(false);

        assertThatThrownBy(() -> recorder.record(command(
                new BigDecimal("2.5000"), WEIGHT_UNIT_ID)))
                .isInstanceOfSatisfying(ApiException.class, error -> {
                    assertThat(error.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED);
                    assertThat(error.getMessage()).contains("MASS");
                });
        verifyNoInteractions(store);
    }

    @Test
    void failedCompareAndSwapIsReportedAsConflict() {
        MeasurementCaptureStore.LockedProfile locked = locked(0, WEIGHT_UNIT_ID);
        when(massUnits.isMassUnit(WEIGHT_UNIT_ID)).thenReturn(true);
        when(store.lockOrCreate(any(), eq(WEIGHT_UNIT_ID))).thenReturn(locked);
        when(store.loadEvidence(PROFILE_ID)).thenReturn(List.of());
        when(store.loadDecisions(PROFILE_ID)).thenReturn(List.of());
        when(store.updateProfile(
                eq(locked), any(), eq(WEIGHT_UNIT_ID), anyString(), eq(true)))
                .thenReturn(false);

        assertThatThrownBy(() -> recorder.record(command(
                new BigDecimal("2.5000"), WEIGHT_UNIT_ID)))
                .isInstanceOfSatisfying(ApiException.class, error -> {
                    assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT);
                    assertThat(error.getMessage()).contains("请重试");
                });
        verify(store).insertEvidence(
                eq(PROFILE_ID), any(MeasurementEvidence.class),
                eq(new BigDecimal("0.90")), eq(ACTOR_ID));
        verify(store).updateProfile(
                eq(locked), any(), eq(WEIGHT_UNIT_ID), anyString(), eq(true));
    }

    private static MeasurementCaptureStore.LockedProfile locked(
            long version, UUID weightUnitId) {
        return new MeasurementCaptureStore.LockedProfile(
                PROFILE_ID,
                new MeasurementProfileKey(GOODS_ID, "PROCUREMENT"),
                BUSINESS_UNIT_ID,
                weightUnitId,
                version,
                null,
                null);
    }

    private static MeasurementEvidence evidence() {
        return new MeasurementEvidence(
                EVENT_ID,
                new MeasurementProfileKey(GOODS_ID, "PROCUREMENT"),
                "record-key-0001",
                MeasurementEvidenceStage.POSTED,
                "purchase_receipt",
                DOCUMENT_ID,
                ITEM_ID,
                BUSINESS_UNIT_ID,
                new BigDecimal("5.00"),
                BigDecimal.ONE,
                WEIGHT_UNIT_ID,
                new BigDecimal("2.5000"),
                MeasurementCapturePreference.QUANTITY_AND_WEIGHT,
                true,
                true,
                BUSINESS_DATE,
                null);
    }

    private static MeasurementEvidenceRecorder.RecordCommand command(
            BigDecimal weight, UUID weightUnitId) {
        return new MeasurementEvidenceRecorder.RecordCommand(
                EVENT_ID,
                GOODS_ID,
                "PROCUREMENT",
                "record-key-0001",
                MeasurementEvidenceStage.POSTED,
                "purchase_receipt",
                DOCUMENT_ID,
                ITEM_ID,
                BUSINESS_UNIT_ID,
                new BigDecimal("5.00"),
                BigDecimal.ONE,
                weight,
                weightUnitId,
                MeasurementCapturePreference.QUANTITY_AND_WEIGHT.storageCode(),
                true,
                new BigDecimal("0.90"),
                BUSINESS_DATE,
                ACTOR_ID);
    }
}
