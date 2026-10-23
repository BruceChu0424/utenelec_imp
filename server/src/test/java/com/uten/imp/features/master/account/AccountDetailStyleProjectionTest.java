package com.uten.imp.features.master.account;

import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.security.authentication.TestingAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class AccountDetailStyleProjectionTest {
    @AfterEach
    void clearSecurityContext() {
        SecurityContextHolder.clearContext();
    }

    @ParameterizedTest
    @ValueSource(booleans = {false, true})
    void authorizedAccountDetailIncludesOnlyItsRelatedSubjectLabel(boolean deleted) {
        Account account = account();
        UUID styleId = UUID.randomUUID();
        account.setStyleId(styleId);
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            assertThat(sql).contains("SELECT code, name, is_deleted")
                    .contains("WHERE id=:styleId").doesNotContain("is_deleted=false");
            return query;
        });
        when(query.setParameter("styleId", styleId)).thenReturn(query);
        when(query.getResultList()).thenReturn(
                List.<Object[]>of(new Object[]{"10201", "基本户", deleted}));

        var detail = service(account, em).detail(account.getId());

        assertThat(detail.getStyleId()).isEqualTo(styleId);
        assertThat(detail.getStyleCode()).isEqualTo("10201");
        assertThat(detail.getStyleName()).isEqualTo("基本户");
        assertThat(detail.getStyleDeleted()).isEqualTo(deleted);
        assertThat(detail.getBalanceCurrent()).isNull();
        verify(query).setParameter("styleId", styleId);
    }

    @Test
    void absentSubjectDoesNotReadTheSubjectDirectory() {
        Account account = account();
        EntityManager em = mock(EntityManager.class);

        var detail = service(account, em).detail(account.getId());

        assertThat(detail.getStyleId()).isNull();
        assertThat(detail.getStyleCode()).isNull();
        assertThat(detail.getStyleName()).isNull();
        assertThat(detail.getStyleDeleted()).isNull();
        verifyNoInteractions(em);
    }

    private static Account account() {
        Account account = new Account();
        account.setId(UUID.randomUUID());
        account.setCode("ZH000001");
        account.setName("测试账户");
        account.setStatus("使用");
        return account;
    }

    private static AccountService service(Account account, EntityManager em) {
        SecurityContextHolder.getContext().setAuthentication(
                new TestingAuthenticationToken("test", "n/a", "account:view"));
        AccountRepository repository = mock(AccountRepository.class);
        when(repository.findById(account.getId())).thenReturn(Optional.of(account));
        return new AccountService(repository, mock(TxSessionVars.class), em,
                mock(MasterCodeService.class));
    }
}
