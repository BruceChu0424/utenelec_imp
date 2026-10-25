package com.uten.imp.features.stock;

import com.uten.imp.common.web.TotaledPageResponse;
import com.uten.imp.features.stock.dto.InstantInventoryRow;
import com.uten.imp.support.MigratedProjectionSchema;
import com.uten.imp.support.MigratedSchemaBaseline;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import java.sql.Connection;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.tuple;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/** Actual warehouse goods/color presence before paging, totals and facets, on migrated column shapes. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class StockWarehouseRelatedInventoryPostgresTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;
    private Connection connection;
    private NamedParameterJdbcTemplate jdbc;
    private StockQueryService service;
    private StockCostMasker costs;

    @BeforeAll static void baseline() throws Exception {
        database=MigratedSchemaBaseline.openDatabase("warehouse_related_inventory");
    }
    @AfterAll static void closeBaseline() throws Exception { if(database!=null) database.close(); }

    @BeforeEach void projection() throws Exception {
        connection=database.openConnection();
        connection.setAutoCommit(false);
        try(var statement=connection.createStatement()) {
            statement.execute("CREATE SCHEMA warehouse_related_inventory_oracle");
            statement.execute("SET LOCAL search_path=warehouse_related_inventory_oracle,public");
        }
        MigratedProjectionSchema.copyEmptyTablesFromMigratedCatalog(connection,
                "goods","warehouses","stock_balances","procurement_inspection_items","material_categories",
                "colors","units","goods_weight_estimates","production_plans","production_plan_items","stock_measurement_holds");
        jdbc=new NamedParameterJdbcTemplate(new SingleConnectionDataSource(connection,true));
        costs=mock(StockCostMasker.class);
        service=new StockQueryService(mock(StockBalanceRepository.class),executingEntityManager(),costs);
    }
    @AfterEach void rollback() throws Exception {
        if(connection!=null) { connection.rollback();connection.close(); }
    }

    @Test void selectedWarehouseKeepsOnlyItsRealColorsZeroBalancesAndInspectionRowsAcrossAllReadProjections() throws Exception {
        World world=world();
        var page=inventory(world.parent(),true,1,2);
        assertThat(page.getTotal()).isEqualTo(5);
        assertThat(page.getTotalPages()).isEqualTo(3);
        assertThat(inventory(world.parent(),true,1,20).getItems())
                .extracting(InstantInventoryRow::getGoodsId,InstantInventoryRow::getColorId)
                .containsExactlyInAnyOrder(tuple(world.stocked(),world.red()),tuple(world.stocked(),null),
                        tuple(world.zero(),world.blue()),tuple(world.inspecting(),world.blue()),tuple(world.released(),world.green()));
        var stocked=inventory(world.parent(),true,1,20).getItems().stream()
                .filter(row->row.getGoodsId().equals(world.stocked()) && world.red().equals(row.getColorId())).findFirst().orElseThrow();
        assertThat(stocked.getQty()).isEqualByComparingTo("15"); // Parent 2 + child A 10 + child B 3; outside 100 excluded.
        assertThat(stocked.isCostMasked()).isTrue();
        assertThat(stocked.getCostAmount()).isNull();
        assertThat(page.getTotals().stream().filter(total->total.key().equals("qty")).findFirst().orElseThrow()
                .groups()).singleElement().satisfies(group->assertThat(group.value()).isEqualByComparingTo("15"));
        assertThat(page.getTotals().stream().filter(total->total.key().equals("inventory_rows")).findFirst().orElseThrow()
                .groups()).singleElement().satisfies(group->assertThat(group.value()).isEqualByComparingTo("5"));
        assertThat(page.getFacets().get("color")).extracting(bucket->bucket.value())
                .containsExactlyInAnyOrder(world.red().toString(),world.blue().toString(),world.green().toString());
        assertThat(page.getFacets().get("owningWarehouse")).singleElement()
                .satisfies(bucket->assertThat(bucket.count()).isEqualTo(5));
        when(costs.canView()).thenReturn(true);
        assertThat(inventory(world.parent(),true,1,20).getItems()).anySatisfy(row->{
            assertThat(row.getGoodsId()).isEqualTo(world.stocked());
            assertThat(row.getColorId()).isEqualTo(world.red());
            assertThat(row.getCostAmount()).isEqualByComparingTo("150");
        });
    }

    @Test void optInParameterIsBoundByAllInstantEndpointsAndOmittingItPreservesGoodsDrivenZeros() throws Exception {
        World world=world();
        assertThat(inventory(world.parent(),false,1,20).getTotal()).isEqualTo(7);
        assertThat(inventory(null,true,1,20).getTotal()).isEqualTo(inventory(null,false,1,20).getTotal());
        var mvc=MockMvcBuilders.standaloneSetup(new StockQueryController(service)).build();
        mvc.perform(get("/api/stock/instant-inventory").param("warehouseId",world.parent().toString())
                        .param("warehouseRelatedOnly","true").param("size","2"))
                .andExpect(status().isOk()).andExpect(jsonPath("total").value(5))
                .andExpect(jsonPath("items.length()").value(2));
        mvc.perform(get("/api/stock/instant-inventory/attention").param("warehouseId",world.parent().toString())
                        .param("warehouseRelatedOnly","true").param("attention","AWAITING_INSPECTION"))
                .andExpect(status().isOk()).andExpect(jsonPath("total").value(1));
    }

    @Test void explicitNonaccountableLineSideDefectiveLeafStillShowsItsRealStockAndEmptyWarehouseStaysEmpty() {
        UUID parent=warehouse(null),leaf=warehouse(parent),empty=warehouse(null),unit=UUID.randomUUID();
        UUID category=UUID.randomUUID();
        UUID goods=goods("内料实物",unit,category,parent);
        jdbc.update("UPDATE warehouses SET is_accountable=FALSE,is_line_side=TRUE,is_defective=TRUE WHERE id=:id",new MapSqlParameterSource("id",leaf));
        balance(leaf,goods,null,7);
        assertThat(inventory(leaf,true,1,20).getItems()).singleElement().satisfies(row->{
            assertThat(row.getQty()).isEqualByComparingTo("7");
            assertThat(row.getDefectiveQty()).isEqualByComparingTo("7");
        });
        assertThat(inventory(parent,true,1,20).getTotal()).isZero();
        assertThat(inventory(empty,true,1,20).getTotal()).isZero();
    }

    @Test void importedClosedStoppedAndDraftPlansNeverContributeCurrentExcessProduction() {
        World world=world();
        plan(world.stocked(),world.red(),1001,(short)1,false,false,10);
        plan(world.stocked(),world.red(),null,(short)1,true,false,20);
        plan(world.stocked(),world.red(),null,(short)1,false,true,30);
        plan(world.stocked(),world.red(),null,(short)0,false,false,40);
        plan(world.stocked(),world.red(),null,(short)1,false,false,50);

        assertThat(inventory(world.parent(),true,1,20).getItems().stream()
                .filter(row->row.getGoodsId().equals(world.stocked()) && world.red().equals(row.getColorId()))
                .findFirst()).hasValueSatisfying(row->{
                    assertThat(row.getMoreQty()).isEqualByComparingTo("47");
                    assertThat(row.getQty()).isEqualByComparingTo("15");
                });
    }

    @Test void persistedMeasurementHoldSurvivesAResolvedMasterUnitWithoutChangingBookValuesOrUnitTotals() {
        World world=world();
        jdbc.update("""
                INSERT INTO stock_measurement_holds(id,stock_balance_id,warehouse_id,goods_id,color_id,reason)
                SELECT :hold,id,warehouse_id,goods_id,color_id,'LEGACY_QUANTITY_BASIS_UNPROVEN'
                FROM stock_balances WHERE goods_id=:goods AND color_id=:color AND qty=10
                """,new MapSqlParameterSource("hold",UUID.randomUUID()).addValue("goods",world.stocked()).addValue("color",world.red()));
        when(costs.canView()).thenReturn(true);
        var result=inventory(world.parent(),true,1,20);
        assertThat(result.getItems().stream().filter(row->row.getGoodsId().equals(world.stocked())
                && world.red().equals(row.getColorId())).findFirst()).hasValueSatisfying(row->{
                    assertThat(row.getQty()).isEqualByComparingTo("15");
                    assertThat(row.getCostAmount()).isEqualByComparingTo("150");
                    assertThat(row.getUnitName()).isNull();
                    assertThat(row.isMeasurementPending()).isTrue();
                    assertThat(row.isAvailableKnown()).isFalse();
                    assertThat(row.getMeasurementHoldReason()).isEqualTo("LEGACY_QUANTITY_BASIS_UNPROVEN");
                });
        assertThat(result.getTotals().stream().filter(total->total.key().equals("missing_unit_rows")).findFirst().orElseThrow().groups())
                .singleElement().satisfies(group->assertThat(group.value()).isEqualByComparingTo("1"));
        assertThat(result.getTotals().stream().filter(total->total.key().equals("qty")).findFirst().orElseThrow().groups())
                .anySatisfy(group->{ assertThat(group.unit()).isNull();assertThat(group.value()).isNull(); });
    }

    private void plan(UUID goods,UUID color,Integer legacy,short status,
                      boolean closed,boolean stopped,int qty) {
        UUID id=UUID.randomUUID();
        var parameters=new MapSqlParameterSource("id",id).addValue("legacy",legacy)
                .addValue("status",status).addValue("closed",closed).addValue("stopped",stopped)
                .addValue("billNo",id.toString()).addValue("goods",goods).addValue("color",color)
                .addValue("qty",qty).addValue("item",UUID.randomUUID());
        jdbc.update("INSERT INTO production_plans(id,legacy_id,bill_no,bill_date,status,is_closed,is_stopped,is_deleted)"
                +" VALUES(:id,:legacy,:billNo,DATE '2026-10-23',:status,:closed,:stopped,FALSE)",parameters);
        jdbc.update("INSERT INTO production_plan_items(id,plan_id,bill_no,bill_date,goods_id,color_id,qty,oqty,lqty,iqty,is_deleted)"
                +" VALUES(:item,:id,:billNo,DATE '2026-10-23',:goods,:color,:qty,0,0,3,FALSE)",parameters);
    }

    private record World(UUID parent,UUID stocked,UUID zero,UUID inspecting,
                         UUID released,UUID red,UUID blue,UUID green) {}

    private World world() {
        UUID parent=warehouse(null),first=warehouse(parent),second=warehouse(parent),outside=warehouse(null);
        UUID category=UUID.randomUUID(),outsideCategory=UUID.randomUUID(),unit=UUID.randomUUID();
        jdbc.update("INSERT INTO material_categories(id,code,name,is_deleted) VALUES(:id,'C-A','分类A',FALSE),(:outside,'C-B','分类B',FALSE)",
                new MapSqlParameterSource("id",category).addValue("outside",outsideCategory));
        jdbc.update("INSERT INTO units(id,code,name,is_deleted) VALUES(:id,'UNIT','个',FALSE)",new MapSqlParameterSource("id",unit));
        UUID red=color("红"),blue=color("蓝"),green=color("绿");
        UUID stocked=goods("库存实物",unit,category,parent),zero=goods("零余额实物",unit,category,parent);
        UUID inspecting=goods("待检实物",unit,category,parent),released=goods("待入库实物",unit,category,parent);
        UUID outsideOnly=goods("别仓实物",unit,outsideCategory,parent);
        goods("未发生实物",unit,outsideCategory,parent); // Owning warehouse alone is not a physical stock fact.
        balance(parent,stocked,red,2);balance(first,stocked,red,10);balance(second,stocked,red,3);
        balance(outside,stocked,red,100);balance(outside,stocked,blue,200);
        balance(first,stocked,null,0);balance(first,zero,blue,0);balance(outside,outsideOnly,red,9);
        inspection(first,inspecting,blue,9,3,2,"PARTIAL");
        inspection(second,released,green,5,5,0,"RESOLVED");
        return new World(parent,stocked,zero,inspecting,released,red,blue,green);
    }

    private TotaledPageResponse<InstantInventoryRow> inventory(UUID warehouse,boolean related,int page,int size) {
        return (TotaledPageResponse<InstantInventoryRow>)service.instantInventory(null,warehouse,false,false,null,
                null,null,null,null,null,null,page,size,"name","asc",false,related);
    }
    private UUID warehouse(UUID parent) {
        UUID id=UUID.randomUUID();
        jdbc.update("INSERT INTO warehouses(id,code,name,parent_id,is_accountable,is_defective,is_line_side,is_deleted)"
                        +" VALUES(:id,:code,'仓库',:parent,TRUE,FALSE,FALSE,FALSE)",
                new MapSqlParameterSource("id",id).addValue("code",id.toString()).addValue("parent",parent));
        return id;
    }
    private UUID goods(String name,UUID unit,UUID category,UUID owner) {
        UUID id=UUID.randomUUID();
        jdbc.update("INSERT INTO goods(id,code,name,unit_id,category_id,owning_warehouse_id,is_deleted) VALUES(:id,:code,:name,:unit,:category,:owner,FALSE)",
                new MapSqlParameterSource("id",id).addValue("code",id.toString()).addValue("name",name)
                        .addValue("unit",unit).addValue("category",category).addValue("owner",owner));
        return id;
    }
    private UUID color(String name) {
        UUID id=UUID.randomUUID();
        jdbc.update("INSERT INTO colors(id,code,name) VALUES(:id,:code,:name)",new MapSqlParameterSource("id",id)
                .addValue("code",id.toString()).addValue("name",name));
        return id;
    }
    private void balance(UUID warehouse,UUID goods,UUID color,int qty) {
        jdbc.update("INSERT INTO stock_balances(id,warehouse_id,goods_id,color_id,qty,weight,amount_local) VALUES(:id,:warehouse,:goods,:color,:qty,0,:amount)",
                new MapSqlParameterSource("warehouse",warehouse).addValue("goods",goods).addValue("color",color)
                        .addValue("qty",qty).addValue("amount",qty*10).addValue("id",UUID.randomUUID()));
    }
    private void inspection(UUID warehouse,UUID goods,UUID color,int received,int passed,int failed,String status) {
        jdbc.update("INSERT INTO procurement_inspection_items(id,receipt_type,receipt_id,receipt_item_id,warehouse_id,goods_id,color_id,"
                        +"received_base_qty,passed_base_qty,failed_base_qty,warehouse_stocked_base_qty,status)"
                        +" VALUES(:id,'PURCHASE',:receipt,:item,:warehouse,:goods,:color,:received,:passed,:failed,0,:status)",
                new MapSqlParameterSource("id",UUID.randomUUID()).addValue("receipt",UUID.randomUUID()).addValue("item",UUID.randomUUID())
                        .addValue("warehouse",warehouse).addValue("goods",goods).addValue("color",color)
                        .addValue("received",received).addValue("passed",passed).addValue("failed",failed).addValue("status",status));
    }
    private EntityManager executingEntityManager() {
        var em=mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation->{
            String sql=invocation.getArgument(0);
            var bindings=new MapSqlParameterSource();
            var query=mock(Query.class);
            when(query.setParameter(anyString(),any())).thenAnswer(binding->{
                bindings.addValue(binding.getArgument(0),binding.getArgument(1));return query;
            });
            when(query.getResultList()).thenAnswer(result->jdbc.query(sql,bindings,(rows,index)->{
                int count=rows.getMetaData().getColumnCount();
                if(count==1) return rows.getObject(1);
                Object[] values=new Object[count];
                for(int column=0;column<count;column++) values[column]=rows.getObject(column+1);
                return values;
            }));
            when(query.getSingleResult()).thenAnswer(result->jdbc.queryForObject(sql,bindings,Object.class));
            return query;
        });
        return em;
    }
}
