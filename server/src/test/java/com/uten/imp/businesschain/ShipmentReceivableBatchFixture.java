package com.uten.imp.businesschain;

import com.uten.imp.application.port.ShipmentReceivablePositionPort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.sales.shipment.SalesShipmentService;
import com.uten.imp.features.sales.shipment.dto.ShipmentQueryFilter;
import com.uten.imp.features.sales.shipment.dto.ShipmentListItem;
import com.uten.imp.features.sales.shipment.dto.ShipmentSaveRequest;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import com.uten.imp.features.stock.valuation.InventoryValueWorkService;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;
import static org.assertj.core.api.Assertions.assertThat;

/** Shared real initial batch for financial PG acceptance and loopback interactive UAT. No receipt is created or approved here. */
final class ShipmentReceivableBatchFixture {
    record Prepared(FullChainEndToEndTest fixture,FullChainEndToEndTest.World world,UUID goods,
                    UUID firstOrder,UUID secondOrder,UUID firstItem,UUID secondItem,
                    UUID shipment,UUID ledger,UUID bank,UUID reviewer) { }
    record PreparedSingle(FullChainEndToEndTest fixture,FullChainEndToEndTest.World world,UUID goods,
                          UUID order,UUID item,UUID shipment,UUID ledger,UUID bank,UUID reviewer) { }
    private record Base(FullChainEndToEndTest fixture,FullChainEndToEndTest.World world,UUID goods,UUID bank,UUID reviewer) { }

    private final AutowireCapableBeanFactory beans;
    private final JdbcTemplate db;
    private final StockDocService stock;
    private final InventoryValueWorkService valueWork;
    private final SalesShipmentService shipments;
    private final ShipmentReceivablePositionPort positions;
    private final PlatformTransactionManager transactions;

    private ShipmentReceivableBatchFixture(AutowireCapableBeanFactory beans,JdbcTemplate db){
        if(org.springframework.transaction.support.TransactionSynchronizationManager.isActualTransactionActive())
            throw new IllegalStateException("真实批次fixture须在外层事务之外调用，让业务提交、异步价值runner与RR读取按真实边界执行");
        this.beans=beans;this.db=db;stock=beans.getBean(StockDocService.class);
        valueWork=beans.getBean(InventoryValueWorkService.class);shipments=beans.getBean(SalesShipmentService.class);
        positions=beans.getBean(ShipmentReceivablePositionPort.class);transactions=beans.getBean(PlatformTransactionManager.class);
    }

    static Prepared prepare(AutowireCapableBeanFactory beans,JdbcTemplate db,String tag){
        return new ShipmentReceivableBatchFixture(beans,db).prepare(tag);
    }
    static PreparedSingle prepareSingle(AutowireCapableBeanFactory beans,JdbcTemplate db,String tag){
        return new ShipmentReceivableBatchFixture(beans,db).prepareSingle(tag);
    }

    /** Exercise the owning paged query with no date bounds; never filter an already loaded page. */
    static PageResponse<ShipmentListItem> openShipments(AutowireCapableBeanFactory beans,JdbcTemplate db,UUID shipment){
        String no=db.queryForObject("SELECT bill_no FROM sales_shipments WHERE id=?",String.class,shipment);
        var filter=new ShipmentQueryFilter(null,null,null,null,null,null,null,null,null,null,null,null,null,
                com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope.ALL,no).withReceivableState("OPEN");
        return beans.getBean(SalesShipmentService.class).list(filter,1,1,"billNo","asc");
    }

    /** Ship the main order's remaining ten items into another independent batch AR. */
    static Prepared shipNext(AutowireCapableBeanFactory beans,JdbcTemplate db,Prepared source){
        var support=new ShipmentReceivableBatchFixture(beans,db);
        UUID shipment=support.ship(source.fixture(),source.world(),source.goods(),source.firstItem());
        return new Prepared(source.fixture(),source.world(),source.goods(),source.firstOrder(),source.secondOrder(),
                source.firstItem(),source.secondItem(),shipment,support.ledgerOf(shipment),source.bank(),source.reviewer());
    }

