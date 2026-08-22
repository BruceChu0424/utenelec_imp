package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.assertj.core.api.Assertions.assertThat;

class PermissionCatalogActionTaxonomyMigrationContractTest {

    private static final Path V328 = Path.of(
            "src/main/resources/db/migration",
            "V328__permission_catalog_action_taxonomy.sql");
    private static final Path V327 = Path.of(
            "src/main/resources/db/migration",
            "V327__permission_override_tombstones.sql");
    private static final String V327_SHA256 =
            "b1584c56c2003e572871e49b5734c34f28a1064dcfeafed1eb91854dcb52571e";

    @Test
    void v328AddsTheAuthoritativeTenActionTypesAndRequiredMetadata()
            throws Exception {
        String sql = raw();
        Matcher constraint = Pattern.compile(
                        "check\\s*\\(action_type\\s+in\\s*\\((.*?)\\)\\)",
                        Pattern.CASE_INSENSITIVE | Pattern.DOTALL)
                .matcher(sql);
        assertThat(constraint.find()).isTrue();

        Set<String> actions = Pattern.compile("'([A-Z_]+)'")
                .matcher(constraint.group(1))
                .results()
                .map(result -> result.group(1))
                .collect(java.util.stream.Collectors.toSet());
        assertThat(actions).containsExactlyInAnyOrder(
                "VIEW", "CREATE", "EDIT", "DELETE", "APPROVE",
                "IMPORT", "EXPORT", "EXECUTE", "CONFIGURE", "ASSIGN");

        assertThat(normalized())
                .contains("add column action_type text")
                .contains("add column description text")
                .contains("add column active boolean not null default true")
                .contains("add column assignable boolean not null default true")
                .contains("alter column action_type set not null")
                .contains("alter column description set not null")
                .contains("validate constraint permissions_action_type_chk");
    }

    @Test
    void v328ClassifiesTheWholePreExistingCatalogExplicitlyAndFailsClosed()
            throws Exception {
        String sql = raw();
        int start = sql.indexOf(
                "INSERT INTO v328_explicit_action_type (code, action_type) VALUES");
        int end = sql.indexOf(";", start);
        assertThat(start).isGreaterThanOrEqualTo(0);
        assertThat(end).isGreaterThan(start);

        String classifications = sql.substring(start, end);
        long rows = Pattern.compile("\\('([^']+)',\\s*'([A-Z_]+)'\\)")
                .matcher(classifications)
                .results()
                .count();
        assertThat(rows)
                .as("211 V327 catalog rows plus the historical source-only production:view code")
                .isEqualTo(212);
        assertThat(classifications)
                .contains("('production:view', 'VIEW')")
                .contains("('finance_asset:approve', 'APPROVE')")
                .contains("('goods:import', 'IMPORT')");
        assertThat(normalized())
                .contains("where action_type is null or description is null")
                .contains("raise exception 'v328 permission catalog contains unclassified codes: %'")
                .doesNotContain("split_part(code")
                .doesNotContain("right(code");
    }

    @Test
    void v328UsesClearNamesAndRetiresConfirmedDeadOrCompositeCodes()
            throws Exception {
        String sql = normalized();
        assertThat(sql)
                .contains("('account:edit', '编辑账户资料'")
                .contains("('stock_doc:edit', '编辑仓库单据草稿'")
                .contains("('authorization:manage', '配置权限与系统安全策略'")
                .contains("('procurement_inspection:handle', '判定采购或委外待检货品合格或不合格'")
                .contains("('visitor:blacklist', '将访客加入黑名单'")
                .contains("('goods:bom:audit', '标记或取消组装明细已核对'")
                .contains("('stock:balance:adjust', '调整库存余额'")
                .contains("('finance:view:all', '查看全部财务单据', '财税管理', '数据范围'")
                .contains("where code in (")
                .contains("'lab:test:view'")
                .contains("'lab:test:upload'")
                .contains("'planning_supply_request:view'")
                .contains("'production_plan_cost:view'")
                .contains("('inventory:view', '历史库存查看权限（已停用）'")
                .contains("('stock:edit', '历史库存编辑权限（已停用）'")
                .contains("('purchase_request:edit', '历史采购申请编辑权限（已停用）'")
                .contains("('subcontract_application:edit', '历史委外申请编辑权限（已停用）'")
                .doesNotContain("('visitor:check_in'")
                .doesNotContain("delete from permissions");
    }

