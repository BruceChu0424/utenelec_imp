package com.uten.imp.audit;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.DepartmentSearchSql;
import com.uten.imp.common.util.EmployeeCandidateFilter;
import com.uten.imp.common.util.KeywordSearch;
import jakarta.persistence.EntityManager;
import jakarta.persistence.PersistenceContext;
import org.springframework.stereotype.Component;

import java.sql.Timestamp;
import java.time.OffsetDateTime;
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
     * @param account 登录账号的脱敏展示值(号码类只保留后 4 位, 与审计表里的 actor_account 同一口径;
     *                列表、详情、导出都只经这里拿账号, 不会带出完整手机号)
     * @param name 员工姓名（无员工档案时为空）
     * @param departmentName 部门名（可能为空）
     * @param positionName 职位/岗位名（可能为空）
     */
    public record ActorProfile(
            String account, String name, String departmentName, String positionName) {

        public ActorProfile {
            account = AuditAccountMask.mask(account);
        }

        /** 列表/详情/导出展示用："张三(*******1111)"，无姓名时退回脱敏账号。 */
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
            if (actorId != null) {
                return byId.get(actorId);
            }
            return actorAccount == null || actorAccount.isBlank()
                    ? null
                    : byAccount.get(actorAccount.trim().toLowerCase());
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
        StringBuilder visitorSql = new StringBuilder("""
                SELECT visitor.id, visitor.visitor_no, visitor.name
                FROM visitor_accounts visitor
                WHERE 1 = 0
                """);
        if (!ids.isEmpty()) {
            visitorSql.append(" OR visitor.id IN (:ids)");
        }
        if (!normalizedAccounts.isEmpty()) {
            visitorSql.append(" OR LOWER(visitor.visitor_no) IN (:accounts)");
        }
        var visitorQuery = entityManager.createNativeQuery(visitorSql.toString());
        if (!ids.isEmpty()) {
            visitorQuery.setParameter("ids", new ArrayList<>(ids));
        }
        if (!normalizedAccounts.isEmpty()) {
            visitorQuery.setParameter("accounts", new ArrayList<>(normalizedAccounts));
        }
        for (Object row : visitorQuery.getResultList()) {
            Object[] cols = (Object[]) row;
            UUID id = toUuid(cols[0]);
            String account = toText(cols[1]);
            ActorProfile profile = new ActorProfile(
                    account, toText(cols[2]), "外部访客", "访客");
            if (id != null) {
                byId.putIfAbsent(id, profile);
            }
            if (account != null && !account.isBlank()) {
                byAccount.putIfAbsent(account.trim().toLowerCase(), profile);
            }
        }
        return new Resolution(byId, byAccount);
    }

    /**
     * UUID-authoritative people directory for the audit-center first step.
     * Deleted/disabled historical users remain selectable; system jobs never
     * appear because they have no row in {@code users}.
     */
    public PageResponse<AuditActorOption> findActors(
            String keyword,
            int page,
            int size) {
        return findActors(keyword, page, size, null, false, null, false);
    }

    public PageResponse<AuditActorOption> findActors(String keyword, int page, int size,
            UUID departmentId, boolean includeSubtree, String actorType, boolean unassignedOnly) {
        var pageable = Pageables.of(page, size);
        boolean searched = !KeywordSearch.terms(keyword).isEmpty();
        String path = searched ? DepartmentSearchSql.name("d.name") : "d.name";
        // One directory expression for both count and rows. Historical/deleted
        // staff and visitors remain visible; HR candidate eligibility does not apply here.
        String directory = """
                    SELECT u.id AS actor_id,
                           'staff' AS actor_type,
                           u.login_account AS account,
                           e.full_name AS name,
                           e.code AS employee_code,
                           d.name AS department_name,
                           p.name AS position_name,
                           e.department_id AS department_id,
                           CASE WHEN u.is_deleted THEN 'deleted' ELSE u.status END AS account_status,
                           e.status AS employment_status,
                           %s AS department_path
                    FROM users u
                    LEFT JOIN employees e ON e.id = u.employee_id
                    LEFT JOIN departments d ON d.id = e.department_id
                    LEFT JOIN positions p ON p.id = e.position_id
                    %s
                    UNION ALL
                    SELECT visitor.id,
                           'visitor',
                           visitor.visitor_no,
                           visitor.name,
                           NULL,
                           '外部访客',
                           '访客',
                           NULL::uuid,
                           visitor.status,
                           NULL::text,
                           '外部访客'::text
                    FROM visitor_accounts visitor
                """.formatted(path, DepartmentSearchSql.joins(searched, "e.department_id"));
        var parameters = new java.util.LinkedHashMap<String,Object>();
        StringBuilder filter = new StringBuilder(" WHERE 1=1\n");
        if (searched) {
            filter.append(" AND ").append(KeywordSearch.nativeCondition(keyword, "actorSearch",
                    "directory.name", "directory.account", "directory.employee_code",
                    "directory.department_path", "directory.position_name"));
            KeywordSearch.bindNative(parameters, keyword, "actorSearch");
        }
        var department = EmployeeCandidateFilter.of(departmentId, includeSubtree, List.of(),
                "directory.actor_id", "directory.department_id");
        filter.append(department.sql());
        parameters.putAll(department.parameters());
        if (actorType != null && !actorType.isBlank()) {
            String type = actorType.strip().toLowerCase(java.util.Locale.ROOT);
            if (!Set.of("staff", "visitor").contains(type)) {
                throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED,
                        "审计人员类型须为staff或visitor");
            }
            filter.append(" AND directory.actor_type=:actorType\n");
            parameters.put("actorType", type);
        }
        if (unassignedOnly) filter.append(" AND directory.actor_type='staff' AND directory.department_id IS NULL\n");
        String prefix = DepartmentSearchSql.prefix(searched);
        var dataQuery = entityManager.createNativeQuery(prefix + """
                SELECT directory.actor_id, directory.actor_type, directory.account, directory.name,
                       directory.department_name, directory.position_name, directory.department_id,
                       directory.account_status, directory.employment_status
                FROM (
                """ + directory + ") directory\n" + filter + "\nORDER BY "
                + KeywordSearch.nativeRank(keyword, "actorSearch", "directory.name", "directory.employee_code", "directory.account")
                + ", COALESCE(directory.name, directory.account), directory.actor_id");
        parameters.forEach(dataQuery::setParameter);
        KeywordSearch.nativeRankParameters(keyword, "actorSearch").forEach(dataQuery::setParameter);
        dataQuery.setFirstResult(com.uten.imp.common.web.Pageables.checkedOffset(pageable.getPageNumber() + 1L, pageable.getPageSize()));
        dataQuery.setMaxResults(pageable.getPageSize());

        List<?> rawRows = dataQuery.getResultList();
        List<AuditActorOption> items = new ArrayList<>();
        for (Object raw : rawRows) {
            Object[] row = (Object[]) raw;
            UUID actorId = toUuid(row[0]);
            if (actorId == null) {
                continue;
            }
            // 人员选择器同样只给脱敏账号; 按完整号码或后 4 位搜索仍在库里匹配原值。
            String account = AuditAccountMask.mask(toText(row[2]));
            String name = toText(row[3]);
            items.add(new AuditActorOption(
                    actorId,
                    toText(row[1]),
                    account,
                    actorDisplay(account, name),
                    name,
                    toText(row[4]),
                    toText(row[5]),
                    null,
                    toUuid(row[6]), toText(row[7]), toText(row[8])));
        }
        if (!items.isEmpty()) {
            var activityQuery = entityManager.createNativeQuery("""
                    SELECT actor_id, max(created_at)
                    FROM audit_log
                    WHERE actor_id IN (:actorIds)
                    GROUP BY actor_id
                    """);
            activityQuery.setParameter(
                    "actorIds", items.stream().map(AuditActorOption::actorId).toList());
            Map<UUID, OffsetDateTime> lastActivity = new HashMap<>();
            for (Object raw : activityQuery.getResultList()) {
                Object[] row = (Object[]) raw;
                UUID id = toUuid(row[0]);
                if (id != null) {
                    lastActivity.put(id, toOffsetDateTime(row[1]));
                }
            }
            items.replaceAll(item -> new AuditActorOption(
                    item.actorId(), item.actorType(), item.account(),
                    item.displayName(), item.name(),
                    item.department(), item.position(), lastActivity.get(item.actorId()), item.departmentId(),
                    item.accountStatus(), item.employmentStatus()));
        }
        var result = org.springframework.data.support.PageableExecutionUtils.getPage(rawRows, pageable, () -> {
            var countQuery = entityManager.createNativeQuery(prefix + "SELECT count(*) FROM (" + directory + ") directory\n" + filter);
            parameters.forEach(countQuery::setParameter);
            return ((Number) countQuery.getSingleResult()).longValue();
        });
        return new PageResponse<>(List.copyOf(items), result);
    }

    private static String actorDisplay(String account, String name) {
        if (name == null || name.isBlank()) {
            return account == null ? "" : account;
        }
        return account == null || account.isBlank()
                ? name
                : name + "(" + account + ")";
    }

    private static OffsetDateTime toOffsetDateTime(Object value) {
        if (value instanceof OffsetDateTime offsetDateTime) {
            return offsetDateTime;
        }
        if (value instanceof Timestamp timestamp) {
            return OffsetDateTime.ofInstant(timestamp.toInstant(), BusinessTime.ZONE);
        }
        return value == null ? null : OffsetDateTime.parse(value.toString());
    }

    private static UUID toUuid(Object value) {
        if (value instanceof UUID uuid) {
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
