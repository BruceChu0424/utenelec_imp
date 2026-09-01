package com.uten.imp.features.measurement;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.measurement.MeasurementCaptureContracts.ClearOverrideRequest;
import com.uten.imp.features.measurement.MeasurementCaptureContracts.OverrideRequest;
import com.uten.imp.features.measurement.MeasurementCaptureContracts.ProfileResolution;
import com.uten.imp.features.measurement.MeasurementCaptureContracts.ResolveBatchRequest;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class MeasurementProfileServiceTest {

    private static final UUID FIRST_GOODS_ID =
            UUID.fromString("11111111-1111-1111-1111-111111111111");
    private static final UUID SECOND_GOODS_ID =
            UUID.fromString("22222222-2222-2222-2222-222222222222");
    private static final UUID PROFILE_ID =
            UUID.fromString("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa");
    private static final UUID BUSINESS_UNIT_ID =
            UUID.fromString("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb");
    private static final UUID WEIGHT_UNIT_ID =
            UUID.fromString("cccccccc-cccc-cccc-cccc-cccccccccccc");
    private static final UUID ACTOR_ID =
            UUID.fromString("dddddddd-dddd-dddd-dddd-dddddddddddd");

    private MeasurementCaptureStore store;
    private MeasurementMassUnitRegistry massUnits;
    private SecurityContextCurrentUser currentUser;
    private MeasurementProfileService service;

    @BeforeEach
    void setUp() {
        store = mock(MeasurementCaptureStore.class);
        massUnits = mock(MeasurementMassUnitRegistry.class);
        currentUser = mock(SecurityContextCurrentUser.class);
        service = new MeasurementProfileService(
                store,
                massUnits,
                new MeasurementLearningPolicyProvider(3, 2),
                currentUser);
    }

    @Test
    void resolveBatchUsesOneStoreCallAndSortsByMappedGoodsIdentity() {
        when(store.resolveBatch(
                MeasurementOperationFamily.PROCUREMENT,
                Set.of(FIRST_GOODS_ID, SECOND_GOODS_ID)))
                .thenReturn(List.of(
                        resolution(PROFILE_ID, SECOND_GOODS_ID, true, 1),
                        resolution(null, FIRST_GOODS_ID, false, 0)));

        var response = service.resolveBatch(new ResolveBatchRequest(
                "procurement", Set.of(SECOND_GOODS_ID, FIRST_GOODS_ID)));

        assertThat(response.items())
                .extracting(ProfileResolution::goodsId)
                .containsExactly(FIRST_GOODS_ID, SECOND_GOODS_ID);
        assertThat(response.items().get(0).status()).isEqualTo("UNCLASSIFIED");
        assertThat(response.items().get(0).primaryInput())
                .isEqualTo("BUSINESS_QUANTITY");
        verify(store).resolveBatch(
                MeasurementOperationFamily.PROCUREMENT,
                Set.of(FIRST_GOODS_ID, SECOND_GOODS_ID));
    }

    @Test
    void dualOverrideAppendsDecisionAndCompareAndSwapsProjection() {
        MeasurementCaptureStore.LockedProfile locked = locked(0, WEIGHT_UNIT_ID);
        when(massUnits.isMassUnit(WEIGHT_UNIT_ID)).thenReturn(true);
        when(store.lockOrCreate(any(), eq(WEIGHT_UNIT_ID))).thenReturn(locked);
        when(store.loadEvidence(PROFILE_ID)).thenReturn(List.of());
        when(store.loadDecisions(PROFILE_ID)).thenReturn(List.of());
        when(currentUser.requireId()).thenReturn(ACTOR_ID);
        when(store.updateProfile(
                eq(locked), any(), eq(WEIGHT_UNIT_ID), anyString(), eq(false)))
                .thenReturn(true);
        when(store.resolveBatch(
                MeasurementOperationFamily.PROCUREMENT, Set.of(FIRST_GOODS_ID)))
                .thenReturn(List.of(
                        resolution(PROFILE_ID, FIRST_GOODS_ID, true, 1)));
        OverrideRequest request = new OverrideRequest(
                UUID.fromString("eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"),
                "override-key-001",
                0,
                MeasurementCapturePreference.QUANTITY_AND_WEIGHT.storageCode(),
                WEIGHT_UNIT_ID,
                "负责人确认此场景同时采集数量和实际重量");

        ProfileResolution result = service.override(
                FIRST_GOODS_ID, "PROCUREMENT", request);

        assertThat(result.goodsId()).isEqualTo(FIRST_GOODS_ID);
        ArgumentCaptor<MeasurementDecision> decision =
                ArgumentCaptor.forClass(MeasurementDecision.class);
        verify(store).insertDecision(
                eq(PROFILE_ID), decision.capture(), anyString());
        assertThat(decision.getValue().action())
                .isEqualTo(MeasurementDecisionAction.OVERRIDE);
        assertThat(decision.getValue().preference())
                .isEqualTo(MeasurementCapturePreference.QUANTITY_AND_WEIGHT);
        assertThat(decision.getValue().actorId()).isEqualTo(ACTOR_ID);
        ArgumentCaptor<MeasurementProfile> profile =
                ArgumentCaptor.forClass(MeasurementProfile.class);
        verify(store).updateProfile(
                eq(locked), profile.capture(), eq(WEIGHT_UNIT_ID),
                anyString(), eq(false));
        assertThat(profile.getValue().status())
                .isEqualTo(MeasurementProfileStatus.CONFIRMED);
        assertThat(profile.getValue().version()).isEqualTo(1);
    }

    @Test
    void exactOverrideRetryIsReplayEvenWithStaleExpectedVersion() {
        UUID decisionId = UUID.fromString(
                "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee");
        String reason = "负责人确认仅采集业务数量";
        MeasurementDecision existing = new MeasurementDecision(
                decisionId,
                new MeasurementProfileKey(FIRST_GOODS_ID, "PROCUREMENT"),
                "override-key-002",
                MeasurementDecisionAction.OVERRIDE,
                MeasurementCapturePreference.QUANTITY,
                ACTOR_ID,
                reason,
                0,
                1,
                OffsetDateTime.of(2026, 8, 31, 12, 0, 0, 0, ZoneOffset.UTC));
        MeasurementCaptureStore.LockedProfile locked = locked(1, null);
        when(store.lockOrCreate(any(), eq(null))).thenReturn(locked);
        when(store.loadEvidence(PROFILE_ID)).thenReturn(List.of());
        when(store.loadDecisions(PROFILE_ID)).thenReturn(List.of(existing));
        when(currentUser.requireId()).thenReturn(ACTOR_ID);
        when(store.resolveBatch(
                MeasurementOperationFamily.PROCUREMENT, Set.of(FIRST_GOODS_ID)))
                .thenReturn(List.of(
                        resolution(PROFILE_ID, FIRST_GOODS_ID, true, 1)));
        OverrideRequest retry = new OverrideRequest(
                decisionId,
                "override-key-002",
                0,
                MeasurementCapturePreference.QUANTITY.storageCode(),
                null,
                reason);

        ProfileResolution result = service.override(
                FIRST_GOODS_ID, "PROCUREMENT", retry);

        assertThat(result.goodsId()).isEqualTo(FIRST_GOODS_ID);
        verify(store, never()).insertDecision(any(), any(), anyString());
        verify(store, never()).updateProfile(
                any(), any(), any(), anyString(), eq(false));
    }

    @Test
    void clearOverrideAppendsClearDecisionAndAdvancesVersion() {
        MeasurementDecision existing = new MeasurementDecision(
                UUID.fromString("eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"),
                new MeasurementProfileKey(FIRST_GOODS_ID, "PROCUREMENT"),
                "override-key-003",
                MeasurementDecisionAction.OVERRIDE,
                MeasurementCapturePreference.QUANTITY,
                ACTOR_ID,
                "负责人确认仅采集业务数量",
                0,
                1,
                OffsetDateTime.of(2026, 8, 31, 12, 0, 0, 0, ZoneOffset.UTC));
        MeasurementCaptureStore.LockedProfile locked = locked(1, null);
        when(store.lockOrCreate(any(), eq(null))).thenReturn(locked);
        when(store.loadEvidence(PROFILE_ID)).thenReturn(List.of());
        when(store.loadDecisions(PROFILE_ID)).thenReturn(List.of(existing));
        when(currentUser.requireId()).thenReturn(ACTOR_ID);
        when(store.updateProfile(
                eq(locked), any(), eq(null), anyString(), eq(false)))
                .thenReturn(true);
        when(store.resolveBatch(
                MeasurementOperationFamily.PROCUREMENT, Set.of(FIRST_GOODS_ID)))
                .thenReturn(List.of(
                        resolution(PROFILE_ID, FIRST_GOODS_ID, true, 2)));

        service.clearOverride(
                FIRST_GOODS_ID,
                "PROCUREMENT",
                new ClearOverrideRequest(
                        UUID.fromString("ffffffff-ffff-ffff-ffff-ffffffffffff"),
                        "clear-key-0001",
                        1,
                        "重新交由证据推断"));

        ArgumentCaptor<MeasurementDecision> decision =
                ArgumentCaptor.forClass(MeasurementDecision.class);
        verify(store).insertDecision(
                eq(PROFILE_ID), decision.capture(), anyString());
        assertThat(decision.getValue().action())
                .isEqualTo(MeasurementDecisionAction.CLEAR_OVERRIDE);
        assertThat(decision.getValue().preference()).isNull();
        assertThat(decision.getValue().resultingVersion()).isEqualTo(2);
    }

    @Test
    void failedCompareAndSwapReturnsConflictWithoutResolvingStaleRow() {
        MeasurementCaptureStore.LockedProfile locked = locked(0, null);
        when(store.lockOrCreate(any(), eq(null))).thenReturn(locked);
        when(store.loadEvidence(PROFILE_ID)).thenReturn(List.of());
        when(store.loadDecisions(PROFILE_ID)).thenReturn(List.of());
        when(currentUser.requireId()).thenReturn(ACTOR_ID);
        OverrideRequest request = new OverrideRequest(
                UUID.randomUUID(),
                "override-key-004",
                0,
                MeasurementCapturePreference.QUANTITY.storageCode(),
                null,
                "负责人确认仅采集业务数量");

        assertThatThrownBy(() -> service.override(
                FIRST_GOODS_ID, "PROCUREMENT", request))
                .isInstanceOfSatisfying(ApiException.class, error -> {
                    assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT);
                    assertThat(error.getMessage()).contains("刷新后重试");
                });
        verify(store, never()).resolveBatch(any(), any());
    }

    private static MeasurementCaptureStore.LockedProfile locked(
            long version, UUID weightUnitId) {
        return new MeasurementCaptureStore.LockedProfile(
                PROFILE_ID,
                new MeasurementProfileKey(FIRST_GOODS_ID, "PROCUREMENT"),
                BUSINESS_UNIT_ID,
                weightUnitId,
                version,
                null,
                null);
    }

    private static ProfileResolution resolution(
            UUID profileId, UUID goodsId, boolean present, long version) {
        return new ProfileResolution(
                profileId,
                goodsId,
                "PROCUREMENT",
                present ? "CONFIRMED" : "UNCLASSIFIED",
                present
                        ? MeasurementCapturePreference.QUANTITY.storageCode()
                        : "BUSINESS_QUANTITY",
                "OFFERED",
                BUSINESS_UNIT_ID,
                "个",
                null,
                null,
                present ? BigDecimal.ONE : BigDecimal.ZERO,
                0,
                null,
                version,
                null,
                present);
    }
}
