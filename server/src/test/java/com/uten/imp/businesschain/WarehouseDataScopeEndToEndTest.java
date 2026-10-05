package com.uten.imp.businesschain;

import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.application.port.WarehouseTaskScopePort.Role;
import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseAccess;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.documents.DocumentDraftCountController;
import com.uten.imp.features.master.warehouse.WarehouseDataScopeService;
import com.uten.imp.features.master.warehouse.WarehouseKeeperService;
import com.uten.imp.features.master.warehouse.dto.MyWarehouseScope;
import com.uten.imp.features.master.warehouse.dto.WarehouseKeeperSaveRequest;
import com.uten.imp.features.notice.WarehouseNoticeRouter;
import com.uten.imp.features.operations.workbench.FulfillmentWorkbenchController;
import com.uten.imp.features.sales.shipment.warehouse.WarehouseSalesOutboundController;
import com.uten.imp.features.stock.StockDocController;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.allocation.ProductionMaterialReturnRequestController;
import com.uten.imp.features.stock.count.StockCountRequestController;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedInboundTaskController;
import com.uten.imp.features.warehouse.inbound.WarehouseInboundController;
import com.uten.imp.features.warehouse.inbound.WarehouseQualityResultController;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialRequisitionController;
import com.uten.imp.features.warehouse.outbound.WarehouseSubcontractOutboundController;
import com.uten.imp.features.workbench.badge.WorkbenchBadgeController;
import com.uten.imp.features.workbench.badge.WorkbenchBadgeSummary;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * ADR-149 仓库数据范围服务端强制, 走真实服务与真实 PG(V804 fn_user_warehouse_access):
 * 七种身份的角色与默认范围; 越界选仓 403; 逐个仓库徽章来源「事实数 == 同身份同范围的列表 total」;
 * 通知收件人与列表同一套负责关系。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false", "uten.production.readiness-reconcile.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=true", "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test", "uten.bootstrap.admin-password=HarnessAdminPass-1!",
        "uten.workshop-material.auto-close.enabled=false"})
class WarehouseDataScopeEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    private static final String[] TASK_PERMISSIONS = {
            "notice:read", "stock_doc:view", "stock_doc:view:all", "warehouse_inbound:view",
            "warehouse_sales_outbound:view", "subcontract_outbound:view", "warehouse_iqc_stock_in:view",
            "workshop_material:view", "stock:count:warehouse_review", "stock_report:view"};

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired PlatformTransactionManager transactions;
    @Autowired WarehouseTaskScopePort scopes;
    @Autowired WarehouseDataScopeService dataScope;
    @Autowired WarehouseKeeperService keepers;
    @Autowired WarehouseNoticeRouter router;
    @Autowired WorkbenchBadgeController badges;
    @Autowired StockDocController stockDocs;
    @Autowired StockDocService stock;
    @Autowired WarehouseInboundController inbound;
    @Autowired WarehouseSalesOutboundController salesOutbound;
    @Autowired WarehouseSubcontractOutboundController subcontractOutbound;
    @Autowired ProductionFinishedInboundTaskController finishedInbound;
    @Autowired WarehouseQualityResultController qualityResults;
    @Autowired FulfillmentWorkbenchController fulfillment;
    @Autowired ProductionMaterialReturnRequestController productionReturns;
    @Autowired WorkshopMaterialRequisitionController requisitions;
    @Autowired StockCountRequestController stockCounts;
    @Autowired DocumentDraftCountController documentCounts;

    private FullChainEndToEndTest fixture;
    private FullChainEndToEndTest.World world;
    private UUID root, warehouseA, warehouseB, warehouseC;
    private UUID admin, manager, mainKeeper, keeperA, keeperAB, member, outsider;
    private UUID previousManager;
    private UUID warehouseDepartment;

    @BeforeEach void seed() {
        fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
        String tag = UUID.randomUUID().toString().substring(0, 8);
        world = fixture.seedWorld("wh-scope-" + tag);
        admin = world.superAdminUserId();
        List<UUID> roots = db.queryForList("SELECT id FROM warehouses WHERE code='001' AND NOT is_deleted", UUID.class);
        if (roots.isEmpty()) {
            root = UUID.randomUUID();
            db.update("INSERT INTO warehouses(id,code,name,status,is_accountable) VALUES (?,'001',?,'使用',true)",
                    root, "范围测试主仓-" + root);
        } else {
            root = roots.getFirst();
        }
        warehouseA = warehouse("范围A仓-" + tag);
        warehouseB = warehouse("范围B仓-" + tag);
        warehouseC = warehouse("范围C仓-" + tag);
        warehouseDepartment = db.queryForObject("SELECT id FROM departments WHERE code='SUB_WH' AND NOT is_deleted", UUID.class);
        manager = warehouseUser("scope-manager-" + tag);
        mainKeeper = warehouseUser("scope-main-" + tag);
        keeperA = warehouseUser("scope-keeper-a-" + tag);
        keeperAB = warehouseUser("scope-keeper-ab-" + tag);
        member = warehouseUser("scope-member-" + tag);
        outsider = fixture.createUserWithPerms(world, "scope-outsider-" + tag, TASK_PERMISSIONS);
        previousManager = db.queryForObject("SELECT manager_id FROM departments WHERE id=?", UUID.class, warehouseDepartment);
        db.update("UPDATE departments SET manager_id=(SELECT employee_id FROM users WHERE id=?) WHERE id=?",
                manager, warehouseDepartment);
        fixture.loginAs(admin);
        keepers.replaceKeepers(root, keepersOf(mainKeeper));
        keepers.replaceKeepers(warehouseA, keepersOf(keeperA, keeperAB));
        keepers.replaceKeepers(warehouseB, keepersOf(keeperAB));
    }

    @AfterEach void clear() {
        db.update("DELETE FROM warehouse_keepers WHERE warehouse_id IN (?,?,?) OR employee_id IN "
                        + "(SELECT employee_id FROM users WHERE id IN (?,?,?,?,?))",
                warehouseA, warehouseB, warehouseC, manager, mainKeeper, keeperA, keeperAB, member);
        db.update("UPDATE departments SET manager_id=? WHERE id=?", previousManager, warehouseDepartment);
        SecurityContextHolder.clearContext();
    }

    @Test void sevenIdentitiesResolveRoleAndDefaultScopeInOnePlace() {
        assertSupervisor(admin);
        assertSupervisor(manager);
        assertSupervisor(mainKeeper);
        assertThat(as(mainKeeper).keeperWarehouseIds()).contains(root);

        WarehouseAccess a = as(keeperA);
        assertThat(a.role()).isEqualTo(Role.KEEPER);
        assertThat(a.defaultScope().active()).isTrue();
        assertThat(a.defaultScope().includeUnassigned()).isFalse();
        assertThat(a.defaultScope().warehouseIds()).contains(warehouseA).doesNotContain(warehouseB, warehouseC, root);

        WarehouseAccess ab = as(keeperAB);
        assertThat(ab.role()).isEqualTo(Role.KEEPER);
        assertThat(ab.defaultScope().warehouseIds()).contains(warehouseA, warehouseB).doesNotContain(warehouseC);

        for (UUID other : List.of(member, outsider)) {
            WarehouseAccess o = as(other);
            assertThat(o.role()).isEqualTo(Role.OTHER);
            assertThat(o.defaultScope().active()).isTrue();
            assertThat(o.defaultScope().includeUnassigned()).isTrue();
            // 没有有效子仓负责人的仓 + 未定仓; 主仓上的登记是主管, 不算覆盖。
            assertThat(o.defaultScope().warehouseIds()).contains(warehouseC, root)
                    .doesNotContain(warehouseA, warehouseB);
        }
        assertThat(as(member).warehouseMember()).isTrue();
        assertThat(as(outsider).warehouseMember()).isFalse();
        assertThat(as(member).warehouseParticipant()).isTrue();
        assertThat(as(outsider).warehouseParticipant()).isFalse();

        // 全公司一个有效子仓负责人都没有: 其他人 = 全部(不限)。主仓上的登记仍在, 不影响这条。
        Object uncovered = new TransactionTemplate(transactions).execute(status -> {
            db.update("DELETE FROM warehouse_keepers WHERE warehouse_id <> ?", root);
            Object scope = db.queryForObject("SELECT scope_warehouse_ids FROM fn_user_warehouse_access(?)",
                    Object.class, member);
            status.setRollbackOnly();
            return scope;
        });
        assertThat(uncovered).isNull();
    }

    @Test void selectedWarehouseIsValidatedServerSideAndMyScopeListsOnlyWhatCanBeSelected() {
        fixture.loginAs(keeperA);
        assertForbidden(() -> scopes.current(warehouseB));
        assertForbidden(() -> stockDocs.list("OTHER_OUT", null, null, null, null, null, null, null, null, null,
                1, 20, null, null, warehouseB, null, false, false));
        assertForbidden(() -> badges.badges(warehouseB));
        MyWarehouseScope a = dataScope.myScope();
        assertThat(a.role()).isEqualTo("KEEPER");
        assertThat(a.canSelectAll()).isFalse();
        assertThat(a.selectable()).extracting(MyWarehouseScope.Option::id).containsExactly(warehouseA);
        assertThat(a.defaultWarehouseId()).isEqualTo(warehouseA);

        fixture.loginAs(keeperAB);
        assertThat(scopes.current(warehouseB).warehouseIds()).contains(warehouseB).doesNotContain(warehouseA);
        assertForbidden(() -> scopes.current(warehouseC));
        MyWarehouseScope ab = dataScope.myScope();
        assertThat(ab.selectable()).extracting(MyWarehouseScope.Option::id).containsExactlyInAnyOrder(warehouseA, warehouseB);
        assertThat(ab.defaultWarehouseId()).isNull();

        fixture.loginAs(member);
        assertForbidden(() -> scopes.current(warehouseC));
        assertThat(dataScope.myScope().selectable()).isEmpty();

        fixture.loginAs(manager);
        assertThat(scopes.current(warehouseC).warehouseIds()).containsExactly(warehouseC);
        assertThat(scopes.current(root).warehouseIds()).contains(root, warehouseA, warehouseB, warehouseC);
        assertForbidden(() -> scopes.current(UUID.randomUUID()));
        MyWarehouseScope supervisor = dataScope.myScope();
        assertThat(supervisor.role()).isEqualTo("SUPERVISOR");
        assertThat(supervisor.canSelectAll()).isTrue();
        assertThat(supervisor.selectable()).extracting(MyWarehouseScope.Option::id)
                .contains(root, warehouseA, warehouseB, warehouseC);
        // 先主仓后子仓。
        assertThat(supervisor.selectable().getFirst().parentId()).isNull();
    }

    @Test void everyWarehouseBadgeSourceEqualsTheListTotalOfTheSameIdentityAndScope() {
        fixture.loginAs(admin);
        UUID docA = otherOutDraft(warehouseA);
        UUID docB = otherOutDraft(warehouseB);
        UUID docC = otherOutDraft(warehouseC);

        fixture.loginAs(keeperA);
        assertThat(otherOutDrafts(null)).contains(docA).doesNotContain(docB, docC);
        fixture.loginAs(keeperAB);
        assertThat(otherOutDrafts(null)).contains(docA, docB).doesNotContain(docC);
        assertThat(otherOutDrafts(warehouseB)).contains(docB).doesNotContain(docA, docC);
        fixture.loginAs(member);
        assertThat(otherOutDrafts(null)).contains(docC).doesNotContain(docA, docB);
        fixture.loginAs(manager);
        assertThat(otherOutDrafts(null)).contains(docA, docB, docC);
        assertThat(otherOutDrafts(warehouseA)).contains(docA).doesNotContain(docB, docC);

        Map<UUID, List<UUID>> selections = new LinkedHashMap<>();
        selections.put(admin, Arrays.asList(null, warehouseA));
        selections.put(manager, Arrays.asList(null, warehouseC));
        selections.put(keeperA, Arrays.asList((UUID) null));
        selections.put(keeperAB, Arrays.asList(null, warehouseB));
        selections.put(member, Arrays.asList((UUID) null));
        for (var entry : selections.entrySet()) {
            fixture.loginAs(entry.getKey());
            for (UUID selected : entry.getValue()) assertBadgeEqualsLists(entry.getKey(), selected);
        }
    }

    /**
     * 建单不限仓: 子仓负责人顶班在范围外的仓建了草稿, 这张草稿不能从他自己的列表、草稿徽章和分段草稿数里消失
     * (本人默认范围里自己的草稿不论仓都算); 挑了某个仓就只看那个仓; 别人在范围外的草稿照样看不到。
     */
    @Test void ownDraftsStayWithTheirMakerInTheDefaultScopeOnly() {
        fixture.loginAs(admin);
        UUID ownOutside = otherOutDraft(warehouseC);
        db.update("UPDATE stock_documents SET maker_id=(SELECT employee_id FROM users WHERE id=?) WHERE id=?",
                keeperAB, ownOutside);
        fixture.loginAs(keeperAB);
        assertThat(otherOutDrafts(null)).contains(ownOutside);
        assertThat(otherOutDrafts(warehouseA)).doesNotContain(ownOutside);
        assertBadgeEqualsLists(keeperAB, null);
        assertBadgeEqualsLists(keeperAB, warehouseA);
        fixture.loginAs(keeperA);
        assertThat(otherOutDrafts(null)).doesNotContain(ownOutside);
        assertBadgeEqualsLists(keeperA, null);
    }

    @Test void noticeRecipientsFollowTheSameResponsibilityAsTheLists() {
        List<UUID> pool = List.of(keeperA, keeperAB, member, mainKeeper, manager);
        // 该仓链上的子仓负责人 ∩ 池。
        assertThat(router.recipients(pool, List.of(warehouseA))).containsExactly(keeperA, keeperAB);
        assertThat(router.recipients(pool, List.of(warehouseB))).containsExactly(keeperAB);
        // 没有子仓负责人(主仓上的登记不算) → 主管 ∩ 池。
        assertThat(router.recipients(pool, List.of(warehouseC))).containsExactlyInAnyOrder(mainKeeper, manager);
        // 未定仓的任务 → 主管 ∩ 池。
        assertThat(router.recipients(pool, List.of())).containsExactlyInAnyOrder(mainKeeper, manager);
        // 池里没有主管 → 整个池(还没配置, 不让任务掉进无人区)。
        assertThat(router.recipients(List.of(member), List.of(warehouseC))).containsExactly(member);
        // 负责人不在池里(缺权限) → 主管那一级, 不是整个池。
        assertThat(router.recipients(List.of(member, manager), List.of(warehouseA))).containsExactly(manager);
        // 超管几乎总在权限池里, 但不因超管身份算作「主管」那一级: 没有子仓负责人、也没有指定的主管
        // (仓储部门负责人 / 主仓负责人) 在池里时, 发整个池(还没配置, 仓库的人照样收到), 不是只发超管。
        assertThat(router.recipients(List.of(admin, member), List.of(warehouseC)))
                .containsExactlyInAnyOrder(admin, member);
        assertThat(router.recipients(List.of(admin, member), List.of())).containsExactlyInAnyOrder(admin, member);
        assertThat(router.recipients(List.of(admin, member, manager), List.of(warehouseC))).containsExactly(manager);
        // 通知池只按这张单涉及的仓纳入部门外的人: 这些仓的子仓负责人 + 指定的主管; 别的仓的负责人不进来。
        assertThat(router.pool(List.of(member), id -> true, List.of(warehouseA)))
                .contains(member, keeperA, keeperAB, mainKeeper, manager).doesNotContain(admin);
        assertThat(router.pool(List.of(member), id -> true, List.of(warehouseC)))
                .contains(member, mainKeeper, manager).doesNotContain(keeperA, keeperAB, admin);
        assertThat(router.pool(List.of(member), id -> false, List.of(warehouseA))).containsExactly(member);
        // 部门外登记的负责人是仓库任务的参与者(通知弹卡资格按仓储部门成员对待); 普通部门外的人不是。
        assertThat(db.queryForObject("SELECT CAST(? AS uuid) = ANY(fn_warehouse_responsible_user_ids())",
                Boolean.class, keeperA)).isTrue();
        assertThat(db.queryForObject("SELECT CAST(? AS uuid) = ANY(fn_warehouse_responsible_user_ids())",
                Boolean.class, outsider)).isFalse();
    }

    // ------------------------------------------------------------------ helpers

    private void assertBadgeEqualsLists(UUID user, UUID selected) {
        WorkbenchBadgeSummary summary = badges.badges(selected);
        String label = user + "@" + selected;
        assertThat(summary.staleSources()).as(label).isEmpty();
        Map<String, Long> facts = summary.facts();
        assertThat(facts.get("warehouseInboundExpectation.count")).as(label + " expectation").isEqualTo(
                inbound.expectations(1, 1, "", "", null, selected, null, null, null).getTotal());
        assertThat(facts.get("warehouseArrivalException.count")).as(label + " arrival exception").isEqualTo(
                inbound.arrivalExceptions(1, 1, null, false, null, null, null, selected, null, null, null, null).getTotal());
        assertThat(facts.get("finishedInbound.count")).as(label + " finished inbound").isEqualTo(
                finishedInbound.tasks("", null, null, 1, 1, selected, null, null, null, null).getTotal());
        assertThat(facts.get("warehouseSalesOutbound.PENDING_PICK")).as(label + " sales outbound").isEqualTo(
                salesOutbound.list(null, "PENDING_PICK", null, null, 1, 1, selected, null, null, null).getTotal());
        // ADR-143: 委外出库红数 = 待发料的领料草稿张数, 所在仓 = 草稿发出仓; 与待发料列表同一谓词。
        assertThat(facts.get("subcontractOutbound.count")).as(label + " subcontract outbound").isEqualTo(
                subcontractOutbound.tasks(1, 1, "", selected).getTotal());
        assertThat(facts.get("productionDraw.count")).as(label + " production draw").isEqualTo(
                fulfillment.warehouse("OPEN_ANY", "", "", null, null, 1, 1, "", "asc", selected, Map.of()).total());
        assertThat(facts.get("productionReturn.count")).as(label + " production return").isEqualTo(
                stockDocs.list(null, null, null, (short) 0, null, null, null, null, true, null, 1, 1, null, null,
                        selected, null, false, false).getTotal());
        assertThat(facts.get("workshopMaterial.pendingIssue")).as(label + " workshop issue").isEqualTo(
                requisitions.list("PENDING", "ISSUE", null, selected, 1, 1).getTotal());
        assertThat(facts.get("workshopMaterial.pendingReturn")).as(label + " workshop return").isEqualTo(
                requisitions.list("PENDING", "RETURN", null, selected, 1, 1).getTotal());
        assertThat(facts.get("stockCountWarehouse.count")).as(label + " stock count").isEqualTo(
                stockCounts.list("WAREHOUSE", "PENDING", null, selected, null, 1, 1).getTotal());
        // 品质检查结果: 红 + 黄 = 列表里没完结的张数; 每个状态段 = 带该状态筛选的列表 total。
        Map<String, Long> statuses = qualityResults.statusCounts("ALL", "", selected);
        long open = statuses.entrySet().stream().filter(e -> !"COMPLETED".equals(e.getKey()))
                .mapToLong(Map.Entry::getValue).sum();
        long typed = facts.entrySet().stream().filter(e -> e.getKey().startsWith("qualityResult."))
                .mapToLong(Map.Entry::getValue).sum();
        assertThat(typed).as(label + " quality result").isEqualTo(open);
        for (var status : statuses.entrySet()) {
            assertThat(qualityResults.list("", "ALL", status.getKey(), null, null, 1, 1, null, null, null, selected)
                    .getTotal()).as(label + " quality " + status.getKey()).isEqualTo(status.getValue());
        }
        // 仓库草稿红数 = 仓库单据列表「草稿」段(同一仓库范围)。
        assertThat(facts.get("drafts.stockDocument")).as(label + " stock drafts").isEqualTo(
                documentCounts.statusCounts("stockDocument", null, null, selected).get("DRAFT"));
        assertThat(documentCounts.statusCounts("stockDocument", null, "OTHER_OUT", selected).get("DRAFT"))
                .as(label + " other-out drafts").isEqualTo(stockDocs.list("OTHER_OUT", null, null, (short) 0, null,
                        null, null, null, null, null, 1, 1, null, null, selected, null, false, false).getTotal());
    }

    private List<UUID> otherOutDrafts(UUID selected) {
        List<UUID> ids = new ArrayList<>();
        for (var item : stockDocs.list("OTHER_OUT", null, null, (short) 0, null, null, null, null, null, null,
                1, 100, null, null, selected, null, false, false).getItems()) {
            ids.add(item.getId());
        }
        return ids;
    }

    private UUID otherOutDraft(UUID warehouse) {
        var request = new StockDocSaveRequest();
        request.setDocType("OTHER_OUT");
        request.setWarehouseId(warehouse);
        request.setBillDate(BusinessTime.today());
        var line = new StockDocItemLine();
        line.setGoodsId(world.goodsA());
        line.setUnitId(world.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(BigDecimal.ONE);
        request.setItems(List.of(line));
        return stock.create(request).getId();
    }

    private UUID warehouse(String name) {
        UUID id = UUID.randomUUID();
        db.update("INSERT INTO warehouses(id,code,name,status,is_accountable,parent_id) VALUES (?,?,?,'使用',true,?)",
                id, "SC-" + id.toString().substring(0, 8), name, root);
        return id;
    }

    private UUID warehouseUser(String tag) {
        UUID user = fixture.createUserWithPerms(world, tag, TASK_PERMISSIONS);
        db.update("UPDATE employees SET department_id=? WHERE id=(SELECT employee_id FROM users WHERE id=?)",
                warehouseDepartment, user);
        return user;
    }

    private WarehouseKeeperSaveRequest keepersOf(UUID... users) {
        List<UUID> employees = new ArrayList<>();
        for (UUID user : users) employees.add(db.queryForObject("SELECT employee_id FROM users WHERE id=?", UUID.class, user));
        return new WarehouseKeeperSaveRequest(employees);
    }

    private WarehouseAccess as(UUID user) {
        fixture.loginAs(user);
        return scopes.access();
    }

    private void assertSupervisor(UUID user) {
        WarehouseAccess access = as(user);
        assertThat(access.role()).as(user.toString()).isEqualTo(Role.SUPERVISOR);
        assertThat(access.defaultScope().active()).isFalse();
    }

    private static void assertForbidden(org.assertj.core.api.ThrowableAssert.ThrowingCallable call) {
        assertThatThrownBy(call).isInstanceOfSatisfying(ApiException.class, error -> {
            assertThat(error.getCode()).isEqualTo(ErrorCode.FORBIDDEN);
            assertThat(error.getMessage()).contains("所选仓库不在你负责的范围内");
        });
    }
}
