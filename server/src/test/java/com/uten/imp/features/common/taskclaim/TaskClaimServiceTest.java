package com.uten.imp.features.common.taskclaim;

import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.time.OffsetDateTime;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * {@link TaskClaimService} 单元测试：聚焦"show-as-locked"语义与重复操作守卫
 * {@link TaskClaimService#requireNoActiveClaimByOther}。该基础设施此前在本分支无测试。
 */
class TaskClaimServiceTest {

    private TaskClaimRepository claimRepo;
    private EmployeeNameResolver nameResolver;
    private SecurityContextCurrentUser currentUser;
    private AuthUser meUser;
    private TaskClaimService service;

    private static final String TYPE = "EXPENSE_APPROVE";
    private static final String KEY = "claim-uuid-1";
    private final UUID me = UUID.randomUUID();
    private final UUID other = UUID.randomUUID();

    @BeforeEach
    void setUp() {
        claimRepo = mock(TaskClaimRepository.class);
        nameResolver = mock(EmployeeNameResolver.class);
        currentUser = mock(SecurityContextCurrentUser.class);
        meUser = mock(AuthUser.class);
        service = new TaskClaimService(claimRepo, nameResolver, currentUser);

        when(currentUser.get()).thenReturn(Optional.of(meUser));
        when(currentUser.employeeId()).thenReturn(Optional.of(me));
        when(meUser.isSuperAdmin()).thenReturn(false);
        when(meUser.getEmployeeId()).thenReturn(me);
        when(nameResolver.nameOf(any(UUID.class))).thenReturn("张三");
        // claim() 会 save 认领记录，回传同一对象便于断言
        when(claimRepo.save(any(TaskClaim.class))).thenAnswer(inv -> inv.getArgument(0));
    }

    private TaskClaim activeClaim(UUID claimedBy) {
        TaskClaim c = new TaskClaim();
        c.setTargetType(TYPE);
        c.setTargetKey(KEY);
        c.setClaimedBy(claimedBy);
        c.setClaimedAt(OffsetDateTime.now().minusMinutes(1));
        c.setLeaseUntil(OffsetDateTime.now().plusMinutes(20));
        c.setLastHeartbeat(OffsetDateTime.now());
        return c;
    }

    // ===== requireNoActiveClaimByOther：动作端点重复操作守卫 =====

    @Test
    void noActiveClaimAllowsAction() {
        when(claimRepo.findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(TYPE, KEY))
                .thenReturn(Optional.empty());
        assertDoesNotThrow(() -> service.requireNoActiveClaimByOther(TYPE, KEY));
    }

    @Test
    void activeClaimByOtherBlocksAction() {
        when(claimRepo.findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(TYPE, KEY))
                .thenReturn(Optional.of(activeClaim(other)));
        ApiException ex = assertThrows(ApiException.class,
                () -> service.requireNoActiveClaimByOther(TYPE, KEY));
        assertEquals(ErrorCode.CONFLICT, ex.getCode());
    }

    @Test
    void activeClaimBySelfDoesNotBlock() {
        when(claimRepo.findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(TYPE, KEY))
                .thenReturn(Optional.of(activeClaim(me)));
        assertDoesNotThrow(() -> service.requireNoActiveClaimByOther(TYPE, KEY));
    }

    @Test
    void expiredLeaseDoesNotBlockEvenIfByOther() {
        TaskClaim expired = activeClaim(other);
        expired.setLeaseUntil(OffsetDateTime.now().minusMinutes(1)); // 租约过期 → isActive=false
        when(claimRepo.findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(TYPE, KEY))
                .thenReturn(Optional.of(expired));
        assertDoesNotThrow(() -> service.requireNoActiveClaimByOther(TYPE, KEY));
    }

    @Test
    void anonymousCallerBlockedIfOthersClaimActive() {
        when(currentUser.employeeId()).thenReturn(Optional.empty()); // 无员工绑定
        when(claimRepo.findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(TYPE, KEY))
                .thenReturn(Optional.of(activeClaim(other)));
        ApiException ex = assertThrows(ApiException.class,
                () -> service.requireNoActiveClaimByOther(TYPE, KEY));
        assertEquals(ErrorCode.CONFLICT, ex.getCode());
    }

    // ===== claim：第一个人认领胜出，他人 409 =====

    @Test
    void firstClaimSucceeds() {
        when(meUser.getPermissions()).thenReturn(Set.of("expense:approve"));
        when(claimRepo.findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(TYPE, KEY))
                .thenReturn(Optional.empty());
        TaskClaimService.TaskClaimView view = service.claim(TYPE, KEY);
        assertTrue(view.claimedByMe());
        assertEquals(me, view.claimedBy());
    }

    @Test
    void claimByOtherIsRejected() {
        when(meUser.getPermissions()).thenReturn(Set.of("expense:approve"));
        when(claimRepo.findFirstByTargetTypeAndTargetKeyAndReleasedAtIsNull(TYPE, KEY))
                .thenReturn(Optional.of(activeClaim(other)));
        ApiException ex = assertThrows(ApiException.class, () -> service.claim(TYPE, KEY));
        assertEquals(ErrorCode.CONFLICT, ex.getCode());
    }
}
