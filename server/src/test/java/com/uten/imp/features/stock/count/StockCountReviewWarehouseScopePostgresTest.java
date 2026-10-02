package com.uten.imp.features.stock.count;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.WorkshopStockCountPostingPort;
import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.warehouse.WarehouseKeeperService;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.validation.Validator;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.nio.charset.StandardCharsets;
import java.util.*;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Real V693 scope resolution and real count/page SQL, using no post-V768 schema objects. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class StockCountReviewWarehouseScopePostgresTest {
    private static final PostgreSQLContainer<?> PG=new PostgreSQLContainer<>("postgres:16-alpine");
    private static JdbcTemplate db;
    private static DriverManagerDataSource source;
    private final UUID actorA=UUID.randomUUID(),actorB=UUID.randomUUID(),employeeA=UUID.randomUUID(),employeeB=UUID.randomUUID();
    private final UUID parentA=UUID.randomUUID(),parentB=UUID.randomUUID(),leafA=UUID.randomUUID(),leafB=UUID.randomUUID();
    private final UUID binA=UUID.randomUUID(),binB=UUID.randomUUID(),unassigned=UUID.randomUUID(),hiddenBin=UUID.randomUUID();
    private SecurityContextCurrentUser user;
    private StockCountRequestController controller;
    private StockCountRequestService service;
    private WorkshopStockCountPostingPort workshop;
    private UUID firstA,secondA,firstB,unassignedRequest;
    private int nextNo;

    @BeforeAll static void start() {
        PG.start();source=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());db=new JdbcTemplate(source);
    }
    @AfterAll static void stop() { PG.stop(); }
    @BeforeEach void seed() throws Exception {
        db.execute("""
                DROP SCHEMA public CASCADE; CREATE SCHEMA public;
                CREATE TABLE warehouses(id uuid PRIMARY KEY,code text,name text,parent_id uuid,is_deleted boolean DEFAULT false,
                    status text DEFAULT '使用',is_line_side boolean DEFAULT false,is_accountable boolean DEFAULT true);
                CREATE TABLE employees(id uuid PRIMARY KEY,full_name text,status text DEFAULT 'active',is_deleted boolean DEFAULT false);
                CREATE TABLE users(id uuid PRIMARY KEY,employee_id uuid,login_account text,status text DEFAULT 'active',is_deleted boolean DEFAULT false);
                CREATE TABLE stock_count_requests(id uuid PRIMARY KEY,request_no text,warehouse_id uuid NOT NULL,
                    review_route text,status text,row_version bigint DEFAULT 0,submitted_by uuid,reason text,review_reason text,
                    stock_document_id uuid,submitted_at timestamptz DEFAULT now(),reviewed_at timestamptz);
                CREATE TABLE stock_count_request_lines(request_id uuid,goods_code text,goods_name text,color_name text);
                """);
        try(var resource=getClass().getResourceAsStream("/db/migration/V693__warehouse_keepers_notice_routing.sql")) {
            String migration=new String(resource.readAllBytes(),StandardCharsets.UTF_8);
            db.execute(migration.substring(0,migration.indexOf("-- 审计:")));
        }
        db.update("INSERT INTO employees(id,full_name) VALUES (?,'甲'),(?,'乙')",employeeA,employeeB);
        db.update("INSERT INTO users(id,employee_id,login_account) VALUES (?,?,'scope-a'),(?,?,'scope-b')",actorA,employeeA,actorB,employeeB);
        warehouse(parentA,"A主仓",null,false);warehouse(leafA,"A叶仓",parentA,false);warehouse(binA,"A内料仓",leafA,true);
        warehouse(parentB,"B主仓",null,false);warehouse(leafB,"B叶仓",parentB,false);warehouse(binB,"B内料仓",leafB,true);
        warehouse(unassigned,"未指定负责人的内料仓",null,true);warehouse(hiddenBin,"无对象权限内料仓",parentA,true);
        db.update("INSERT INTO warehouse_keepers(warehouse_id,employee_id) VALUES (?,?),(?,?)",parentA,employeeA,parentB,employeeB);
        user=mock(SecurityContextCurrentUser.class);
        as(actorA,StockCountRequestService.SUBMIT,StockCountRequestService.FINANCE,StockCountRequestService.WAREHOUSE);
        workshop=mock(WorkshopStockCountPostingPort.class);
        for(UUID bin:List.of(binA,binB,unassigned))when(workshop.canAccessWarehouse(bin)).thenReturn(true);
        var tx=mock(TxSessionVars.class);
        service=new StockCountRequestService(new NamedParameterJdbcTemplate(db),user,workshop,mock(StockDocService.class),
                mock(DocNumberService.class),mock(BusinessEventPublisher.class),tx,new ObjectMapper(),mock(Validator.class));
        var scopes=new WarehouseKeeperService(JdbcClient.create(source),tx,user);
        controller=new StockCountRequestController(service,mock(AuditDetailViewRecorder.class),scopes);
        firstA=request(binA,"WAREHOUSE","PENDING",actorA);
        secondA=request(binA,"WAREHOUSE","PENDING",actorB);
        request(binA,"WAREHOUSE","REJECTED",actorA);
        firstB=request(binB,"WAREHOUSE","PENDING",actorA);
        unassignedRequest=request(unassigned,"WAREHOUSE","PENDING",actorB);
        request(hiddenBin,"WAREHOUSE","PENDING",actorA);
        request(leafA,"FINANCE","PENDING",actorA);
    }

    @Test void mineUsesRealKeeperAncestryAndUnassignedRulesWhileGlobalBadgesStayGlobal() {
        var mine=controller.list("WAREHOUSE","PENDING",null,"MINE",null,1,50);
        assertThat(mine.getTotal()).isEqualTo(3);
        assertThat(mine.getItems()).extracting(row->row.get("id")).containsExactlyInAnyOrder(firstA,secondA,unassignedRequest);
        assertThat(controller.list("WAREHOUSE","PENDING",null,"ALL",null,1,50).getTotal()).isEqualTo(4);
        assertThat(controller.list("WAREHOUSE","PENDING",null,1,50).getTotal()).isEqualTo(4);
        assertThat(((Number)controller.counts().get("warehousePending")).longValue()).isEqualTo(4);
        as(actorB,StockCountRequestService.WAREHOUSE);
        var other=controller.list("WAREHOUSE","PENDING",null,"MINE",null,1,50);
        assertThat(other.getItems()).extracting(row->row.get("id")).containsExactlyInAnyOrder(firstB,unassignedRequest);
    }

    @Test void aParentScopeExpandsToNestedBinsBeforeCountingAndPagingWithoutBecomingAnExactFilter() {
        var first=controller.list("WAREHOUSE","PENDING",null,"",parentA,1,1);
        var second=controller.list("WAREHOUSE","PENDING",null,"",parentA,2,1);
        assertThat(first.getTotal()).isEqualTo(2);assertThat(second.getTotal()).isEqualTo(2);
        assertThat(first.getTotalPages()).isEqualTo(2);assertThat(second.getTotalPages()).isEqualTo(2);
        assertThat(first.getItems()).hasSize(1);assertThat(second.getItems()).hasSize(1);
        assertThat(List.of(first.getItems().getFirst().get("id"),second.getItems().getFirst().get("id")))
                .containsExactlyInAnyOrder(firstA,secondA);
        assertThat(controller.list("WAREHOUSE","PENDING",parentA,1,50).getTotal()).isZero();
        assertThat(controller.list("WAREHOUSE","PENDING",binA,"",parentA,1,50).getTotal()).isEqualTo(2);
        assertThat(controller.list("WAREHOUSE","PENDING",binB,"",parentA,1,50).getTotal()).isZero();
        assertThat(controller.list("WAREHOUSE","PENDING",null,"MINE",parentB,1,50).getItems())
                .extracting(row->row.get("id")).containsExactly(firstB);
    }

    @Test void allOrParentFilteringCannotBroadenReviewPermissionOrWorkshopObjectScope() {
        assertThat(controller.list("WAREHOUSE","PENDING",null,"",parentA,1,50).getItems())
                .extracting(row->row.get("warehouseId")).doesNotContain(hiddenBin);
        assertThat(controller.list("WAREHOUSE","PENDING",null,"",hiddenBin,1,50).getTotal()).isZero();
        when(workshop.canAccessWarehouse(binB)).thenReturn(false);
        assertThat(controller.list("WAREHOUSE","PENDING",null,"ALL",null,1,50).getTotal()).isEqualTo(3);
        as(actorA,StockCountRequestService.FINANCE);
        assertThatThrownBy(()->controller.list("WAREHOUSE","PENDING",null,"ALL",null,1,50))
                .isInstanceOf(ApiException.class).satisfies(error->assertThat(((ApiException)error).getCode()).isEqualTo(ErrorCode.FORBIDDEN));
        assertThat(controller.list("FINANCE","PENDING",null,"",parentA,1,50).getTotal()).isEqualTo(1);
        as(actorA,StockCountRequestService.SUBMIT);
        assertThatThrownBy(()->controller.list("FINANCE","PENDING",null,"",parentA,1,50)).isInstanceOf(ApiException.class);
        assertThat(controller.list(null,"PENDING",null,"",parentA,1,50).getTotal()).isEqualTo(2);
    }

    @Test void emptyScopeStaysEmptyAndHistoricalExactWarehouseBehaviorIsPreserved() {
        assertThat(controller.list("WAREHOUSE","PENDING",null,"",UUID.randomUUID(),1,50).getTotal()).isZero();
        db.update("UPDATE warehouses SET is_deleted=true,status='禁用' WHERE id=?",binA);
        assertThat(controller.list("WAREHOUSE","PENDING",binA,1,50).getTotal()).isEqualTo(2);
        assertThat(controller.list("WAREHOUSE","PENDING",null,"",parentA,1,50).getTotal()).isZero();
        assertThat(controller.list("WAREHOUSE","PENDING",null,"",binA,1,50).getTotal()).isEqualTo(2);
        db.update("DELETE FROM warehouse_keepers");
        assertThat(controller.list("WAREHOUSE","PENDING",null,"MINE",null,1,50).getTotal()).isEqualTo(4);
    }

    @Test void keywordSearchUsesTheSameScopedRowsForItsTotalAndPagedResults() {
        db.update("INSERT INTO stock_count_request_lines VALUES (?,'PP-9','PP 颗粒','黑色'),(?,'PP-9','PP 颗粒','黑色')",firstA,firstB);
        var matching=controller.list("WAREHOUSE","PENDING",null,"MINE",null," pp-9 ",1,1);
        assertThat(matching.getTotal()).isEqualTo(1);
        assertThat(matching.getItems()).extracting(row->row.get("id")).containsExactly(firstA);
        assertThat(controller.list("WAREHOUSE","PENDING",null,"",parentA,"a内料仓",1,1).getTotal()).isEqualTo(2);
        assertThat(controller.list("WAREHOUSE","PENDING",null,"",parentA,"黑色",1,50).getTotal()).isEqualTo(1);
        assertThat(controller.list("WAREHOUSE","PENDING",null,"",parentB,"PK-1",1,50).getTotal()).isZero();
        assertThat(controller.list("WAREHOUSE","PENDING",null,"MINE",null,"测试盘点",1,50).getTotal()).isEqualTo(3);
        assertThat(controller.list("WAREHOUSE","PENDING",null,"MINE",null," ",1,50).getTotal()).isEqualTo(3);
        assertThat(((Number)controller.counts().get("warehousePending")).longValue()).isEqualTo(4);
    }

    private void as(UUID actor,String... permissions) {
        when(user.get()).thenReturn(Optional.of(new AuthUser(actor,actor.equals(actorA)?employeeA:employeeB,"scope",
                Set.of(permissions),false,true,false)));
        when(user.id()).thenReturn(Optional.of(actor));when(user.requireId()).thenReturn(actor);
    }
    private void warehouse(UUID id,String name,UUID parent,boolean bin) {
        db.update("INSERT INTO warehouses(id,code,name,parent_id,is_line_side) VALUES (?,?,?,?,?)",id,id.toString(),name,parent,bin);
    }
    private UUID request(UUID warehouse,String route,String status,UUID maker) {
        UUID id=UUID.randomUUID();int no=++nextNo;
        db.update("""
                INSERT INTO stock_count_requests(id,request_no,warehouse_id,review_route,status,submitted_by,reason,submitted_at)
                VALUES (?,?,?,?,?,?,'测试盘点',TIMESTAMPTZ '2026-10-01 00:00:00+00' + ? * interval '1 second')
                """,id,"PK-"+no,warehouse,route,status,maker,no);
        return id;
    }
}
