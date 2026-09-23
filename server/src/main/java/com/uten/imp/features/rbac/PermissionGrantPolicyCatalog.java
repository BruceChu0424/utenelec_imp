package com.uten.imp.features.rbac;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.sql.init.dependency.DependsOnDatabaseInitialization;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

import java.sql.Array;
import java.sql.SQLException;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.Set;

/**
 * 授权策略的只读快照(permissions.grant_policy 由迁移维护，运行期不改)。
 *
 * <p>权限合成在每次解析负责人委派时都要判断「这个码能不能委派」，这里第一次使用时一条
 * SQL 把整张目录的策略读进内存，之后不再查库；与 {@code PermissionSurfaceRegistry}
 * 同一口径(迁移拥有的目录，请求期不回源)。
 */
@Component
@DependsOnDatabaseInitialization
public class PermissionGrantPolicyCatalog {

    private final JdbcTemplate jdbc;
    private volatile Map<String, Set<GrantPolicy>> snapshot;

    @Autowired
    public PermissionGrantPolicyCatalog(JdbcTemplate jdbc) {
        this.jdbc = Objects.requireNonNull(jdbc, "jdbc");
    }

    private PermissionGrantPolicyCatalog(Map<String, Set<GrantPolicy>> fixed) {
        this.jdbc = null;
        this.snapshot = Map.copyOf(fixed);
    }

    /** 固定快照(不回源数据库)，供不连库的单元测试构造授权策略。 */
    public static PermissionGrantPolicyCatalog fixed(Map<String, Set<GrantPolicy>> policies) {
        return new PermissionGrantPolicyCatalog(policies);
    }

    /** 码的授权策略；目录里没有这个码时为空。 */
    public Optional<Set<GrantPolicy>> policyOf(String code) {
        if (code == null) {
            return Optional.empty();
        }
        return Optional.ofNullable(snapshot().get(code));
    }

    private Map<String, Set<GrantPolicy>> snapshot() {
        Map<String, Set<GrantPolicy>> current = snapshot;
        if (current == null) {
            synchronized (this) {
                current = snapshot;
                if (current == null) {
                    current = load();
                    snapshot = current;
                }
            }
        }
        return current;
    }

    private Map<String, Set<GrantPolicy>> load() {
        Map<String, Set<GrantPolicy>> result = new HashMap<>();
        jdbc.query("SELECT code, grant_policy FROM permissions", rs -> {
            result.put(rs.getString("code"), parse(rs.getArray("grant_policy")));
        });
        return Collections.unmodifiableMap(result);
    }

    private static Set<GrantPolicy> parse(Array array) throws SQLException {
        if (array == null) {
            return GrantPolicy.parse((String[]) null);
        }
        Object raw = array.getArray();
        String[] values = raw instanceof String[] strings
                ? strings
                : Arrays.stream((Object[]) raw).map(String::valueOf).toArray(String[]::new);
        return Collections.unmodifiableSet(GrantPolicy.parse(values));
    }
}
