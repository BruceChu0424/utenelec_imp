package com.uten.imp.security;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Stream;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * permissions-03 / 07 / 12：「一个码能怎么授」只有 permissions.grant_policy 一份。
 * 锁住：原先 5 份名单合并后的结果、数据库守卫、页面权限面一致性、全员基础包、角色体系已删除，
 * 以及主代码 / 前端不再出现任何按码写死的授权名单。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class PermissionGrantPolicyContractTest {

    /** 原 PermissionDelegationPolicy 硬编码名单里仍存在的码：合并后必须全部不可委派。 */
    private static final List<String> FORMER_NON_DELEGABLE = List.of(
            "authorization:manage", "account:support", "account:balance:adjust", "stock:balance:adjust",
            "finance_asset:approve", "finance_asset:post", "finance_asset:dispose",
            "finance_asset_period:manage", "production_material_analysis:view",
            "production_material_analysis:cross_reallocate", "sales_order:priority", "sales_order:reallocate",
            "supplier_return_task:view", "supplier_return_task:complete", "attachment:reconcile:view",
            "attachment:reconcile:approve_delete", "payroll:export", "dashboard:finance_sensitive:view",
            "audit_log:view", "audit_log:export");

    /** 原前端 authorize_all_excluded 名单里仍存在的码：合并后必须全部不随「全部授权」发放。 */
    private static final List<String> FORMER_BULK_EXCLUDED = List.of(
            "client:view:all", "finance:view:all", "goods:view:all", "payroll:view:all",
            "production_plan:view:all", "purchase:view:all", "sales:view:all", "stock_doc:view:all",
            "subcontract:view:all", "audit_log:view", "audit_log:export", "authorization:manage",
            "goods:price:view", "account:balance:adjust", "stock:balance:adjust", "finance_asset:approve",
            "finance_asset:post", "finance_asset:dispose", "finance_asset_period:manage",
            "sales_order:priority", "sales_order:reallocate", "production_material_analysis:cross_reallocate",
            "supplier_return_task:view", "supplier_return_task:complete", "goods:cost:view",
            "sales_order:price:view", "production_direct_transfer:approve",
            "production_material_analysis:over_supply", "dashboard:finance_sensitive:view");

    @Test
    void everyCodeFollowsTheNamingRuleAndHasAValidPolicy() {
        JdbcTemplate db = PermissionCatalogTestSupport.database();
        assertThat(PermissionCatalogTestSupport.catalogCodes())
                .allMatch(code -> PermissionCatalogTestSupport.CODE.matcher(code).matches());
        assertThat(db.queryForObject(
                "SELECT count(*) FROM permissions WHERE code LIKE '%:view:all'"
                        + " AND NOT (grant_policy @> ARRAY['BULK_EXCLUDED','NON_DELEGABLE']::text[])",
                Integer.class)).isZero();
        assertThatThrownBy(() -> db.update(
                "UPDATE permissions SET code = 'goods:view-all' WHERE code = 'goods:view:all'"))
                .isInstanceOf(DataAccessException.class);
        assertThatThrownBy(() -> db.update(
                "UPDATE permissions SET grant_policy = ARRAY['NORMAL','BULK_EXCLUDED'] WHERE code = 'goods:view'"))
                .isInstanceOf(DataAccessException.class);
    }

    @Test
    void formerFiveListsAreMergedIntoGrantPolicy() {
        JdbcTemplate db = PermissionCatalogTestSupport.database();
        for (String code : FORMER_NON_DELEGABLE) {
            assertThat(db.queryForObject(
                    "SELECT grant_policy && ARRAY['NON_DELEGABLE','INDIVIDUAL_ONLY','SUPERADMIN_ONLY']::text[]"
                            + " FROM permissions WHERE code = ?", Boolean.class, code))
                    .as(code + " 必须不可委派").isTrue();
        }
        for (String code : FORMER_BULK_EXCLUDED) {
            assertThat(db.queryForObject(
                    "SELECT grant_policy && ARRAY['BULK_EXCLUDED','INDIVIDUAL_ONLY','SUPERADMIN_ONLY']::text[]"
                            + " FROM permissions WHERE code = ?", Boolean.class, code))
                    .as(code + " 必须不随全部授权发放").isTrue();
        }
        assertThat(db.queryForList(
                "SELECT code FROM permissions WHERE 'SUPERADMIN_ONLY' = ANY(grant_policy) ORDER BY code",
                String.class)).contains("authorization:manage", "system:business_data_reset");
    }

    @Test
    void databaseGuardsEnforceThePolicyForEveryGrantPath() {
        JdbcTemplate db = PermissionCatalogTestSupport.database();
        assertThat(db.queryForObject("""
                SELECT count(*) FROM department_permissions grant_row
                JOIN permissions permission ON permission.id = grant_row.permission_id
                WHERE permission.grant_policy && ARRAY['INDIVIDUAL_ONLY','SUPERADMIN_ONLY']::text[]
                """, Integer.class)).isZero();
        assertThatThrownBy(() -> db.update("""
                INSERT INTO department_permissions (department_id, permission_id)
                SELECT department.id, permission.id FROM departments department, permissions permission
                WHERE department.code = 'DEPT_FIN' AND permission.code = 'stock:balance:adjust'
                """)).isInstanceOf(DataAccessException.class).hasMessageContaining("逐人授予");
        // BEFORE 行触发器先于外键检查执行：随便一个用户 id 就能验证守卫本身。
        UUID user = UUID.randomUUID();
        assertThatThrownBy(() -> db.update("""
                INSERT INTO user_permission_overrides (user_id, permission_id, effect)
                SELECT ?, permission.id, 'grant' FROM permissions permission
                WHERE permission.code = 'authorization:manage'
                """, user))
                .isInstanceOf(DataAccessException.class).hasMessageContaining("超级管理员");
        assertThatThrownBy(() -> db.update("""
                INSERT INTO permission_surface_permissions (surface_id, permission_id)
                SELECT surface.id, permission.id FROM permission_surfaces surface, permissions permission
                WHERE surface.surface_key = 'basic.goods' AND permission.code = 'system:business_data_reset'
                """)).isInstanceOf(DataAccessException.class);
    }

    @Test
    void pageSurfacesOnlyOfferGrantableCodesAndEveryDelegableCodeHasASurface() {
        JdbcTemplate db = PermissionCatalogTestSupport.database();
        assertThat(db.queryForList("""
                SELECT permission.code FROM permission_surface_permissions mapping
                JOIN permission_surfaces surface ON surface.id = mapping.surface_id AND surface.enabled
                JOIN permissions permission ON permission.id = mapping.permission_id
                WHERE 'SUPERADMIN_ONLY' = ANY(permission.grant_policy)
                """, String.class)).isEmpty();
        assertThat(db.queryForList("""
                SELECT permission.code FROM permissions permission
                WHERE NOT permission.baseline
                  AND NOT (permission.grant_policy && ARRAY['NON_DELEGABLE','INDIVIDUAL_ONLY','SUPERADMIN_ONLY']::text[])
                  AND NOT EXISTS (
                      SELECT 1 FROM permission_surface_permissions mapping
                      JOIN permission_surfaces surface ON surface.id = mapping.surface_id AND surface.enabled
                      WHERE mapping.permission_id = permission.id)
                ORDER BY permission.code
                """, String.class))
                .as("可由负责人委派的码必须挂在至少一个页面权限面上，否则负责人无处可授")
                .isEmpty();
    }

    @Test
    void visitorHostWhitelistIsASuperAdminDecidedDepartmentGrant() {
        JdbcTemplate db = PermissionCatalogTestSupport.database();
        assertThat(db.queryForObject(
                "SELECT grant_policy::text FROM permissions WHERE code = 'visitor:host_confirm'", String.class))
                .isEqualTo("{NON_DELEGABLE}");
        assertThat(db.queryForList("""
                SELECT department.code FROM department_permissions allocation
                JOIN departments department ON department.id = allocation.department_id
                JOIN permissions permission ON permission.id = allocation.permission_id
                WHERE permission.code = 'visitor:host_confirm'
                """, String.class))
                .contains("GM", "DEPT_SALES", "DEPT_HR", "SUB_PURCHASE")
                .doesNotContain("SUB_WH", "DEPT_FIN", "WS_ZHUSU");
    }

    @Test
    void baselineReplacesTheRoleSystemEntirely() {
        JdbcTemplate db = PermissionCatalogTestSupport.database();
        assertThat(db.queryForList("SELECT code FROM permissions WHERE baseline ORDER BY code", String.class))
                .contains("notice:read", "expense:apply", "profile:edit:self")
                // V657：接待访客是对外接待白名单，不再人人有份。
                .doesNotContain("visitor:apply", "visitor:view", "visitor:host_confirm");
        for (String table : List.of("roles", "user_roles", "role_permissions", "department_roles")) {
            assertThat(db.queryForObject("SELECT to_regclass(?) IS NULL", Boolean.class, table))
                    .as(table + " 应已删除").isTrue();
        }
        assertThatThrownBy(() -> db.update(
                "UPDATE permissions SET baseline = TRUE WHERE code = 'finance:view:all'"))
                .isInstanceOf(DataAccessException.class);
    }

    @Test
    void noHardCodedGrantListsRemainInServerOrClientCode() throws Exception {
        try (Stream<Path> files = Files.walk(Path.of("src", "main", "java"))) {
            for (Path file : files.filter(p -> p.toString().endsWith(".java")).toList()) {
                String source = Files.readString(file);
                assertThat(source).as(file.toString())
                        .doesNotContain("INDIVIDUAL_ONLY_PERMISSION_CODES")
                        .doesNotContain("NON_DELEGABLE = Set.of(")
                        .doesNotContain("BASELINE_ROLE_CODE")
                        .doesNotContain("ROLE_\" +");
            }
        }
        Path lib = Files.exists(Path.of("..", "lib")) ? Path.of("..", "lib") : Path.of("lib");
        assertThat(lib.resolve("features/admin/authorize_all_excluded.dart")).doesNotExist();
        String permissions = Files.readString(lib.resolve("shared/auth/permissions.dart"));
        assertThat(permissions)
                .as("超管不再并手写兜底清单，只用服务端下发集合")
                .doesNotContain("union 所有已知 Perm")
                .doesNotContain("buttonActionCodes");
        assertThat(Set.of("kAuthorizeAllExcluded")).allSatisfy(name -> {
            try (Stream<Path> files = Files.walk(lib)) {
                assertThat(files.filter(p -> p.toString().endsWith(".dart"))
                        .map(p -> {
                            try {
                                return Files.readString(p);
                            } catch (java.io.IOException e) {
                                throw new IllegalStateException(e);
                            }
                        })
                        .noneMatch(text -> text.contains(name))).isTrue();
            } catch (java.io.IOException e) {
                throw new IllegalStateException(e);
            }
        });
    }
}
