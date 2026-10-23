package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.admin.serveroperations.HostOperationsClient;
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
import com.uten.imp.features.stock.StockDocController;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.count.StockCountRequestController;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import com.uten.imp.features.warehouse.inbound.WarehouseInboundController;
import com.uten.imp.features.warehouse.inbound.WarehouseQualityResultController;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialRequisitionController;
import com.uten.imp.features.warehouse.taskcenter.WarehouseInboundTaskCenterController;
import com.uten.imp.features.warehouse.taskcenter.WarehouseOutboundTaskCenterController;
import com.uten.imp.features.workbench.badge.WorkbenchBadgeController;
import com.uten.imp.features.workbench.badge.WorkbenchBadgeSummary;
import com.uten.imp.security.ProductionStockTaskAccessPolicy;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.boot.webmvc.test.autoconfigure.MockMvcPrint;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Primary;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MockMvc;
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
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

/**
 * ADR-149 仓库数据范围服务端强制, 走真实服务与真实 PG(V804 fn_user_warehouse_access):
 * 七种身份的角色与默认范围; 越界选仓 403; 逐个仓库徽章来源「事实数 == 同身份同范围的列表 total」;
 * 通知收件人与列表同一套负责关系; 范围每次实时解析(不靠请求边界), 一次徽章汇总、一次只读请求只解析一次。
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
@AutoConfigureMockMvc(print = MockMvcPrint.NONE)
@Import({ProductionJdbcMeasurement.Configuration.class, WarehouseDataScopeEndToEndTest.HostBridgeFixture.class})
class WarehouseDataScopeEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    private static final String[] TASK_PERMISSIONS = {
            "notice:read", "stock_doc:view", "stock_doc:view:all", "warehouse_inbound:view",
            "warehouse_sales_outbound:view", "subcontract_outbound:view", "warehouse_iqc_stock_in:view",
            "workshop_material:view", "stock:count:warehouse_review", "stock_report:view",
            "stock_doc:create", "stock_doc:edit", "stock_doc:approve", "stock_doc:issue",
            "warehouse_inbound:stock_in", "warehouse_sales_outbound:execute", "subcontract_outbound:execute",
            "warehouse_iqc_stock_in:confirm", "warehouse_iqc_return:view", "procurement_iqc_rejection:record_return",
            "workshop_material:issue", "workshop_material:count"};

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired PlatformTransactionManager transactions;
    @Autowired WarehouseTaskScopePort scopes;
    @Autowired WarehouseDataScopeService dataScope;
    @Autowired WarehouseKeeperService keepers;
    @Autowired WarehouseNoticeRouter router;
    @Autowired ProductionStockTaskAccessPolicy productionTaskAccess;
    @Autowired WorkbenchBadgeController badges;
    @Autowired com.uten.imp.application.port.TaskAudiencePort taskAudience;
    @Autowired StockDocController stockDocs;
    @Autowired StockDocService stock;
    @Autowired WarehouseInboundController inbound;
    @Autowired WarehouseInboundTaskCenterController inboundCenter;
    @Autowired WarehouseOutboundTaskCenterController outboundCenter;
    @Autowired WarehouseQualityResultController qualityResults;
    @Autowired WorkshopMaterialRequisitionController requisitions;
    @Autowired StockCountRequestController stockCounts;
    @Autowired DocumentDraftCountController documentCounts;
    @Autowired MockMvc http;
    @Autowired ObjectMapper json;

    /** Keep this warehouse-scope fixture independent of an installed root daemon.
     * The real status controller and its permissions still execute; only the host
     * RPC boundary supplies a healthy, manually managed host with no update.
     * Production unavailable/stale behavior is covered by the dedicated operations tests.
     */
    @TestConfiguration(proxyBeanMethods = false)
    static class HostBridgeFixture {
        @Bean
        @Primary
        HostOperationsClient warehouseScopeHostOperations(ObjectMapper mapper) {
            return (operation, payload, actorId, requestId) -> {
                if (operation != HostOperationsClient.Operation.STATUS || !payload.isEmpty()) {
                    throw new AssertionError("Warehouse scope must only read local host status");
                }
                return mapper.createObjectNode()
                        .put("available", true).put("manualOnly", true)
                        .put("timerActive", false).put("timerEnabled", false)
                        .put("currentVersion", "v2.5.18").put("sourceRevision", "0".repeat(64))
                        .put("sourceConfigured", true).put("updateAvailable", false)
                        .put("serverTimeZone", "UTC")
                        .put("serverTime", java.time.OffsetDateTime.now(java.time.ZoneOffset.UTC).toString());
            };
        }
    }

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
        for (String permission : TASK_PERMISSIONS) {
            db.update("""
                    INSERT INTO user_permission_overrides(user_id, permission_id, effect)
                    SELECT ?, id, 'grant' FROM permissions WHERE code=?
                    ON CONFLICT (user_id, permission_id) DO UPDATE SET effect='grant', active=TRUE
                    """, admin, permission);
        }
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
        ProductionJdbcMeasurement.end();
        db.update("DELETE FROM warehouse_keepers WHERE warehouse_id IN (?,?,?) OR employee_id IN "
                        + "(SELECT employee_id FROM users WHERE id IN (?,?,?,?,?,?))",
                warehouseA, warehouseB, warehouseC, manager, mainKeeper, keeperA, keeperAB, member, admin);
        db.update("UPDATE departments SET manager_id=? WHERE id=?", previousManager, warehouseDepartment);
        SecurityContextHolder.clearContext();
    }

    @Test void administratorTasksUseRegisteredPhysicalResponsibilityWhileBrowsingRemainsAdministrative() {
        fixture.loginAs(admin);
        assertThat(scopes.access().role()).isEqualTo(Role.SUPERVISOR);
        assertThat(taskAudience.read(scopes::access).role()).isEqualTo(Role.OTHER);
        keepers.replaceKeepers(warehouseA, keepersOf(keeperA, keeperAB, admin));
        WarehouseAccess tasks = taskAudience.read(scopes::access);
        assertThat(tasks.role()).isEqualTo(Role.KEEPER);
        assertThat(tasks.defaultScope().warehouseIds()).contains(warehouseA).doesNotContain(warehouseB);
        assertThat(scopes.access().role()).isEqualTo(Role.SUPERVISOR);
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
                1, 20, null, null, warehouseB, null, false, false, null, "ACTIVE"));
        assertForbidden(() -> badges.badges(warehouseB));
        MyWarehouseScope a = dataScope.myScope();
        assertThat(a.role()).isEqualTo("KEEPER");
        assertThat(a.warehouseParticipant()).isTrue();
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
        assertThat(scopes.current(warehouseC).warehouseIds()).containsExactly(warehouseC);
        assertThat(dataScope.myScope().selectable()).extracting(MyWarehouseScope.Option::id)
                .contains(root, warehouseC).doesNotContain(warehouseA, warehouseB);
        assertThat(dataScope.myScope().canSelectAll()).isFalse();
        assertThat(scopes.current(root).warehouseIds()).contains(root, warehouseC)
                .doesNotContain(warehouseA, warehouseB);
        assertForbidden(() -> scopes.current(warehouseA));
        assertThat(dataScope.myScope().role()).isEqualTo("OTHER");
        assertThat(dataScope.myScope().warehouseParticipant()).isTrue();

        fixture.loginAs(outsider);
        assertThat(dataScope.myScope().role()).isEqualTo("OTHER");
        assertThat(dataScope.myScope().warehouseParticipant()).isFalse();
        assertThat(scopes.current(warehouseC).warehouseIds()).containsExactly(warehouseC);
        assertForbidden(() -> scopes.current(warehouseA));

        fixture.loginAs(manager);
        assertThat(scopes.current(warehouseC).warehouseIds()).containsExactly(warehouseC);
        assertThat(scopes.current(root).warehouseIds()).contains(root, warehouseA, warehouseB, warehouseC);
        assertForbidden(() -> scopes.current(UUID.randomUUID()));
        MyWarehouseScope supervisor = dataScope.myScope();
        assertThat(supervisor.role()).isEqualTo("SUPERVISOR");
        assertThat(supervisor.warehouseParticipant()).isTrue();
        assertThat(supervisor.canSelectAll()).isTrue();
        assertThat(supervisor.selectable()).extracting(MyWarehouseScope.Option::id)
                .contains(root, warehouseA, warehouseB, warehouseC);
        // 先主仓后子仓。
        assertThat(supervisor.selectable().getFirst().parentId()).isNull();
    }

    @Test void everyWarehouseBadgeSourceEqualsTheListTotalOfTheSameIdentityAndScope() {
        fixture.loginAs(admin);
        // This comparison intentionally covers a real full-scope task operator.
        keepers.replaceKeepers(root, keepersOf(mainKeeper, admin));
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
        selections.put(member, Arrays.asList(null, warehouseC, root));
        for (var entry : selections.entrySet()) {
            fixture.loginAs(entry.getKey());
            for (UUID selected : entry.getValue()) assertBadgeEqualsLists(entry.getKey(), selected);
        }
    }

    @Test void repeatedPurchaseLinesKeepTheirPhysicalIdentityAndWarehouseInBadgeLists() {
        var source = mixedWarehousePurchase();
        String billNo = source.billNo();
        fixture.loginAs(keeperA);
        var visible = inboundCenter.list("PURCHASE", "ACTIVE", "", "", billNo, null, null,
                warehouseA, null, null, 1, 100);
        assertThat(visible.total()).isEqualTo(2);
        assertThat(visible.items()).extracting(row -> row.line().goodsCode()).containsOnly(
                db.queryForObject("SELECT code FROM goods WHERE id=?", String.class, world.goodsD()));
        assertThat(visible.items()).extracting(row -> row.line().itemId()).doesNotHaveDuplicates();
        assertForbidden(() -> inboundCenter.list("PURCHASE", "ACTIVE", "", "", billNo, null, null,
                warehouseB, null, null, 1, 100));
        assertBadgeEqualsLists(keeperA, warehouseA);
        fixture.loginAs(keeperAB);
        assertThat(inboundCenter.list("PURCHASE", "ACTIVE", "", "", billNo, null, null,
                null, null, null, 1, 100).total()).isEqualTo(3);
        assertThat(inbound.expectations(1, 100, "PURCHASE", "", null, null, null, null, billNo).getTotal())
                .as("the legacy registration source remains one header, not the task-center grain").isEqualTo(1);
        assertBadgeEqualsLists(keeperAB, null);
        fixture.loginAs(member);
        assertThat(inboundCenter.list("PURCHASE", "ACTIVE", "", "", billNo, null, null,
                null, null, null, 1, 100).total()).isZero();
        assertBadgeEqualsLists(member, null);
    }

    @Test void readableManualDrawNeverInflatesTheActionableProductionBadge() {
        fixture.loginAs(admin);
        keepers.replaceKeepers(root, keepersOf(mainKeeper, admin));
        var request = new StockDocSaveRequest();
        request.setDocType("DRAW");
        request.setWarehouseId(warehouseA);
        request.setBillDate(BusinessTime.today());
        var line = new StockDocItemLine();
        line.setGoodsId(world.goodsA());
        line.setUnitId(world.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(BigDecimal.ONE);
        request.setItems(List.of(line));
        var manual = stock.create(request);

        var visible = outboundCenter.list("DRAW", "ACTIVE", "DRAW_PENDING", "", manual.getBillNo(),
                null, null, warehouseA, 1, 100, null, null);
        assertThat(visible.items()).singleElement().satisfies(row -> {
            assertThat(row.id()).isEqualTo(manual.getId());
            assertThat(row.canHandle()).isFalse();
        });
        assertThat(badges.badges(warehouseA).facts().get("productionDraw.count")).isZero();
        assertBadgeEqualsLists(admin, warehouseA);
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

    /**
     * 授权与范围判断不靠请求边界: 整个测试方法是同一个 MOCK 请求, 中途撤掉负责登记、调离仓储部门,
     * 下一次判定立即按新组织算。每个不同责任范围仅解析一次；2026-10-18 ADR-184 修订后
     * 徽章只用浏览准入一个范围(fn_user_warehouse_access(user,false)), 不再为业务任务单解析任务范围。
     */
    @Test void organizationChangesApplyImmediatelyWhileOneBadgeSummaryResolvesTheScopeOnce() {
        fixture.loginAs(keeperA);
        assertThat(scopes.access().role()).isEqualTo(Role.KEEPER);
        assertThat(scopes.current(null).warehouseIds()).contains(warehouseA);
        db.update("DELETE FROM warehouse_keepers WHERE warehouse_id=? AND employee_id=(SELECT employee_id FROM users WHERE id=?)",
                warehouseA, keeperA);
        assertThat(scopes.access().role()).isEqualTo(Role.OTHER);
        assertThat(scopes.current(null).warehouseIds()).doesNotContain(warehouseA);

        fixture.loginAs(member);
        assertThat(productionTaskAccess.canAccessWarehouseTasks()).isTrue();
        db.update("UPDATE employees SET department_id=? WHERE id=(SELECT employee_id FROM users WHERE id=?)",
                world.departmentId(), member);
        assertThat(productionTaskAccess.canAccessWarehouseTasks()).isFalse();

        fixture.loginAs(keeperAB);
        assertThat(scopeResolutions(() -> badges.badges(null))).isEqualTo(1);
        assertThat(scopeResolutions(() -> badges.badges(warehouseB))).as("徽章只解析选仓浏览准入一个范围").isEqualTo(1);
        fixture.loginAs(manager);
        assertThat(scopeResolutions(() -> badges.badges(null))).isEqualTo(1);
        assertThat(scopeResolutions(() -> badges.badges(warehouseC))).as("徽章只解析选仓浏览准入一个范围").isEqualTo(1);
        // 汇总结束窗口即关: 之后的判定照样实时。
        db.update("UPDATE departments SET manager_id=? WHERE id=?", previousManager, warehouseDepartment);
        assertThat(scopes.access().role()).isNotEqualTo(Role.SUPERVISOR);
    }

    /**
     * 只读请求整请求一个范围快照(ADR-149 §2.1): 非超管经真实过滤链 GET 仓库单据列表——控制器解析默认范围、
     * 列表谓词再判一次仓库任务参与者——一次请求只调一次 fn_user_warehouse_access。
     */
    @Test void aReadRequestThroughTheFilterChainResolvesTheScopeOnce() {
        fixture.loginAs(admin);
        UUID docA = otherOutDraft(warehouseA);
        UUID docC = otherOutDraft(warehouseC);
        for (UUID user : List.of(keeperA, member)) {
            fixture.loginAs(user);
            var actor = SecurityContextHolder.getContext().getAuthentication();
            String[] body = new String[1];
            long resolutions = scopeResolutions(() -> {
                try {
                    var response = http.perform(get("/api/stock/docs").param("docType", "OTHER_OUT")
                            .param("status", "0").param("size", "100").with(authentication(actor)))
                            .andReturn().getResponse();
                    assertThat(response.getStatus()).as(response.getContentAsString()).isEqualTo(200);
                    body[0] = response.getContentAsString();
                } catch (Exception failure) {
                    throw new IllegalStateException(failure);
                }
            });
            assertThat(resolutions).as(user.toString()).isEqualTo(1);
            // 同一请求里的范围仍是本人的: 子仓负责人只看自己的仓, 其他人只看没人负责的仓。
            UUID visible = user.equals(keeperA) ? docA : docC;
            UUID hidden = user.equals(keeperA) ? docC : docA;
            assertThat(body[0]).contains(visible.toString()).doesNotContain(hidden.toString());
        }
    }

    // ------------------------------------------------------------------ helpers

    /** 一段操作里 Java 侧调了几次 fn_user_warehouse_access。 */
    private static long scopeResolutions(Runnable work) {
        ProductionJdbcMeasurement.Sample sample = ProductionJdbcMeasurement.begin();
        try {
            work.run();
        } finally {
            ProductionJdbcMeasurement.end();
        }
        return sample.labelsByFingerprint.entrySet().stream()
                .filter(label -> "warehouse.scope_access".equals(label.getValue()))
                .mapToLong(label -> sample.fingerprints.getOrDefault(label.getKey(), 0L))
                .sum();
    }

    private void assertBadgeEqualsLists(UUID user, UUID selected) {
        taskAudience.read(() -> {
            assertTaskBadgeEqualsLists(user, selected);
            return null;
        });
    }

    private void assertTaskBadgeEqualsLists(UUID user, UUID selected) {
        WorkbenchBadgeSummary summary = badges.badges(selected);
        String label = user + "@" + selected;
        assertThat(summary.staleSources()).as(label).isEmpty();
        Map<String, Long> facts = summary.facts();
        assertThat(facts.get("warehouseInboundExpectation.count")).as(label + " expectation").isEqualTo(
                inboundTaskTotal(selected, "PURCHASE", "PURCHASE_READY_REGISTER", "PURCHASE_BLOCKED",
                        "PURCHASE_CONTINUE_INSPECTION", "PURCHASE_EXCESS_PENDING_FINANCE")
                        + inboundTaskTotal(selected, "SUBCONTRACT", "SUBCONTRACT_READY_REGISTER", "SUBCONTRACT_BLOCKED",
                        "SUBCONTRACT_CONTINUE_INSPECTION", "SUBCONTRACT_EXCESS_PENDING_FINANCE"));
        assertThat(facts.get("warehouseArrivalException.count")).as(label + " arrival exception").isEqualTo(
                inbound.arrivalExceptions(1, 1, null, false, null, null, null, selected, null, null, null, null).getTotal());
        assertThat(facts.get("finishedInbound.count")).as(label + " finished inbound").isEqualTo(
                inboundTaskTotal(selected, "FINISHED", "FINISHED_READY_REGISTER", "FINISHED_READY_COUNT", "FINISHED_RESIDUAL_COUNT"));
        assertThat(facts.get("warehouseSalesOutbound.PENDING_PICK")).as(label + " sales outbound").isEqualTo(
                outboundTaskTotal(selected, "SALES", "SALES_PENDING"));
        // The task center and its badges count physical items, retaining each item's warehouse.
        assertThat(facts.get("subcontractOutbound.count")).as(label + " subcontract outbound").isEqualTo(
                outboundTaskTotal(selected, "SUBCONTRACT", "SUBCONTRACT_PENDING"));
        assertThat(facts.get("productionDraw.count")).as(label + " production draw").isEqualTo(
                actionableProductionDrawTotal(selected));
        assertThat(facts.get("productionReturn.count")).as(label + " production return").isEqualTo(
                inboundTaskTotal(selected, "RETURN", "RETURN_PENDING_RECEIVE"));
        assertThat(facts.get("workshopMaterial.pendingIssue")).as(label + " workshop issue").isEqualTo(
                requisitions.list("PENDING", "ACTIVE", "ISSUE", null, selected, 1, 1, null).getTotal());
        assertThat(facts.get("workshopMaterial.pendingReturn")).as(label + " workshop return").isEqualTo(
                requisitions.list("PENDING", "ACTIVE", "RETURN", null, selected, 1, 1, null).getTotal());
        assertThat(facts.get("stockCountWarehouse.count")).as(label + " stock count").isEqualTo(
                stockCounts.list("WAREHOUSE", "PENDING", null, selected, null, 1, 1).getTotal());
        // 品质检查结果: 红 + 黄 = 列表里没完结的张数; 每个状态段 = 带该状态筛选的列表 total。
        Map<String, Long> statuses = qualityResults.statusCounts("ALL", "", selected);
        long open = statuses.entrySet().stream().filter(e -> !e.getKey().startsWith("TASK_") && !"COMPLETED".equals(e.getKey()))
                .mapToLong(Map.Entry::getValue).sum();
        long typed = facts.entrySet().stream().filter(e -> e.getKey().startsWith("qualityResult."))
                .mapToLong(Map.Entry::getValue).sum();
        assertThat(typed).as(label + " quality result").isEqualTo(open);
        for (var status : statuses.entrySet()) {
            if (status.getKey().startsWith("TASK_")) continue;
            assertThat(qualityResults.list("", "ALL", status.getKey(), "COMPLETED".equals(status.getKey()) ? "HISTORY" : "ACTIVE",
                    null, null, 1, 1, null, null, null, selected)
                    .getTotal()).as(label + " quality " + status.getKey()).isEqualTo(status.getValue());
        }
        // 仓库草稿红数 = 仓库单据列表「草稿」段(同一仓库范围)。
        assertThat(facts.get("drafts.stockDocument")).as(label + " stock drafts").isEqualTo(
                documentCounts.statusCounts("stockDocument", null, null, selected).get("DRAFT"));
        assertThat(documentCounts.statusCounts("stockDocument", null, "OTHER_OUT", selected).get("DRAFT"))
                .as(label + " other-out drafts").isEqualTo(stockDocs.list("OTHER_OUT", null, null, (short) 0, null,
                        null, null, null, null, null, 1, 1, null, null, selected, null, false, false, null, "ACTIVE").getTotal());
    }

    private long inboundTaskTotal(UUID selected, String source, String... statuses) {
        long total = 0;
        for (String status : statuses) {
            total += inboundCenter.list(source, "ACTIVE", status, "", null, null, null,
                    selected, null, null, 1, 1).total();
        }
        return total;
    }

    private long outboundTaskTotal(UUID selected, String source, String... statuses) {
        long total = 0;
        for (String status : statuses) {
            total += outboundCenter.list(source, "ACTIVE", status, "", null, null, null,
                    selected, 1, 1, null, null).total();
        }
        return total;
    }

    /** Browsable manual/stale DRAW rows retain their status without becoming warehouse tasks. */
    private long actionableProductionDrawTotal(UUID selected) {
        long total = 0;
        for (String status : List.of("DRAW_PENDING", "DRAW_PARTIAL", "DRAW_DISCOVERY_PENDING")) {
            int page = 1;
            com.uten.imp.features.warehouse.taskcenter.WarehouseTaskCenterContracts.Page rows;
            do {
                rows = outboundCenter.list("DRAW", "ACTIVE", status, "", null, null, null,
                        selected, page++, 100, null, null);
                total += rows.items().stream().filter(row -> row.canHandle()).count();
            } while (page <= rows.totalPages());
        }
        return total;
    }

    private List<UUID> otherOutDrafts(UUID selected) {
        List<UUID> ids = new ArrayList<>();
        for (var item : stockDocs.list("OTHER_OUT", null, null, (short) 0, null, null, null, null, null, null,
                1, 100, null, null, selected, null, false, false, null, "ACTIVE").getItems()) {
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
            assertThat(error.getMessage()).contains("所选仓库不在你可见的范围内");
        });
    }
    @Test void exactBusinessSelectionPreservesCrossWarehousePermissionsAndRejectsIncompleteSources() throws Exception {
        var source = mixedWarehousePurchase();
        fixture.loginAs(keeperA);
        assertThat(scopes.current(null).warehouseIds()).contains(warehouseA).doesNotContain(warehouseB);
        assertThat(inboundCenter.list("PURCHASE", "ACTIVE", "", "", source.billNo(), null, null,
                null, null, null, 1, 100).total()).isEqualTo(2);
        var auth = SecurityContextHolder.getContext().getAuthentication();
        // Task subscription scope is not commercial-document authority (ADR-149/151).
        var selected = http.perform(get("/api/warehouse/inbound/expectations/by-ids")
                .param("ids", source.expectation().toString()).param("itemIds", source.itemIds().getLast().toString())
                .with(authentication(auth))).andReturn().getResponse();
        assertThat(selected.getStatus()).isEqualTo(200);
        var selectedBody = json.readTree(selected.getContentAsString()).get(0);
        assertThat(selectedBody.get("items").size()).isEqualTo(1);
        assertThat(selectedBody.get("items").get(0).get("id").asText()).isEqualTo(source.itemIds().getLast().toString());
        assertThat(selectedBody.get("remainingQty").decimalValue()).isEqualByComparingTo("10");
        var repeatedGoods = http.perform(get("/api/warehouse/inbound/expectations/by-ids")
                .param("ids", source.expectation().toString()).param("itemIds", source.itemIds().get(1).toString())
                .with(authentication(auth))).andReturn().getResponse();
        assertThat(repeatedGoods.getStatus()).isEqualTo(200);
        var repeatedBody = json.readTree(repeatedGoods.getContentAsString()).get(0);
        assertThat(repeatedBody.get("items").size()).isEqualTo(1);
        assertThat(repeatedBody.get("items").get(0).get("orderItemId").asText()).isEqualTo(source.orderItems().get(1).toString());
        assertThat(http.perform(get("/api/warehouse/inbound/expectations/by-ids")
                .param("ids", "").with(authentication(auth))).andReturn().getResponse().getStatus()).isEqualTo(422);
        assertThat(http.perform(get("/api/warehouse/inbound/expectations/by-ids")
                .param("ids", source.expectation().toString(), UUID.randomUUID().toString())
                .param("itemIds", source.itemIds().getLast().toString()).with(authentication(auth)))
                .andReturn().getResponse().getStatus()).isEqualTo(409);
        assertThat(http.perform(get("/api/warehouse/inbound/expectations/by-ids")
                .param("ids", source.expectation().toString()).param("itemIds", "")
                .with(authentication(auth))).andReturn().getResponse().getStatus()).isEqualTo(422);
        assertThat(http.perform(get("/api/warehouse/inbound/expectations/by-ids")
                .param("ids", source.expectation().toString()).param("itemIds", UUID.randomUUID().toString())
                .with(authentication(auth))).andReturn().getResponse().getStatus()).isEqualTo(409);
        var legacy = http.perform(get("/api/warehouse/inbound/expectations/by-ids")
                .param("ids", source.expectation().toString()).with(authentication(auth)))
                .andReturn().getResponse();
        assertThat(legacy.getStatus()).isEqualTo(200);
        assertThat(json.readTree(legacy.getContentAsString()).get(0).get("items").size()).isEqualTo(3);
    }

    @Test void crossWarehouseRegistrationRetainsBusinessOwnerAndActionPermissionOnReplay() {
        var source = mixedWarehousePurchase();
        new TransactionTemplate(transactions).executeWithoutResult(status -> {
            try {
                fixture.loginAs(keeperA);
                var auth = SecurityContextHolder.getContext().getAuthentication();
                assertThat(scopes.current(null).warehouseIds()).doesNotContain(warehouseB);
                String key = "business-cross-warehouse-" + UUID.randomUUID();
                Map<String, Object> line = Map.of("orderType", "PURCHASE", "warehouseId", warehouseB,
                        "goodsId", source.hiddenGoods(), "qty", BigDecimal.ONE, "orderItemId", source.orderItems().getLast(),
                        "unitId", world.unitId(), "unitRate", BigDecimal.ONE);
                byte[] request = json.writeValueAsBytes(Map.of("idempotencyKey", key,
                        "billDate", BusinessTime.today().toString(), "receiverEmployeeId",
                        ((com.uten.imp.security.AuthUser) auth.getPrincipal()).getEmployeeId(), "lines", List.of(line)));
                var first = postBusinessArrival(request, auth);
                assertThat(first.getStatus()).isEqualTo(200);
                var result = json.readTree(first.getContentAsString());
                assertThat(result.get("items").size()).isEqualTo(1);
                UUID receipt = UUID.fromString(result.get("items").get(0).get("receiptId").asText());
                assertThat(db.queryForObject("SELECT count(*) FROM purchase_receipt_items WHERE receipt_id=? AND NOT is_deleted",
                        Integer.class, receipt)).isEqualTo(1);
                assertThat(db.queryForObject("SELECT order_item_id FROM purchase_receipt_items WHERE receipt_id=? AND NOT is_deleted",
                        UUID.class, receipt)).isEqualTo(source.orderItems().getLast());
                var replay = postBusinessArrival(request, auth);
                assertThat(replay.getStatus()).isEqualTo(200);
                assertThat(json.readTree(replay.getContentAsString()).get("replay").booleanValue()).isTrue();
                fixture.loginAs(keeperAB);
                assertThatThrownBy(() -> beans.getBean(com.uten.imp.features.purchase.receipt.PurchaseReceiptService.class)
                        .approveFromWarehouseDecision(receipt)).isInstanceOfSatisfying(ApiException.class, error -> {
                    assertThat(error.getCode()).isEqualTo(ErrorCode.FORBIDDEN);
                    assertThat(error.getMessage()).contains("只能操作本人负责的采购收货单");
                });
                // Removing an action permission must still deny even an otherwise valid cached result.
                db.update("UPDATE user_permission_overrides SET effect='revoke',active=TRUE WHERE user_id=? "
                        + "AND permission_id=(SELECT id FROM permissions WHERE code='warehouse_inbound:stock_in')", keeperA);
                fixture.loginAs(keeperA);
                var revoked = SecurityContextHolder.getContext().getAuthentication();
                assertThat(revoked.getAuthorities()).extracting(org.springframework.security.core.GrantedAuthority::getAuthority)
                        .contains("warehouse_inbound:view").doesNotContain("warehouse_inbound:stock_in");
                assertThat(postBusinessArrival(request, revoked).getStatus()).isEqualTo(403);
                assertThat(db.queryForObject("SELECT received_qty FROM purchase_order_items WHERE id=?", BigDecimal.class,
                        source.orderItems().getLast())).isEqualByComparingTo("1");
            } catch (Exception error) {
                throw new IllegalStateException(error);
            } finally { status.setRollbackOnly(); }
        });
    }

    private org.springframework.mock.web.MockHttpServletResponse postBusinessArrival(
            byte[] request, org.springframework.security.core.Authentication auth) throws Exception {
        return http.perform(post("/api/warehouse/inbound/arrivals/batch").with(authentication(auth))
                .with(org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf().asHeader())
                .contentType(org.springframework.http.MediaType.APPLICATION_JSON).content(request)).andReturn().getResponse();
    }

    private MixedWarehousePurchase mixedWarehousePurchase() {
        fixture.loginAs(admin);
        UUID reviewer = org.springframework.test.util.ReflectionTestUtils.invokeMethod(fixture, "createApprover", world);
        UUID settlement = org.springframework.test.util.ReflectionTestUtils.invokeMethod(fixture, "activeSettlementMethodId");
        UUID hiddenGoods = UUID.randomUUID();
        fixture.insertGoods(hiddenGoods, "SCOPE-LINE-" + hiddenGoods, "Outside purchase line", "采购",
                world.unitId(), world.unitLegacy());
        db.update("UPDATE goods SET owning_warehouse_id=? WHERE id=?", warehouseA, world.goodsD());
        db.update("UPDATE goods SET owning_warehouse_id=? WHERE id=?", warehouseB, hiddenGoods);
        var order = new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        order.setBillDate(BusinessTime.today());
        order.setSupplierId(world.supplierId());
        order.setCurrencyId(world.currencyId());
        order.setExchangeRate(BigDecimal.ONE);
        order.setTaxRate(BigDecimal.ZERO);
        order.setSettlementMethodId(settlement);
        var lines = new ArrayList<com.uten.imp.features.purchase.order.dto.OrderItemLine>();
        for (UUID goods : List.of(world.goodsD(), world.goodsD(), hiddenGoods)) {
            var line = new com.uten.imp.features.purchase.order.dto.OrderItemLine();
            line.setGoodsId(goods);
            line.setUnitId(world.unitId());
            line.setUnitRate(BigDecimal.ONE);
            line.setQty(BigDecimal.TEN);
            line.setPrice(BigDecimal.ONE);
            lines.add(line);
        }
        order.setItems(lines);
        var created = beans.getBean(com.uten.imp.features.purchase.order.PurchaseOrderService.class).createBatch(order);
        assertThat(created).hasSize(1);
        UUID orderId = created.getFirst().getId();
        beans.getBean(com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService.class)
                .submit("PURCHASE", orderId);
        fixture.loginAs(reviewer);
        fixture.approvePendingFinance("PURCHASE", orderId);
        String billNo = db.queryForObject("SELECT bill_no FROM purchase_orders WHERE id=?", String.class, orderId);
        UUID expectation = db.queryForObject("SELECT id FROM inbound_expectations WHERE order_type='PURCHASE' AND order_id=?", UUID.class, orderId);
        List<UUID> itemIds = db.queryForList("SELECT id FROM inbound_expectation_items WHERE expectation_id=? ORDER BY line_no", UUID.class, expectation);
        List<UUID> orderItems = db.queryForList("SELECT order_item_id FROM inbound_expectation_items WHERE expectation_id=? ORDER BY line_no", UUID.class, expectation);
        return new MixedWarehousePurchase(expectation, billNo, hiddenGoods, itemIds, orderItems, reviewer);
    }

    private record MixedWarehousePurchase(UUID expectation, String billNo, UUID hiddenGoods,
                                          List<UUID> itemIds, List<UUID> orderItems, UUID reviewer) {}


}
