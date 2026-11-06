package com.uten.imp.features.subcontract.waste;

import com.uten.imp.support.MigratedProjectionSchema;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.math.BigDecimal;
import java.sql.Date;
import java.time.LocalDate;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/** Real source-read SQL over migrated column shapes; no posted business history is rewritten. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class SubcontractNormalMaterialLossBudgetPostgresTest {
    static final PostgreSQLContainer DB=new PostgreSQLContainer("postgres:16-alpine");
    static JdbcTemplate db;
    @BeforeAll static void start() {
        DB.start();db=new JdbcTemplate(new DriverManagerDataSource(DB.getJdbcUrl(),DB.getUsername(),DB.getPassword()));
        MigratedProjectionSchema.createCurrentColumns(db,"subcontract_order_items","subcontract_material_plan_items",
                "subcontract_material_issues","subcontract_material_issue_items","subcontract_wastes","subcontract_waste_items",
                "subcontract_receipts","subcontract_receipt_items","subcontract_receipt_material_consumptions");
        MigratedProjectionSchema.createCurrentFunctions(db,"fn_subcontract_draw_f");
    }
    @AfterAll static void stop() { DB.stop(); }

    @Test void aSupplyCeilingIsNotANormalMaterialLossAllowance() {
        World w=world("10000","0.000001","0.0000010001","0.0101","1");
        Object[] source=read(w);
        amount("0.000001",SubcontractWasteService.remainingNormalMaterialBudgetForSource(source));
        var allocation=SubcontractWasteService.allocateNormalMaterialBudget(
                SubcontractWasteService.remainingNormalMaterialBudgetForSource(source),(BigDecimal)source[8],(BigDecimal)source[4]);
        amount("0.000001",allocation.standardDoc());
        assertThat(allocation.standardDoc()).isLessThan(new BigDecimal("0.0001"));
    }

    @Test void aLiveHistoricalEstimateAlreadySpent95OfThe100NormalBudget() {
        World w=world("1000","1","1.1","1100","1");
        Slice old=receipt(w,1,"950","1045");
        Map<String,Object> original=db.queryForMap("SELECT * FROM subcontract_receipt_material_consumptions WHERE id=?",old.consumption());
        Object[] source=read(w);amount("55",(BigDecimal)source[8]);
        amount("950",(BigDecimal)source[16]);amount("1045",(BigDecimal)source[17]);
        BigDecimal remaining=SubcontractWasteService.remainingNormalMaterialBudgetForSource(source);amount("5",remaining);
        var allocation=SubcontractWasteService.allocateNormalMaterialBudget(remaining,(BigDecimal)source[8],(BigDecimal)source[4]);
        amount("5",allocation.standardDoc());amount("50",new BigDecimal("55").subtract(allocation.standardDoc()));
        assertThat(db.queryForMap("SELECT * FROM subcontract_receipt_material_consumptions WHERE id=?",old.consumption())).isEqualTo(original);
    }

    @Test void newActualConsumptionDoesNotSpendAFixedLegacyPadding() {
        World w=world("1000","1","1.1","1100","1");receipt(w,2,"950","950");
        Object[] source=read(w);amount("150",(BigDecimal)source[8]);
        amount("0",(BigDecimal)source[16]);amount("0",(BigDecimal)source[17]);
        amount("100",SubcontractWasteService.remainingNormalMaterialBudgetForSource(source));
    }

    @Test void mixedCohortsExplicitNormalLossDifferentUnitsAndReversalAllUseTheSameBudget() {
        World w=world("1000","1","1.1","1100","2");
        Slice old=receipt(w,1,"400","440");receipt(w,2,"550","550");
        amount("60",SubcontractWasteService.remainingNormalMaterialBudgetForSource(read(w)));
        UUID waste=UUID.randomUUID();db.update("INSERT INTO subcontract_wastes(id,status,is_deleted) VALUES(?,1,false)",waste);
        db.update("INSERT INTO subcontract_waste_items(id,waste_id,material_issue_item_id,standard_qty,unit_id,unit_rate,qty,is_deleted) VALUES(?,?,?,10,?,2,10,false)",
                UUID.randomUUID(),waste,w.issueLine(),w.unit());
        db.update("UPDATE subcontract_material_issue_items SET wasted_qty=10 WHERE id=?",w.issueLine());
        amount("40",SubcontractWasteService.remainingNormalMaterialBudgetForSource(read(w)));
        db.update("UPDATE subcontract_wastes SET status=-1 WHERE id=?",waste);
        db.update("UPDATE subcontract_material_issue_items SET wasted_qty=0 WHERE id=?",w.issueLine());
        amount("60",SubcontractWasteService.remainingNormalMaterialBudgetForSource(read(w)));
        // The original historical source stays immutable; its reversal is a new source.
        db.update("INSERT INTO subcontract_receipt_material_consumptions(id,receipt_item_id,issue_item_id,qty_doc,qty_base,consumption_basis,reversal_of) SELECT ?,receipt_item_id,issue_item_id,qty_doc,qty_base,consumption_basis,id FROM subcontract_receipt_material_consumptions WHERE id=?",UUID.randomUUID(),old.consumption());
        db.update("UPDATE subcontract_receipts SET status=-1 WHERE id=?",old.receipt());
        db.update("UPDATE subcontract_material_issue_items SET consumed_qty=consumed_qty-220 WHERE id=?",w.issueLine());
        amount("100",SubcontractWasteService.remainingNormalMaterialBudgetForSource(read(w)));
        assertThat(db.queryForObject("SELECT COUNT(*) FROM subcontract_receipt_material_consumptions WHERE id=?",Integer.class,old.consumption())).isEqualTo(1);
    }

    private static World world(String target,String base,String budget,String supplied,String issueRate) {
        World w=new World(UUID.randomUUID(),UUID.randomUUID(),UUID.randomUUID(),UUID.randomUUID(),UUID.randomUUID(),UUID.randomUUID(),new BigDecimal(issueRate));
        db.update("INSERT INTO subcontract_order_items(id,qty,unit_id,unit_rate,is_deleted) VALUES(?,?,?,1,false)",w.orderItem(),new BigDecimal(target),w.baseUnit());
        db.update("INSERT INTO subcontract_material_plan_items(id,order_item_id,unit_id,base_bom_unit_qty,bom_unit_qty,planned_qty,material_loss_pct,is_deleted) VALUES(?,?,?,?,?,fn_subcontract_draw_f(?,?),0,false)",
                w.planLine(),w.orderItem(),w.baseUnit(),new BigDecimal(base),new BigDecimal(budget),new BigDecimal(target),new BigDecimal(budget));
        db.update("INSERT INTO subcontract_material_issues(id,status,warehouse_id,supplier_id,bill_date,is_deleted) VALUES(?,1,?,?,?,false)",
                w.issue(),UUID.randomUUID(),UUID.randomUUID(),Date.valueOf(LocalDate.of(2026,11,6)));
        BigDecimal qty=new BigDecimal(supplied).divide(w.issueRate());
        db.update("INSERT INTO subcontract_material_issue_items(id,issue_id,plan_item_id,order_item_id,goods_id,unit_id,unit_rate,at_supplier_qty,qty,consumed_qty,compensated_qty,returned_qty,wasted_qty,is_deleted) VALUES(?,?,?,?,?,?,?,?,?,0,0,0,0,false)",
                w.issueLine(),w.issue(),w.planLine(),w.orderItem(),UUID.randomUUID(),w.unit(),w.issueRate(),qty,qty);
        return w;
    }
    private static Slice receipt(World w,int version,String basis,String consumedBase) {
        Slice s=new Slice(UUID.randomUUID(),UUID.randomUUID(),UUID.randomUUID());
        db.update("INSERT INTO subcontract_receipts(id,status,is_deleted) VALUES(?,1,false)",s.receipt());
        db.update("INSERT INTO subcontract_receipt_items(id,receipt_id,order_item_id,material_consumption_version,material_basis_qty,qty,unit_id,unit_rate,is_deleted) VALUES(?,?,?,?,?,?,?,1,false)",
                s.item(),s.receipt(),w.orderItem(),version,new BigDecimal(basis),new BigDecimal(basis),w.baseUnit());
        BigDecimal base=new BigDecimal(consumedBase),doc=base.divide(w.issueRate());
        db.update("INSERT INTO subcontract_receipt_material_consumptions(id,receipt_item_id,issue_item_id,qty_doc,qty_base,consumption_basis) VALUES(?,?,?,?,?,?)",
                s.consumption(),s.item(),w.issueLine(),doc,base,version==1?"FROZEN_BOM_ESTIMATE":"FROZEN_BASE_BOM_ACTUAL");
        db.update("UPDATE subcontract_material_issue_items SET consumed_qty=consumed_qty+? WHERE id=?",doc,w.issueLine());
        return s;
    }
    private static Object[] read(World w) {
        String sql=SubcontractWasteService.shortDeliveryLossSourcesSql().replace(":orderItemId","'"+w.orderItem()+"'::uuid");
        return db.queryForObject(sql,(rs,row)->{
            Object[] values=new Object[19];
            for(int i=0;i<values.length;i++) {
                values[i]=rs.getObject(i+1);
            }
            return values;
        });
    }
    private static void amount(String expected,BigDecimal actual) { assertThat(actual).isEqualByComparingTo(expected); }
    private record World(UUID orderItem,UUID planLine,UUID issue,UUID issueLine,UUID unit,UUID baseUnit,BigDecimal issueRate) { }
    private record Slice(UUID receipt,UUID item,UUID consumption) { }
}
