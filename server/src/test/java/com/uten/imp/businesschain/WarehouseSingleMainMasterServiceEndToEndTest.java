package com.uten.imp.businesschain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.dto.MasterStatusChangeRequest;
import com.uten.imp.features.master.lifecycle.MasterEntityKind;
import com.uten.imp.features.master.lifecycle.MasterLifecycleService;
import com.uten.imp.features.master.lifecycle.dto.MasterBatchRequests;
import com.uten.imp.features.master.warehouse.WarehouseService;
import com.uten.imp.features.master.warehouse.dto.WarehouseDetail;
import com.uten.imp.features.master.warehouse.dto.WarehouseListItem;
import com.uten.imp.features.master.warehouse.dto.WarehouseSaveRequest;
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
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * ADR-145 仓库主档单主仓, 走真实服务与真实 PG(V798 守卫):
 * 新建默认挂主仓、只能挂主仓、规范化重名被拒、仓库资料不能建内料仓;
 * 停用前置条件在单条启停、编辑表单改状态、批量启停三条路径上逐条列出原因;
 * 字典每行的 selectableForNew/defective 就是数据库函数的结果; 有归属的仓不能改成不良品仓。
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
class WarehouseSingleMainMasterServiceEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired WarehouseService warehouses;
    @Autowired MasterLifecycleService lifecycle;
    private FullChainEndToEndTest fixture;
    private FullChainEndToEndTest.World world;
    private UUID root;

    @BeforeEach void seed() {
        fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
        world = fixture.seedWorld("wh-master-" + UUID.randomUUID());
        fixture.loginAs(world.superAdminUserId());
        // 共用测试库里有很多夹具顶层仓; 唯一主仓按编号 001 判定(与 fn_warehouse_root_id 同口径)。
        List<UUID> roots = db.queryForList(
                "SELECT id FROM warehouses WHERE code='001' AND NOT is_deleted", UUID.class);
        if (roots.isEmpty()) {
            root = UUID.randomUUID();
            db.update("INSERT INTO warehouses(id,code,name,status,is_accountable) VALUES (?,'001',?,'使用',true)",
                    root, "单主仓测试主仓-" + root);
        } else {
            root = roots.getFirst();
        }
        assertThat(db.queryForObject("SELECT fn_warehouse_root_id()", UUID.class)).isEqualTo(root);
    }

    @AfterEach void clear() { SecurityContextHolder.clearContext(); }

    @Test void newWarehousesHangUnderTheMainWarehouseAndNamesStayDistinct() {
        String suffix = UUID.randomUUID().toString().substring(0, 8);
        WarehouseDetail created = warehouses.create(request("备件仓（" + suffix + "）"));
        assertThat(created.getParentId()).isEqualTo(root);
        assertThat(created.isSelectableForNew()).isTrue();
        assertThat(created.isDefective()).isFalse();

        // 只能挂主仓: 写别的上级直接拒绝(两层树), 不传就补成主仓。
        WarehouseSaveRequest otherParent = request("挂错上级-" + suffix);
        otherParent.setParentId(created.getId());
        assertThatThrownBy(() -> warehouses.create(otherParent))
                .isInstanceOfSatisfying(ApiException.class, error -> {
                    assertThat(error.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED);
                    assertThat(error.getMessage()).contains("上级仓库只能是主仓").contains("两层");
                });
        WarehouseSaveRequest rootParent = request("挂主仓-" + suffix);
        rootParent.setParentId(root);
        assertThat(warehouses.create(rootParent).getParentId()).isEqualTo(root);

        // 名称比对键: 去空白、括号不分全角半角、不分大小写。
        for (String variant : List.of(" 备件仓(" + suffix + ") ", "备件仓 （" + suffix.toUpperCase() + "）")) {
            assertThatThrownBy(() -> warehouses.create(request(variant)))
                    .isInstanceOfSatisfying(ApiException.class, error ->
                            assertThat(error.getMessage()).contains("已有同名仓库"));
        }
        // 仓库资料不能建内料仓(由车间内料仓页管理)。
        WarehouseSaveRequest lineSide = request("内料仓-" + suffix);
        lineSide.setIsLineSide(true);
        assertThatThrownBy(() -> warehouses.create(lineSide))
                .isInstanceOfSatisfying(ApiException.class, error ->
                        assertThat(error.getMessage()).contains("车间内料仓"));
        // 主仓自己不能挂到别的仓下面。
        WarehouseSaveRequest moveRoot = request(db.queryForObject("SELECT name FROM warehouses WHERE id=?", String.class, root));
        moveRoot.setParentId(created.getId());
        assertThatThrownBy(() -> warehouses.update(root, moveRoot))
                .isInstanceOfSatisfying(ApiException.class, error ->
                        assertThat(error.getMessage()).contains("主仓不能挂到别的仓库下面"));
    }

    @Test void retirementListsTheSameReasonsOnEveryStatusPath() {
        String suffix = UUID.randomUUID().toString().substring(0, 8);
        WarehouseDetail owned = warehouses.create(request("归属仓-" + suffix));
        db.update("UPDATE goods SET owning_warehouse_id=? WHERE id=?", owned.getId(), world.goodsD());

        assertThatThrownBy(() -> warehouses.changeStatus(owned.getId(), new MasterStatusChangeRequest("禁用", null)))
                .isInstanceOfSatisfying(ApiException.class, error -> assertThat(error.getMessage())
                        .isEqualTo("仓库「归属仓-" + suffix + "」现在不能停用: 还是 1 个货品的所属仓库"));
        WarehouseSaveRequest disable = request("归属仓-" + suffix);
        disable.setStatus("禁用");
        assertThatThrownBy(() -> warehouses.update(owned.getId(), disable))
                .isInstanceOfSatisfying(ApiException.class, error ->
                        assertThat(error.getMessage()).contains("现在不能停用").contains("所属仓库"));
        var batch = lifecycle.batchStatus(MasterEntityKind.WAREHOUSE, "禁用",
                List.of(new MasterBatchRequests.Item(owned.getId(), null), new MasterBatchRequests.Item(root, null)));
        assertThat(batch.succeeded()).isZero();
        assertThat(batch.results()).extracting(item -> item.reason())
                .anySatisfy(reason -> assertThat(reason).contains("还是 1 个货品的所属仓库"))
                .anySatisfy(reason -> assertThat(reason).contains("它是主仓"));
        assertThat(db.queryForObject("SELECT status FROM warehouses WHERE id=?", String.class, owned.getId()))
                .isEqualTo("使用");

        // 有归属的仓不能改成不良品仓, 也不能改成「不核算」(两条都让它退出新选, 与停用同一组前置条件;
        // 服务层先给中文原因, 数据库守卫同一定义兜底)。
        WarehouseSaveRequest toDefective = request("归属仓-" + suffix);
        toDefective.setDefective(true);
        assertThatThrownBy(() -> warehouses.update(owned.getId(), toDefective))
                .isInstanceOfSatisfying(ApiException.class, error -> assertThat(error.getMessage())
                        .isEqualTo("仓库「归属仓-" + suffix + "」现在不能改成不良品仓: 还是 1 个货品的所属仓库"));
        WarehouseSaveRequest toUnaccountable = request("归属仓-" + suffix);
        toUnaccountable.setAccountable(false);
        assertThatThrownBy(() -> warehouses.update(owned.getId(), toUnaccountable))
                .isInstanceOfSatisfying(ApiException.class, error -> assertThat(error.getMessage())
                        .isEqualTo("仓库「归属仓-" + suffix + "」现在不能改成不核算: 还是 1 个货品的所属仓库"));
        assertThatThrownBy(() -> db.update("UPDATE warehouses SET is_accountable=false WHERE id=?", owned.getId()))
                .hasStackTraceContaining("现在不能改成不核算");
        assertThat(db.queryForObject("SELECT is_accountable FROM warehouses WHERE id=?", Boolean.class, owned.getId()))
                .isTrue();

        // 清掉归属后可以停用, 停用后字典里它不再是新选项。
        db.update("UPDATE goods SET owning_warehouse_id=NULL WHERE id=?", world.goodsD());
        assertThat(warehouses.changeStatus(owned.getId(), new MasterStatusChangeRequest("禁用", null)).getStatus())
                .isEqualTo("禁用");
        assertThat(warehouses.dict()).filteredOn(row -> row.getId().equals(owned.getId()))
                .singleElement().satisfies(row -> assertThat(row.isSelectableForNew()).isFalse());
    }

    @Test void dictionaryCarriesTheDatabaseDefinitionOfSelectabilityAndUse() {
        List<WarehouseListItem> dict = warehouses.dict();
        assertThat(dict.getFirst().getParentId()).as("主仓在最前").isNull();
        for (WarehouseListItem row : dict) {
            assertThat(row.isSelectableForNew()).as(row.getCode())
                    .isEqualTo(db.queryForObject("SELECT fn_warehouse_is_good_stock_leaf(?)", Boolean.class, row.getId()));
            assertThat(row.isDefective()).as(row.getCode())
                    .isEqualTo(db.queryForObject("SELECT is_defective FROM warehouses WHERE id=?", Boolean.class, row.getId()));
        }
        assertThat(dict).filteredOn(row -> row.getId().equals(root))
                .singleElement().satisfies(row -> assertThat(row.isSelectableForNew()).as("主仓只作汇总").isFalse());
    }

    private static WarehouseSaveRequest request(String name) {
        WarehouseSaveRequest request = new WarehouseSaveRequest();
        request.setName(name);
        request.setStatus("使用");
        request.setAccountable(true);
        return request;
    }
}
