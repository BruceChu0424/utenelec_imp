package com.uten.imp.businesschain;

import com.uten.imp.application.port.InventoryValuationPort.*;
import com.uten.imp.application.port.InventoryPositionPort.*;
import com.uten.imp.application.port.InventoryProductionCostPort.*;
import com.uten.imp.audit.AuditDeviceContext;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.config.Jackson2ObjectMapperAutoConfiguration;
import com.uten.imp.config.props.CryptoProperties;
import com.uten.imp.features.finance.gl.InventoryCostPostingService;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.InventoryMutationLock;
import com.uten.imp.features.stock.valuation.*;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import com.uten.imp.testsupport.HistoricalJdbcNativeSql;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.support.TransactionTemplate;

import javax.sql.DataSource;
import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.time.YearMonth;
import java.util.*;
import java.util.function.Supplier;

/** Runs the real native inventory engines against the complete historical catalog.
 * Only original business inputs are inserted here. Value nodes, edges, returns,
 * revisions, allocation tasks, postings and GL are produced by their owners. */
final class HistoricalInventoryJdbc {
    final JdbcTemplate db;
    final FullChainEndToEndTest fixture;
    final FullChainEndToEndTest.World world;
    final InventoryValuationService values;
    final InventoryPositionService positions;
    final InventoryProductionCostService costs;
    final ProductionInventoryValueService material;
    final InventoryValueWorkService worker;
    private final InventoryMutationLock mutex;
    private final TransactionTemplate transactions;
    private final TxSessionVars session;
    private final DocNumberService numbers;
    private final InventoryCostPostingService gl;

