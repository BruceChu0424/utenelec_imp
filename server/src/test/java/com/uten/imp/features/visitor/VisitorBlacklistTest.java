package com.uten.imp.features.visitor;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.visitor.dto.VisitorScanDto.BlacklistListItem;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.data.domain.PageImpl;
import org.springframework.data.domain.Pageable;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/** 黑名单运营链路：拉黑（原因/时间/操作人 + 审计）、重复拉黑拒绝、解除恢复、列表装配。 */
class VisitorBlacklistTest {

    private VisitorAccountRepository accounts;
    private UserAccountRepository users;
    private EmployeeRepository employees;
    private AuditService audit;
    private VisitorGateService gate;
    private UUID actorId;

    @BeforeEach
    void setUp() {
        accounts = mock(VisitorAccountRepository.class);
        users = mock(UserAccountRepository.class);
        employees = mock(EmployeeRepository.class);
        audit = mock(AuditService.class);
        actorId = UUID.randomUUID();
        SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
        when(current.id()).thenReturn(Optional.of(actorId));
        when(current.get()).thenReturn(Optional.of(new AuthUser(
                actorId, UUID.randomUUID(), "tester",
                Set.of(), Set.of("visitor:blacklist"), false, false, false)));
        VisitorGuard guard = new VisitorGuard(current);
        TxSessionVars tx = mock(TxSessionVars.class);
        when(tx.decrypt(anyString())).thenAnswer(inv -> "decrypted:" + inv.getArgument(0));
        gate = new VisitorGateService(
                mock(VisitorApplicationRepository.class), accounts,
                mock(VisitorApplicationService.class),
                mock(VisitorApplicationMapper.class), guard, tx, current,
                new ObjectMapper(), audit, users, employees);
    }

    private VisitorAccount activeAccount() {
        VisitorAccount account = new VisitorAccount();
        account.setPhoneEnc("phone-cipher");
        account.setPhoneHash("hash");
        account.setName("访客甲");
        account.setVisitorNo("V123456");
        account.setStatus("active");
        return account;
    }

    @Test
    void blacklistRecordsReasonTimeOperatorAndAudits() {
        VisitorAccount account = activeAccount();
        when(accounts.findAndLockById(account.getId())).thenReturn(Optional.of(account));

        gate.blacklist(account.getId(), " 冒用他人凭证 ");

        assertThat(account.getStatus()).isEqualTo("blocked");
        assertThat(account.getBlockedReason()).isEqualTo("冒用他人凭证");
        assertThat(account.getBlockedAt()).isNotNull();
        assertThat(account.getBlockedBy()).isEqualTo(actorId);
        verify(accounts).save(account);
        verify(audit).logCommitted(
                account.getId(), "V123456", "visitor_blacklist",
                "visitor_account", account.getId().toString(),
                "冒用他人凭证", null);
    }

    @Test
    void doubleBlacklistIsRejectedWithoutRewritingEvidence() {
        VisitorAccount account = activeAccount();
        account.setStatus("blocked");
        OffsetDateTime firstAt = OffsetDateTime.now().minusMinutes(5);
        account.setBlockedAt(firstAt);
        account.setBlockedReason("第一次原因");
        when(accounts.findAndLockById(account.getId())).thenReturn(Optional.of(account));

        assertThatThrownBy(() -> gate.blacklist(account.getId(), "第二次原因"))
                .isInstanceOfSatisfying(ApiException.class,
                        ex -> assertThat(ex.getCode()).isEqualTo(ErrorCode.BUSINESS));
        assertThat(account.getBlockedReason()).isEqualTo("第一次原因");
        assertThat(account.getBlockedAt()).isEqualTo(firstAt);
    }

    @Test
    void unblacklistRestoresActiveAndClearsOperationalFields() {
        VisitorAccount account = activeAccount();
        account.setStatus("blocked");
        account.setBlockedReason("原因");
        account.setBlockedAt(OffsetDateTime.now());
        account.setBlockedBy(actorId);
        when(accounts.findAndLockById(account.getId())).thenReturn(Optional.of(account));

        gate.unblacklist(account.getId());

        assertThat(account.getStatus()).isEqualTo("active");
        assertThat(account.getBlockedReason()).isNull();
        assertThat(account.getBlockedAt()).isNull();
        assertThat(account.getBlockedBy()).isNull();
        verify(audit).logCommitted(
                account.getId(), "V123456", "visitor_unblacklist",
                "visitor_account", account.getId().toString(), "success", null);
    }

    @Test
    void unblacklistRejectsAccountsNotOnTheList() {
        VisitorAccount account = activeAccount();
        when(accounts.findAndLockById(account.getId())).thenReturn(Optional.of(account));

        assertThatThrownBy(() -> gate.unblacklist(account.getId()))
                .isInstanceOfSatisfying(ApiException.class,
                        ex -> assertThat(ex.getCode()).isEqualTo(ErrorCode.BUSINESS));
    }

    @Test
    void blacklistPageMapsItemsAndResolvesOperatorNamesInBulk() {
        VisitorAccount blocked = activeAccount();
        blocked.setStatus("blocked");
        blocked.setBlockedReason("威胁门岗");
        blocked.setBlockedAt(OffsetDateTime.now());
        blocked.setBlockedBy(actorId);
        UUID employeeId = UUID.randomUUID();
        UserAccount operator = new UserAccount();
        operator.setId(actorId);
        operator.setEmployeeId(employeeId);
        Employee employee = new Employee();
        employee.setId(employeeId);
        employee.setFullName("张保安");
        when(accounts.findBlacklisted(any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of(blocked)));
        when(users.findAllById(any())).thenReturn(List.of(operator)).thenReturn(List.of(operator));
        when(employees.findAllById(any())).thenReturn(List.of(employee));

        PageResponse<BlacklistListItem> page = gate.blacklistPage(1, 20);

        assertThat(page.getTotal()).isEqualTo(1);
        BlacklistListItem item = page.getItems().get(0);
        assertThat(item.visitorNo()).isEqualTo("V123456");
        assertThat(item.name()).isEqualTo("访客甲");
        assertThat(item.phone()).isEqualTo("decrypted:phone-cipher");
        assertThat(item.blockedReason()).isEqualTo("威胁门岗");
        assertThat(item.blockedByName()).isEqualTo("张保安");
    }
}
