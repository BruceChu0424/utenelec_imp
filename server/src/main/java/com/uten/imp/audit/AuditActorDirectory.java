package com.uten.imp.audit;

import jakarta.persistence.EntityManager;
import jakarta.persistence.PersistenceContext;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.Collection;
import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * 审计操作人信息解析（只读）。
 *
 * <p>audit_log 只存 actor_id / actor_account；展示层需要"姓名 · 部门 · 职位"
 * 才能回答"是谁做的"。本组件用原生 SQL 一次性批量解析，避免逐行 N+1 查询。
 *
 * <p>架构约束：audit 是基础包，不允许 import features 包的实体/仓储，
 * 因此这里直接对 users / employees / departments / positions 表做只读原生查询。
 * 软删除的员工/账号仍会被解析（历史记录需要还原当时的操作人）。
 */
@Component
public class AuditActorDirectory {

    @PersistenceContext
    private EntityManager entityManager;

    /**
     * @param account 登录账号（通常是手机号）
     * @param name 员工姓名（无员工档案时为空）
     * @param departmentName 部门名（可能为空）
     * @param positionName 职位/岗位名（可能为空）
     */
    public record ActorProfile(
            String account, String name, String departmentName, String positionName) {

        /** 列表/详情展示用："张三（13900001111）"，无姓名时退回账号。 */
        public String displayName() {
            if (name == null || name.isBlank()) {
                return account == null || account.isBlank() ? "" : account;
            }
            return account == null || account.isBlank()
                    ? name
                    : name + "(" + account + ")";
        }
    }

    /** 一次解析结果：同时支持按用户 ID 与按登录账号索引。 */
    public record Resolution(
            Map<UUID, ActorProfile> byId, Map<String, ActorProfile> byAccount) {

        static Resolution empty() {
            return new Resolution(Map.of(), Map.of());
        }

        public ActorProfile forActor(UUID actorId, String actorAccount) {
            ActorProfile profile = actorId == null ? null : byId.get(actorId);
            if (profile == null && actorAccount != null && !actorAccount.isBlank()) {
                profile = byAccount.get(actorAccount.trim().toLowerCase());
            }
            return profile;
        }
    }

    /**
     * 批量解析一页审计记录的操作人档案。id / 账号任一命中即可；
     * 解析不到（访客、已清理的历史账号、纯系统任务）时返回空集合，调用方降级展示。
     */
    public Resolution resolve(Collection<UUID> actorIds, Collection<String> accounts) {
        Set<UUID> ids = new LinkedHashSet<>();
        if (actorIds != null) {
            actorIds.stream().filter(value -> value != null).forEach(ids::add);
        }
        Set<String> normalizedAccounts = new LinkedHashSet<>();
        if (accounts != null) {
            accounts.stream()
                    .filter(value -> value != null && !value.isBlank())
                    .map(value -> value.trim().toLowerCase())
                    .forEach(normalizedAccounts::add);
        }
        if (ids.isEmpty() && normalizedAccounts.isEmpty()) {
            return Resolution.empty();
        }

        StringBuilder sql = new StringBuilder("""
                SELECT u.id, u.login_account, e.full_name, d.name, p.name
                FROM users u
                LEFT JOIN employees e ON e.id = u.employee_id
                LEFT JOIN departments d ON d.id = e.department_id
                LEFT JOIN positions p ON p.id = e.position_id
                WHERE 1 = 0
                """);
        if (!ids.isEmpty()) {
            sql.append(" OR u.id IN (:ids)");
        }
        if (!normalizedAccounts.isEmpty()) {
            sql.append(" OR LOWER(u.login_account) IN (:accounts)");
        }

        var query = entityManager.createNativeQuery(sql.toString());
        if (!ids.isEmpty()) {
            query.setParameter("ids", new ArrayList<>(ids));
        }
        if (!normalizedAccounts.isEmpty()) {
            query.setParameter("accounts", new ArrayList<>(normalizedAccounts));
        }

        Map<UUID, ActorProfile> byId = new HashMap<>();
        Map<String, ActorProfile> byAccount = new HashMap<>();
        for (Object row : query.getResultList()) {
            Object[] cols = (Object[]) row;
            UUID id = toUuid(cols[0]);
            String account = toText(cols[1]);
            ActorProfile profile = new ActorProfile(
                    account, toText(cols[2]), toText(cols[3]), toText(cols[4]));
            if (id != null) {
                byId.put(id, profile);
            }
            if (account != null && !account.isBlank()) {
                byAccount.put(account.trim().toLowerCase(), profile);
            }
        }
        return new Resolution(byId, byAccount);
    }

    /**
     * 按员工姓名模糊匹配用户 ID（审计关键词搜索"操作人姓名"用）。
     * 匹配不到返回空集，调用方退回账号/路径等字段检索。
     */
    public Set<UUID> findUserIdsByNameKeyword(String keyword) {
        if (keyword == null || keyword.isBlank()) {
            return Set.of();
        }
        String escaped = keyword.trim().toLowerCase()
                .replace("!", "!!")
                .replace("%", "!%")
                .replace("_", "!_");
        var query = entityManager.createNativeQuery("""
                SELECT u.id FROM users u
                JOIN employees e ON e.id = u.employee_id
                WHERE LOWER(e.full_name) LIKE :kw ESCAPE '!'
                """);
        query.setParameter("kw", "%" + escaped + "%");
        Set<UUID> result = new LinkedHashSet<>();
        for (Object row : query.getResultList()) {
            UUID id = toUuid(row);
            if (id != null) {
                result.add(id);
            }
        }
        return result;
    }

    private static UUID toUuid(Object value) {        if (value instanceof UUID uuid) {
            return uuid;
        }
        if (value instanceof String text) {
            try {
                return UUID.fromString(text);
            } catch (IllegalArgumentException ignored) {
                return null;
            }
        }
        return null;
    }

    private static String toText(Object value) {
        return value == null ? null : value.toString();
    }

    /** 汇总一页行项目涉及的 actor id / account，供一次性批量解析。 */
    static List<UUID> actorIdsOf(List<? extends AuditLog> logs) {
        return logs.stream()
                .map(AuditLog::getActorId)
                .filter(value -> value != null)
                .distinct()
                .toList();
    }

    static List<String> actorAccountsOf(List<? extends AuditLog> logs) {
        return logs.stream()
                .map(AuditLog::getActorAccount)
                .filter(value -> value != null && !value.isBlank())
                .distinct()
                .toList();
    }
}
