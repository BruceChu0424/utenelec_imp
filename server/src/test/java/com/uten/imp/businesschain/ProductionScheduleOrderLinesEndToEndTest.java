package com.uten.imp.businesschain;

import com.uten.imp.features.production.schedule.ProductionScheduleService;
import com.uten.imp.features.production.schedule.dto.ScheduleOrderLine;
import org.junit.jupiter.api.AfterEach;
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
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.stream.Collectors;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;

/**
 * 「来源订单→选行带入计划」弹窗的一层 BOM(ADR-129 §2.3)在真实库上跑：计算用量取 V739 的
 * v_goods_bom_item_usage，需求小计走共享边公式；用量不大于零的存量 BOM 行(V182 的 qty>0 约束是
 * NOT VALID，存量没清)只列出零件、不算用量，整张订单照常带入，不再 500。
 */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.policy-intelligence.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class ProductionScheduleOrderLinesEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired PlatformTransactionManager transactions;
    @Autowired ProductionScheduleService schedule;

    @AfterEach void clear(){SecurityContextHolder.clearContext();}

    @Test void orderLinesUseTheUsageViewAndListLegacyNonPositiveBomRowsWithoutUsage() {
        FullChainEndToEndTest fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        FullChainEndToEndTest.World world=fixture.seedWorld("order-lines-"+UUID.randomUUID());
        // 成品 A 的一层 BOM：半成品 B 每件 2，委外件 E 每件 1。
        UUID order=fixture.createApprovedOrder(world,world.goodsA(),"10","100");

        ScheduleOrderLine line=single(schedule.orderLines(order));
        amount("10",line.needQty());
        Map<UUID,ScheduleOrderLine.BomComponent> bom=byGoods(line);
        amount("2",bom.get(world.goodsB()).perQty());
        amount("20",bom.get(world.goodsB()).needQty());
        amount("1",bom.get(world.goodsE()).perQty());
        amount("10",bom.get(world.goodsE()).needQty());

        // 新写入会被 goods_bom_qty_positive_chk 拦住；在回滚的事务里去掉约束，造一条历史存量行。
        new TransactionTemplate(transactions).executeWithoutResult(status->{
            db.execute("ALTER TABLE goods_bom_items DROP CONSTRAINT goods_bom_qty_positive_chk");
            db.update("UPDATE goods_bom_items SET qty=0 WHERE goods_id=? AND component_goods_id=? AND NOT is_deleted",
                    world.goodsA(),world.goodsE());
            Map<UUID,ScheduleOrderLine.BomComponent> legacy=byGoods(single(schedule.orderLines(order)));
            assertEquals(2,legacy.size(),"坏行照样列出，整张订单不因它失败");
            assertNull(legacy.get(world.goodsE()).perQty());
            assertNull(legacy.get(world.goodsE()).needQty());
            amount("2",legacy.get(world.goodsB()).perQty());
            amount("20",legacy.get(world.goodsB()).needQty());
            status.setRollbackOnly();
        });
    }

    private static ScheduleOrderLine single(List<ScheduleOrderLine> lines){assertEquals(1,lines.size());return lines.getFirst();}
    private static Map<UUID,ScheduleOrderLine.BomComponent> byGoods(ScheduleOrderLine line){
        return line.bom().stream().collect(Collectors.toMap(ScheduleOrderLine.BomComponent::goodsId,component->component));
    }
    private static void amount(String expected,BigDecimal actual){assertEquals(0,new BigDecimal(expected).compareTo(actual),String.valueOf(actual));}
}
