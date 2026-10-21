package com.uten.imp.features.admin.workflow;

import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;

import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class SalesQuoteFinanceReviewerEligibilityTest {
    private final UUID actor = UUID.randomUUID();
    private final JdbcTemplate jdbc = mock(JdbcTemplate.class);
    private final UserAccountRepository users = mock(UserAccountRepository.class);
    private final PermissionResolver resolver = mock(PermissionResolver.class);
    private final UserAccount account = mock(UserAccount.class);
    private final SalesQuoteFinanceReviewerEligibility eligibility =
            new SalesQuoteFinanceReviewerEligibility(jdbc, users, resolver);

    @BeforeEach
    void setup() {
        when(jdbc.query(anyString(), org.mockito.ArgumentMatchers.<RowMapper<UUID>>any(), any(Object[].class)))
                .thenReturn(List.of(actor));
        when(users.findById(actor)).thenReturn(Optional.of(account));
    }

    @Test
    void rejectAndReopenAreIndependentOfConfirmation() {
        Set<String> reject = Set.of("sales_quote_finance:view", "sales_quote_finance:reject");
        when(resolver.permsOf(account)).thenReturn(reject);
        when(resolver.grantedPermsOf(account)).thenReturn(reject);
        assertThat(eligibility.isEligible(actor)).isTrue();
        assertThat(eligibility.eligibleUserIds()).containsExactly(actor);
        assertThat(eligibility.canReopen(actor)).isFalse();

        Set<String> reopen = Set.of("sales_quote_finance:view", "sales_quote_finance:reverse");
        when(resolver.permsOf(account)).thenReturn(reopen);
        when(resolver.grantedPermsOf(account)).thenReturn(reopen);
        assertThat(eligibility.isEligible(actor)).isFalse();
        assertThat(eligibility.eligibleUserIds()).isEmpty();
        assertThat(eligibility.canReopen(actor)).isTrue();
    }

    @Test
    void missingViewOrInactiveIdentityCannotReviewOrReopen() {
        when(resolver.permsOf(account)).thenReturn(Set.of("sales_quote_finance:reject", "sales_quote_finance:reverse"));
        assertThat(eligibility.isEligible(actor)).isFalse();
        assertThat(eligibility.canReopen(actor)).isFalse();
        when(resolver.permsOf(account)).thenReturn(Set.of("sales_quote_finance:view", "sales_quote_finance:confirm", "sales_quote_finance:reverse"));
        when(jdbc.query(anyString(), org.mockito.ArgumentMatchers.<RowMapper<UUID>>any(), any(Object[].class)))
                .thenReturn(List.of());
        assertThat(eligibility.isEligible(actor)).isFalse();
        assertThat(eligibility.canReopen(actor)).isFalse();
    }
}
