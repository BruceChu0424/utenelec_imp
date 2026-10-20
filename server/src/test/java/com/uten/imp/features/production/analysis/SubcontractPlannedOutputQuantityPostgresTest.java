package com.uten.imp.features.production.analysis;

import com.uten.imp.support.MigratedProjectionSchema;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.DriverManager;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/** Executes the production planned-output expression; business helper outcomes are explicit adapters. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class SubcontractPlannedOutputQuantityPostgresTest {
    private static final PostgreSQLContainer DB=new PostgreSQLContainer("postgres:16-alpine");
    private static Connection connection;
    private static JdbcTemplate db;
    private static final UUID GOODS=UUID.randomUUID();
    private static final List<String> TABLES=List.of("preplan_supply_actions","preplan_supply_action_allocations",
            "subcontract_application_items","subcontract_order_item_sources","subcontract_order_items","subcontract_orders",
            "subcontract_receipt_items","subcontract_receipts","procurement_inspection_items");

    @BeforeAll static void start()throws Exception{
        DB.start();connection=DriverManager.getConnection(DB.getJdbcUrl(),DB.getUsername(),DB.getPassword());
        db=new JdbcTemplate(new SingleConnectionDataSource(connection,true));
        MigratedProjectionSchema.createCurrentTables(db,TABLES.toArray(String[]::new));
        db.execute("""
                CREATE TEMP TABLE subcontract_draw_adapter(goods_id uuid PRIMARY KEY,enabled boolean NOT NULL);
                CREATE FUNCTION fn_subcontract_draw_edges(uuid) RETURNS SETOF uuid LANGUAGE sql AS
                    $$ SELECT goods_id FROM subcontract_draw_adapter WHERE goods_id=$1 AND enabled $$;
                CREATE FUNCTION fn_procurement_order_source_remaining_qty(text,uuid,uuid) RETURNS numeric LANGUAGE sql AS
                    $$ SELECT source.alloc_qty*COALESCE(item.unit_rate,1)
                       FROM subcontract_order_item_sources source JOIN subcontract_order_items item ON item.id=source.order_item_id
                       WHERE source.order_item_id=$2 AND source.application_item_id=$3 $$;
                CREATE FUNCTION fn_subcontract_order_source_share(uuid,uuid,numeric) RETURNS numeric LANGUAGE sql AS $$ SELECT $3 $$;
                """);
    }
    @AfterAll static void stop()throws Exception{if(connection!=null){ connection.close(); }DB.stop();}
    @BeforeEach void clear(){for(String table:TABLES){ db.execute("TRUNCATE "+table); }db.execute("TRUNCATE subcontract_draw_adapter");}

    @Test void hundredOfOneHundredTenDoesNotInventAFourthDecimalBomRequirement(){
        UUID action=action("110","0");application(action,"110",true);
        allocation(action,1,"10");allocation(action,2,"100");
        var planned=planned(action);
        assertThat(planned).usingComparatorForType(BigDecimal::compareTo,BigDecimal.class)
                .containsExactly(new BigDecimal("10"),new BigDecimal("100"));
        assertThat(MaterialConsumptionMath.required(planned.get(1),BigDecimal.ONE,"PER_UNIT",BigDecimal.ONE,true))
                .isEqualByComparingTo("100");
        assertThat(sum(planned)).isEqualByComparingTo("110");
    }

    @Test void thirdsOfAOneUnitBudgetKeepOneSharedRemainderAndConserveTheMaterialNeed(){
        UUID action=action("3","0");UUID application=application(action,"3",true);
        for(int index=1;index<=3;index++)allocation(action,index,"1",application);
        stocked(application,"2");
        var planned=planned(action);
        assertThat(sum(planned)).isEqualByComparingTo("1");
        assertThat(planned).allSatisfy(value->{assertThat(value.signum()).isNotNegative();assertThat(value.stripTrailingZeros().scale()).isLessThanOrEqualTo(4);});
        assertThat(sum(planned.stream().map(value->MaterialConsumptionMath.required(value,BigDecimal.ONE,"PER_UNIT",BigDecimal.ONE,true)).toList()))
                .isEqualByComparingTo("1");
    }

    @Test void publicExtraAndPartialActualReceiptRemainOnePhysicalBudget(){
        UUID action=action("110","10");UUID application=application(action,"120",true);
        allocation(action,1,"10",application);allocation(action,2,"100",application);
        assertThat(sum(planned(action))).isEqualByComparingTo("120");
        stocked(application,"7");assertThat(sum(planned(action))).isEqualByComparingTo("113");
    }

    @Test void aRealSmallestSourceQuantityCannotBeRoundedAway(){
        UUID action=action("0.0003","0");application(action,"0.0003",true);
        allocation(action,1,"0.0001");allocation(action,2,"0.0002");
        assertThat(planned(action)).usingComparatorForType(BigDecimal::compareTo,BigDecimal.class)
                .containsExactly(new BigDecimal("0.0001"),new BigDecimal("0.0002"));
    }

    private static UUID action(String privateQty,String publicQty){
        UUID id=UUID.randomUUID();db.update("INSERT INTO preplan_supply_actions(id,goods_id,route,requested_qty,public_surplus_qty,status,operation_type) VALUES (?,?,'SUBCONTRACT',?,?,'CREATED','SUPPLY')",
                id,GOODS,new BigDecimal(privateQty),new BigDecimal(publicQty));return id;
    }
    private static UUID application(UUID action,String qty,boolean drawable){
        UUID item=UUID.randomUUID();db.update("INSERT INTO subcontract_application_items(id,goods_id,qty,unit_rate) VALUES (?,?,?,1)",item,GOODS,new BigDecimal(qty));
        db.update("INSERT INTO subcontract_draw_adapter VALUES (?,?)",GOODS,drawable);
        db.update("UPDATE preplan_supply_actions SET public_surplus_external_item_id=? WHERE id=?",item,action);return item;
    }
    private static void allocation(UUID action,int ordinal,String qty){
        UUID application=db.queryForObject("SELECT public_surplus_external_item_id FROM preplan_supply_actions WHERE id=?",UUID.class,action);
        allocation(action,ordinal,qty,application);
    }
    private static void allocation(UUID action,int ordinal,String qty,UUID application){
        UUID id=new UUID(0,ordinal);db.update("INSERT INTO preplan_supply_action_allocations(id,action_id,analysis_material_id,allocated_qty,external_item_id) VALUES (?,?,?,?,?)",
                id,action,UUID.randomUUID(),new BigDecimal(qty),application);
    }
    private static void stocked(UUID application,String qty){
        UUID document=UUID.randomUUID(),item=UUID.randomUUID(),receipt=UUID.randomUUID();
        db.update("INSERT INTO subcontract_orders(id,status,is_deleted) VALUES (?,1,false)",document);
        db.update("INSERT INTO subcontract_order_items(id,order_id,qty,unit_rate,returned_qty,is_deleted) VALUES (?,?,?,1,0,false)",item,document,new BigDecimal(qty));
        db.update("INSERT INTO subcontract_order_item_sources(order_item_id,application_item_id,alloc_qty,line_no) VALUES (?,?,?,1)",item,application,new BigDecimal(qty));
        db.update("INSERT INTO subcontract_receipts(id,status,is_deleted) VALUES (?,1,false)",receipt);
        db.update("INSERT INTO subcontract_receipt_items(id,receipt_id,order_item_id,qty,unit_rate,is_deleted) VALUES (gen_random_uuid(),?,?,?,1,false)",receipt,item,new BigDecimal(qty));
    }
    private static List<BigDecimal> planned(UUID action){return db.queryForList("WITH subcontract_budget_allocations AS MATERIALIZED ("+
            MaterialAnalysisService.allocationBudgetRowsSql("source.action_id=?")+") SELECT "+MaterialAnalysisService.SUBCONTRACT_PLANNED_OUTPUT_SQL+
            " FROM preplan_supply_actions action JOIN subcontract_budget_allocations allocation ON allocation.action_id=action.id WHERE action.id=? ORDER BY allocation.id",BigDecimal.class,action,action);}
    private static BigDecimal sum(List<BigDecimal> values){return values.stream().reduce(BigDecimal.ZERO,BigDecimal::add);}
}
