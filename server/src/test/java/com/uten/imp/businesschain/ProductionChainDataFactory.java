package com.uten.imp.businesschain;

import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewItem;
import com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService;
import com.uten.imp.features.sales.order.SalesOrderService;
import com.uten.imp.features.sales.order.dto.OrderItemLine;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.jdbc.core.JdbcTemplate;

/** Test-only masters and real sales sources. It never seeds stock, plans or fulfillment facts. */
final class ProductionChainDataFactory {
    private final FullChainEndToEndTest masters;
    private final JdbcTemplate jdbc;
    private final SalesOrderService sales;
    private final SalesOrderFinanceConfirmService finance;
    private final com.uten.imp.features.common.taskclaim.TaskClaimService claims;

    ProductionChainDataFactory(AutowireCapableBeanFactory beans, JdbcTemplate jdbc,
            SalesOrderService sales, SalesOrderFinanceConfirmService finance) {
        masters = new FullChainEndToEndTest();
        beans.autowireBean(masters);
        this.jdbc = jdbc;
        this.sales = sales;
        this.finance = finance;
        this.claims=beans.getBean(com.uten.imp.features.common.taskclaim.TaskClaimService.class);
    }

    private void confirmInitialFinance(UUID orderId) {
        var claim=claims.claim("SALES_ORDER_FINANCE_CONFIRM",orderId.toString());
        finance.confirm(orderId,new SalesOrderFinanceConfirmService.FinanceConfirmRequest(null,0L,claim.claimId()));
    }

    record Scenario(FullChainEndToEndTest.World world, UUID orderId,
            List<UUID> products, List<PreviewItem> sources, UUID assembledSubcontract,
            List<UUID> sharedAssemblies, List<UUID> sharedBuyLeaves,
            int physicalBomRows, int expectedExpandedRowsPerProduct) {}

    Scenario sharedTree(String tag, int productCount) {
        if (productCount < 1 || productCount > 500) {
            throw new IllegalArgumentException("Use 1..500 actual sales source lines");
        }
        var w = masters.seedWorld(tag);
        jdbc.update("update goods set default_supplier_id=? where id in (?,?)",
                w.supplierId(), w.goodsD(), w.goodsE());
        // C is intentionally a childless MAKE node; its route is explicitly confirmed by the scenario.
        UUID assembled = goods(w, tag + "-sc", "委外");
        masters.insertBom(assembled, w.goodsD(), "2");
        masters.insertBom(assembled, w.goodsC(), "1");
        List<UUID> leaves = new ArrayList<>();
        for (int n = 0; n < 8; n++) leaves.add(goods(w, tag + "-raw-" + n, "采购"));
        List<UUID> assemblies = new ArrayList<>();
        for (int n = 0; n < 10; n++) {
            UUID assembly = goods(w, tag + "-make-" + n, "自制");
            assemblies.add(assembly);
            for (UUID leaf : leaves) masters.insertBom(assembly, leaf, "1");
        }
        List<UUID> products = new ArrayList<>();
        for (int n = 0; n < productCount; n++) {
            UUID root = goods(w, tag + "-product-" + n, "自制");
            products.add(root);
            masters.insertBom(root, w.goodsB(), "2");
            masters.insertBom(root, w.goodsE(), "1");
            masters.insertBom(root, assembled, "1");
            for (UUID assembly : assemblies) masters.insertBom(root, assembly, "1");
        }
        masters.loginAs(w.superAdminUserId());
        var request = masters.orderRequest(w, products.getFirst(), "10", "100");
        List<OrderItemLine> lines = products.stream()
                .map(product -> masters.orderRequest(w, product, "10", "100").getItems().getFirst())
                .toList();
        request.setItems(lines);
        UUID orderId = sales.create(request).getId();
        sales.approve(orderId);
        confirmInitialFinance(orderId);
        List<PreviewItem> sources = jdbc.query("""
                select id from sales_order_items where order_id=? and is_deleted=false
                order by line_no,id
                """, (rs, row) -> new PreviewItem("SALES_ORDER_ITEM", rs.getObject("id", UUID.class),
                        null, null, null, null, null, LocalDate.of(2026, 9, 30), new BigDecimal("10")),
                orderId);
        // 13 edges per product, shared B(2), SC(2), 10 assemblies(80), and unused seed A(2).
        // Expanded per product: root(1) + B/C/D(3) + leafSC(1) + SC/C/D(3) + assemblies/leaves(90).
        return new Scenario(w, orderId, List.copyOf(products), sources, assembled,
                List.copyOf(assemblies), List.copyOf(leaves), 13 * productCount + 86, 98);
    }

    UUID goods(FullChainEndToEndTest.World w, String tag, String sourceType) {
        UUID id = UUID.randomUUID();
        masters.insertGoods(id, "ST-" + tag, "压力夹具-" + tag, sourceType, w.unitId(), w.unitLegacy());
        jdbc.update("update goods set default_supplier_id=? where id=?", w.supplierId(), id);
        return id;
    }

