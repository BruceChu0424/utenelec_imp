package com.uten.imp.features.master.client;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.mock;

class ClientAccessCandidateBoundaryTest {

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
