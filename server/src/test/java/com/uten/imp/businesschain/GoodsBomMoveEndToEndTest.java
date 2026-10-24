package com.uten.imp.businesschain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.goods.GoodsBomService;
import com.uten.imp.features.master.goods.dto.BomMoveRequest;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * 组装信息拖拽移动(2026-10-19)的真库 E2E：多选批量的同层 below/above 与跨层移入，
 * 在真实 JPA + V775 留痕触发器环境下验最终 sort_order 落库结果——mock 层验不出
 * 「flush 时序 / 触发器 / 唯一索引」这三类只有真库才有的行为。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false",
        "uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true", "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class GoodsBomMoveEndToEndTest {
    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired GoodsBomService bom;
    FullChainEndToEndTest fixture;

    @BeforeEach void before() {
        fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
        UUID adminId = db.queryForObject(
                "SELECT id FROM users WHERE login_account='full-chain-bootstrap-admin-test'", UUID.class);
        fixture.loginAs(adminId);
        // 引导超管的权限镜像若不含 BOM 维护码，就地补齐（其他 E2E 同款做法）。
        var auth = (org.springframework.security.authentication.UsernamePasswordAuthenticationToken)
                SecurityContextHolder.getContext().getAuthentication();
        com.uten.imp.security.AuthUser admin =
                (com.uten.imp.security.AuthUser) auth.getPrincipal();
        java.util.Set<String> grants = new java.util.HashSet<>(admin.getPermissions());
        grants.add("goods:bom:edit");
        grants.add("goods:view");
        com.uten.imp.security.AuthUser boosted = new com.uten.imp.security.AuthUser(
                admin.getId(), admin.getEmployeeId(), admin.getUsername(), grants, false, true, true);
        SecurityContextHolder.getContext().setAuthentication(
                new org.springframework.security.authentication.UsernamePasswordAuthenticationToken(
                        boosted, null, boosted.getAuthorities()));
    }

    @AfterEach void after() {
        SecurityContextHolder.clearContext();
        // Scenario UUIDs/codes are unique. V911 lifecycle/use facts and V775
        // history retain these goods/BOM identities; keep the complete fixture
        // graph until the disposable FullChain Testcontainers database is destroyed.
    }

    UUID goods(String tag) {
        UUID id = UUID.randomUUID();
        db.update("""
                INSERT INTO goods(id, code, name, model, code_sequence)
                VALUES (?, ?, '移动测试', '', (SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))
                """, id, "MV-" + tag + "-" + UUID.randomUUID().toString().substring(0, 8));
        return id;
    }

    UUID edge(UUID parent, UUID component, int sort) {
        UUID id = UUID.randomUUID();
        db.update("INSERT INTO goods_bom_items(id, goods_id, component_goods_id, qty, sort_order) VALUES (?,?,?,1,?)",
                id, parent, component, sort);
        return id;
    }

    List<UUID> childComponents(UUID parent) {
        return db.query(
                "SELECT component_goods_id FROM goods_bom_items WHERE goods_id=? AND NOT is_deleted ORDER BY sort_order, id",
                (rs, i) -> UUID.fromString(rs.getString(1)), parent);
    }

    static BomMoveRequest.Move move(UUID itemId, UUID targetParent, UUID anchor, boolean after) {
        BomMoveRequest.Move m = new BomMoveRequest.Move();
        m.setItemId(itemId);
        m.setTargetParentGoodsId(targetParent);
        m.setAnchorItemId(anchor);
        m.setAfterAnchor(after);
        return m;
    }

    /** 多选批量 below（前端逆序提交 afterAnchor）与 above（正序提交 BEFORE）的落库顺序。 */
    @Test void multiSelectSameLevelMovesLandAsOneBlock() {
        UUID root = goods("root");
        UUID a = goods("a"), b = goods("b"), c = goods("c");
        UUID ra = edge(root, a, 0), rb = edge(root, b, 1), rc = edge(root, c, 2);

        // 拖 [a,b] 到 c 下方：前端逆序 [b,a]，afterAnchor=c。
        int moved = bom.moveAll(root, List.of(move(rb, root, rc, true), move(ra, root, rc, true)));
        assertEquals(2, moved);
        assertEquals(List.of(c, a, b), childComponents(root), "批量 below 应把整块按原顺序落到 c 之后");

        // 再拖 [a,b] 到 c 上方：前端正序 [a,b]，BEFORE=c。
        moved = bom.moveAll(root, List.of(move(ra, root, rc, false), move(rb, root, rc, false)));
        assertEquals(2, moved);
        assertEquals(List.of(a, b, c), childComponents(root), "批量 above 应把整块按原顺序落到 c 之前");
    }

    /** 多选批量跨层移入：旧行软删（留痕触发器放行）、新身份按提交顺序追加到目标层。 */
    @Test void multiSelectCrossLevelIntoCreatesNewIdentitiesInOrder() {
        UUID root = goods("root");
        UUID a = goods("a"), b = goods("b"), sub = goods("sub");
        UUID ra = edge(root, a, 0), rb = edge(root, b, 1);
        edge(root, sub, 2);

        int moved = bom.moveAll(root, List.of(move(ra, sub, null, false), move(rb, sub, null, false)));
        assertEquals(2, moved);
        assertEquals(List.of(sub), childComponents(root), "根层只剩 sub");
        assertEquals(List.of(a, b), childComponents(sub), "两个组件按提交顺序进入 sub");
        Integer oldAlive = db.queryForObject(
                "SELECT COUNT(*) FROM goods_bom_items WHERE id IN (?,?) AND NOT is_deleted", Integer.class, ra, rb);
        assertEquals(0, oldAlive, "旧关系行必须软删");
        Integer freshRows = db.queryForObject(
                "SELECT COUNT(*) FROM goods_bom_items WHERE goods_id=? AND component_goods_id IN (?,?) AND NOT is_deleted",
                Integer.class, sub, a, b);
        assertEquals(2, freshRows, "目标层必须是新身份行");
    }

    /** 成环拒绝：把 sub 移进它自己的子件 x 之下整批 422 回滚（真库触发器/约束也不得触发）。 */
    @Test void cycleBatchIsRejectedAtomically() {
        UUID root = goods("root");
        UUID a = goods("a"), sub = goods("sub"), x = goods("x");
        UUID ra = edge(root, a, 0);
        UUID rsub = edge(root, sub, 1);
        edge(sub, x, 0);

        ApiException error = assertThrows(ApiException.class, () -> bom.moveAll(root, List.of(
                move(ra, root, null, false),
                move(rsub, x, null, false))));
        assertEquals(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED, error.getCode());
        assertEquals(List.of(a, sub), childComponents(root), "整批回滚：a 的同层移动也不得落库");
        assertEquals(List.of(x), childComponents(sub));
    }
}
