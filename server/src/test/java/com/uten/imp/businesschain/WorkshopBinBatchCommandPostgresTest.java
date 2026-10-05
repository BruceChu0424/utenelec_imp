package com.uten.imp.businesschain;

import com.uten.imp.common.web.ApiError;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.BatchDisableRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.BatchEnableRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.BinItem;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.SettingsView;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialSettingsService;
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

import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.stream.Collectors;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * ADR-147 车间内料仓批量开通/撤销命令(POST /settings/batch-enable、/batch-disable), 走真实服务与真实 PG,
 * 用只有设置权限的非超管账号:
 * <ul>
 *   <li>一次开通两个车间; 同键重放不多建仓, 同键不同内容 409;</li>
 *   <li>任一车间版本过期 -> 整批 409 并逐车间列原因, 什么都不写; 规则不满足 -> 整批 422, 什么都不写;</li>
 *   <li>改来源仓、恢复按货品所属仓库(来源仓置空)以后, 原来源仓不再被「发料来源仓」挡住停用;</li>
 *   <li>撤销开通 = 删开通行 + 软删内料仓; 再开通复用同一行(同 id、同编号, 过 V798 两层树守卫与 V800 同生共死断言);</li>
 *   <li>内料仓有引用(预留)时撤销被拒 422 并列出原因; 名字被占用时开通被拒。</li>
 * </ul>
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false", "uten.policy-intelligence.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!",
        "uten.workshop-material.auto-close.enabled=false"})
class WorkshopBinBatchCommandPostgresTest {

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired WorkshopMaterialSettingsService settings;

    private FullChainEndToEndTest fixture;
    private FullChainEndToEndTest.World world;
    private UUID first, second, setupUser, otherSource;
    private String tag;

    @BeforeEach
    void seed() {
        fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
        tag = UUID.randomUUID().toString().substring(0, 8);
        world = fixture.seedWorld("wm-batch-" + tag);
        UUID production = db.queryForObject("SELECT id FROM departments WHERE code = 'DEPT_PROD'", UUID.class);
        first = workshop(production, "A");
        second = workshop(production, "B");
        otherSource = UUID.randomUUID();
        db.update("INSERT INTO warehouses(id, code, name, status, is_accountable) VALUES (?, ?, ?, '使用', TRUE)",
                otherSource, "WMB-" + tag, "批量来源仓-" + tag);
        setupUser = fixture.createUserWithPerms(world, "wm-setup-" + tag, "notice:read",
                "workshop_material:view", "workshop_material:setup");
        fixture.loginAs(setupUser);
    }

    @AfterEach
    void logout() {
        SecurityContextHolder.clearContext();
    }

    @Test
    void batchOpenReplayStaleVersionRuleProblemsSourceClearRevokeAndRevive() {
        // 1. 一次开通两个车间(来源仓 = 测试世界的良品仓)。
        BatchEnableRequest open = new BatchEnableRequest(List.of(item(first, "NOT_OPEN", 0L), item(second, "NOT_OPEN", 0L)),
                world.warehouseId(), null, false, null, List.of(), key("open"));
        List<SettingsView> opened = settings.batchEnable(open).settings();
        assertThat(opened).extracting(SettingsView::status).containsExactly("OPEN", "OPEN");
        assertThat(opened).extracting(SettingsView::sourceWarehouseId).containsOnly(world.warehouseId());
        assertThat(bins()).hasSize(2);
        UUID secondBin = opened.get(1).binWarehouseId();
        String secondCode = opened.get(1).binWarehouseCode();

        // 2. 同键重放: 原结果, 不多建仓; 同键不同内容: 409。
        assertThat(settings.batchEnable(open).settings()).extracting(SettingsView::binWarehouseId)
                .containsExactly(opened.get(0).binWarehouseId(), secondBin);
        assertThat(bins()).hasSize(2);
        assertThat(db.queryForObject("SELECT count(*) FROM warehouses WHERE is_line_side AND workshop_department_id IN (?, ?)",
                Integer.class, first, second)).isEqualTo(2);
        assertThatThrownBy(() -> settings.batchEnable(new BatchEnableRequest(open.items(), otherSource, null, false,
                null, List.of(), open.idempotencyKey())))
                .isInstanceOfSatisfying(ApiException.class, error -> assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT));

