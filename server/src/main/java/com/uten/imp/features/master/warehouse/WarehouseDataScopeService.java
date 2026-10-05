package com.uten.imp.features.master.warehouse;

import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.warehouse.dto.MyWarehouseScope;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;
import org.springframework.web.context.request.RequestAttributes;
import org.springframework.web.context.request.RequestContextHolder;

import java.sql.Array;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.Collection;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;
import java.util.function.Supplier;
import java.util.stream.Collectors;

/**
 * 仓库数据范围的唯一服务端判定(ADR-149 / V802), 实现 {@link WarehouseTaskScopePort} v2。
 *
 * <p>角色与默认可见仓只由数据库函数 {@code fn_user_warehouse_access} 回答, 本类只做三件事:
 * 按请求缓存一次解析结果(工作台徽章一次汇总十来个来源只解析一次)、校验页面选的仓
 * (越界 403)、把仓库类通知收件人交给 {@code fn_warehouse_notice_recipients}。
 * Java 不再自己算一遍「谁负责哪个仓」。
 */
@Service
@RequiredArgsConstructor
public class WarehouseDataScopeService implements WarehouseTaskScopePort {

    private static final String CACHE_ATTRIBUTE = WarehouseDataScopeService.class.getName() + ".cache";
    /** 工作台徽章按任务中心所选仓汇总时的「本次所选仓」(只在同一线程的汇总执行期间有效)。 */
    private static final ThreadLocal<UUID> REQUESTED = new ThreadLocal<>();

    private final JdbcClient jdbc;
    private final SecurityContextCurrentUser currentUser;

    // ---- WarehouseTaskScopePort ----------------------------------------------------

    @Override
    public WarehouseAccess access() {
        UUID userId = currentUser.id().orElse(null);
        if (userId == null) {
            // 系统上下文(定时任务、事件投递)没有登录主体: 不按人裁剪; HTTP 端点都要求登录。
            return new WarehouseAccess(Role.SUPERVISOR, List.of(), WarehouseTaskScope.ALL, false);
        }
        Map<Object, Object> cache = requestCache();
        String key = "access:" + userId;
        if (cache != null && cache.get(key) instanceof WarehouseAccess cached) return cached;
        WarehouseAccess resolved = resolve(userId);
        if (cache != null) cache.put(key, resolved);
        return resolved;
    }

    @Override
    public WarehouseTaskScope current(UUID requestedWarehouseId) {
        UUID requested = requestedWarehouseId != null ? requestedWarehouseId : REQUESTED.get();
        WarehouseAccess access = access();
        if (requested == null) return access.defaultScope();
        Map<Object, Object> cache = requestCache();
        String key = "scope:" + currentUser.id().map(UUID::toString).orElse("-") + ":" + requested;
        if (cache != null && cache.get(key) instanceof WarehouseTaskScope cached) return cached;
        if (!selectable(access, requested)) {
            throw new ApiException(ErrorCode.FORBIDDEN, OUT_OF_SCOPE_MESSAGE);
        }
        WarehouseTaskScope scope = new WarehouseTaskScope(true, subtree(requested), false);
        if (cache != null) cache.put(key, scope);
        return scope;
    }

    @Override
    public <T> T withRequestedWarehouse(UUID requestedWarehouseId, Supplier<T> work) {
        if (requestedWarehouseId == null) return work.get();
        current(requestedWarehouseId);
        UUID previous = REQUESTED.get();
        REQUESTED.set(requestedWarehouseId);
        try {
            return work.get();
        } finally {
            if (previous == null) REQUESTED.remove();
            else REQUESTED.set(previous);
        }
    }

    @Override
    public boolean warehousePicked() {
        return REQUESTED.get() != null;
    }

    @Override
    public List<UUID> keeperUserIds(Collection<UUID> warehouseIds) {
        List<UUID> ids = distinct(warehouseIds);
        if (ids.isEmpty()) return List.of();
        return jdbc.sql("SELECT unnest(fn_warehouse_keeper_user_ids(CAST(string_to_array(:ids, ',') AS uuid[])))")
                .param("ids", csv(ids))
                .query(UUID.class)
                .list();
    }

    @Override
    public List<UUID> supervisorUserIds() {
        return jdbc.sql("SELECT unnest(fn_warehouse_supervisor_user_ids())").query(UUID.class).list();
    }

    @Override
    public List<UUID> responsibleUserIds() {
        return jdbc.sql("SELECT unnest(fn_warehouse_responsible_user_ids())").query(UUID.class).list();
    }

    @Override
    public List<UUID> noticeCandidateUserIds(Collection<UUID> warehouseIds) {
        return jdbc.sql("""
                        SELECT unnest(fn_warehouse_notice_candidate_user_ids(
                            CAST(string_to_array(NULLIF(:warehouses, ''), ',') AS uuid[])))
                        """)
                .param("warehouses", csv(distinct(warehouseIds)))
                .query(UUID.class)
                .list();
    }

    @Override
    public List<UUID> noticeRecipients(Collection<UUID> pool, Collection<UUID> warehouseIds) {
        List<UUID> members = distinct(pool);
        if (members.isEmpty()) return List.of();
        List<UUID> warehouses = distinct(warehouseIds);
        List<UUID> routed = jdbc.sql("""
                        SELECT unnest(fn_warehouse_notice_recipients(
                            CAST(string_to_array(NULLIF(:warehouses, ''), ',') AS uuid[]),
                            CAST(string_to_array(:pool, ',') AS uuid[])))
                        """)
                .param("warehouses", csv(warehouses))
                .param("pool", csv(members))
                .query(UUID.class)
                .list();
        // 保持调用方池子的顺序(通知逐个投递, 顺序稳定便于测试与审计)。
        return members.stream().filter(routed::contains).toList();
    }