    /** Cancelled demand metadata; no fabricated fulfillment, stock, WIP or financial facts. */
    void terminalAnalysisMetadata(Scenario scenario, int rows) {
        for (int offset=0;offset<rows;offset+=1000) {
        int batch=Math.min(1000,rows-offset);
        jdbc.update("""
                WITH headers AS (
                    insert into production_material_analyses
                      (warehouse_id,status,fingerprint,initial_idempotency_key,maker_id,
                       created_by,updated_by,analyzed_at,created_at,updated_at,
                       cancelled_by,cancelled_at,cancellation_reason)
                    select ?, 'CANCELLED', repeat('a',64), ? || '-' || n, ?, ?, ?,
                           now() - interval '1 year' - n * interval '1 second',
                           now() - interval '1 year', now() - interval '1 year',
                           ?, now() - interval '1 year', '已取消历史需求规模夹具'
                    from generate_series(1,?) n RETURNING id
                )
                insert into production_material_analysis_items
                  (analysis_id,source_type,goods_id,unit_id,requested_qty,source_ref,source_reason)
                select id,'OTHER',?,?,10,'HISTORY-CANCELLED-'||id,'已取消历史需求，仅用于只读查询规模验证'
                from headers
                """, scenario.world().warehouseId(), "stress-history-" + scenario.orderId()+"-"+offset,
                scenario.world().employeeId(), scenario.world().superAdminUserId(),
                scenario.world().superAdminUserId(), scenario.world().superAdminUserId(), batch,
                scenario.world().goodsA(),scenario.world().unitId());
        }
    }

    /** Disconnected, valid BOM masters stress the same root/parent lookup indexes as live trees. */
    void historicalBomMasters(Scenario scenario, int rows) {
        var w=scenario.world();
        String prefix="H-"+UUID.randomUUID().toString().substring(0,8);
        int leafCount=Math.min(100,rows);
        int parentCount=(rows+leafCount-1)/leafCount;
        List<UUID> leaves=java.util.stream.IntStream.range(0,leafCount).mapToObj(n -> UUID.randomUUID()).toList();
        List<UUID> parents=java.util.stream.IntStream.range(0,parentCount).mapToObj(n -> UUID.randomUUID()).toList();
        List<UUID> ids=new ArrayList<>(leaves); ids.addAll(parents);
        long sequence=jdbc.queryForObject("select coalesce(max(code_sequence),0) from goods",Long.class);
        jdbc.batchUpdate("""
                insert into goods(id,code,name,source_type,status,unit_id,unit_legacy_id,price,code_sequence)
                values (?,?,?,?,'使用',?,?,10,?)
                """,java.util.stream.IntStream.range(0,ids.size()).boxed().toList(),500,(statement,n) -> {
                    statement.setObject(1,ids.get(n)); statement.setString(2,prefix+"-"+n);
                    statement.setString(3,"历史BOM规模夹具-"+n); statement.setString(4,n<leafCount ? "采购" : "自制");
                    statement.setObject(5,w.unitId()); statement.setInt(6,w.unitLegacy()); statement.setLong(7,sequence+n+1);
                });
        jdbc.batchUpdate("insert into goods_bom_items(goods_id,component_goods_id,qty) values (?,?,1)",
                java.util.stream.IntStream.range(0,rows).boxed().toList(),1000,(statement,n) -> {
                    statement.setObject(1,parents.get(n/leafCount)); statement.setObject(2,leaves.get(n%leafCount));
                });
    }

    void login(Scenario scenario) { masters.loginAs(scenario.world().superAdminUserId()); }

    record DepthScenario(FullChainEndToEndTest.World world, List<PreviewItem> sources) {}

    DepthScenario depthChain(String tag, int depth) {
        var w = masters.seedWorld(tag);
        UUID root = goods(w, tag + "-root", "自制");
        UUID parent = root;
        for (int level = 1; level <= depth; level++) {
            UUID child = goods(w, tag + "-level-" + level, level == depth ? "采购" : "自制");
            masters.insertBom(parent, child, "1");
            parent = child;
        }
        UUID orderId = masters.createApprovedOrder(w, root, "10", "100");
        UUID source = jdbc.queryForObject("select id from sales_order_items where order_id=? and is_deleted=false", UUID.class, orderId);
        return new DepthScenario(w, List.of(new PreviewItem("SALES_ORDER_ITEM", source, null, null, null,
                null, null, LocalDate.of(2026, 9, 30), BigDecimal.TEN)));
    }

    Scenario anotherSalesOrder(Scenario scenario) {
        var w = scenario.world();
        login(scenario);
        var request = masters.orderRequest(w, scenario.products().getFirst(), "10", "100");
        request.setItems(scenario.products().stream()
                .map(product -> masters.orderRequest(w, product, "10", "100").getItems().getFirst()).toList());
        UUID orderId = sales.create(request).getId();
        sales.approve(orderId);
        confirmInitialFinance(orderId);
        List<PreviewItem> sources = jdbc.query("""
                select id from sales_order_items where order_id=? and is_deleted=false order by line_no,id
                """, (rs, row) -> new PreviewItem("SALES_ORDER_ITEM", rs.getObject("id", UUID.class),
                        null, null, null, null, null, LocalDate.of(2026, 9, 30), new BigDecimal("10")), orderId);
        return new Scenario(w, orderId, scenario.products(), sources, scenario.assembledSubcontract(),
                scenario.sharedAssemblies(), scenario.sharedBuyLeaves(), scenario.physicalBomRows(),
                scenario.expectedExpandedRowsPerProduct());
    }
}
