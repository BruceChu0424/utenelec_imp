package com.uten.imp.features.master.client;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.RETURNS_SELF;
import static org.mockito.Mockito.when;
import static org.mockito.ArgumentMatchers.anyString;

class ClientAccessCandidateBoundaryTest {

    @Test
    void sameNamedDepartmentsKeepTheirDistinctIdentifiers() {
        UUID firstDepartment = UUID.randomUUID();
        UUID secondDepartment = UUID.randomUUID();
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class, RETURNS_SELF);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.getSingleResult()).thenReturn(2L);
        when(query.getResultList()).thenReturn(List.of(
                new Object[]{UUID.randomUUID(), "甲", "UT01", "销售组", "active", true, firstDepartment},
                new Object[]{UUID.randomUUID(), "乙", "UT02", "销售组", "active", true, secondDepartment}));
        ClientAccessService service = new ClientAccessService(
                em, mock(TxSessionVars.class), mock(SecurityContextCurrentUser.class),
                mock(ClientAccessPolicy.class));

        var result = service.candidates(null, 1, 100);

        assertThat(result.getItems()).extracting(row -> row.departmentId())
                .containsExactly(firstDepartment, secondDepartment);
        assertThat(result.getItems()).extracting(row -> row.departmentName())
                .containsExactly("销售组", "销售组");
    }

    @Test
    void rejectsSearchLongerThanOneHundredCharactersBeforeDatabaseWork() {
        ClientAccessService service = new ClientAccessService(
                mock(EntityManager.class),
                mock(TxSessionVars.class),
                mock(SecurityContextCurrentUser.class),
                mock(ClientAccessPolicy.class));

        ApiException error = assertThrows(
                ApiException.class,
                () -> service.candidates(" x" + "a".repeat(100) + " ", 1, 20));

        assertThat(error.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED);
    }
}