    HistoricalInventoryJdbc(DataSource source,String tag) {
        db=new JdbcTemplate(source);
        var named=new NamedParameterJdbcTemplate(db);
        var statements=HistoricalJdbcNativeSql.statements(db);
        var manager=new DataSourceTransactionManager(source);transactions=new TransactionTemplate(manager);
        mutex=new InventoryMutationLock(statements);numbers=new DocNumberService(statements);
        fixture=new FullChainEndToEndTest();ReflectionTestUtils.setField(fixture,"jdbc",db);
        world=fixture.seedWorld(tag);fixture.seedChartOfAccounts();
        // This is the real isolated fixture account and its actual catalog, not
        // an application factory or an authorization substitute on a live host.
        var user=new AuthUser(world.superAdminUserId(),world.employeeId(),
                db.queryForObject("SELECT login_account FROM users WHERE id=?",String.class,world.superAdminUserId()),
                new HashSet<>(db.queryForList("SELECT code FROM permissions",String.class)),false,true,true);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user,null,user.getAuthorities()));
        var crypto=new CryptoProperties();crypto.setPgpMasterKey(FullChainEndToEndTest.SHARED_PGP_KEY);crypto.setHmacKey(FullChainEndToEndTest.SHARED_HMAC_KEY);
        session=new TxSessionVars(crypto,new SecurityContextCurrentUser(),new AuditDeviceContext(Jackson2ObjectMapperAutoConfiguration.domainObjectMapper()));
        ReflectionTestUtils.setField(session,"em",statements);
        var services=new org.springframework.beans.factory.support.StaticListableBeanFactory(Map.of("session",session));
        manager.addListener(new com.uten.imp.security.TransactionAuditActorBinder(services.getBeanProvider(TxSessionVars.class)));
        manager.addListener(new com.uten.imp.common.finance.BusinessPrecisionTransactionBinder(services.getBeanProvider(TxSessionVars.class)));
        values=new InventoryValuationService(named,mutex);
        positions=new InventoryPositionService(named,mutex,Optional.empty());
        costs=new InventoryProductionCostService(named,mutex,values);
        var support=new InventoryBusinessValueSupport(named);
        material=new ProductionInventoryValueService(named,positions,costs,mutex,support);
        var losses=new SubcontractLossValueService(named,positions,costs,mutex,support);
        var subcontract=new SubcontractOwnMaterialCostService(named,positions,costs,mutex,support,losses);subcontract.setValuePropagation(values);
        worker=new InventoryValueWorkService(values,costs,mutex,manager);worker.configureSourceRecalculations(named,support,material,subcontract);
        gl=new InventoryCostPostingService(statements,session,new SecurityContextCurrentUser(),new InventoryCostPostingQueryService(named));
    }

    <T>T transaction(Supplier<T> action) {return transactions.execute(status->{session.bind();return action.get();});}
    <T>T locked(Collection<PoolKey> pools,Supplier<T> action){return transaction(()->{
        mutex.lockAll(pools.stream().map(pool->new InventoryKey(pool.goodsId(),pool.colorId())).toList());return action.get();});}
    PoolKey pool(UUID goods,UUID color){return new PoolKey(world.warehouseId(),goods,color);}
    EventContext context(String type,UUID event,UUID document,UUID item){return new EventContext(event,type,document,item,1,
            world.superAdminUserId(),world.employeeId(),type+":"+event,OffsetDateTime.now());}
    record Document(UUID id,UUID item) {}
    record Receipt(Document document,MovementValue value) {}
    Receipt receipt(UUID goods,UUID color,String qty,String amount){
        PoolKey pool=pool(goods,color);return locked(List.of(pool),()->{
            BigDecimal source=new BigDecimal(amount);
            var document=stockDocument("OTHER_IN",DocNumberPrefix.STOCK_OTHER_IN,goods,color,new BigDecimal(qty),null,source);
            var context=context("STOCK_DOC",UUID.randomUUID(),document.id(),document.item());
            var result=values.receive(new Receive(context,UUID.randomUUID(),pool,new BigDecimal(qty),quantity(pool),source,true));
            physical(result,context,pool,new BigDecimal(qty),1,11);return new Receipt(document,result);
        });
    }
    private record Order(UUID id,UUID item) {}
    private Order order(UUID goods,BigDecimal quantity){
        UUID order=UUID.randomUUID(),orderItem=UUID.randomUUID();String orderNo=numbers.nextNumber(DocNumberPrefix.SALES_ORDER);
        BigDecimal amount=quantity.multiply(new BigDecimal("100"));
        db.update("INSERT INTO sales_orders(id,bill_no,bill_date,client_id,currency_id,status,total_original,total_local,created_by) VALUES(?,?,?,?,?,1,?,?,?)",
                order,orderNo,BusinessTime.today(),world.clientId(),world.currencyId(),amount,amount,world.superAdminUserId());
        db.update("""
                INSERT INTO sales_order_items(id,order_id,bill_no,bill_date,goods_id,unit_id,unit_rate,qty,price,amount_original,amount_local,
                  goods_code_snapshot,goods_name_snapshot,goods_snapshot_source,goods_snapshot_locked_at)
                SELECT ?,?,?,?,id,?,1,?,100,?,?,code,name,'MASTER_AT_APPROVAL',now() FROM goods WHERE id=?
                """,orderItem,order,orderNo,BusinessTime.today(),world.unitId(),quantity,amount,amount,goods);
        return new Order(order,orderItem);
    }
    UUID ship(UUID goods,String qty){return ship(goods,qty,null);}
    UUID ship(UUID goods,String qty,UUID originalOrderItem){PoolKey pool=pool(goods,null);return locked(List.of(pool),()->{
        UUID document=UUID.randomUUID(),item=UUID.randomUUID();String number=numbers.nextNumber(DocNumberPrefix.SALES_SHIPMENT);
        BigDecimal quantity=new BigDecimal(qty),amount=quantity.multiply(new BigDecimal("100"));UUID settlement=settlement();
        Order source=originalOrderItem==null?order(goods,quantity):new Order(db.queryForObject("SELECT order_id FROM sales_order_items WHERE id=?",UUID.class,originalOrderItem),originalOrderItem);
        UUID order=source.id(),orderItem=source.item();
        db.update("""
                INSERT INTO sales_shipments(id,bill_no,bill_date,client_id,warehouse_id,currency_id,source_order_id,settlement_method_id,
                  total_original,total_local,created_by,updated_by)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
                """,document,number,BusinessTime.today(),world.clientId(),world.warehouseId(),world.currencyId(),order,settlement,amount,amount,world.superAdminUserId(),world.superAdminUserId());
        db.update("""
                INSERT INTO sales_shipment_items(id,shipment_id,bill_no,bill_date,goods_id,unit_id,unit_rate,qty,order_item_id,price,amount_original,amount_local,
                  goods_code_snapshot,goods_name_snapshot,goods_snapshot_source,goods_snapshot_locked_at)
                SELECT ?,?,?,?,id,?,1,?,?,100,?,?,code,name,'MASTER_AT_APPROVAL',now() FROM goods WHERE id=?
                """,item,document,number,BusinessTime.today(),world.unitId(),quantity,orderItem,amount,amount,goods);
        approveShipmentInputs(document);
        var context=context("SALES_SHIPMENT",UUID.randomUUID(),document,item);
        var result=values.issue(new Issue(context,UUID.randomUUID(),pool,quantity,quantity(pool),Destination.COGS,item));
        physical(result,context,pool,quantity,-1,3);
        db.update("UPDATE sales_shipments SET status=1,warehouse_work_status='SHIPPED' WHERE id=?",document);
        return item;
    });}
    private UUID settlement(){return db.queryForObject("SELECT id FROM settlement_methods WHERE status='使用' AND NOT is_deleted ORDER BY code LIMIT 1",UUID.class);}
    private void approveShipmentInputs(UUID document){
        // Snapshot and hash use the real SQL owners. This isolated, newly
        // created client has no pre-existing receivable or prepayment inputs.
        if(db.queryForObject("SELECT count(*) FROM ar_ap_ledger WHERE client_id=?",Long.class,world.clientId())!=0)
            throw new IllegalStateException("Historical fixture client unexpectedly has existing finance facts");
        UUID submission=UUID.randomUUID(),claim=UUID.randomUUID(),decision=UUID.randomUUID();
        db.update("""
                INSERT INTO sales_shipment_submission_events(id,shipment_id,review_revision,content_hash,commercial_snapshot,actor_user_id,actor_employee_id,occurred_at)
                SELECT ?,id,review_revision,fn_customer_shipment_snapshot_hash(fn_customer_shipment_commercial_snapshot(id)),
                  fn_customer_shipment_commercial_snapshot(id)::jsonb,?,?,now() FROM sales_shipments WHERE id=?
                """,submission,world.superAdminUserId(),world.employeeId(),document);
        db.update("""
                UPDATE sales_shipments shipment SET sales_confirmed_revision=event.review_revision,sales_confirmed_at=event.occurred_at,sales_confirmed_by=event.actor_employee_id
                FROM sales_shipment_submission_events event WHERE event.id=? AND shipment.id=event.shipment_id
                """,submission);
        db.update("INSERT INTO task_claims(id,target_type,target_key,claimed_by,lease_until) VALUES(?,'SALES_SHIPMENT_FINANCE_AUDIT',?,?,clock_timestamp()+interval '30 minutes')",
                claim,document.toString(),world.employeeId());
        db.update("""
                INSERT INTO sales_shipment_finance_release_events(id,shipment_id,event_type,actor_user_id,occurred_at,client_id,client_name,currency_id,
                  settlement_method_id,shipment_total_original,formal_ar_outstanding_local,credit_floor_local,over_floor_local,
                  available_prepayment_original,available_prepayment_local,review_revision,claim_id,content_hash,commercial_snapshot,billing_mode,
                  exchange_rate,exchange_rate_source,actor_employee_id,actor_name_snapshot)
                SELECT ?,shipment.id,'RELEASED',?,now(),shipment.client_id,client.name,shipment.currency_id,shipment.settlement_method_id,
                  shipment.total_original,0,0,0,0,0,shipment.review_revision,?,event.content_hash,event.commercial_snapshot,shipment.billing_mode,
                  shipment.exchange_rate,'CURRENCY_MASTER',employee.id,employee.full_name
                FROM sales_shipments shipment JOIN clients client ON client.id=shipment.client_id
                JOIN sales_shipment_submission_events event ON event.shipment_id=shipment.id AND event.review_revision=shipment.review_revision
                CROSS JOIN employees employee WHERE shipment.id=? AND employee.id=?
                """,decision,world.superAdminUserId(),claim,document,world.employeeId());
        db.update("""
                UPDATE sales_shipments shipment SET finance_audit=1,finance_auditor_id=event.actor_user_id,finance_audited_at=event.occurred_at,
                  finance_release_event_id=event.id,finance_auditor_name_snapshot=event.actor_name_snapshot,handed_over_by=?,handed_over_at=now()
                FROM sales_shipment_finance_release_events event WHERE event.id=? AND shipment.id=event.shipment_id
                """,world.employeeId(),decision);
        db.update("""
                INSERT INTO sales_shipment_warehouse_events(shipment_id,from_status,to_status,actor_employee_id,occurred_at,warehouse_id,review_revision)
                SELECT id,'PENDING_PICK','SHIPPED',handed_over_by,handed_over_at,warehouse_id,review_revision FROM sales_shipments WHERE id=?
                """,document);
        db.update("UPDATE task_claims SET released_at=clock_timestamp(),release_reason='COMPLETED',released_by=? WHERE id=?",world.employeeId(),claim);
    }
    Document stockDocument(String type,DocNumberPrefix prefix,UUID goods,UUID color,BigDecimal qty,UUID segment){
        return stockDocument(type,prefix,goods,color,qty,segment,null);
    }
    private Document stockDocument(String type,DocNumberPrefix prefix,UUID goods,UUID color,BigDecimal qty,UUID segment,BigDecimal amount){
        return stockDocument(type,prefix,goods,color,qty,segment,amount,null,null,null,null);
    }
    private Document stockDocument(String type,DocNumberPrefix prefix,UUID goods,UUID color,BigDecimal qty,UUID segment,BigDecimal amount,
                                   UUID report,UUID reportItem,UUID allocation,String place){
        UUID document=UUID.randomUUID(),item=UUID.randomUUID();String number=numbers.nextNumber(prefix);
        db.update("""
                INSERT INTO stock_documents(id,doc_type,bill_no,bill_date,warehouse_id,status,total_original,total_local,created_by,updated_by,source_daily_report_id)
                VALUES(?,?,?,?,?,?, ?,?,?,?,?)
                """,document,type,number,BusinessTime.today(),world.warehouseId(),"FINISHED_IN".equals(type)?0:1,
                amount==null?BigDecimal.ZERO:amount,amount==null?BigDecimal.ZERO:amount,world.superAdminUserId(),world.superAdminUserId(),report);
        db.update("""
                INSERT INTO stock_document_items(id,doc_id,bill_type,bill_no,bill_date,goods_id,color_id,unit_id,unit_rate,qty,base_qty,
                  execution_segment_id,upstream_item_id,amount_original,amount_local,source_daily_report_item_id,reported_qty,place,execution_segment_sales_allocation_id,
                  goods_code_snapshot,goods_name_snapshot,goods_snapshot_source,goods_snapshot_locked_at,created_by,updated_by)
                SELECT ?,?,?,?, ?,id,?,?,1,?,?,?,?,?,?,?,?,?,?,code,name,'MASTER_AT_APPROVAL',now(),?,? FROM goods WHERE id=?
                """,item,document,type,number,BusinessTime.today(),color,world.unitId(),qty,qty,segment,
                segment==null?null:db.queryForObject("SELECT source_plan_item_id FROM production_execution_segments WHERE id=?",UUID.class,segment),amount,amount,
                reportItem,reportItem==null?null:qty,place,allocation,world.superAdminUserId(),world.superAdminUserId(),goods);
        return new Document(document,item);
    }
    void physical(MovementValue result,EventContext context,PoolKey pool,BigDecimal qty,int direction,int type){
        if(result.replayed())return;
        db.update("""
                INSERT INTO stock_movements(id,transaction_date,movement_type,source_doc_type,source_doc_id,source_item_id,
                  goods_id,color_id,warehouse_id,direction,unit_id,unit_rate,qty,amount_local,created_by)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,1,?,?,?)
                """,result.movementId(),context.occurredAt(),type,context.sourceDocType(),context.sourceDocId(),context.sourceItemId(),
                pool.goodsId(),pool.colorId(),pool.warehouseId(),direction,world.unitId(),qty,result.knownValueLocal(),world.superAdminUserId());
        db.update("""
                INSERT INTO stock_balances(warehouse_id,goods_id,color_id,qty,amount_local) VALUES(?,?,?,?,?)
                ON CONFLICT(warehouse_id,goods_id,color_id) DO UPDATE SET qty=stock_balances.qty+excluded.qty,
                  amount_local=stock_balances.amount_local+excluded.amount_local
                """,pool.warehouseId(),pool.goodsId(),pool.colorId(),qty.multiply(BigDecimal.valueOf(direction)),result.knownValueLocal().multiply(BigDecimal.valueOf(direction)));
    }
    BigDecimal quantity(PoolKey pool){var rows=db.queryForList("SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=? AND color_id IS NOT DISTINCT FROM ?",BigDecimal.class,pool.warehouseId(),pool.goodsId(),pool.colorId());return rows.isEmpty()?BigDecimal.ZERO:rows.getFirst();}
    void enableGl(String reason){transaction(()->{var policy=gl.policy();return gl.configure(new InventoryCostPostingService.PolicyChange(true,BusinessTime.today().withDayOfMonth(1),reason,policy.version()));});}
    void postGl(){transaction(()->gl.post(YearMonth.from(BusinessTime.today()).toString()));}
    void drain(){for(int batch=0;batch<200;batch++){if(!worker.hasPendingWork())return;worker.runBatch();}throw new AssertionError("Historical real inventory worker did not drain");}

    UUID produceA(){
        List<PoolKey> pools=List.of(pool(world.goodsA(),null),pool(world.goodsB(),null),pool(world.goodsE(),null));
        UUID segment=locked(pools,()->{
            UUID plan=UUID.randomUUID(),item=UUID.randomUUID(),pack=UUID.randomUUID(),scope=UUID.randomUUID(),orderLink=UUID.randomUUID(),allocation=UUID.randomUUID(),report=UUID.randomUUID();
            Order sales=order(world.goodsA(),new BigDecimal("3"));
            // Existing JDBC-only world preparation owns the real DEPT_PROD
            // child workshop and its active responsible employee.
            Object assignment=ReflectionTestUtils.invokeMethod(fixture,"productionAssignment","old-scope-"+scope);
            UUID workshop=(UUID)ReflectionTestUtils.getField(assignment,"workshopId"),worker=(UUID)ReflectionTestUtils.getField(assignment,"workerId");
            String number=numbers.nextNumber(DocNumberPrefix.PRODUCTION_PLAN);
            String fingerprint=db.queryForObject("SELECT encode(digest(jsonb_agg(to_jsonb(bom) ORDER BY bom.id)::text,'sha256'),'hex') FROM goods_bom_items bom WHERE goods_id=?",String.class,world.goodsA());
            db.update("INSERT INTO production_plans(id,bill_no,bill_date,status,department_id,created_by,approver_id,approved_at) VALUES(?,?,?,1,?,?,?,now())",
                    plan,number,BusinessTime.today(),world.departmentId(),world.superAdminUserId(),world.employeeId());
            db.update("""
                    INSERT INTO production_plan_items(id,plan_id,bill_no,bill_date,product_no,goods_id,unit_id,unit_rate,qty,allowed_overproduction_rate,sales_order_item_id)
                    SELECT ?,?,?,?,?,id,?,1,3,0.10,? FROM goods WHERE id=?
                    """,item,plan,number,BusinessTime.today(),new com.uten.imp.features.production.plan.ProductionProductNoAllocator(db).allocate(plan,Set.of()),world.unitId(),sales.item(),world.goodsA());
            db.update("INSERT INTO plan_order_item_links(id,plan_item_id,order_item_id,allocated_qty,created_by) VALUES(?,?,?,3,?)",orderLink,item,sales.item(),world.superAdminUserId());
            db.update("""
                    INSERT INTO production_planning_packages(id,plan_id,warehouse_id,idempotency_key,request_hash,preview_fingerprint,execution_model_version,created_by)
                    VALUES(?,?,?,?,?,?,1,?)
                    """,pack,plan,world.warehouseId(),"old-package:"+pack,fingerprint,fingerprint,world.superAdminUserId());
            db.update("""
                    INSERT INTO production_execution_segments(id,package_id,plan_id,source_plan_item_id,segment_no,segment_code,client_segment_key,
                      product_goods_id,product_unit_id,product_unit_rate,planned_qty,status,bom_fingerprint,idempotency_key,created_by,
                      workshop_department_id,responsible_employee_id,plan_begin_date,plan_end_date)
                    VALUES(?,?,?,?,1,?,?,?, ?,1,3,'READY',?,?,?, ?,?,?,?)
                    """,scope,pack,plan,item,new com.uten.imp.common.mastercode.MasterCodeService(HistoricalJdbcNativeSql.statements(db)).nextCode(
                            com.uten.imp.common.mastercode.MasterCodePrefix.PRODUCTION_EXECUTION_SEGMENT),"old-client:"+scope,
                    world.goodsA(),world.unitId(),fingerprint,"old-execution:"+scope,world.superAdminUserId(),
                    workshop,worker,BusinessTime.today(),BusinessTime.today());
            db.update("INSERT INTO execution_segment_sales_allocations(id,execution_segment_id,plan_order_item_link_id,sales_order_item_id,allocated_qty,created_by) VALUES(?,?,?,?,3,?)",allocation,scope,orderLink,sales.item(),world.superAdminUserId());
            String reportNo=numbers.nextNumber(DocNumberPrefix.PRODUCTION_DAILY_REPORT);
            db.update("""
                    INSERT INTO production_daily_reports(id,bill_no,bill_date,warehouse_id,department_id,worker_id,maker_id,approver_id,status,created_by)
                    VALUES(?,?,?,?,?,?,?,?,0,?)
                    """,report,reportNo,BusinessTime.today(),world.warehouseId(),workshop,worker,world.employeeId(),world.employeeId(),world.superAdminUserId());
            db.update("INSERT INTO production_daily_report_workers(report_id,employee_id,sort_order) VALUES(?,?,1)",report,worker);
            var inputs=new ArrayList<Input>();
            for(var spec:List.of(Map.entry(world.goodsB(),new BigDecimal("6")),Map.entry(world.goodsE(),new BigDecimal("3")))){
                UUID goods=spec.getKey(),demand=UUID.randomUUID(),reservation=UUID.randomUUID(),issue=UUID.randomUUID(),event=UUID.randomUUID();BigDecimal qty=spec.getValue();PoolKey pool=pool(goods,null);
                String route=switch(db.queryForObject("SELECT source_type FROM goods WHERE id=?",String.class,goods)){case "自制"->"MAKE";case "采购"->"BUY";case "委外"->"SUBCONTRACT";default->throw new IllegalStateException("Unknown historical fixture source");};
                db.update("""
                        INSERT INTO production_material_demands(id,package_id,plan_id,warehouse_id,goods_id,unit_id,required_qty,supply_route,idempotency_key,
                          execution_segment_id,source_plan_item_id,per_product_qty,created_by)
                        VALUES(?,?,?,?,?, ?,?,?, ?,?,?,?,?)
                        """,demand,pack,plan,world.warehouseId(),goods,world.unitId(),qty,route,"old-demand:"+demand,scope,item,qty.divide(new BigDecimal("3")),world.superAdminUserId());
                UUID balance=db.queryForObject("SELECT id FROM stock_balances WHERE warehouse_id=? AND goods_id=? AND color_id IS NULL",UUID.class,world.warehouseId(),goods);
                db.update("""
                        INSERT INTO stock_reservations(id,goods_id,warehouse_id,qty,owner_type,owner_id,purpose,demand_id,supply_type,supply_id,idempotency_key)
                        VALUES(?,?,?,?,'PRODUCTION_MATERIAL_DEMAND',?,'PRODUCTION_MATERIAL',?,'STOCK_BALANCE',?,?)
                        """,reservation,goods,world.warehouseId(),qty,demand,demand,balance,"old-reservation:"+reservation);
                var draw=stockDocument("DRAW",DocNumberPrefix.STOCK_DRAW,goods,null,qty,null);
                db.update("""
                        INSERT INTO production_planning_package_documents(package_id,document_type,document_id,document_no,execution_segment_id,created_by)
                        SELECT ?,'DRAW',id,bill_no,?,? FROM stock_documents WHERE id=?
                        """,pack,scope,world.superAdminUserId(),draw.id());
                db.update("""
                        INSERT INTO production_planning_package_document_items(package_id,demand_id,document_type,document_id,document_item_id,created_by)
                        VALUES(?,?,'DRAW',?,?,?)
                        """,pack,demand,draw.id(),draw.item(),world.superAdminUserId());
                db.update("INSERT INTO production_material_stock_events(id,stock_document_id,event_type,idempotency_key,request_hash,created_by) VALUES(?,?,'ISSUE',?,?,?)",
                        event,draw.id(),"old-issue:"+event,fingerprint,world.superAdminUserId());
                db.update("""
                        INSERT INTO production_material_stock_postings(id,event_id,stock_document_item_id,demand_id,reservation_id,posting_type,qty_base,created_by)
                        VALUES(?,?,?,?,?,'ISSUE',?,?)
                        """,issue,event,draw.item(),demand,reservation,qty,world.superAdminUserId());
                db.queryForObject("SELECT fn_stock_claim_consume(?,?,?,?,?)",Object.class,reservation,world.warehouseId(),qty,draw.id(),draw.item());
                var context=context("STOCK_DOC",event,draw.id(),draw.item());
                var issued=values.issue(new Issue(context,UUID.randomUUID(),pool,qty,quantity(pool),Destination.WIP,issue));
                physical(issued,context,pool,qty,-1,5);
                db.update("INSERT INTO production_material_movement_links(event_id,document_item_id,movement_id,created_by) VALUES(?,?,?,?)",event,draw.item(),issued.movementId(),world.superAdminUserId());
                db.update("UPDATE stock_reservations SET consumed_qty=qty,status=1 WHERE id=?",reservation);
                UUID settled=UUID.randomUUID(),posting=UUID.randomUUID();
                db.update("INSERT INTO production_material_settlement_events(id,plan_id,event_type,idempotency_key,request_hash,created_by,daily_report_id) VALUES(?,?,'POST',?,?,?,?)",
                        settled,plan,"old-consumed:"+settled,fingerprint,world.superAdminUserId(),report);
                db.update("INSERT INTO production_material_settlement_postings(id,event_id,demand_id,settlement_type,qty_base,issue_posting_id,created_by) VALUES(?,?,?,'CONSUMED',?,?,?)",
                        posting,settled,demand,qty,issue,world.superAdminUserId());
                // The real material adapter creates the COST_WIP position and
                // original settlement event lineage from the approved facts.
                material.settled(settled,world.superAdminUserId());
                UUID consumed=db.queryForObject("SELECT result_node_id FROM stock_value_events WHERE source_event_id=? AND source_doc_type='PRODUCTION_CONSUMED_VALUE'",UUID.class,posting);
                inputs.add(new Input(consumed,posting,InputKind.CONSUMED));
            }
            var finished=qualifiedFinishedInput(scope,report);
            var context=context("STOCK_DOC",UUID.randomUUID(),finished.id(),finished.item());
            PoolKey product=pool(world.goodsA(),null);
            var output=values.receive(new Receive(context,UUID.randomUUID(),product,new BigDecimal("3"),quantity(product),BigDecimal.ZERO,false));
            physical(output,context,product,new BigDecimal("3"),1,13);
            costs.revise(new Revision(context("PRODUCTION_COST_BUSINESS",output.movementId(),scope,inputs.getFirst().approvedPostingId()),scope,product,0,new BigDecimal("3"),true,
                    scope,fingerprint,inputs,List.of(new Output(output.valueNodeId(),output.movementId()))));
            db.update("UPDATE stock_documents SET status=1 WHERE id=?",finished.id());
            db.update("""
                    UPDATE plan_order_item_links link SET inbound_qty=(SELECT coalesce(sum(item.qty),0)
                      FROM stock_document_items item JOIN stock_documents document ON document.id=item.doc_id
                      JOIN execution_segment_sales_allocations allocation ON allocation.id=item.execution_segment_sales_allocation_id
                      WHERE allocation.plan_order_item_link_id=link.id AND document.doc_type='FINISHED_IN' AND document.status=1
                        AND NOT document.is_deleted AND NOT item.is_deleted)
                    WHERE link.id=?
                    """,orderLink);
            UUID confirmation=UUID.randomUUID();
            db.update("""
                    INSERT INTO production_finished_in_confirmations(id,stock_document_id,decision,idempotency_key,request_hash,confirmed_by_employee_id,created_by)
                    VALUES(?,?,'ACCEPTED',?,?,?,?)
                    """,confirmation,finished.id(),"old-count:"+confirmation,fingerprint,world.employeeId(),world.superAdminUserId());
            db.update("""
                    INSERT INTO production_finished_in_confirmation_items(confirmation_id,stock_document_item_id,reported_qty,accepted_qty,residual_qty,created_by)
                    VALUES(?,?,3,3,0,?)
                    """,confirmation,finished.item(),world.superAdminUserId());
            return scope;
        });
        drain();return segment;
    }
    void reverseConsumption(UUID posting,String quantity){
        var source=db.queryForMap("SELECT p.*,d.plan_id,d.goods_id,d.execution_segment_id FROM production_material_settlement_postings p JOIN production_material_demands d ON d.id=p.demand_id WHERE p.id=?",posting);
        locked(List.of(pool((UUID)source.get("goods_id"),null),pool(world.goodsA(),null)),()->{
            UUID event=UUID.randomUUID();String hash=db.queryForObject("SELECT encode(digest(?,'sha256'),'hex')",String.class,"old-return:"+event);
            db.update("INSERT INTO production_material_settlement_events(id,plan_id,event_type,idempotency_key,request_hash,created_by) VALUES(?,?,'REVERSE',?,?,?)",
                    event,source.get("plan_id"),"old-return:"+event,hash,world.superAdminUserId());
            // Same source-bound reopen protocol as the settlement adapter;
            // its real REVERSE event exists before any completed scope changes.
            for(var segment:db.queryForList("SELECT id,lock_version FROM production_execution_segments WHERE id=? AND status='COMPLETED' FOR UPDATE",source.get("execution_segment_id"))){
                long version=((Number)segment.get("lock_version")).longValue();
                db.queryForObject("SELECT set_config('app.production_completion_reopen_settlement_id',?,true)",String.class,event.toString());
                db.update("""
                        INSERT INTO production_execution_segment_events(execution_segment_id,action,idempotency_key,request_hash,expected_version,resulting_version,created_by)
                        VALUES(?,'REOPEN_COMPLETION',?,?,?,?,?)
                        """,segment.get("id"),"MATERIAL_SETTLEMENT_REVERSE:"+event,hash,version,version+1,world.superAdminUserId());
                if(db.update("UPDATE production_execution_segments SET status='IN_PROGRESS',completion_reopened=true WHERE id=? AND lock_version=? AND status='COMPLETED'",segment.get("id"),version)!=1)
                    throw new IllegalStateException("Historical actual settlement scope changed");
            }
            db.update("INSERT INTO production_material_settlement_postings(event_id,demand_id,settlement_type,qty_base,source_posting_id,issue_posting_id,created_by) VALUES(?,?,'CONSUMED',?,?,?,?)",
                    event,source.get("demand_id"),new BigDecimal(quantity),posting,source.get("issue_posting_id"),world.superAdminUserId());
            material.settled(event,world.superAdminUserId());return null;
        });drain();
    }

    private Document qualifiedFinishedInput(UUID scope,UUID report){
        var execution=db.queryForMap("SELECT segment.plan_id,segment.source_plan_item_id,segment.workshop_department_id,segment.responsible_employee_id,allocation.id AS allocation_id,allocation.sales_order_item_id,allocation.plan_order_item_link_id FROM production_execution_segments segment JOIN execution_segment_sales_allocations allocation ON allocation.execution_segment_id=segment.id WHERE segment.id=?",scope);
        db.update("UPDATE production_execution_segments SET status='DISPATCHED' WHERE id=?",scope);
        db.update("UPDATE production_execution_segments SET status='IN_PROGRESS' WHERE id=?",scope);
        UUID line=UUID.randomUUID(),registration=UUID.randomUUID(),inspection=UUID.randomUUID(),decision=UUID.randomUUID(),release=UUID.randomUUID();
        String number=db.queryForObject("SELECT bill_no FROM production_daily_reports WHERE id=?",String.class,report);
        String hash=db.queryForObject("SELECT encode(digest(jsonb_build_object('report',?::uuid,'scope',?::uuid,'qty',3)::text,'sha256'),'hex')",String.class,report,scope);
        db.update("""
                INSERT INTO production_daily_report_items(id,report_id,bill_no,bill_date,goods_id,unit_id,unit_rate,qty,
                  plan_item_id,execution_segment_id,execution_segment_sales_allocation_id,sales_order_item_id,is_public_output,output_batch_id,output_batch_qty,created_by)
                VALUES(?,?,?,?,?,?,1,3,?,?,?,?,false,?,3,?)
                """,line,report,number,BusinessTime.today(),world.goodsA(),world.unitId(),execution.get("source_plan_item_id"),scope,execution.get("allocation_id"),execution.get("sales_order_item_id"),UUID.randomUUID(),world.superAdminUserId());
        db.update("UPDATE production_daily_reports SET status=1,row_version=row_version+1 WHERE id=?",report);
        db.update("""
                UPDATE plan_order_item_links link SET produced_qty=(SELECT coalesce(sum(item.qty),0)
                  FROM production_daily_report_items item JOIN production_daily_reports report ON report.id=item.report_id
                  JOIN execution_segment_sales_allocations allocation ON allocation.id=item.execution_segment_sales_allocation_id
                  WHERE allocation.plan_order_item_link_id=link.id AND report.status=1 AND NOT report.is_deleted AND NOT item.is_deleted)
                WHERE link.id=?
                """,execution.get("plan_order_item_link_id"));
        db.update("""
                INSERT INTO production_finished_arrival_registrations(id,source_report_id,warehouse_id,warehouse_code_snapshot,warehouse_name_snapshot,
                  receiver_employee_id,receiver_name_snapshot,idempotency_key,request_hash,created_by)
                SELECT ?,?,?,warehouse.code,warehouse.name,employee.id,employee.full_name,?,?,?
                FROM warehouses warehouse CROSS JOIN employees employee WHERE warehouse.id=? AND employee.id=?
                """,registration,report,world.warehouseId(),"old-arrival:"+registration,hash,world.superAdminUserId(),world.warehouseId(),world.employeeId());
        db.update("INSERT INTO production_finished_arrival_registration_items(registration_id,source_report_item_id,place_snapshot,counted_qty,created_by) VALUES(?,?,'HISTORICAL-CI',3,?)",
                registration,line,world.superAdminUserId());
        db.update("""
                INSERT INTO production_fqc_inspections(id,source_report_id,source_report_item_id,source_plan_item_id,execution_segment_id,execution_segment_sales_allocation_id,
                  warehouse_id,goods_id,unit_id,unit_rate,reported_qty,report_maker_id,created_by)
                VALUES(?,?,?,?,?,?,?,?, ?,1,3,?,?)
                """,inspection,report,line,execution.get("source_plan_item_id"),scope,execution.get("allocation_id"),world.warehouseId(),world.goodsA(),world.unitId(),world.employeeId(),world.superAdminUserId());
        // The real decision trigger derives the inspection projection. No
        // exemption or direct status/amount/pending update is used.
        db.update("""
                INSERT INTO production_fqc_decision_events(id,inspection_id,decision,pass_qty,fail_qty,idempotency_key,request_hash,decided_by_employee_id,created_by)
                VALUES(?,?,'PASS',3,0,?,?,?,?)
                """,decision,inspection,"old-quality:"+decision,hash,world.employeeId(),world.superAdminUserId());
        var finished=stockDocument("FINISHED_IN",DocNumberPrefix.STOCK_FINISHED_IN,world.goodsA(),null,new BigDecimal("3"),scope,null,report,line,(UUID)execution.get("allocation_id"),"HISTORICAL-CI");
        db.update("INSERT INTO plan_draw_links(plan_id,draw_id,created_by) VALUES(?,?,?)",execution.get("plan_id"),finished.id(),world.superAdminUserId());
        db.update("""
                INSERT INTO production_fqc_release_commands(id,inspection_id,source_report_item_id,stock_document_item_id,requested_qty,idempotency_key,request_hash,created_by)
                VALUES(?,?,?,?,3,?,?,?)
                """,release,inspection,line,finished.item(),"old-release:"+release,hash,world.superAdminUserId());
        db.update("INSERT INTO production_fqc_release_allocations(release_command_id,inspection_id,decision_event_id,qty,created_by) VALUES(?,?,?,3,?)",
                release,inspection,decision,world.superAdminUserId());
        return finished;
    }

    record SubcontractIssue(UUID parent,UUID material,UUID orderItem,UUID item,UUID document) {}
    SubcontractIssue subcontractIssue(){
        UUID parent=world.goodsE(),material=world.goodsD();fixture.insertBom(parent,material,"1");
        receipt(material,null,"10","100");PoolKey pool=pool(material,null);
        return locked(List.of(pool),()->{
            UUID order=UUID.randomUUID(),orderItem=UUID.randomUUID(),plan=UUID.randomUUID(),planItem=UUID.randomUUID(),issue=UUID.randomUUID(),item=UUID.randomUUID();
            String orderNo=numbers.nextNumber(DocNumberPrefix.SUB_ORDER),issueNo=numbers.nextNumber(DocNumberPrefix.SUB_MATERIAL_ISSUE);
            db.update("""
                    INSERT INTO subcontract_orders(id,bill_no,bill_date,supplier_id,warehouse_id,currency_id,settlement_method_id,deliver_date,total_original,total_local,status,created_by,updated_by)
                    VALUES(?,?,?,?,?,?,?, ?,500,500,1,?,?)
                    """,order,orderNo,BusinessTime.today(),world.supplierId(),world.warehouseId(),world.currencyId(),settlement(),BusinessTime.today().plusDays(5),world.superAdminUserId(),world.superAdminUserId());
            db.update("""
                    INSERT INTO subcontract_order_items(id,order_id,bill_no,bill_date,goods_id,unit_id,unit_rate,qty,price,amount_original,amount_local,
                      goods_code_snapshot,goods_name_snapshot,goods_snapshot_source,goods_snapshot_locked_at)
                    SELECT ?,?,?,?,id,?,1,10,50,500,500,code,name,'MASTER_AT_APPROVAL',now() FROM goods WHERE id=?
                    """,orderItem,order,orderNo,BusinessTime.today(),world.unitId(),parent);
            db.update("INSERT INTO subcontract_material_plans(id,order_id,order_bill_no,supplier_id,created_by) VALUES(?,?,?,?,?)",
                    plan,order,orderNo,world.supplierId(),world.superAdminUserId());
            db.update("""
                    INSERT INTO subcontract_material_plan_items(id,plan_id,order_item_id,parent_goods_id,goods_id,unit_id,
                      unit_rate,bom_unit_qty,base_bom_unit_qty,planned_qty,issued_qty,created_by)
                    VALUES(?,?,?,?,?,?,1,1,1,10,0,?)
                    """,planItem,plan,orderItem,parent,material,world.unitId(),world.superAdminUserId());
            db.update("""
                    INSERT INTO subcontract_material_issues(id,bill_no,bill_date,supplier_id,warehouse_id,status,created_by,updated_by)
                    VALUES(?,?,?,?,?,0,?,?)
                    """,issue,issueNo,BusinessTime.today(),world.supplierId(),world.warehouseId(),world.superAdminUserId(),world.superAdminUserId());
            db.update("""
                    INSERT INTO subcontract_material_issue_items(id,issue_id,bill_no,bill_date,goods_id,unit_id,unit_rate,qty,order_item_id,
                      parent_goods_id,plan_item_id,at_supplier_qty,frozen_unit_qty,requested_qty,
                      goods_code_snapshot,goods_name_snapshot,goods_snapshot_source,goods_snapshot_locked_at)
                    SELECT ?,?,?,?,id,?,1,10,?,?,?,0,1,10,code,name,'MASTER_AT_APPROVAL',now() FROM goods WHERE id=?
                    """,item,issue,issueNo,BusinessTime.today(),world.unitId(),orderItem,parent,planItem,material);
            UUID reservation=UUID.randomUUID();UUID balance=db.queryForObject("SELECT id FROM stock_balances WHERE warehouse_id=? AND goods_id=? AND color_id IS NULL",UUID.class,world.warehouseId(),material);
            db.update("""
                    INSERT INTO stock_reservations(id,goods_id,warehouse_id,qty,source_doc_type,source_doc_id,owner_type,owner_id,purpose,
                      supply_type,supply_id,idempotency_key,created_by,updated_by)
                    VALUES(?,?,?,10,'SUBCONTRACT_OUTBOUND_DRAFT',?,'SUBCONTRACT_OUTBOUND',?,'SUBCONTRACT_OUTBOUND','STOCK_BALANCE',?,?,?,?)
                    """,reservation,material,world.warehouseId(),issue,planItem,balance,"old-sub-reservation:"+reservation,world.superAdminUserId(),world.superAdminUserId());
            db.queryForObject("SELECT fn_stock_claim_consume(?,?,?,?,?)",Object.class,reservation,world.warehouseId(),new BigDecimal("10"),issue,item);
            db.update("UPDATE stock_reservations SET consumed_qty=qty,status=1 WHERE id=?",reservation);
            db.update("""
                    INSERT INTO subcontract_outbound_issue_reservation_allocations(issue_id,issue_item_id,plan_item_id,reservation_id,allocated_qty,idempotency_key,created_by)
                    VALUES(?,?,?,?,10,?,?)
                    """,issue,item,planItem,reservation,"old-sub-allocation:"+reservation,world.superAdminUserId());
            var context=context("SUBCONTRACT_MATERIAL_ISSUE",UUID.randomUUID(),issue,item);
            var result=values.issue(new Issue(context,UUID.randomUUID(),pool,new BigDecimal("10"),quantity(pool),Destination.SUBCONTRACT_WIP,item));
            physical(result,context,pool,new BigDecimal("10"),-1,15);
            db.update("UPDATE subcontract_material_issue_items SET at_supplier_qty=qty WHERE id=?",item);
            db.update("UPDATE subcontract_material_issues SET status=1 WHERE id=?",issue);
            db.update("""
                    UPDATE subcontract_material_plan_items plan SET issued_qty=(SELECT coalesce(sum(line.qty),0)
                      FROM subcontract_material_issue_items line JOIN subcontract_material_issues issue ON issue.id=line.issue_id
                      WHERE line.plan_item_id=plan.id AND issue.status=1 AND NOT issue.is_deleted AND NOT line.is_deleted)
                    WHERE plan.id=?
                    """,planItem);
            return new SubcontractIssue(parent,material,orderItem,item,issue);
        });
    }
}
