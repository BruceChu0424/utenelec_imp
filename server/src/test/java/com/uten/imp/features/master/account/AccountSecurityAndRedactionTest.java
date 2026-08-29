package com.uten.imp.features.master.account;

import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.account.dto.AccountQueryFilter;
import com.uten.imp.features.master.account.dto.AccountWarningUpdateRequest;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.authentication.TestingAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;

import java.math.BigDecimal;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class AccountSecurityAndRedactionTest {

    @Test
    void accountViewWithoutBalanceViewReceivesNullMoneyFields() {
        authenticate("account:view");
        AccountRepository repository = mock(AccountRepository.class);
        Account account = account();
        when(repository.findById(account.getId())).thenReturn(Optional.of(account));
        AccountService service = service(repository, mock(EntityManager.class));

        var detail = service.detail(account.getId());

        assertThat(detail.getCode()).isEqualTo("ZH000001");
        assertThat(detail.getInitBalance()).isNull();
        assertThat(detail.getReceiptsTotal()).isNull();
        assertThat(detail.getPaymentsTotal()).isNull();
        assertThat(detail.getAdjustmentsTotal()).isNull();
        assertThat(detail.getBalanceCurrent()).isNull();
        assertThat(detail.getBalanceFloor()).isNull();
        assertThat(detail.getBalanceCurrentText()).isNull();
    }

    @Test
    void accountViewWithoutBalanceViewCannotUseBalanceSortSideChannel() {
        authenticate("account:view");
        AccountRepository repository = mock(AccountRepository.class);
        AccountService service = service(repository, mock(EntityManager.class));

        assertThatThrownBy(() -> service.list(
                new AccountQueryFilter(null, Set.of(), null, null, null, null, null),
                1, 20, "balanceCurrent", "desc"))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("不能按余额排序");
        verifyNoInteractions(repository);
    }

    @Test
    void warningEndpointAndServiceRequireViewBalanceAndWarningAuthorities()
            throws Exception {
        String required = "hasAuthority('account:view') and hasAuthority('account:balance:view') "
                + "and hasAuthority('account:warning:manage')";

        PreAuthorize controller = AccountController.class.getDeclaredMethod(
                        "updateWarning", UUID.class, AccountWarningUpdateRequest.class)
                .getAnnotation(PreAuthorize.class);
        PreAuthorize service = AccountService.class.getDeclaredMethod(
                        "updateWarning", UUID.class, AccountWarningUpdateRequest.class)
                .getAnnotation(PreAuthorize.class);

        assertThat(controller.value()).isEqualTo(required);
        assertThat(service.value()).isEqualTo(required);
    }

    @AfterEach
    void clearSecurityContext() {
        SecurityContextHolder.clearContext();
    }

    private static AccountService service(AccountRepository repository, EntityManager em) {
        return new AccountService(
                repository, mock(TxSessionVars.class), em, mock(MasterCodeService.class));
    }

    private static Account account() {
        Account account = new Account();
        account.setCode("ZH000001");
        account.setName("测试账户");
        account.setAccountType(AccountService.TYPE_BANK);
        account.setStatus("使用");
        account.setInitBalance(new BigDecimal("10.0000"));
        account.setReceiptsTotal(new BigDecimal("5.0000"));
        account.setPaymentsTotal(new BigDecimal("1.0000"));
        account.setBalanceAdjustmentsTotal(new BigDecimal("2.0000"));
        account.setBalanceCurrent(new BigDecimal("16.0000"));
        account.setBalanceFloor(new BigDecimal("3.0000"));
        return account;
    }

    private static void authenticate(String... authorities) {
        SecurityContextHolder.getContext().setAuthentication(
                new TestingAuthenticationToken("test", "n/a", authorities));
    }
}
