package com.uten.imp.features.production;

import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.Test;

import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

/**
 * 超级管理员不隶属任何车间，却必须能替任何车间办理执行段（开工 / 报工 / 确认用料）。
 *
 * <p>2026-09-11 用户反馈：超管打开「我的车间任务」点不动任何按钮——
 * {@code DailyReportExecutionSegmentGuard.requireWorkshopOperationAccess} 是**无回退**的
 * 成员判定，超管既不是段负责人也不在任何车间子树里，一律 403。
 * 放行点统一落在本类，两个调用方（执行段写侧 + 日报守卫）同时生效。
 */
class ProductionWorkshopMembershipSuperAdminTest {

    private static AuthUser staff(boolean superAdmin) {
        return new AuthUser(
                UUID.randomUUID(),
                UUID.randomUUID(),
                "tester",
                Set.of(),
                Set.of(),
                false,
                true,
                superAdmin);
    }

    private static ProductionWorkshopMembership membership(
            EntityManager em, AuthUser user) {
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.get()).thenReturn(Optional.ofNullable(user));
        return new ProductionWorkshopMembership(em, currentUser);
    }

    /** 超管直接放行，且**不查库**——省一次递归 CTE，也不依赖超管有员工档案。 */
    @Test
    void superAdminPassesWithoutTouchingTheDatabase() {
        EntityManager em = mock(EntityManager.class);

        boolean allowed = membership(em, staff(true))
                .isWorkshopMember(UUID.randomUUID(), UUID.randomUUID(), null);

        assertThat(allowed).isTrue();
        verifyNoInteractions(em);
    }

    /** 普通员工不受影响：没有员工档案 id 时照旧不成立，不会被超管分支放水。 */
    @Test
    void ordinaryStaffWithoutEmployeeIdStillFails() {
        EntityManager em = mock(EntityManager.class);

        boolean allowed = membership(em, staff(false))
                .isWorkshopMember(UUID.randomUUID(), UUID.randomUUID(), null);

        assertThat(allowed).isFalse();
        verifyNoInteractions(em);
    }

    /** 段负责人本人的短路仍在超管判定之后、查库之前。 */
    @Test
    void segmentOwnerStillShortCircuits() {
        EntityManager em = mock(EntityManager.class);
        UUID me = UUID.randomUUID();

        boolean allowed = membership(em, staff(false))
                .isWorkshopMember(UUID.randomUUID(), me, me);

        assertThat(allowed).isTrue();
        verifyNoInteractions(em);
    }

    /** 未登录（无安全上下文）不能当成超管。 */
    @Test
    void anonymousIsNotSuperAdmin() {
        EntityManager em = mock(EntityManager.class);

        boolean allowed = membership(em, null)
                .isWorkshopMember(UUID.randomUUID(), UUID.randomUUID(), null);

        assertThat(allowed).isFalse();
        verifyNoInteractions(em);
    }
}