    private Prepared prepare(String tag){
        Base base=seed(tag,"20");var fixture=base.fixture();var world=base.world();UUID goods=base.goods();
        UUID firstOrder=fixture.createApprovedOrder(world,goods,"20","100"),secondOrder=fixture.createApprovedOrder(world,goods,"10","100");
        UUID firstItem=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=? AND NOT is_deleted",UUID.class,firstOrder);
        UUID secondItem=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=? AND NOT is_deleted",UUID.class,secondOrder);
        amount("20","SELECT reserved_qty FROM sales_order_items WHERE id=?",firstItem);
        amount("0","SELECT reserved_qty FROM sales_order_items WHERE id=?",secondItem);
        UUID shipment=ship(fixture,world,goods,firstItem),ledger=ledgerOf(shipment);
        amount("10","SELECT reserved_qty FROM sales_order_items WHERE id=?",firstItem);
        amount("10","SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=? AND color_id IS NULL",world.warehouseId(),goods);
        amount("1000","SELECT amount_original FROM ar_ap_ledger WHERE id=?",ledger);
        amount("7000","SELECT amount_original_local FROM ar_ap_ledger WHERE id=?",ledger);
        assertThat(db.queryForList("SELECT source_id FROM ar_ap_source_refs WHERE ledger_id=? AND source_type='SALES_ORDER' ORDER BY source_sequence,id",
                UUID.class,ledger)).containsExactly(firstOrder);
        return new Prepared(fixture,world,goods,firstOrder,secondOrder,firstItem,secondItem,shipment,ledger,base.bank(),base.reviewer());
    }

    private PreparedSingle prepareSingle(String tag){
        Base base=seed(tag,"7");var fixture=base.fixture();var world=base.world();UUID goods=base.goods();
        assertThat(db.queryForObject("SELECT count(*) FROM sales_order_items WHERE goods_id=?",Long.class,goods)).isZero();
        // Configure this independent world's real master price before any order snapshot.
        // The order preview must match SalesPriceAuthority; a request cannot invent 105 over the seeded 100.
        assertThat(db.update("UPDATE goods SET price=? WHERE id=?",n("105"),goods)).isEqualTo(1);
        drain(goods);
        UUID order=fixture.createApprovedOrder(world,goods,"7","105");
        UUID item=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=? AND NOT is_deleted",UUID.class,order);
        amount("7","SELECT reserved_qty FROM sales_order_items WHERE id=?",item);
        fixture.loginAs(world.superAdminUserId());drain(goods);
        var request=fixture.shipmentRequest(world,item,goods,"7");request.setBillDate(BusinessTime.today());
        request.getItems().getFirst().setLineNo(1);request.getItems().getFirst().setPrice(n("105"));
        request.setRemark("完整履约后真实多付款仍须保留为本单预收，不能自动转收入");
        UUID shipment=finishShipment(fixture,world,request),ledger=ledgerOf(shipment);
        amount("0","SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=? AND color_id IS NULL",world.warehouseId(),goods);
        amount("735","SELECT amount_original FROM ar_ap_ledger WHERE id=?",ledger);
        amount("5145","SELECT amount_original_local FROM ar_ap_ledger WHERE id=?",ledger);
        assertThat(db.queryForObject("SELECT is_closed FROM sales_orders WHERE id=?",Boolean.class,order))
                .as("真实全量发货必须由系统recalcClosed结案，fixture不写is_closed").isTrue();
        assertThat(db.queryForList("SELECT source_id FROM ar_ap_source_refs WHERE ledger_id=? AND source_type='SALES_ORDER'",UUID.class,ledger)).containsExactly(order);
        return new PreparedSingle(fixture,world,goods,order,item,shipment,ledger,base.bank(),base.reviewer());
    }