    @Test
    void v328ContainsRepresentativeButtonLevelCodesWithoutRewritingV327()
            throws Exception {
        assertThat(normalized())
                .contains("('goods:create', '新增货品资料'")
                .contains("('material_category:move', '移动物料分类'")
                .contains("('sales_order:create', '新增销售订货单'")
                .contains("('purchase_receipt:approve', '审核采购收货单'")
                .contains("('stock_doc:reverse', '红冲仓库单据'")
                .contains("('department:create', '新增部门'")
                .contains("('employee:offboard', '办理员工离职'")
                .contains("('attachment:upload', '上传附件'")
                .contains("('rd_task:assign', '分配研发任务'")
                .contains("('production_material_analysis:refresh', '刷新生产物料分析'")
                .contains("('production_execution:assign', '调整生产执行段分配'")
                .contains("('production_mrp:generate_draw', '生成生产领料单'")
                .contains("('production_planning_package:draft_edit', '编辑生产预排草案'")
                .contains("('production_material:close', '关闭已结清生产任务'")
                .contains("('webinquiry:convert_client', '将官网询盘转为客户'");

        byte[] digest = MessageDigest.getInstance("SHA-256")
                .digest(Files.readAllBytes(V327));
        assertThat(HexFormat.of().formatHex(digest)).isEqualTo(V327_SHA256);
    }

    @Test
    void v328KeepsUnreachableProductionCompatibilityEndpointsOutOfUiCatalog() throws Exception {
        assertThat(normalized())
                .contains("set active = false, assignable = false")
                .contains("when 'production_execution:cancel' then "
                        + "'历史生产执行段取消接口（已停用）'")
                .contains("'production_mrp:generate_purchase'")
                .contains("'production_mrp:generate_draw'")
                .contains("'production_mrp:generate_finished_in'");
    }


    @Test
    void v328CreatesTheUuidBackedAuditedSurfaceCatalog() throws Exception {
        String sql = normalized();

        assertThat(sql)
                .contains("create table permission_surfaces")
                .contains("id uuid primary key")
                .contains("constraint permission_surfaces_key_uk unique (surface_key)")
                .contains("constraint permission_surfaces_key_chk check")
                .contains("create table permission_surface_permissions")
                .contains("primary key (surface_id, permission_id)")
                .contains("foreign key (surface_id) references permission_surfaces(id) "
                        + "on delete restrict")
                .contains("foreign key (permission_id) references permissions(id) "
                        + "on delete restrict")
                .contains("create index idx_permission_surfaces_enabled_catalog")
                .contains("create index idx_permission_surface_permissions_permission")
                .contains("create trigger trg_set_updated_at_permission_surfaces")
                .contains("create trigger trg_audit_permission_surfaces")
                .contains("create trigger trg_audit_permission_surface_permissions")
                .contains("execute function fn_audit()");
    }

    @Test
    void v328SeedsExactlyEightyFiveStableSurfaceIdsAndTitles()
            throws Exception {
        String sql = raw();
        int start = sql.indexOf(
                "INSERT INTO permission_surfaces (id, surface_key, name, sort_order) VALUES");
        int end = sql.indexOf(";", start);
        assertThat(start).isGreaterThanOrEqualTo(0);
        assertThat(end).isGreaterThan(start);
        String seeds = sql.substring(start, end);

        Pattern seed = Pattern.compile(
                "\\('([0-9a-f-]{36})',\\s*'([^']+)',\\s*'([^']+)',\\s*(\\d+)\\)");
        Set<String> ids = seed.matcher(seeds)
                .results()
                .map(result -> result.group(1))
                .collect(java.util.stream.Collectors.toSet());
        Set<String> keys = seed.matcher(seeds)
                .results()
                .map(result -> result.group(2))
                .collect(java.util.stream.Collectors.toSet());

        assertThat(ids).hasSize(85);
        assertThat(keys).hasSize(85);
        assertThat(ids).allMatch(id -> id.startsWith(
                "32800000-0000-4000-8000-"));
        assertThat(seeds)
                .contains("('32800000-0000-4000-8000-000000000001', "
                        + "'basic.goods', '货品资料', 1)")
                .contains("('32800000-0000-4000-8000-000000000023', "
                        + "'quality.lab-test', '检测记录', 23)")
                .contains("('32800000-0000-4000-8000-000000000085', "
                        + "'finance.hub', '钱流管理', 85)");
    }

