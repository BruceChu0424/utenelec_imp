package com.uten.imp.features.workbench.badge;

import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.application.port.WorkbenchBadgeSources;
import com.uten.imp.features.auth.BusinessTaskAudienceService;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.BusinessTaskContext;
import jakarta.persistence.EntityManager;
import org.hibernate.Session;
import org.hibernate.jdbc.ReturningWork;
import org.hibernate.jdbc.Work;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.SimpleTransactionStatus;

import java.sql.Connection;
import java.sql.Savepoint;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;
import java.util.stream.Stream;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * 徽章是纯展示层汇总, 按会话主体浏览口径读取(ADR-184 修订): 只有目录镜像、没有任何
 * 真实业务授权的超管, 工作台卡片红黄数照常出现; 任务口径改写只属于任务页面、弹窗与行动通知。
 */
class WorkbenchBadgeBrowsingAudienceTest {
    private WorkbenchBadgeService service;

    @AfterEach void clean() { SecurityContextHolder.clearContext(); }

    @Test void directoryMirrorSuperAdminWithoutRealGrantsStillGetsBadgeEntries() throws Exception {
        Set<String> keys = Arrays.stream(WorkbenchBadgeCatalog.values())
                .flatMap(entry -> Stream.concat(entry.todoFacts().stream(), entry.inProgressFacts().stream()))
                .map(WorkbenchBadgeCatalog::sourceOf)
                .collect(Collectors.toSet());
        List<WorkbenchBadgeSources.Source> registered = keys.stream()
                .map(key -> new WorkbenchBadgeSources.Source(key, () -> {
                    if (BusinessTaskContext.active()
                            || !(SecurityContextHolder.getContext().getAuthentication().getPrincipal()
                                    instanceof AuthUser reader)
                            || !reader.isSuperAdmin()) {
                        throw new AccessDeniedException("task subject leaked into the badge read");
                    }
                    return Map.of("count", 5L);
                })).toList();
        var transactions = mock(PlatformTransactionManager.class);
        when(transactions.getTransaction(any())).thenAnswer(call -> new SimpleTransactionStatus());
        var scopes = mock(WarehouseTaskScopePort.class);
        when(scopes.withQueryScopeCache(any())).thenAnswer(call -> ((WarehouseTaskScopePort.ReadQuery<?>) call.getArgument(0)).read());
        var permissions = mock(PermissionResolver.class);
        when(permissions.grantedPermsOf(any(UUID.class))).thenReturn(Set.of());
        service = new WorkbenchBadgeService(List.of(() -> registered), transactions, scopes,
                new BusinessTaskAudienceService(permissions));

        EntityManager entityManager = mock(EntityManager.class);
        Connection connection = mock(Connection.class);
        Session session = mock(Session.class);
        when(connection.setSavepoint()).thenReturn(mock(Savepoint.class));
        when(entityManager.unwrap(Session.class)).thenReturn(session);
        when(session.doReturningWork(any())).thenAnswer(call ->
                ((ReturningWork<?>) call.getArgument(0)).execute(connection));
        doAnswer(call -> {
            ((Work) call.getArgument(0)).execute(connection);
            return null;
        }).when(session).doWork(any());
        ReflectionTestUtils.setField(service, "entityManager", entityManager);

        AuthUser root = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "root",
                Set.of("production_schedule:view"), false, true, true);
        SecurityContextHolder.getContext().setAuthentication(
                UsernamePasswordAuthenticationToken.authenticated(root, null, root.getAuthorities()));

        WorkbenchBadgeSummary summary = service.summary(Set.of("productionSchedule"));
        assertThat(summary.entries()).containsKey("productionSchedule");
        assertThat(summary.entries().get("productionSchedule").todo()).isEqualTo(5L);
        assertThat(summary.facts()).containsEntry("productionSchedule.count", 5L);
    }
}
