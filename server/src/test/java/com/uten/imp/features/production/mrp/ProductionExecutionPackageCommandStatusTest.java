package com.uten.imp.features.production.mrp;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.sql.Date;
import java.time.LocalDate;
import java.util.Collections;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ProductionExecutionPackageCommandStatusTest {

    @Test
    void rejectsFormalConfirmationForDraftPlanBeforeRequestValidation() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(Collections.singletonList(
                new Object[]{"SJ-1", Date.valueOf(LocalDate.now()),
                        (short) 0, false, false, false}));
        TxSessionVars tx = mock(TxSessionVars.class);
        ProductionPlanningRequestValidator validator =
                mock(ProductionPlanningRequestValidator.class);
        ProductionExecutionPackageCommandService command =
                new ProductionExecutionPackageCommandService(
                        em, null, null, null, null, null, null, null,
                        null, null, null, null, tx, null, validator);

        assertThatThrownBy(() -> command.confirm(
                UUID.randomUUID(), new GeneratePlanningPackageRequest()))
                .isInstanceOf(ApiException.class)
                .satisfies(error -> assertThat(((ApiException) error).getCode())
                        .isEqualTo(ErrorCode.CONFLICT))
                .hasMessageContaining("仅已审核")
                .hasMessageContaining("预排草案");
        verify(validator, never()).validateCurrent(any(), any());
    }
}
