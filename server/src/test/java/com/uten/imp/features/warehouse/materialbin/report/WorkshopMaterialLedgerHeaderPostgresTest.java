package com.uten.imp.features.warehouse.materialbin.report;

import com.uten.imp.features.warehouse.materialbin.WorkshopBinService;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialPermissions;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialScope;
import com.uten.imp.support.MigratedProjectionSchema;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.time.LocalDate;
import java.util.Map;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Original union ledger view and actual service count/page/joins, including approved-count sources. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class WorkshopMaterialLedgerHeaderPostgresTest {
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    private static JdbcTemplate db;
    private static WorkshopMaterialReportQueryService service;
    private static WorkshopMaterialScope scope;
    private static final UUID BIN=UUID.randomUUID(),WORKSHOP=UUID.randomUUID(),PERIOD=UUID.randomUUID(),GOODS=UUID.randomUUID(),COLOR=UUID.randomUUID(),UNIT=UUID.randomUUID(),ACTOR=UUID.randomUUID(),EMPLOYEE=UUID.randomUUID();
    @BeforeAll static void start(){
        PG.start();var source=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());db=new JdbcTemplate(source);
        MigratedProjectionSchema.createCurrentTables(db,"workshop_material_periods","goods","colors","units","workshop_material_requisition_postings",
                "workshop_material_requisition_lines","workshop_material_requisitions","stock_document_items","stock_documents","workshop_material_other_issues",
                "workshop_material_count_postings","workshop_material_period_lines","workshop_material_counts","workshop_material_count_adjustment_postings",
                "stock_count_requests","users","employees");
        // Projection fixtures intentionally copy scalar defaults only. Restore the
        // original V768 generated fact before using the original union view.
        db.execute("ALTER TABLE workshop_material_count_adjustment_postings DROP COLUMN signed_qty");
        db.execute("ALTER TABLE workshop_material_count_adjustment_postings ADD COLUMN signed_qty numeric(18,4) GENERATED ALWAYS AS (target_qty-before_qty) STORED");
        MigratedProjectionSchema.createCurrentViews(db,"v_workshop_material_bin_ledger");
        scope=mock(WorkshopMaterialScope.class);var openings=mock(WorkshopBinService.class);when(openings.requireWorkshopOfOpenedBin(BIN)).thenReturn(WORKSHOP);
        service=new WorkshopMaterialReportQueryService(new NamedParameterJdbcTemplate(source),scope,mock(WorkshopMaterialPermissions.class),openings);
        db.update("INSERT INTO units(id,name) VALUES (?,'千克')",UNIT);
        db.update("INSERT INTO goods(id,code,name,unit_id) VALUES (?,'LEDGER-G','颗粒_% 黑色',?)",GOODS,UNIT);
        db.update("INSERT INTO colors(id,name) VALUES (?,'黑_%')",COLOR);
        db.update("INSERT INTO employees(id,code,full_name) VALUES (?,'WM-TEST','操作_% 人员')",EMPLOYEE);
        db.update("INSERT INTO users(id,employee_id,login_account,password_hash) VALUES (?,?,'fallback-account','fixture')",ACTOR,EMPLOYEE);
        db.update("INSERT INTO workshop_material_periods(id,bin_warehouse_id,workshop_department_id,period_no,start_date) VALUES (?,?,?,11,'2026-10-01')",PERIOD,BIN,WORKSHOP);
        adjustment(BIN,"2026-10-31",".1234");adjustment(BIN,"2026-10-31",".5678");
        adjustment(BIN,"2026-11-01",".1234");adjustment(UUID.randomUUID(),"2026-10-31",".1234");
    }
    @AfterAll static void stop(){PG.stop();}
    private static void adjustment(UUID bin,String date,String consumed){
        UUID request=UUID.randomUUID(),approval=UUID.randomUUID();
        db.update("INSERT INTO stock_count_requests(id,request_no,warehouse_id,review_route,submitted_by,reason,command_key,request_hash,status,approval_event_id,reviewed_by,reviewed_at) VALUES (?,?,?,'WAREHOUSE',?,'真实核对','cmd-'||?,?,'APPROVED',?,?,now())",request,"REQ_%"+request,bin,ACTOR,request.toString(),"a".repeat(64),approval,ACTOR);
        db.update("INSERT INTO workshop_material_count_adjustment_postings(id,request_id,line_id,approval_event_id,period_id,bin_warehouse_id,goods_id,color_id,unit_id,kind,before_qty,target_qty,business_date,created_by) VALUES (?,?,?,?,?,?,?,?,?,'ADJUSTMENT',1,1-CAST(? AS numeric),?,?)",
                UUID.randomUUID(),request,UUID.randomUUID(),approval,PERIOD,bin,GOODS,COLOR,UNIT,consumed,LocalDate.parse(date),ACTOR);
    }
    @Test void allEightHeadersUseCompleteScopedRowsBeforeCountPagingAndDisplayedSourceDerivation(){
        UUID unrelatedUnit=UUID.randomUUID();db.update("INSERT INTO units(id,name) VALUES (?,'当前主档非原单位')",unrelatedUnit);
        db.update("UPDATE goods SET unit_id=? WHERE id=?",unrelatedUnit,GOODS);
        assertThat(db.queryForList("SELECT signed_qty FROM workshop_material_count_adjustment_postings WHERE bin_warehouse_id=? AND business_date='2026-10-31'",java.math.BigDecimal.class,BIN))
                .containsExactlyInAnyOrder(new java.math.BigDecimal("-0.1234"),new java.math.BigDecimal("-0.5678"));
        assertThat(db.queryForObject("SELECT count(*) FROM v_workshop_material_bin_ledger WHERE bin_warehouse_id=? AND business_date='2026-10-31'",Long.class,BIN)).isEqualTo(2);
        assertThat(service.ledger(BIN,LocalDate.of(2026,10,1),LocalDate.of(2026,10,31),1,50).getTotal()).isEqualTo(2);
        var filters=Map.of("material","颗粒_% 黑色","materialColor","黑_%","qty","-0.6..-0.1","date","2026-10-01..2026-10-31","operator","操作_% 人员","period","11","docNo","REQ_%","kind","账面修正");
        for(var entry:filters.entrySet())assertThat(service.ledger(BIN,LocalDate.of(2026,10,1),LocalDate.of(2026,10,31),1,50,
                Map.of(entry.getKey(),entry.getValue()),null,null,null).getTotal()).as(entry.getKey()).isEqualTo(2);
        var first=service.ledger(BIN,null,null,1,1,filters,"已审核账面修正","qty","asc");
        assertThat(first.getTotal()).isEqualTo(2);assertThat(first.getItems()).hasSize(1);
        assertThat(first.getItems().getFirst().signedQty()).isEqualByComparingTo("-.5678");
        assertThat(first.getItems().getFirst().operatorName()).isEqualTo("操作_% 人员");
        assertThat(first.getItems().getFirst().unitName()).isEqualTo("千克");
        assertThat(first.getItems().getFirst().getSignedQtyExact()).isEqualTo("-0.5678");
        var second=service.ledger(BIN,null,null,2,1,filters,null,"qty","asc");
        assertThat(second.getTotal()).isEqualTo(2);assertThat(second.getItems().getFirst().signedQty()).isEqualByComparingTo("-.1234");
        var overflow=service.ledger(BIN,null,null,999,1,filters,null,"qty","asc");
        assertThat(overflow.getItems()).isEmpty();assertThat(overflow.getTotal()).isEqualTo(2);
        assertThat(service.ledger(BIN,null,null,1,10,filters,"领入",null,null).getTotal()).isZero();
        assertThat(service.ledger(BIN,null,null,1,10,Map.of("docNo","盘点审核"),null,null,null).getTotal()).isZero();
        verify(scope,atLeastOnce()).requireWorkshop(WORKSHOP);
    }
    @Test void openedBinScopeIsRequiredBeforeAnyHeaderGrammarIsParsed(){
        doThrow(new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.FORBIDDEN)).when(scope).requireWorkshop(WORKSHOP);
        try{assertThatThrownBy(()->service.ledger(BIN,null,null,1,50,Map.of("qty","invalid"),null,null,null))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class)
                .satisfies(error->assertThat(((com.uten.imp.common.web.ApiException)error).getCode()).isEqualTo(com.uten.imp.common.web.ErrorCode.FORBIDDEN));}
        finally{reset(scope);}
    }
}
