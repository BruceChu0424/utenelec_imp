package com.uten.imp.features.quality.pending;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.QualityPendingSourcePort;
import com.uten.imp.features.warehouse.inbound.ProcurementInspectionService;
import com.uten.imp.features.warehouse.inbound.dto.PendingInspectionReceiptView;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.springframework.test.util.ReflectionTestUtils;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.sql.*;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class QualityPendingQueuePostgresTest {
    private static final PostgreSQLContainer POSTGRES=new PostgreSQLContainer("postgres:16-alpine").withDatabaseName("quality_queue");
    @BeforeAll static void start(){POSTGRES.start();}
    @AfterAll static void stop(){POSTGRES.stop();}

    @Test void completeQueueSearchesBeyondBothOldCapsAndPagesAfterTheSameFiltersAndDraftBadges() throws Exception {
        try(var fixture=fixture(Set.of("procurement_inspection:view","production_quality_inspection:view"))){
            var whole=fixture.service.query(request(1,null,null,Map.of(),Map.of()));
            // 2026-11-09 行粒度：IQC 一行 = 一条检验明细（采购 650 行 + 委外 2 行）。
            assertThat(whole.total()).isEqualTo(1954);
            assertThat(whole.items()).hasSize(10);
            assertThat(whole.sourceCounts()).containsEntry("PURCHASE",650L).containsEntry("SUBCONTRACT",2L).containsEntry("FQC",1302L);
            var beyond=fixture.service.query(request(1,null,null,Map.of("billNo","PQ-0601"),Map.of()));
            assertThat(beyond.total()).isEqualTo(1);
            String pq0601Item=fixture.db.queryForObject("""
                    SELECT i.id::text FROM procurement_inspection_items i
                    JOIN purchase_receipts r ON r.id=i.receipt_id WHERE r.bill_no='PQ-0601'
                    """,String.class);
            assertThat(beyond.items()).singleElement().satisfies(row->{
                assertThat(row.source()).isEqualTo("IQC");
                assertThat(row.identity()).startsWith("iqc:PURCHASE:").endsWith(":"+pq0601Item);
                assertThat(row.payload()).isInstanceOf(PendingInspectionReceiptView.class);
                assertThat(((PendingInspectionReceiptView)row.payload()).billNo()).isEqualTo("PQ-0601");
            });
            String identity=beyond.items().getFirst().identity();
            String receiptIdentity=identity.substring(0,identity.lastIndexOf(':'));
            var draft=fixture.service.query(request(1,null,"采购提交待核对",Map.of(),Map.of(receiptIdentity,"提交待核对")));
            assertThat(draft.total()).isEqualTo(1);
            assertThat(draft.items().getFirst().identity()).isEqualTo(identity);
            assertThat(draft.facets().get("status")).anySatisfy(value->assertThat(value.value()).isEqualTo("成品待检"));
            var counted=fixture.service.query(request(1,null,null,Map.of("goods","辅料"),Map.of()));
            assertThat(counted.total()).isEqualTo(1);
            String subcontractGoods2=fixture.db.queryForObject("""
                    SELECT i.id::text FROM procurement_inspection_items i
                    JOIN goods g ON g.id=i.goods_id WHERE i.receipt_type='SUBCONTRACT' AND g.name='辅料'
                    """,String.class);
            assertThat(counted.items().getFirst().identity()).endsWith(":"+subcontractGoods2);
            assertThat(counted.items().getFirst().values().get("pendingQty").toString()).isEqualTo("3 米");
            var purchaseMaterial=fixture.service.query(request(1,null,null,Map.of("goods","IQC材料"),Map.of()));
            assertThat(purchaseMaterial.total()).isEqualTo(651);
            var first=fixture.service.query(request(1,"FQC",null,Map.of("billNo","SHEET"),Map.of()));
            var second=fixture.service.query(request(2,"FQC",null,Map.of("billNo","SHEET"),Map.of()));
            assertThat(first.total()).isEqualTo(651);
            assertThat(first.items().stream().map(QualityPendingQueueService.Row::identity).toList())
                    .doesNotContainAnyElementsOf(second.items().stream().map(QualityPendingQueueService.Row::identity).toList());
            assertThat(fixture.service.query(request(1,"FQC",null,Map.of("enteredAt","2026-10-28"),Map.of())).total()).isEqualTo(1302);
            assertThat(fixture.service.query(request(1,"FQC",null,Map.of("billNo","SECRET"),Map.of())).total()).isZero();
        }
    }
    @Test void eachSourcePermissionIsCheckedBeforeItsPlanAndUnsupportedFieldsCannotBecomeSql() throws Exception {
        try(var fixture=fixture(Set.of("production_quality_inspection:view"))){
            var page=fixture.service.query(request(1,null,null,Map.of(),Map.of()));
            assertThat(page.total()).isEqualTo(1302);
            verify(fixture.iqc,never()).pendingPlans();
            assertThatThrownBy(()->fixture.service.query(request(1,null,null,Map.of("received_amount_local",">0"),Map.of())))
                    .isInstanceOf(com.uten.imp.common.web.ApiException.class);
        }
    }
    @Test void singleReceiptEndpointKeepsReceiptGrainPayloadAfterQueueRowsSplitPerItem() throws Exception {
        // 2026-11-09 队列行身份改为 iqc:类型:收货单:明细 后，单收货单端点仍按收货单键取原载荷：
        // 有待检明细返回该单摘要，没有待检明细保持原 NOT_FOUND 语义。
        try(var fixture=fixture(Set.of("procurement_inspection:view"))){
            var controller=new com.uten.imp.features.warehouse.inbound.ProcurementInspectionController(fixture.iqc);
            UUID purchase=fixture.db.queryForObject("SELECT id FROM purchase_receipts WHERE bill_no='PQ-0601'",UUID.class);
            assertThat(controller.pendingReceipt("purchase",purchase)).isInstanceOfSatisfying(PendingInspectionReceiptView.class,view->{
                assertThat(view.receiptType()).isEqualTo("PURCHASE");
                assertThat(view.receiptId()).isEqualTo(purchase);
                assertThat(view.billNo()).isEqualTo("PQ-0601");
                assertThat(view.supplierName()).isEqualTo("供应商");
                assertThat(view.itemCount()).isEqualTo(1);
            });
            UUID subcontract=fixture.db.queryForObject("SELECT id FROM subcontract_receipts WHERE bill_no='SUB-SPECIAL'",UUID.class);
            assertThat(controller.pendingReceipt("SUBCONTRACT",subcontract)).isInstanceOfSatisfying(PendingInspectionReceiptView.class,view->{
                assertThat(view.billNo()).isEqualTo("SUB-SPECIAL");
                assertThat(view.itemCount()).isEqualTo(2);
            });
            fixture.db.update("UPDATE procurement_inspection_items SET status='RESOLVED',passed_base_qty=received_base_qty WHERE receipt_id=?",purchase);
            assertThatThrownBy(()->controller.pendingReceipt("PURCHASE",purchase))
                    .isInstanceOfSatisfying(com.uten.imp.common.web.ApiException.class,
                            error->assertThat(error.getCode()).isEqualTo(com.uten.imp.common.web.ErrorCode.NOT_FOUND));
        }
    }
    private static QualityPendingQueueService.Request request(int page,String kind,String status,Map<String,String> columns,Map<String,String> drafts){
        return new QualityPendingQueueService.Request(page,10,"",kind,status,columns,null,"asc",drafts);
    }
    private record Fixture(Connection connection,JdbcTemplate db,QualityPendingQueueService service,ProcurementInspectionService iqc) implements AutoCloseable{
        @Override public void close()throws Exception{connection.close();}
    }
    private static Fixture fixture(Set<String> permissions)throws Exception{
        Connection connection=DriverManager.getConnection(POSTGRES.getJdbcUrl(),POSTGRES.getUsername(),POSTGRES.getPassword());
        var source=new SingleConnectionDataSource(connection,true);var db=new JdbcTemplate(source);
        db.execute("""
            CREATE TEMP TABLE units(id uuid,name text);CREATE TEMP TABLE goods(id uuid,code text,name text,unit_id uuid);
            CREATE TEMP TABLE colors(id uuid,name text);CREATE TEMP TABLE suppliers(id uuid,name text);CREATE TEMP TABLE warehouses(id uuid,name text);
            CREATE TEMP TABLE purchase_receipts(id uuid,bill_no text,bill_date date,supplier_id uuid,is_deleted boolean,legacy_id integer);
            CREATE TEMP TABLE subcontract_receipts(LIKE purchase_receipts);
            CREATE TEMP TABLE procurement_inspection_items(id uuid,receipt_type text,receipt_id uuid,warehouse_id uuid,goods_id uuid,color_id uuid,status text,
                received_base_qty numeric(18,4),passed_base_qty numeric(18,4),failed_base_qty numeric(18,4),received_at timestamptz,
                pre_stocked_at timestamptz,pre_stocked_warehouse_id uuid,pre_stocked_place text);
            INSERT INTO units VALUES(md5('unit1')::uuid,'件'),(md5('unit2')::uuid,'米');
            INSERT INTO goods VALUES(md5('goods1')::uuid,'G1','IQC材料',md5('unit1')::uuid),(md5('goods2')::uuid,'G2','辅料',md5('unit2')::uuid);
            INSERT INTO suppliers VALUES(md5('supplier')::uuid,'供应商');
            INSERT INTO purchase_receipts SELECT md5('receipt'||n)::uuid,'PQ-'||lpad(n::text,4,'0'),'2026-10-01',md5('supplier')::uuid,FALSE,NULL FROM generate_series(1,650)n;
            INSERT INTO procurement_inspection_items SELECT md5('item-'||bill_no)::uuid,'PURCHASE',id,NULL,md5('goods1')::uuid,NULL,'PENDING',1,0,0,
                '2026-10-01'::timestamptz+right(bill_no,4)::integer*INTERVAL '1 second',NULL,NULL,NULL FROM purchase_receipts;
            INSERT INTO subcontract_receipts VALUES(md5('special')::uuid,'SUB-SPECIAL','2026-10-01',md5('supplier')::uuid,FALSE,NULL);
            INSERT INTO procurement_inspection_items VALUES(md5('sub-item-1')::uuid,'SUBCONTRACT',md5('special')::uuid,NULL,md5('goods1')::uuid,NULL,'PENDING',2,0,0,'2026-10-02',NULL,NULL,NULL),
                (md5('sub-item-2')::uuid,'SUBCONTRACT',md5('special')::uuid,NULL,md5('goods2')::uuid,NULL,'PENDING',3,0,0,'2026-10-02',NULL,NULL,NULL);
            CREATE TEMP TABLE quality_fqc_fixture(source_key text,identity text,kind text,bill_no text,party text,goods text,goods_code text,
                color_name text,warehouse text,place text,pending_qty text,entered_at timestamptz,status_code text,sequence_at timestamptz,
                goods_names text[],draft_identity text,pre_stocked boolean,owner_id uuid);
            INSERT INTO quality_fqc_fixture SELECT 'FQC_SHEET','sheet:'||md5('sheet'||n)::uuid,'FQC','SHEET-'||n,'成品仓','成品','FG','白','成品仓','A','1 件',
                '2026-10-27 18:00+00'::timestamptz,'PENDING','2026-10-27 18:00+00'::timestamptz+n*INTERVAL '1 second',ARRAY['成品'],
                'sheet:'||md5('sheet'||n)::uuid,FALSE,md5('owner')::uuid FROM generate_series(1,651)n;
            INSERT INTO quality_fqc_fixture SELECT 'FQC','fqc:'||md5('loose'||n)::uuid,'FQC','REPORT-'||n,'计划','成品','FG','白','成品仓','B','2 件',
                '2026-10-27 18:00+00'::timestamptz,'PENDING','2026-10-27 18:00+00'::timestamptz+n*INTERVAL '1 second',ARRAY['成品'],
                'fqc:'||md5('loose'||n)::uuid,FALSE,md5('owner')::uuid FROM generate_series(1,651)n;
            INSERT INTO quality_fqc_fixture SELECT 'FQC','fqc:'||md5('secret')::uuid,'FQC','SECRET','秘密','秘密','X','X','X','X','1 件',now(),'PENDING',now(),ARRAY['秘密'],
                'fqc:'||md5('secret')::uuid,FALSE,md5('other-owner')::uuid;
            """);
        var jdbc=new NamedParameterJdbcTemplate(source);var em=mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(call->query(jdbc,call.getArgument(0)));
        ProcurementInspectionService iqc=mock(ProcurementInspectionService.class,CALLS_REAL_METHODS);ReflectionTestUtils.setField(iqc,"em",em);
        QualityPendingSourcePort fqc=mock(QualityPendingSourcePort.class);when(fqc.readAuthority()).thenReturn("production_quality_inspection:view");
        UUID owner=db.queryForObject("SELECT md5('owner')::uuid",UUID.class);
        List<QualityPendingSourcePort.Plan> plans=new ArrayList<>();
        for(String key:List.of("FQC_SHEET","FQC"))plans.add(new QualityPendingSourcePort.Plan(key,
            "SELECT identity,kind,bill_no,party,goods,goods_code,color_name,warehouse,place,pending_qty,entered_at,status_code,sequence_at,goods_names,draft_identity,pre_stocked FROM quality_fqc_fixture WHERE source_key='"+key+"' AND owner_id=:qualityTestOwner",Map.of("qualityTestOwner",owner)));
        when(fqc.pendingPlans()).thenReturn(plans);
        when(fqc.pendingPayloads(anyString(),anySet())).thenAnswer(call->{Map<String,Object> result=new LinkedHashMap<>();for(String id:call.<Set<String>>getArgument(1)) { result.put(id,Map.of("identity",id)); } return result;});
        var current=mock(SecurityContextCurrentUser.class);when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"reader",permissions,false,true,false)));
        return new Fixture(connection,db,new QualityPendingQueueService(em,List.of(iqc,fqc),current,new ObjectMapper()),iqc);
    }
    private static Query query(NamedParameterJdbcTemplate jdbc,String sql){
        Map<String,Object> parameters=new LinkedHashMap<>();return mock(Query.class,call->{
            if(call.getMethod().getName().equals("setParameter")){parameters.put(call.getArgument(0),call.getArgument(1));return call.getMock();}
            if(call.getMethod().getName().equals("getResultList"))return jdbc.query(sql,parameters,(rs,index)->{
                int count=rs.getMetaData().getColumnCount();if(count==1)return rs.getObject(1);Object[] row=new Object[count];for(int i=0;i<count;i++) { row[i]=rs.getObject(i+1); } return row;});
            return null;
        });
    }
}
