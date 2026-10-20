package com.uten.imp.features.master.goods.pricing;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.security.OwnerVisibility;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Real PostgreSQL query and actual fulfillment functions; never touches a business database. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class GoodsSubcontractSupplierPostgresTest {
    static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    static JdbcTemplate db;
    final ObjectMapper json=new ObjectMapper().findAndRegisterModules();
    UUID goods,material,unit,supplier,owner;
    GoodsSubcontractSupplierService service;MasterReferenceValidationPort references;GoodsPriceAccess access;
    @BeforeAll static void start(){PG.start();db=new JdbcTemplate(new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword()));}
    @AfterAll static void stop(){PG.stop();}
    @BeforeEach void schema() throws Exception {
        db.execute("DROP SCHEMA public CASCADE; CREATE SCHEMA public");
        com.uten.imp.support.MigratedProjectionSchema.createCurrentTables(db,"goods","suppliers","units","colors",
                "subcontract_orders","subcontract_order_items","subcontract_material_plans","subcontract_material_plan_items",
                "subcontract_receipts","subcontract_receipt_items","procurement_inspection_items","subcontract_returns","subcontract_return_items",
                "subcontract_wastes","subcontract_short_delivery_cases","procurement_order_approval_cases","procurement_arrival_exceptions",
                "procurement_iqc_rejection_cases");
        db.execute("""
                ALTER TABLE subcontract_orders ALTER COLUMN status SET DEFAULT 1;
                ALTER TABLE subcontract_order_items ALTER COLUMN goods_code_snapshot SET DEFAULT 'SC', ALTER COLUMN goods_name_snapshot SET DEFAULT '委外件';
                ALTER TABLE subcontract_receipts ALTER COLUMN status SET DEFAULT 1;
                ALTER TABLE subcontract_returns ALTER COLUMN status SET DEFAULT 1;
                ALTER TABLE subcontract_wastes ALTER COLUMN status SET DEFAULT 1;
                ALTER TABLE subcontract_material_plans ALTER COLUMN status SET DEFAULT 'OPEN';
                ALTER TABLE procurement_inspection_items ALTER COLUMN status SET DEFAULT 'RESOLVED', ALTER COLUMN quantity_tranche SET DEFAULT 'LEGACY';
                ALTER TABLE subcontract_short_delivery_cases ALTER COLUMN goods_code_snapshot SET DEFAULT 'SC', ALTER COLUMN goods_name_snapshot SET DEFAULT '委外件',
                    ALTER COLUMN status SET DEFAULT 'ACCEPTED_LOSS', ALTER COLUMN decision SET DEFAULT 'ACCEPT_LOSS', ALTER COLUMN closed_at SET DEFAULT now();
                ALTER TABLE procurement_order_approval_cases ALTER COLUMN order_type SET DEFAULT 'SUBCONTRACT', ALTER COLUMN status SET DEFAULT 'APPROVED',
                    ALTER COLUMN attempt SET DEFAULT 1, ALTER COLUMN decided_at SET DEFAULT now();
                """);
        db.execute(function("V688__subcontract_loss_fulfillment_without_order_revision.sql","fn_subcontract_settled_loss_qty"));
        db.execute(function("V798__subcontract_step_draw.sql","fn_subcontract_draw_sets"));
        goods=UUID.randomUUID();material=UUID.randomUUID();unit=UUID.randomUUID();supplier=UUID.randomUUID();owner=UUID.randomUUID();
        db.update("INSERT INTO goods(id,source_type) VALUES(?,'委外')",goods);db.update("INSERT INTO units(id,name) VALUES(?,'件')",unit);db.update("INSERT INTO suppliers(id,name) VALUES(?,'委外商')",supplier);
        references=mock(MasterReferenceValidationPort.class);access=mock(GoodsPriceAccess.class);
        when(access.sourceScope(GoodsPriceContracts.Kind.SUBCONTRACT)).thenReturn(new OwnerVisibility.OwnerScope(false,Set.of(owner)));
        when(access.has("subcontract_order:view")).thenReturn(true);
        service=new GoodsSubcontractSupplierService(new NamedParameterJdbcTemplate(db),json,references,access);
    }
    @Test void settledLossIsWeightedByOriginalOrderQuantityAndKeepsIndependentOrderCount() throws Exception {
        F a=order("100","90","1","1"),b=order("200","160","1","1");loss(a,"10",null,false);loss(b,"40",null,false);
        var group=read().groups().getFirst();assertThat(group.settledLineCount()).isEqualTo(2);assertThat(group.settledSourceOrderCount()).isEqualTo(2);
        assertThat(group.settledOrderQty()).isEqualTo("300");assertThat(group.settledConfirmedLossQty()).isEqualTo("50");
        assertThat(new BigDecimal(group.confirmedLossRatePct())).isEqualByComparingTo(new BigDecimal("5000").divide(new BigDecimal("300"),java.math.MathContext.DECIMAL128));
    }
    @Test void aTinyConfirmedLossNeverTurnsIntoAZeroPercent() throws Exception {
        F f=order("10000000000","9999999999.9999","1","1");loss(f,"0.0001",null,false);
        assertThat(new BigDecimal(read().groups().getFirst().confirmedLossRatePct())).isEqualByComparingTo("0.000000000001");
    }
    @Test void noReturnAndUnfinishedDeliveryAreNotZeroLossSamples() throws Exception {
        F f=order("100","40","1","1");var g=read().groups().getFirst();
        assertThat(g.confirmedLossRatePct()).isNull();assertThat(g.settledOrderQty()).isNull();assertThat(g.pendingLineCount()).isEqualTo(1);
        assertThat(g.lines().getFirst().confirmedLossQty()).isEqualTo("0");assertThat(g.reasonCodes()).contains("DELIVERY_NOT_SETTLED","NO_SETTLED_COMPARABLE_ORDERS");
        db.update("DELETE FROM subcontract_receipt_items WHERE id=?",f.receiptItem());
        assertThat(read().groups().getFirst().reasonCodes()).contains("NO_QUALIFIED_RECEIPT");
    }
    @Test void multipleAcceptedLossesCountOnceEachAndReversedWasteReopensTheComparison() throws Exception {
        F f=order("100","90","1","1");UUID waste=UUID.randomUUID();db.update("INSERT INTO subcontract_wastes(id) VALUES(?)",waste);
        loss(f,"4",null,false);loss(f,"6",waste,false);assertThat(read().groups().getFirst().confirmedLossRatePct()).isEqualTo("10");
        db.update("UPDATE subcontract_wastes SET status=-1 WHERE id=?",waste);
        var g=read().groups().getFirst();assertThat(g.confirmedLossRatePct()).isNull();assertThat(g.lines().getFirst().confirmedLossQty()).isEqualTo("4");
        assertThat(g.reasonCodes()).contains("DELIVERY_NOT_SETTLED");
    }
    @Test void ordinaryReturnReducesQualifiedStockAndItsReversalRestoresTheSameLossBasis() throws Exception {
        F f=order("100","90","1","1");loss(f,"10",null,false);UUID returned=returned(f,"5");
        var line=read().groups().getFirst().lines().getFirst();assertThat(line.qualifiedStockedNetQty()).isEqualTo("85");assertThat(line.included()).isFalse();
        db.update("UPDATE subcontract_returns SET status=-1 WHERE id=?",returned);
        assertThat(read().groups().getFirst().confirmedLossRatePct()).isEqualTo("10");
    }
    @Test void rejectedQualityReturnIsNeverSubtractedAgainFromAlreadyQualifiedStock() throws Exception {
        F f=order("100","100","1","1");loss(f,"10",null,false);
        db.update("UPDATE procurement_inspection_items SET passed_base_qty=90,failed_base_qty=10,warehouse_stocked_base_qty=90 WHERE id=?",f.inspection());
        db.update("INSERT INTO procurement_iqc_rejection_cases(order_item_id,failed_base_qty,return_recorded_at,status) VALUES(?,10,now(),'RETURN_RECORDED')",f.item());
        var g=read().groups().getFirst();assertThat(g.confirmedLossRatePct()).isEqualTo("10");assertThat(g.lines().getFirst().qualifiedStockedNetQty()).isEqualTo("90");
    }
    @Test void receiptsWithoutQualityEvidenceOrPendingQualityAreNotSettledProof() throws Exception {
        F f=order("100","100","1","1");db.update("DELETE FROM procurement_inspection_items WHERE id=?",f.inspection());
        assertThat(read().groups().getFirst().reasonCodes()).contains("QUALITY_OR_UNIT_EVIDENCE_INCOMPLETE");
        db.update("INSERT INTO procurement_inspection_items(id,receipt_type,receipt_item_id,status,received_base_qty,passed_base_qty,failed_base_qty,warehouse_stocked_base_qty) VALUES(?,'SUBCONTRACT',?,'PENDING',100,0,0,0)",f.inspection(),f.receiptItem());
        assertThat(read().groups().getFirst().reasonCodes()).contains("QUALITY_OR_STOCK_PENDING");
        db.update("UPDATE procurement_inspection_items SET passed_base_qty=100,status='RESOLVED' WHERE id=?",f.inspection());
        assertThat(read().groups().getFirst().confirmedLossRatePct()).isNull();
    }
    @Test void acceptedLossWithoutFullIssueIsNotASettledSampleEvenAfterDrawWasClosed() throws Exception {
        F f=order("100","90","1","1");loss(f,"10",null,false);
        db.update("UPDATE subcontract_material_plan_items SET issued_qty=90,draw_closed_at=now() WHERE id=?",f.materialLine());
        db.update("UPDATE subcontract_material_plans SET status='CLOSED' WHERE id=?",f.plan());
        var g=read().groups().getFirst();assertThat(g.confirmedLossRatePct()).isNull();assertThat(g.reasonCodes()).contains("MATERIAL_ISSUE_PENDING");
    }
    @Test void oldQuantityChangeLossIsVisibleAsLegacyEvidenceRatherThanAZeroLossRate() throws Exception {
        F f=order("90","90","1","1");loss(f,"10",null,true);
        var g=read().groups().getFirst();assertThat(g.confirmedLossRatePct()).isNull();assertThat(g.excludedLineCount()).isEqualTo(1);
        assertThat(g.lines().getFirst().legacyConfirmedLossQty()).isEqualTo("10");assertThat(g.reasonCodes()).contains("LEGACY_LOSS_REQUIRES_REVIEW");
    }
    @Test void changedIdentityQuantityReviewFutureApprovalAndSupplierOwnMaterialAreExcluded() throws Exception {
        F f=order("100","90","1","1");UUID loss=loss(f,"10",null,false);
        db.update("UPDATE subcontract_short_delivery_cases SET supplier_id=? WHERE id=?",UUID.randomUUID(),loss);
        assertThat(read().groups().getFirst().reasonCodes()).contains("LOSS_SNAPSHOT_MISMATCH");
        db.update("UPDATE subcontract_short_delivery_cases SET supplier_id=? WHERE id=?",supplier,loss);
        db.update("UPDATE procurement_order_approval_cases SET status='PENDING' WHERE id=?",f.approval());
        assertThat(read().groups().getFirst().reasonCodes()).contains("APPROVED_QUANTITY_BASIS_UNPROVEN");
        db.update("UPDATE procurement_order_approval_cases SET status='APPROVED',decided_at=now()+interval '1 day' WHERE id=?",f.approval());
        assertThat(read().groups().getFirst().reasonCodes()).contains("APPROVAL_NOT_EFFECTIVE");
        db.update("UPDATE procurement_order_approval_cases SET decided_at=now() WHERE id=?",f.approval());
        db.update("INSERT INTO procurement_arrival_exceptions(order_type,order_item_id,status,decision,approved_excess_qty) VALUES('SUBCONTRACT',?,'RECEIPT_POSTED','APPROVE_ALL',1)",f.item());
        assertThat(read().groups().getFirst().reasonCodes()).contains("SUPPLIER_OWN_MATERIAL_BASIS");
    }
    @Test void unitRatesColorsAndFrozenMaterialVersionsAreSeparateButIdenticalPlanRowsDoNotInventVersions() throws Exception {
        F first=order("100","90","1","1");loss(first,"10",null,false);
        F duplicate=order("100","90","1","1");loss(duplicate,"10",null,false);
        db.update("INSERT INTO subcontract_material_plan_items(id,plan_id,order_item_id,parent_goods_id,parent_color_id,goods_id,color_id,unit_id,unit_rate,bom_unit_qty,planned_qty,issued_qty,draw_closed_at,is_deleted) SELECT gen_random_uuid(),plan_id,order_item_id,parent_goods_id,parent_color_id,goods_id,color_id,unit_id,unit_rate,bom_unit_qty,planned_qty,issued_qty,draw_closed_at,is_deleted FROM subcontract_material_plan_items WHERE id=?",duplicate.materialLine());
        assertThat(read().groups()).hasSize(1);assertThat(read().groups().getFirst().materialKindCount()).isEqualTo(1);
        order("100","100","2","1");order("100","100","1","2");
        assertThat(read().groups()).hasSize(3);
        F coloured=order("100","100","1","1");UUID color=UUID.randomUUID();
        db.update("UPDATE subcontract_order_items SET color_id=? WHERE id=?",color,coloured.item());
        assertThat(read().groups()).hasSize(4);
    }
    @Test void currentGoodsTypeAndOwnerScopeAreCheckedBeforeAggregating() throws Exception {
        F own=order("100","100","1","1"),hidden=order("100","10","1","1");loss(hidden,"90",null,false);
        db.update("UPDATE subcontract_orders SET maker_id=? WHERE id=?",UUID.randomUUID(),hidden.order());
        var g=read().groups().getFirst();assertThat(g.lineCount()).isEqualTo(1);assertThat(g.confirmedLossRatePct()).isEqualTo("0");
        assertThat(g.lines().getFirst().orderId()).isEqualTo(own.order());verify(references,atLeastOnce()).requireVisibleGoods(goods);
        db.update("UPDATE goods SET source_type='采购' WHERE id=?",goods);
        assertThat(read().applicable()).isFalse();assertThat(read().groups()).isEmpty();
    }
    @Test void periodIsExplicitlyOrderDateAndUnboundedResultsNeverPublishPartialRatios() throws Exception {
        F old=order("100","90","1","1");loss(old,"10",null,false);
        db.update("UPDATE subcontract_orders SET bill_date=? WHERE id=?",BusinessTime.today().minusDays(200),old.order());
        assertThat(read().groups()).isEmpty();assertThat(read().summary()).contains("按订货日期","不是期间内结案");
        F current=order("100","100","1","1");
        db.update("INSERT INTO subcontract_order_items(id,order_id,goods_id,unit_id,unit_rate,qty) SELECT gen_random_uuid(),?,?,?,1,1 FROM generate_series(1,500)",current.order(),goods,unit);
        var result=read();assertThat(result.dataComplete()).isFalse();assertThat(result.groups()).isEmpty();assertThat(result.status()).isEqualTo("LIMIT_EXCEEDED");
    }
    @Test void queryAlsoMatchesCurrentMigratedTableShapesRatherThanOnlyTheFocusedFixture() throws Exception {
        db.execute("DROP SCHEMA public CASCADE; CREATE SCHEMA public");
        com.uten.imp.support.MigratedProjectionSchema.createCurrentTables(db,"goods","suppliers","units","colors",
                "subcontract_orders","subcontract_order_items","subcontract_material_plans","subcontract_material_plan_items",
                "subcontract_receipts","subcontract_receipt_items","procurement_inspection_items","subcontract_returns","subcontract_return_items",
                "subcontract_wastes","subcontract_short_delivery_cases","procurement_order_approval_cases","procurement_arrival_exceptions");
        db.execute(function("V688__subcontract_loss_fulfillment_without_order_revision.sql","fn_subcontract_settled_loss_qty"));
        db.execute(function("V798__subcontract_step_draw.sql","fn_subcontract_draw_sets"));
        var params=new org.springframework.jdbc.core.namedparam.MapSqlParameterSource().addValue("goods",UUID.randomUUID()).addValue("supplier",null)
                .addValue("from",BusinessTime.today().minusDays(180)).addValue("to",BusinessTime.today());
        assertThat(new NamedParameterJdbcTemplate(db).queryForList(GoodsSubcontractSupplierService.FACTS_SQL.formatted(" AND 1=0"),params)).isEmpty();
    }
    private GoodsSubcontractSupplierContracts.Result read(){return service.read(goods,180,null);}
    private record F(UUID order,UUID item,UUID plan,UUID materialLine,UUID receipt,UUID receiptItem,UUID inspection,UUID approval,String ordered,String rate) {}
    private F order(String qty,String received,String rate,String bom) throws Exception {
        UUID order=UUID.randomUUID(),item=UUID.randomUUID(),plan=UUID.randomUUID(),m=UUID.randomUUID(),receipt=UUID.randomUUID(),ri=UUID.randomUUID(),iqc=UUID.randomUUID(),approval=UUID.randomUUID();
        db.update("INSERT INTO subcontract_orders(id,bill_no,bill_date,supplier_id,maker_id) VALUES(?,?,?,?,?)",order,"EO-"+order,BusinessTime.today(),supplier,owner);
        db.update("INSERT INTO subcontract_order_items(id,order_id,goods_id,unit_id,unit_rate,qty,allowed_loss_pct) VALUES(?,?,?,?,?,?,15)",item,order,goods,unit,new BigDecimal(rate),new BigDecimal(qty));
        db.update("INSERT INTO subcontract_material_plans(id) VALUES(?)",plan);
        db.update("INSERT INTO subcontract_material_plan_items(id,plan_id,order_item_id,parent_goods_id,goods_id,unit_id,unit_rate,bom_unit_qty,planned_qty,issued_qty) VALUES(?,?,?,?,?,?,1,?,?,?)",m,plan,item,goods,material,unit,new BigDecimal(bom),new BigDecimal(qty).multiply(new BigDecimal(bom)),new BigDecimal(qty).multiply(new BigDecimal(bom)));
        db.update("INSERT INTO subcontract_receipts(id) VALUES(?)",receipt);
        db.update("INSERT INTO subcontract_receipt_items(id,receipt_id,order_item_id,goods_id,unit_id,unit_rate,qty) VALUES(?,?,?,?,?,?,?)",ri,receipt,item,goods,unit,new BigDecimal(rate),new BigDecimal(received));
        BigDecimal base=new BigDecimal(received).multiply(new BigDecimal(rate));
        db.update("INSERT INTO procurement_inspection_items(id,receipt_type,receipt_item_id,received_base_qty,passed_base_qty,failed_base_qty,warehouse_stocked_base_qty) VALUES(?,'SUBCONTRACT',?,?,?,0,?)",iqc,ri,base,base,base);
        Map<String,Object> snapshot=Map.of("orderId",order,"supplierId",supplier,"items",List.of(Map.of("itemId",item,"goodsId",goods,"unitId",unit,"unitRate",rate,"qty",qty)));
        db.update("INSERT INTO procurement_order_approval_cases(id,order_id,submission_snapshot) VALUES(?,?,?::jsonb)",approval,order,json.writeValueAsString(snapshot));
        return new F(order,item,plan,m,receipt,ri,iqc,approval,qty,rate);
    }
    private UUID loss(F f,String qty,UUID waste,boolean legacy){UUID id=UUID.randomUUID();db.update("INSERT INTO subcontract_short_delivery_cases(id,order_item_id,supplier_id,goods_id,unit_id,ordered_qty,loss_qty,waste_id,qty_change_log_id) VALUES(?,?,?,?,?,?,?,?,?)",id,f.item(),supplier,goods,unit,new BigDecimal(f.ordered()),new BigDecimal(qty),waste,legacy?UUID.randomUUID():null);return id;}
    private UUID returned(F f,String qty){UUID id=UUID.randomUUID();db.update("INSERT INTO subcontract_returns(id) VALUES(?)",id);db.update("INSERT INTO subcontract_return_items(id,return_id,order_item_id,goods_id,unit_id,unit_rate,qty) VALUES(?,?,?,?,?,?,?)",UUID.randomUUID(),id,f.item(),goods,unit,new BigDecimal(f.rate()),new BigDecimal(qty));return id;}
    private static String function(String migration,String name) throws Exception {
        try(var input=GoodsSubcontractSupplierPostgresTest.class.getResourceAsStream("/db/migration/"+migration)){
            String source=new String(Objects.requireNonNull(input).readAllBytes(),StandardCharsets.UTF_8);int start=source.indexOf("CREATE FUNCTION "+name+"(");
            assertThat(start).isGreaterThanOrEqualTo(0);int end=source.indexOf("$$;",start);return source.substring(start,end+3);
        }
    }
}