    private Base seed(String tag,String openingQuantity){
        var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        var world=fixture.seedWorld(tag);fixture.loginAs(world.superAdminUserId());fixture.seedChartOfAccounts();
        db.update("UPDATE currencies SET code=?,name='发货批次收款回归原币',exchange_rate=7 WHERE id=?","BATCH-"+world.currencyId(),world.currencyId());
        // Native monthly-credit master. Warehouse recognition owns the AR date/term snapshot.
        db.update("UPDATE clients SET default_settlement_method_id=?,tday=30 WHERE id=?",
                UUID.fromString("27300000-0000-4000-8100-000000000006"),world.clientId());
        UUID goods=world.goodsD();drain(goods);
        var opening=new StockDocSaveRequest();opening.setDocType("OTHER_IN");
        opening.setBillDate(BusinessTime.today().minusDays(1));opening.setWarehouseId(world.warehouseId());
        opening.setRemark("发货批次资金回归的真实有价期初实物");
        var input=new StockDocItemLine();input.setGoodsId(goods);input.setUnitId(world.unitId());
        input.setUnitRate(BigDecimal.ONE);input.setQty(n(openingQuantity));input.setPrice(n("10"));
        input.setAmountOriginal(n(openingQuantity).multiply(n("10")));input.setAmountLocal(input.getAmountOriginal());opening.setItems(List.of(input));
        UUID openingId=stock.create(opening).getId();drain(goods);stock.approve(openingId);drain(goods);
        amount(openingQuantity,"SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=? AND color_id IS NULL",world.warehouseId(),goods);
        UUID bankStyle=UUID.randomUUID(),bank=UUID.randomUUID();
        db.update("INSERT INTO payment_styles(id,code,name,category,level,status) VALUES(?,?,?,'ACCOUNT',0,'使用')",bankStyle,"BT-ST-"+bankStyle,"本批实际收款账户科目-"+tag);
        db.update("INSERT INTO accounts(id,code,name,account_type,currency_id,status,style_id) VALUES(?,?,?,'BANK',?,'使用',?)",bank,"BT-BK-"+bank,"本批实际收款账户-"+tag,world.currencyId(),bankStyle);
        UUID reviewer=fixture.createUserWithPerms(world,"review-"+tag,"finance_receipt:view","finance_receipt:approve",
                "finance_receipt:reverse","finance:view:all","customer_prepayment:view");
        fixture.grantDataScope(reviewer,"finance",world.employeeId());
        return new Base(fixture,world,goods,bank,reviewer);
    }

    private UUID ship(FullChainEndToEndTest fixture,FullChainEndToEndTest.World world,UUID goods,UUID firstItem){
        fixture.loginAs(world.superAdminUserId());drain(goods);
        var request=fixture.shipmentRequest(world,firstItem,goods,"10");request.setBillDate(BusinessTime.today());
        request.setRemark("本批尾款约定到货后支付；未经实际到账或本批核销不得收清");
        request.getItems().getFirst().setLineNo(1);
        return finishShipment(fixture,world,request);
    }
    private UUID finishShipment(FullChainEndToEndTest fixture,FullChainEndToEndTest.World world,ShipmentSaveRequest request){
        UUID id=shipments.create(request).getId();
        var read=new TransactionTemplate(transactions);read.setReadOnly(true);read.setIsolationLevel(TransactionDefinition.ISOLATION_REPEATABLE_READ);
        var pending=read.execute(ignored->positions.read(List.of(id)).get(id));
        assertThat(pending).isNotNull();assertThat(pending.state()).isEqualTo("NOT_POSTED");
        assertThat(pending.ledgerId()).isNull();assertThat(pending.cashReceivedOriginal()).isNull();assertThat(pending.balanceOriginal()).isNull();
        var open=openShipments(beans,db,id);assertThat(open.getTotal()).isZero();assertThat(open.getItems()).isEmpty();
        fixture.shipThroughWarehouse(id);fixture.loginAs(world.superAdminUserId());
        return id;
    }
    private UUID ledgerOf(UUID shipment){return db.queryForObject("SELECT id FROM ar_ap_ledger WHERE source_doc_type='SALES_SHIPMENT' AND source_doc_id=?",UUID.class,shipment);}
    private void drain(UUID goods){
        var operator=SecurityContextHolder.getContext();SecurityContextHolder.clearContext();
        try{InventoryValueWorkTestSupport.drain(valueWork,db,List.of(goods));}
        finally{SecurityContextHolder.setContext(operator);}
        assertThat(db.queryForObject("SELECT fn_inventory_value_precision_marked(ARRAY[fn_inventory_value_precision_key(?::uuid,NULL::uuid)])",
                Boolean.class,goods)).as("真实价值后继必须由公共runner处理完成，不关闭或绕过精度闭包守卫").isFalse();
    }
    private void amount(String expected,String sql,Object... args){assertThat(db.queryForObject(sql,BigDecimal.class,args)).isEqualByComparingTo(expected);}
    private static BigDecimal n(String text){return new BigDecimal(text);}
}
