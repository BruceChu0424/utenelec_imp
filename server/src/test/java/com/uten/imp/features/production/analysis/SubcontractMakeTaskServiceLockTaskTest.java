package com.uten.imp.features.production.analysis;

import com.uten.imp.application.port.ProductionSubcontractRequestPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.math.BigDecimal;
import java.sql.Timestamp;
import java.time.Instant;
import java.time.LocalDate;
import java.util.Collections;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class SubcontractMakeTaskServiceLockTaskTest {

    @Test
    void activeStatusComesFromSelectedStatusColumnNotDeliveryDate() {
        SubcontractMakeTaskService service = service(row("ACTIVE"));

        assertThatCode(() -> invokeLockTask(service))
                .doesNotThrowAnyException();
    }

    @Test
    void cancelledStatusIsRejectedEvenWhenDeliveryDateLooksValid() {
        SubcontractMakeTaskService service = service(row("CANCELLED"));

        try {
            invokeLockTask(service);
        } catch (Exception error) {
            Throwable cause = error instanceof InvocationTargetException
                    ? error.getCause() : error;
            assertThat(cause)
                    .isInstanceOf(ApiException.class)
                    .hasMessageContaining("已取消");
            return;
        }
        throw new AssertionError("cancelled task should have been rejected");
    }

    private static SubcontractMakeTaskService service(Object[] row) {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                .thenReturn(query);
        when(query.getResultList()).thenReturn(Collections.singletonList(row));
        return new SubcontractMakeTaskService(
                em,
                mock(MaterialAnalysisService.class),
                mock(ProductionDocumentAccessPolicy.class),
                mock(ProductionSubcontractRequestPort.class),
                mock(ChainNoticeService.class),
                mock(SecurityContextCurrentUser.class));
    }

    private static Object invokeLockTask(SubcontractMakeTaskService service)
            throws Exception {
        Method method = SubcontractMakeTaskService.class
                .getDeclaredMethod("lockTask", UUID.class);
        method.setAccessible(true);
        return method.invoke(service, UUID.randomUUID());
    }

    private static Object[] row(String status) {
        return new Object[]{
                UUID.randomUUID(), UUID.randomUUID(), UUID.randomUUID(),
                UUID.randomUUID(), UUID.randomUUID(), UUID.randomUUID(),
                null, UUID.randomUUID(), UUID.randomUUID(),
                new BigDecimal("10"), new BigDecimal("6"),
                new BigDecimal("2"), status,
                LocalDate.of(2026, 9, 8), Timestamp.from(Instant.now())
        };
    }
}