    @Test
    void v328ExpandsLegacyRulesOnceThenStoresOnlyExactUuidLinks()
            throws Exception {
        String sql = raw();
        int start = sql.indexOf(
                "INSERT INTO v328_permission_surface_rules");
        int end = sql.indexOf(";", start);
        assertThat(start).isGreaterThanOrEqualTo(0);
        assertThat(end).isGreaterThan(start);
        String rules = sql.substring(start, end);
        long ruleRows = Pattern.compile(
                        "(?m)^\\s*\\('([a-z][a-z0-9.-]+)'")
                .matcher(rules)
                .results()
                .count();

        assertThat(ruleRows).isEqualTo(85);
        assertThat(rules).doesNotContain("'production:view'");
        assertThat(normalized())
                .contains("left(permission.code, length(code_prefix.value)) "
                        + "= code_prefix.value")
                .contains("insert into permission_surface_permissions "
                        + "(surface_id, permission_id)")
                .contains("on conflict (surface_id, permission_id) do nothing")
                .contains("('basic.payment-style', 'settlement_method:create')")
                .contains("('org.department', 'department:create')")
                .contains("('org.department', 'department:move')")
                .contains("('org.department', 'department:manager_assign')")
                .contains("('org.department', 'position:delete')")
                .contains("('org.employee', 'attachment:download')")
                .contains("('purchase.arrival-exception', "
                        + "'supplier_return_task:complete')")
                .contains("('purchase.hub', 'supplier_return_task:view')")
                .contains("('hr.visitor-security', 'visitor:verify')")
                .contains("('production.plan', 'production_execution:dispatch')")
                .contains("('production.plan', 'production_planning_package:generate')")
                .contains("('production.plan', 'production_material:close')")
                .contains("page catalog must contain exactly 85 matching surfaces and rules")
                .doesNotContain("permission.code like code_prefix.value");
    }

    @Test
    void v328ExplicitlyPreservesAllFourAuthorizationSourcesAndSessions()
            throws Exception {
        String sql = raw();
        int start = sql.indexOf(
                "INSERT INTO v328_permission_expansion (old_code, new_code) VALUES");
        int end = sql.indexOf(";", start);
        assertThat(start).isGreaterThanOrEqualTo(0);
        assertThat(end).isGreaterThan(start);
        assertThat(Pattern.compile("\\('([^']+)',\\s*'([^']+)'\\)")
                .matcher(sql.substring(start, end))
                .results()
                .count()).isEqualTo(207);

        assertThat(sql.substring(start, end))
                .contains("('goods:edit', 'goods:create')")
                .contains("('department:edit', 'department:move')")
                .contains("('department:edit', 'department:manager_assign')")
                .contains("('attachment:manage', 'attachment:upload')")
                .contains("('production_material_analysis:manage', "
                        + "'production_material_analysis:cancel')")
                .contains("('inventory:view', 'stock:view')")
                .contains("('production_plan:edit', "
                        + "'production_execution:release_defer')");

        assertThat(normalized())
                .contains("insert into role_permissions (role_id, permission_id)")
                .contains("insert into department_permissions "
                        + "( department_id, permission_id, created_at, created_by )")
                .contains("where source.active = true")
                .contains("insert into user_permission_overrides as target")
                .contains("target.effect = 'grant' and excluded.effect = 'revoke'")
                .contains("from v328_effective_manager_delegation_source source")
                .contains("insert into manager_permission_delegations")
                .contains("on conflict (user_id, permission_id, department_id) do nothing")
                .contains("update authorization_state set epoch = epoch + 1")
                .contains("update users set auth_version = auth_version + 1")
                .contains("update refresh_tokens set revoked_at = current_timestamp "
                        + "where revoked_at is null");
    }

    private static String raw() throws Exception {
        return Files.readString(V328, StandardCharsets.UTF_8);
    }

    private static String normalized() throws Exception {
        return raw()
                .replaceAll("--[^\\r\\n]*", " ")
                .replaceAll("\\s+", " ")
                .trim()
                .toLowerCase();
    }
}
