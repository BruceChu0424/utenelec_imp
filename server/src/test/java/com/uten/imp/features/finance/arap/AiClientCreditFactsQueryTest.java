package com.uten.imp.features.finance.arap;

import com.uten.imp.application.port.MasterIntakeLookupPort;
import com.uten.imp.application.port.PartyOpenBalancePort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.ClientCreditReadAccess;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;

import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.*;

class AiClientCreditFactsQueryTest {
    private final JdbcTemplate jdbc = mock(JdbcTemplate.class);
    private final PartyOpenBalancePort balances = mock(PartyOpenBalancePort.class);
    private final MasterIntakeLookupPort clients = mock(MasterIntakeLookupPort.class);
    private final SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
    private final AiClientCreditFactsQuery query = new AiClientCreditFactsQuery(jdbc, balances, clients, current);
    @AfterEach void clear() { SecurityContextHolder.clearContext(); }
    private void login(Set<String> permissions) {
        var actor = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "credit", permissions, false, true, false);
        when(current.get()).thenReturn(Optional.of(actor));
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(actor, null, actor.getAuthorities()));
    }
    @Test void callerCannotUseFinancialPortWithOnlyCustomerView() {
        login(Set.of("client:view"));
        assertThatThrownBy(() -> query.read(UUID.randomUUID())).isInstanceOf(ApiException.class);
        verifyNoInteractions(clients, jdbc, balances);
    }
    @Test void narrowFinancialGrantDoesNotExposeAnotherCustomersRecords() {
        login(Set.of("client:view", ClientCreditReadAccess.VIEW));
        UUID privateClient = UUID.randomUUID(); when(clients.clientProfile(privateClient)).thenReturn(null);
        assertThatThrownBy(() -> query.read(privateClient)).isInstanceOf(ApiException.class);
        verifyNoInteractions(jdbc, balances);
    }
    @Test void incompleteFinanceWidePairCannotQueryFinancialFacts() {
        login(Set.of("client:view", "ar_ap_ledger:view"));
        assertThatThrownBy(() -> query.read(UUID.randomUUID())).isInstanceOf(ApiException.class);
        verifyNoInteractions(clients, jdbc, balances);
    }
}