    // ---- my-scope ------------------------------------------------------------------

    /** 当前账号的仓库数据范围(任务中心仓库选择器只依赖它)。 */
    public MyWarehouseScope myScope() {
        WarehouseAccess access = access();
        List<MyWarehouseScope.Option> keepers = options(access.keeperWarehouseIds(), false);
        List<MyWarehouseScope.Option> selectable = switch (access.role()) {
            case SUPERVISOR -> options(null, true);
            case KEEPER -> options(access.defaultScope().warehouseIds(), true);
            case OTHER -> List.of();
        };
        UUID defaultWarehouseId = access.role() == Role.KEEPER && selectable.size() == 1
                ? selectable.getFirst().id() : null;
        return new MyWarehouseScope(access.role().name(), access.role() == Role.SUPERVISOR,
                selectable, keepers, defaultWarehouseId);
    }

    /** 负责关系改了以后, 同一请求里后续的范围判定要重新解析。 */
    void invalidate() {
        Map<Object, Object> cache = requestCache();
        if (cache != null) cache.clear();
    }

    // ---- helpers -------------------------------------------------------------------

    private WarehouseAccess resolve(UUID userId) {
        return jdbc.sql("""
                        SELECT role, keeper_warehouse_ids, scope_warehouse_ids, includes_unassigned, warehouse_member
                        FROM fn_user_warehouse_access(:userId)
                        """)
                .param("userId", userId)
                .query((rs, row) -> {
                    Role role = Role.valueOf(rs.getString("role"));
                    Array scope = rs.getArray("scope_warehouse_ids");
                    WarehouseTaskScope defaultScope = scope == null
                            ? WarehouseTaskScope.ALL
                            : new WarehouseTaskScope(true, uuids(scope), rs.getBoolean("includes_unassigned"));
                    return new WarehouseAccess(role, uuids(rs.getArray("keeper_warehouse_ids")), defaultScope,
                            rs.getBoolean("warehouse_member"));
                })
                .single();
    }

    private boolean selectable(WarehouseAccess access, UUID warehouseId) {
        return switch (access.role()) {
            case SUPERVISOR -> Boolean.TRUE.equals(jdbc.sql(
                            "SELECT EXISTS (SELECT 1 FROM warehouses WHERE id = :id AND NOT is_deleted)")
                    .param("id", warehouseId).query(Boolean.class).single());
            case KEEPER -> access.defaultScope().warehouseIds().contains(warehouseId);
            case OTHER -> false;
        };
    }

    private List<UUID> subtree(UUID warehouseId) {
        return jdbc.sql("SELECT unnest(fn_warehouse_scope_ids(ARRAY[CAST(:id AS uuid)]))")
                .param("id", warehouseId)
                .query(UUID.class)
                .list();
    }

    /** 选择器选项: 先主仓后子仓(按编号); ids 为 null = 全部在用仓。车间内料仓不进选择器。 */
    private List<MyWarehouseScope.Option> options(List<UUID> ids, boolean excludeLineSide) {
        if (ids != null && ids.isEmpty()) return List.of();
        return jdbc.sql("""
                        SELECT w.id, w.code, w.name, w.parent_id
                        FROM warehouses w
                        WHERE NOT w.is_deleted
                          AND (CAST(:all AS boolean) OR w.id = ANY(CAST(string_to_array(:ids, ',') AS uuid[])))
                          AND (NOT CAST(:excludeLineSide AS boolean) OR NOT w.is_line_side)
                        ORDER BY (w.parent_id IS NOT NULL), w.code, w.name, w.id
                        """)
                .param("all", ids == null)
                .param("ids", ids == null ? "" : csv(ids))
                .param("excludeLineSide", excludeLineSide)
                .query((rs, row) -> new MyWarehouseScope.Option(
                        rs.getObject("id", UUID.class), rs.getString("code"), rs.getString("name"),
                        rs.getObject("parent_id", UUID.class)))
                .list();
    }

    @SuppressWarnings("unchecked")
    private static Map<Object, Object> requestCache() {
        RequestAttributes attributes = RequestContextHolder.getRequestAttributes();
        if (attributes == null) return null;
        Object existing = attributes.getAttribute(CACHE_ATTRIBUTE, RequestAttributes.SCOPE_REQUEST);
        if (existing instanceof Map<?, ?> map) return (Map<Object, Object>) map;
        Map<Object, Object> created = new HashMap<>();
        attributes.setAttribute(CACHE_ATTRIBUTE, created, RequestAttributes.SCOPE_REQUEST);
        return created;
    }

    private static List<UUID> distinct(Collection<UUID> ids) {
        return ids == null ? List.of() : ids.stream().filter(Objects::nonNull).distinct().toList();
    }

    private static String csv(Collection<UUID> ids) {
        return ids.stream().map(UUID::toString).collect(Collectors.joining(","));
    }

    private static List<UUID> uuids(Array array) throws SQLException {
        if (array == null) return List.of();
        Object[] values = (Object[]) array.getArray();
        List<UUID> result = new ArrayList<>(values.length);
        for (Object value : values) {
            if (value != null) result.add(value instanceof UUID uuid ? uuid : UUID.fromString(value.toString()));
        }
        return List.copyOf(result);
    }
}
