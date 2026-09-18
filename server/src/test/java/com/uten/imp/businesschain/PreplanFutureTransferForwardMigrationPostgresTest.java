package com.uten.imp.businesschain;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Upgrade real V569-shaped facts without rewriting history or disabling a guard. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class PreplanFutureTransferForwardMigrationPostgresTest {
    @Test void oldCancellationKeepsItsWholeRestorationAndNewWritesRequireAnExplicitSplit() {
        try(var postgres=new PostgreSQLContainer<>("postgres:16-alpine")) {
            postgres.start();
            var config=Flyway.configure().dataSource(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword())
                    .locations("classpath:db/migration");
            config.target("569").load().migrate();
            var dataSource=new DriverManagerDataSource(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword());
            var db=new JdbcTemplate(dataSource);var tx=new TransactionTemplate(new DataSourceTransactionManager(dataSource));
            assertEquals(1405930679,db.queryForObject("SELECT checksum FROM flyway_schema_history WHERE version='569'",Integer.class));
            var fixture=new FullChainEndToEndTest();ReflectionTestUtils.setField(fixture,"jdbc",db);
            var w=fixture.seedWorld("v571-history");
            var state=tx.execute(status->seedOldFacts(db,w));
            assertNotNull(state);
            String originalCancel=db.queryForObject("SELECT to_jsonb(c)::text FROM preplan_future_supply_transfer_cancellations c WHERE id=?",String.class,state.cancel());
            String originalTransfer=db.queryForObject("SELECT to_jsonb(t)::text FROM preplan_future_supply_transfers t WHERE id=?",String.class,state.transfer());
            String originalAudit=audit(db,state);
            assertNotEquals("[]",originalAudit);
            qty(db,"75.5","SELECT fn_preplan_allocation_admitted_qty(?)",state.sourceAllocation());
            qty(db,"24.5","SELECT fn_preplan_allocation_admitted_qty(?)",state.targetAllocation());
            assertEquals(1,db.queryForObject("SELECT count(*) FROM preplan_future_supply_transfer_cancellations",Integer.class));

            var upgrade=Flyway.configure().dataSource(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword())
                    .locations("classpath:db/migration").load().migrate();
            // 从 V569 升到当前目录头应当只跑 V569 之后的迁移，且都不触碰本测试的事实行：
            // V570 售价查看权限、V571 在途前向兼容、V572 审计触发器 sweep、
            // V573 原因可选、V574 跨路线在途调入、V575 货品订货策略、
            // V577 下达车间超量的公共备货产出分账(只给计划关联行加列改触发器)、
            // V578 出货财审「撤回退回」事件类型、V579 客户/供应商联系方式·地址·
            // 跟进记录三张子表 + clients.credit_score、V580 放宽计划关联行对账、
            // V581 委外「单一叶子子件」直接发料出仓(只扩 flow_mode 白名单与
            // 四个既有守卫)、V582 销售出货仓库一步确认出库(收窄作业状态取值、
            // 重建 V566 实仓取证触发器与待办索引)、V583 报工同页登记实际用料
            //(新增日报实耗表 + 日报收尾退仓意愿列 + 结算事件日报来源列)、
            // V584 车间直送(线边仓标记 + 报工行产出去向 + 直送三张表 +
            // FQC 检验种类与来源守卫分流)。
            // 新增迁移时这个数字要 +1(与 ops 白名单、MigrationRehearsalSupport、
            // 迁移 README 同属「迁移头四处同步」的连带项)。
            // V585 报工行接收需求列 + 车间直送审核权限码、
            // V586 把 V583/V584 的四张表补登记进清库策略、
            // V587 货品主档加「所属仓库」一列(只加列，不建表不改行)、
            // V588 放宽销售分摊守卫(顶层超量一张计划，只改函数定义)、
            // V589 委外前置自制跟量(放宽公共备货形态守卫与批次 allocation 锚)。
            // V590 货品归属单一事实源(偏好表废弃删除)、V591 存量归属回填、
            // V592 客户默认销售条款、V593 采购/委外主档默认值。
            // V594 日报审核补链放行(只 CREATE OR REPLACE 只增不改守卫函数)、
            // V595 车间直送 v2(持续生产/直送供给两列 + 四函数 + 两索引)、
            // V598 货品来源按路线确认历史回填(只 UPDATE goods.source_type 一列)。
            // (V596 / V597 由并行分支 feat/iqc-stock-in-before-inspection 占号，
            //  不在本树目录里；合并后此处每多一个迁移 +1。)
            //
            // 改这个数之前先确认 target/classes/db/migration 里没有改名前的残留
            // 文件：Flyway 读的是 classpath 而不是 src，`mvn compile` 不会删掉已
            // 被重命名/删除的旧资源，残留一个就凭空多算一条(本轮踩过一次)。
            // V596 到货先入库后质检、V597 产成品先入库后质检(都只加列/守卫/权限码，不加表)、
            // V599 开工路线确认与到货进展通知(段两列+三函数+事件白名单，不加表)、
            // V600 庆典自动发送默认关(只 UPDATE system_settings 一行)。
            // 改这个数之前先确认 server/target/classes/db/migration 没有改名残留的孤儿文件。
            assertEquals(30,upgrade.migrationsExecuted);
            assertEquals(1405930679,db.queryForObject("SELECT checksum FROM flyway_schema_history WHERE version='569'",Integer.class));
            assertEquals(originalCancel,db.queryForObject("SELECT (to_jsonb(c)-'restore_to_source_qty'-'public_release_qty')::text FROM preplan_future_supply_transfer_cancellations c WHERE id=?",String.class,state.cancel()));
            assertEquals(originalTransfer,db.queryForObject("SELECT to_jsonb(t)::text FROM preplan_future_supply_transfers t WHERE id=?",String.class,state.transfer()));
            assertEquals(originalAudit,audit(db,state));
            assertTrue(db.queryForObject("SELECT restore_to_source_qty IS NULL AND public_release_qty IS NULL FROM preplan_future_supply_transfer_cancellations WHERE id=?",Boolean.class,state.cancel()));
            qty(db,"15.5","SELECT fn_preplan_future_transfer_restored_qty(?)",state.transfer());
            qty(db,"75.5","SELECT fn_preplan_allocation_admitted_qty(?)",state.sourceAllocation());
            qty(db,"24.5","SELECT fn_preplan_allocation_admitted_qty(?)",state.targetAllocation());
            qty(db,"0","SELECT fn_preplan_future_public_release_qty(?,?)",state.sourceAction(),state.externalItem());

            assertThrows(org.springframework.dao.DataAccessException.class,()->tx.execute(status->{
                actor(db,w.superAdminUserId());
                db.update("INSERT INTO preplan_future_supply_transfer_cancellations(transfer_id,qty,reason,idempotency_key,request_hash,created_by) VALUES(?,1,'旧格式不能写新记录',? ,?,?)",state.transfer(),"v571-null-"+state.transfer(),"c".repeat(64),w.superAdminUserId());return null;
            }));
            assertThrows(org.springframework.dao.DataAccessException.class,()->db.update("UPDATE preplan_future_supply_transfer_cancellations SET reason='禁止改写旧事实' WHERE id=?",state.cancel()));
            assertThrows(org.springframework.dao.DataAccessException.class,()->db.update("DELETE FROM preplan_future_supply_transfer_cancellations WHERE id=?",state.cancel()));
            tx.execute(status->{actor(db,w.superAdminUserId());
                db.update("INSERT INTO preplan_future_supply_transfer_cancellations(transfer_id,qty,restore_to_source_qty,public_release_qty,reason,idempotency_key,request_hash,created_by) VALUES(?,10,3,7,'新撤销三件恢复七件公共',?,?,?)",state.transfer(),"v571-split-"+state.transfer(),"d".repeat(64),w.superAdminUserId());return null;
            });
            qty(db,"18.5","SELECT fn_preplan_future_transfer_restored_qty(?)",state.transfer());
            qty(db,"78.5","SELECT fn_preplan_allocation_admitted_qty(?)",state.sourceAllocation());
            qty(db,"14.5","SELECT fn_preplan_allocation_admitted_qty(?)",state.targetAllocation());
            qty(db,"7","SELECT fn_preplan_future_public_release_qty(?,?)",state.sourceAction(),state.externalItem());
            qty(db,"7","SELECT approved_capacity_qty FROM v_preplan_public_surplus_source_state WHERE source_action_id=?",state.sourceAction());
            assertEquals(originalCancel,db.queryForObject("SELECT (to_jsonb(c)-'restore_to_source_qty'-'public_release_qty')::text FROM preplan_future_supply_transfer_cancellations c WHERE id=?",String.class,state.cancel()));
            assertEquals(4,db.queryForObject("SELECT count(*) FROM pg_trigger WHERE tgname IN('trg_future_transfer_purchase_item','trg_future_transfer_subcontract_item','trg_future_transfer_purchase_sources','trg_future_transfer_subcontract_sources') AND tgenabled='A'",Integer.class));
        }
    }

    private static OldFacts seedOldFacts(JdbcTemplate db,FullChainEndToEndTest.World w) {
        actor(db,w.superAdminUserId());
        UUID a=analysis(db,w,"A"),b=analysis(db,w,"B");
        UUID am=material(db,w,a,"A"),bm=material(db,w,b,"B");
        UUID request=UUID.randomUUID(),external=UUID.randomUUID(),order=UUID.randomUUID(),orderItem=UUID.randomUUID();
        String requestNo=documentNumber(db,"PURCHASE_REQUEST"),orderNo=documentNumber(db,"PURCHASE_ORDER");
        db.update("INSERT INTO purchase_requests(id,bill_no,bill_date,warehouse_id,status,maker_id,created_by,updated_by) VALUES(?,?,CURRENT_DATE,?,0,?,?,?)",request,requestNo,w.warehouseId(),w.employeeId(),w.superAdminUserId(),w.superAdminUserId());
        db.update("INSERT INTO purchase_request_items(id,request_id,bill_no,bill_date,line_no,goods_id,unit_id,unit_rate,qty,goods_snapshot_source) VALUES(?,?,?,CURRENT_DATE,1,?,?,1,100,'MASTER_AT_SAVE')",external,request,requestNo,w.goodsD(),w.unitId());
        UUID sourceAction=UUID.randomUUID(),sourceAllocation=UUID.randomUUID();
        action(db,w,sourceAction,a,request,requestNo,"SUPPLY",null,100);
        allocation(db,w,sourceAllocation,sourceAction,a,am,external,100);
        db.update("INSERT INTO purchase_orders(id,bill_no,bill_date,supplier_id,warehouse_id,currency_id,exchange_rate,status,maker_id,created_by,updated_by) VALUES(?,?,CURRENT_DATE,?,?,?,1,0,?,?,?)",order,orderNo,w.supplierId(),w.warehouseId(),w.currencyId(),w.employeeId(),w.superAdminUserId(),w.superAdminUserId());
        db.update("INSERT INTO purchase_order_items(id,order_id,request_item_id,bill_no,bill_date,line_no,goods_id,unit_id,unit_rate,qty,goods_snapshot_source) VALUES(?,?,?,?,CURRENT_DATE,1,?,?,1,100,'MASTER_AT_SAVE')",orderItem,order,external,orderNo,w.goodsD(),w.unitId());
        db.update("INSERT INTO purchase_order_item_sources(order_item_id,request_item_id,line_no,alloc_qty) VALUES(?,?,1,100)",orderItem,external);
        db.update("UPDATE purchase_orders SET status=1 WHERE id=?",order);
        qty(db,"100","SELECT fn_preplan_future_source_available_qty(?)",sourceAllocation);
        UUID transfer=UUID.randomUUID(),targetAction=UUID.randomUUID(),targetAllocation=UUID.randomUUID(),cancel=UUID.randomUUID();
        db.update("""
                INSERT INTO preplan_future_supply_transfers(id,source_allocation_id,source_analysis_id,source_material_id,
                  target_analysis_id,target_material_id,target_action_id,target_allocation_id,external_item_id,qty,
                  source_version,source_fingerprint,target_version,target_fingerprint,reason,idempotency_key,request_hash,created_by)
                VALUES(?,?,?,?,?,?,?,?,?,40,0,?,0,?,'旧版专属供给转拨',?,?,?)
                """,transfer,sourceAllocation,a,am,b,bm,targetAction,targetAllocation,external,"a".repeat(64),"a".repeat(64),"v571-transfer-"+transfer,"b".repeat(64),w.superAdminUserId());
        action(db,w,targetAction,b,request,requestNo,"FUTURE_TRANSFER",sourceAction,40);
        allocation(db,w,targetAllocation,targetAction,b,bm,external,40);
        db.update("INSERT INTO preplan_future_supply_transfer_cancellations(id,transfer_id,qty,reason,idempotency_key,request_hash,created_by) VALUES(?,?,15.5,'旧版全部恢复原计划',?,?,?)",cancel,transfer,"v571-legacy-cancel-"+cancel,"c".repeat(64),w.superAdminUserId());
        return new OldFacts(transfer,cancel,sourceAction,sourceAllocation,targetAllocation,external);
    }
    private static UUID analysis(JdbcTemplate db,FullChainEndToEndTest.World w,String name) {
        UUID id=UUID.randomUUID();db.update("INSERT INTO production_material_analyses(id,warehouse_id,status,fingerprint,initial_idempotency_key,maker_id,created_by,updated_by) VALUES(?,?,'ACTIVE',?,?,?,?,?)",id,w.warehouseId(),"a".repeat(64),"v571-analysis-"+name,w.employeeId(),w.superAdminUserId(),w.superAdminUserId());return id;
    }
    private static UUID material(JdbcTemplate db,FullChainEndToEndTest.World w,UUID analysis,String name) {
        UUID item=UUID.randomUUID(),material=UUID.randomUUID();
        db.update("INSERT INTO production_material_analysis_items(id,analysis_id,source_type,goods_id,unit_id,source_ref,source_reason,requested_qty,line_priority,created_by,updated_by) VALUES(?,?,'OTHER',?,? ,?,'迁移保留真实需求',100,1,?,?)",item,analysis,w.goodsD(),w.unitId(),"v571-"+name,w.superAdminUserId(),w.superAdminUserId());
        db.update("""
                INSERT INTO production_material_analysis_materials(id,analysis_id,analysis_item_id,node_key,goods_id,unit_id,node_role,depth,path,
                  per_product_qty,required_qty,available_qty,allocated_available_qty,shortage_qty,source_suggestion,confirmed_route,
                  route_confirmed_by,route_confirmed_at,created_by,updated_by)
                VALUES(?,?,?,'ROOT',?,?,'ROOT_SUPPLY',0,'ROOT',1,100,0,0,100,'BUY','BUY',?,now(),?,?)
                """,material,analysis,item,w.goodsD(),w.unitId(),w.superAdminUserId(),w.superAdminUserId(),w.superAdminUserId());return material;
    }
    private static void action(JdbcTemplate db,FullChainEndToEndTest.World w,UUID id,UUID analysis,UUID request,String requestNo,String operation,UUID source,int qty) {
        db.update("""
                INSERT INTO preplan_supply_actions(id,analysis_id,warehouse_id,goods_id,unit_id,route,requested_qty,status,
                  external_document_type,external_document_id,external_document_no,operation_type,claim_source_action_id,
                  idempotency_key,action_group_key,request_business_key,request_hash,created_by)
                VALUES(?,?,?,?,?,'BUY',?,'CREATED','PURCHASE_REQUEST',?,?,?,?,?,?,?,?,?)
                """,id,analysis,w.warehouseId(),w.goodsD(),w.unitId(),qty,request,requestNo,operation,source,"v571-action-"+id,"b".repeat(64),id.toString().replace("-","").repeat(2),"c".repeat(64),w.superAdminUserId());
    }
    private static void allocation(JdbcTemplate db,FullChainEndToEndTest.World w,UUID id,UUID action,UUID analysis,UUID material,UUID external,int qty) {
        db.update("INSERT INTO preplan_supply_action_allocations(id,analysis_id,action_id,analysis_material_id,allocated_qty,external_item_id,created_by) VALUES(?,?,?,?,?,?,?)",id,analysis,action,material,qty,external,w.superAdminUserId());
    }
    private static void actor(JdbcTemplate db,UUID id){db.queryForObject("SELECT set_config('app.actor_id',?,true)",String.class,id.toString());}
    private static String documentNumber(JdbcTemplate db,String namespace){
        return db.queryForObject("""
                WITH allocated AS (
                  INSERT INTO business_document_sequences(namespace_key,sequence_date,last_seq)
                  VALUES(?,(CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Shanghai')::date,1)
                  ON CONFLICT(namespace_key,sequence_date) DO UPDATE
                    SET last_seq=business_document_sequences.last_seq+1
                  RETURNING namespace_key,sequence_date,last_seq)
                SELECT registry.fixed_prefix||to_char(allocated.sequence_date,'YYYYMMDD')||lpad(allocated.last_seq::text,6,'0')
                FROM allocated JOIN business_identifier_namespaces registry USING(namespace_key)
                """,String.class,namespace);
    }
    private static String audit(JdbcTemplate db,OldFacts facts){return db.queryForObject("SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY a.id)::text,'[]') FROM audit_log a WHERE target_id IN (?,?)",String.class,facts.transfer().toString(),facts.cancel().toString());}
    private static void qty(JdbcTemplate db,String expected,String sql,Object... args){assertEquals(0,new BigDecimal(expected).compareTo(db.queryForObject(sql,BigDecimal.class,args)));}
    private record OldFacts(UUID transfer,UUID cancel,UUID sourceAction,UUID sourceAllocation,UUID targetAllocation,UUID externalItem){}
}