        // 3. 一个车间版本过期: 整批 409, 逐车间说明, 另一个车间也不写。
        long v1 = version(first), v2 = version(second);
        assertThatThrownBy(() -> settings.batchEnable(new BatchEnableRequest(
                List.of(item(first, "OPEN", v1 + 5), item(second, "OPEN", v2)), otherSource, null, false, null,
                List.of(), key("stale"))))
                .isInstanceOfSatisfying(ApiException.class, error -> {
                    assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT);
                    assertThat(error.getFieldErrors()).extracting(ApiError.FieldError::field)
                            .containsExactly(first.toString());
                    assertThat(error.getMessage()).contains("已被别人改过");
                });
        assertThat(sources().values()).containsOnly(world.warehouseId());

        // 4. 规则不满足(一个车间没有要改的): 整批 422, 另一个车间的改来源仓也不写。
        assertThatThrownBy(() -> settings.batchEnable(new BatchEnableRequest(
                List.of(item(first, "OPEN", v1), item(second, "OPEN", v2)), world.warehouseId(), null, false, null,
                List.of(), key("noop"))))
                .isInstanceOfSatisfying(ApiException.class, error -> {
                    assertThat(error.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED);
                    assertThat(error.getFieldErrors()).hasSize(2);
                    assertThat(error.getMessage()).contains("没有要改的");
                });
        // 来源仓与「恢复按货品所属仓库」不能同时给。
        assertThatThrownBy(() -> settings.batchEnable(new BatchEnableRequest(List.of(item(first, "OPEN", v1)),
                otherSource, true, false, null, List.of(), key("both"))))
                .isInstanceOfSatisfying(ApiException.class,
                        error -> assertThat(error.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED));

        // 5. 改来源仓, 再恢复按货品所属仓库(来源仓置空): 原来源仓不再被「发料来源仓」挡住停用。
        List<SettingsView> moved = settings.batchEnable(new BatchEnableRequest(
                List.of(item(first, "OPEN", v1), item(second, "OPEN", v2)), otherSource, null, false, null,
                List.of(), key("move"))).settings();
        assertThat(moved).extracting(SettingsView::sourceWarehouseId).containsOnly(otherSource);
        assertThat(retirementBlockers(otherSource)).contains("个车间内料仓的发料来源仓");
        List<SettingsView> cleared = settings.batchEnable(new BatchEnableRequest(
                List.of(item(first, "OPEN", moved.get(0).rowVersion()), item(second, "OPEN", moved.get(1).rowVersion())),
                null, true, false, null, List.of(), key("clear"))).settings();
        assertThat(cleared).extracting(SettingsView::sourceWarehouseId).containsOnlyNulls();
        assertThat(cleared).extracting(SettingsView::status).containsOnly("OPEN");
        assertThat(retirementBlockers(otherSource)).doesNotContain("发料来源仓");
        // 已经是「按货品所属仓库」, 再恢复一次没有要改的。
        assertThatThrownBy(() -> settings.batchEnable(new BatchEnableRequest(
                List.of(item(first, "OPEN", cleared.get(0).rowVersion())), null, true, false, null, List.of(),
                key("clear-again"))))
                .isInstanceOfSatisfying(ApiException.class, error -> assertThat(error.getMessage()).contains("没有要改的"));

        // 6. 内料仓有引用(没结束的预留)时撤销被拒 422 并列出原因, 两个车间都不撤。
        UUID reservation = UUID.randomUUID();
        replica("INSERT INTO stock_reservations(order_item_id,owner_type,owner_id,purpose,goods_id,warehouse_id,qty) "
                + "VALUES ('" + reservation + "','SALES_ORDER_ITEM','" + reservation + "','SALES_FULFILLMENT','"
                + world.goodsA() + "','" + cleared.get(0).binWarehouseId() + "',1)");
        try {
            assertThatThrownBy(() -> settings.batchDisable(new BatchDisableRequest(List.of(
                    item(first, "OPEN", cleared.get(0).rowVersion()), item(second, "OPEN", cleared.get(1).rowVersion())),
                    key("revoke-used"))))
                    .isInstanceOfSatisfying(ApiException.class, error -> {
                        assertThat(error.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED);
                        assertThat(error.getMessage()).contains("内料仓已经在用, 不能撤销开通").contains("没结束的库存预留");
                        assertThat(error.getFieldErrors()).extracting(ApiError.FieldError::field)
                                .containsExactly(first.toString());
                    });
            assertThat(bins()).hasSize(2);
        } finally {
            replica("DELETE FROM stock_reservations WHERE order_item_id='" + reservation + "'");
        }

        // 7. 撤销第二个车间: 开通行删除, 内料仓软删; 再开通复用同一行(同 id、同编号、同一个上级仓)。
        UUID secondParent = db.queryForObject("SELECT parent_id FROM warehouses WHERE id = ?", UUID.class, secondBin);
        List<SettingsView> revoked = settings.batchDisable(new BatchDisableRequest(
                List.of(item(second, "OPEN", cleared.get(1).rowVersion())), key("revoke"))).settings();
        assertThat(revoked).extracting(SettingsView::status).containsExactly("NOT_OPEN");
        assertThat(bins()).containsOnlyKeys(first);
        assertThat(db.queryForObject("SELECT is_deleted FROM warehouses WHERE id = ?", Boolean.class, secondBin)).isTrue();
        List<SettingsView> revived = settings.batchEnable(new BatchEnableRequest(List.of(item(second, "NOT_OPEN", 0L)),
                world.warehouseId(), null, false, null, List.of(), key("revive"))).settings();
        assertThat(revived.getFirst().status()).isEqualTo("OPEN");
        assertThat(revived.getFirst().binWarehouseId()).isEqualTo(secondBin);
        assertThat(revived.getFirst().binWarehouseCode()).isEqualTo(secondCode);
        assertThat(db.queryForObject("SELECT is_deleted FROM warehouses WHERE id = ?", Boolean.class, secondBin)).isFalse();
        assertThat(db.queryForObject("SELECT parent_id FROM warehouses WHERE id = ?", UUID.class, secondBin))
                .isEqualTo(secondParent);
        assertThat(bins()).containsOnlyKeys(first, second);
    }

    @Test
    void nameTakenByAnotherWarehouseRefusesTheWholeBatch() {
        String name = db.queryForObject("SELECT name FROM departments WHERE id = ?", String.class, first) + "内料仓";
        db.update("INSERT INTO warehouses(id, code, name, status, is_accountable) VALUES (?, ?, ?, '使用', TRUE)",
                UUID.randomUUID(), "WMN-" + tag, name);
        assertThatThrownBy(() -> settings.batchEnable(new BatchEnableRequest(
                List.of(item(first, "NOT_OPEN", 0L), item(second, "NOT_OPEN", 0L)), world.warehouseId(), null, false,
                null, List.of(), key("name"))))
                .isInstanceOfSatisfying(ApiException.class, error -> {
                    assertThat(error.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED);
                    assertThat(error.getMessage()).contains("内料仓建不出来");
                    assertThat(error.getFieldErrors()).extracting(ApiError.FieldError::field)
                            .containsExactly(first.toString());
                });
        assertThat(bins()).isEmpty();
    }

    // ------------------------------------------------------------------ helpers

    private UUID workshop(UUID production, String suffix) {
        UUID id = UUID.randomUUID();
        db.update("INSERT INTO departments(id, code, name, parent_id, level) VALUES (?, ?, ?, ?, '二级班组')",
                id, "WMB-" + suffix + "-" + tag, "批量车间" + suffix + "-" + tag, production);
        return id;
    }

    private static BinItem item(UUID workshop, String status, Long version) {
        return new BinItem(workshop, status, version);
    }

    private String key(String step) {
        return "wm-batch-" + step + "-" + tag;
    }

    private long version(UUID workshop) {
        return db.queryForObject("SELECT row_version FROM workshop_bins WHERE workshop_department_id = ?", Long.class,
                workshop);
    }

    private Map<UUID, UUID> bins() {
        return db.queryForList("SELECT workshop_department_id, bin_warehouse_id FROM workshop_bins "
                        + "WHERE workshop_department_id IN (?, ?)", first, second).stream()
                .collect(Collectors.toMap(row -> (UUID) row.get("workshop_department_id"),
                        row -> (UUID) row.get("bin_warehouse_id")));
    }

    private Map<UUID, UUID> sources() {
        return db.queryForList("SELECT workshop_department_id, source_warehouse_id FROM workshop_bins "
                        + "WHERE workshop_department_id IN (?, ?)", first, second).stream()
                .collect(Collectors.toMap(row -> (UUID) row.get("workshop_department_id"),
                        row -> (UUID) row.get("source_warehouse_id")));
    }

    private String retirementBlockers(UUID warehouse) {
        return db.queryForObject("SELECT array_to_string(fn_warehouse_retirement_blockers(?), ';')", String.class,
                warehouse);
    }

    private void replica(String sql) {
        db.execute((org.springframework.jdbc.core.ConnectionCallback<Void>) connection -> {
            try (var statement = connection.createStatement()) {
                statement.execute("SET session_replication_role = replica");
                try {
                    statement.execute(sql);
                } finally {
                    statement.execute("SET session_replication_role = origin");
                }
            }
            return null;
        });
    }
}
