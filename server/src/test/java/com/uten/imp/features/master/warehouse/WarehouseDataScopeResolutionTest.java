package com.uten.imp.features.master.warehouse;

import com.uten.imp.application.port.WarehouseTaskScopePort.Role;
import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseAccess;
import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.simple.JdbcClient;

import java.util.List;
import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicReference;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.RETURNS_SELF;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * ADR-149 仓库数据范围的解析时机: 窗口外每次实时解析(调离部门、改负责人后下一次判定立即生效, 不靠请求边界),
 * 只读汇总显式打开的窗口内同一账号同一所选仓只解析一次(准则 14「范围解析次数 ≤ 不同范围数」)。
 */
class WarehouseDataScopeResolutionTest {

    private static final String ACCESS_SQL = "fn_user_warehouse_access";
    private static final String EXISTS_SQL = "FROM warehouses WHERE id";
    private static final String SUBTREE_SQL = "fn_warehouse_scope_ids";

    private final UUID warehouse = UUID.fromString("00000000-0000-0000-0000-00000000b001");
    private final UUID other = UUID.fromString("00000000-0000-0000-0000-00000000b002");
    private final UUID userA = UUID.fromString("00000000-0000-0000-0000-00000000c001");
    private final UUID userB = UUID.fromString("00000000-0000-0000-0000-00000000c002");

    private final JdbcClient jdbc = mock(JdbcClient.class);
    private final SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
    private final WarehouseDataScopeService service = new WarehouseDataScopeService(jdbc, currentUser);
    /** 数据库函数「此刻」会回答的范围(测试里改它 = 改了组织或负责关系)。 */
    private final AtomicReference<WarehouseAccess> database = new AtomicReference<>();

    @BeforeEach
    @SuppressWarnings({"unchecked", "rawtypes"})
    void stubDatabase() {
        JdbcClient.StatementSpec access = mock(JdbcClient.StatementSpec.class, RETURNS_SELF);
        JdbcClient.MappedQuerySpec resolved = mock(JdbcClient.MappedQuerySpec.class);
        when(jdbc.sql(contains(ACCESS_SQL))).thenReturn(access);
        when(access.query(any(RowMapper.class))).thenReturn(resolved);
        when(resolved.single()).thenAnswer(call -> database.get());

        JdbcClient.StatementSpec exists = mock(JdbcClient.StatementSpec.class, RETURNS_SELF);
        JdbcClient.MappedQuerySpec existing = mock(JdbcClient.MappedQuerySpec.class);
        when(jdbc.sql(contains(EXISTS_SQL))).thenReturn(exists);
        when(exists.query(eq(Boolean.class))).thenReturn(existing);
        when(existing.single()).thenReturn(true);

        JdbcClient.StatementSpec subtree = mock(JdbcClient.StatementSpec.class, RETURNS_SELF);
        JdbcClient.MappedQuerySpec ids = mock(JdbcClient.MappedQuerySpec.class);
        when(jdbc.sql(contains(SUBTREE_SQL))).thenReturn(subtree);
        when(subtree.query(eq(UUID.class))).thenReturn(ids);
        when(ids.list()).thenReturn(List.of(warehouse));

        when(currentUser.id()).thenReturn(Optional.of(userA));
    }

    @Test
    void outsideAWindowEveryDecisionSeesTheCurrentOrganization() {
        database.set(member());
        assertThat(service.access().warehouseParticipant()).isTrue();
        // 同一线程、同一「请求」里调离仓储部门: 下一次判定立即按新组织算。
        database.set(outsider());
        assertThat(service.access().warehouseParticipant()).isFalse();
        database.set(keeper(warehouse));
        assertThat(service.current(null).warehouseIds()).containsExactly(warehouse);
        database.set(keeper(other));
        assertThat(service.current(null).warehouseIds()).containsExactly(other);

        verify(jdbc, times(4)).sql(contains(ACCESS_SQL));
    }

    @Test
    void aSummaryWindowResolvesEachDistinctScopeOnceAndClosesAfterwards() {
        database.set(member());
        service.withScopeCache(() -> {
            for (int source = 0; source < 12; source++) {
                service.access();
                service.current(null);
            }
            // 窗口内再开窗口(徽章汇总里的本部门待办)沿用外层。
            return service.withScopeCache(() -> service.current(null));
        });
        verify(jdbc, times(1)).sql(contains(ACCESS_SQL));

        // 换了账号是另一个范围; 同一账号仍只解析一次。
        service.withScopeCache(() -> {
            service.access();
            when(currentUser.id()).thenReturn(Optional.of(userB));
            service.access();
            service.access();
            when(currentUser.id()).thenReturn(Optional.of(userA));
            return service.access();
        });
        verify(jdbc, times(3)).sql(contains(ACCESS_SQL));

        // 窗口关了: 又回到每次实时解析。
        database.set(outsider());
        assertThat(service.access().warehouseParticipant()).isFalse();
        verify(jdbc, times(4)).sql(contains(ACCESS_SQL));
    }

    @Test
    void aPickedWarehouseSummaryValidatesAndExpandsTheWarehouseOnce() {
        database.set(supervisor());
        WarehouseTaskScope scope = service.withRequestedWarehouse(warehouse, () -> {
            assertThat(service.warehousePicked()).isTrue();
            WarehouseTaskScope last = null;
            for (int source = 0; source < 12; source++) last = service.current(null);
            return last;
        });
        assertThat(scope.warehouseIds()).containsExactly(warehouse);
        assertThat(service.warehousePicked()).isFalse();
        verify(jdbc, times(1)).sql(contains(ACCESS_SQL));
        verify(jdbc, times(1)).sql(contains(EXISTS_SQL));
        verify(jdbc, times(1)).sql(contains(SUBTREE_SQL));
    }

    @Test
    void anOutOfScopeSelectionIsNeverRemembered() {
        database.set(keeper(warehouse));
        service.withScopeCache(() -> {
            for (int attempt = 0; attempt < 2; attempt++) {
                assertThatThrownBy(() -> service.current(other)).isInstanceOfSatisfying(ApiException.class,
                        error -> assertThat(error.getCode()).isEqualTo(ErrorCode.FORBIDDEN));
            }
            return null;
        });
        // 越界抛错后窗口照样关闭, 后面的判定实时。
        assertThatThrownBy(() -> service.withRequestedWarehouse(other, () -> null)).isInstanceOf(ApiException.class);
        database.set(supervisor());
        assertThat(service.access().role()).isEqualTo(Role.SUPERVISOR);
    }

    private WarehouseAccess member() {
        return new WarehouseAccess(Role.OTHER, List.of(), new WarehouseTaskScope(true, List.of(other), true), true);
    }

    private WarehouseAccess outsider() {
        return new WarehouseAccess(Role.OTHER, List.of(), new WarehouseTaskScope(true, List.of(other), true), false);
    }

    private WarehouseAccess keeper(UUID id) {
        return new WarehouseAccess(Role.KEEPER, List.of(id), new WarehouseTaskScope(true, List.of(id), false), true);
    }

    private WarehouseAccess supervisor() {
        return new WarehouseAccess(Role.SUPERVISOR, List.of(), WarehouseTaskScope.ALL, true);
    }
}
