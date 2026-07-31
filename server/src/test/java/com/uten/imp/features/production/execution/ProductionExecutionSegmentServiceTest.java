package com.uten.imp.features.production.execution;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.Collections;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class ProductionExecutionSegmentServiceTest {

    private final UUID planId = UUID.randomUUID();
    private final UUID segmentId = UUID.randomUUID();
    private final UUID packageId = UUID.randomUUID();
    private EntityManager em;
    private ProductionExecutionSegmentService service;

    @BeforeEach
    void setUp() {
        em = mock(EntityManager.class);
        service = new ProductionExecutionSegmentService(
                em,
                mock(SecurityContextCurrentUser.class),
                mock(TxSessionVars.class),
                mock(ChainNoticeService.class));
    }

    @Test
    void staleExpectedVersionIsRejectedBeforeMutation() {
        stubLockAndReplay("READY", 7L, "CONFIRMED");

        ApiException error = assertThrows(
                ApiException.class,
                () -> service.dispatch(
                        planId,
                        segmentId,
                        new SegmentTransitionRequest(6L, "dispatch-key-0001")));

        assertTrue(error.getMessage().contains("其他用户修改"));
    }

    @Test
    void illegalStatusTransitionIsRejected() {
        stubLockAndReplay("WAITING", 3L, "CONFIRMED");

        ApiException error = assertThrows(
                ApiException.class,
                () -> service.dispatch(
                        planId,
                        segmentId,
                        new SegmentTransitionRequest(3L, "dispatch-key-0002")));

        assertTrue(error.getMessage().contains("状态已经变化"));
    }

    @Test
    void confirmedPackageCannotCancelOneSegment() {
        stubLockAndReplay("READY", 2L, "CONFIRMED");

        ApiException error = assertThrows(
                ApiException.class,
                () -> service.cancel(
                        planId,
                        segmentId,
                        new SegmentTransitionRequest(2L, "cancel-key-00001")));

        assertTrue(error.getMessage().contains("整包取消"));
    }

    private void stubLockAndReplay(
            String status, long version, String packageStatus) {
        Query lock = query();
        when(lock.getResultList()).thenReturn(Collections.singletonList(new Object[]{
                segmentId,
                planId,
                packageId,
                status,
                version,
                packageStatus,
                (short) 1,
                false,
                false,
                false
        }));
        Query replay = query();
        when(replay.getResultList()).thenReturn(List.of());
        when(em.createNativeQuery(anyString())).thenReturn(lock, replay);
    }

    private static Query query() {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                .thenReturn(query);
        return query;
    }
}
