package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.application.port.LineSideWarehousePort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.security.access.prepost.PreAuthorize;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.*;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Setup metadata queries do not read inventory and require no generic warehouse-view grant. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class WorkshopMaterialSetupMainWarehousesPostgresTest {
    private static final PostgreSQLContainer<?> PG=new PostgreSQLContainer<>("postgres:16-alpine");
    private static JdbcTemplate db;
    private SecurityContextCurrentUser user;
    private WorkshopMaterialSettingsService service;

    @BeforeAll static void start() {
        PG.start();db=new JdbcTemplate(new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword()));
    }
    @AfterAll static void stop() { PG.stop(); }
    @BeforeEach void seed() {
        db.execute("""
                DROP SCHEMA public CASCADE; CREATE SCHEMA public;
                CREATE TABLE warehouses(id uuid PRIMARY KEY,code text,name text,parent_id uuid,
                    is_accountable boolean DEFAULT true,is_line_side boolean DEFAULT false,
                    status text DEFAULT '使用',is_deleted boolean DEFAULT false,
                    location text DEFAULT '不应对设置页泄露的位置',remark text DEFAULT '不应返回的主档备注');
                """);
        user=mock(SecurityContextCurrentUser.class);
        as(WorkshopMaterialPermissions.SETUP);
        service=new WorkshopMaterialSettingsService(new NamedParameterJdbcTemplate(db),mock(WorkshopMaterialBinSupport.class),
                mock(WorkshopMaterialCommandLedger.class),mock(WorkshopMaterialScope.class),
                new WorkshopMaterialPermissions(user),mock(WorkshopMaterialChoiceAdapter.class),mock(LineSideWarehousePort.class),user);
    }

    @Test void setupAloneReadsOnlyActiveTopLevelAccountableOrdinaryWarehouseIdentities() {
        UUID main=warehouse("A","主仓 A",null),second=warehouse("B","主仓 B",null);
        UUID child=warehouse("A1","普通叶仓",main),disabled=warehouse("OFF","禁用主仓",null);
        UUID deleted=warehouse("DEL","已删主仓",null),nonAccountable=warehouse("NON","非核算仓",null);
        UUID bin=warehouse("BIN","内料仓",null),unknownStatus=warehouse("NULL","状态未定",null);
        db.update("UPDATE warehouses SET status='禁用' WHERE id=?",disabled);
        db.update("UPDATE warehouses SET is_deleted=true WHERE id=?",deleted);
        db.update("UPDATE warehouses SET is_accountable=false WHERE id=?",nonAccountable);
        db.update("UPDATE warehouses SET is_line_side=true WHERE id=?",bin);
        db.update("UPDATE warehouses SET status=NULL WHERE id=?",unknownStatus);
        var rows=service.mainWarehouses();
        assertThat(rows).extracting(row->row.get("id")).containsExactly(main,second);
        assertThat(rows).allSatisfy(row->assertThat(row.keySet()).containsExactly("id","code","name"));
        assertThat(rows).extracting(row->row.get("id")).doesNotContain(child,disabled,deleted,nonAccountable,bin,unknownStatus);
        assertThat(db.queryForObject("SELECT count(*) FROM warehouses",Integer.class)).isEqualTo(8);
        assertThat(db.queryForObject("SELECT count(*) FROM information_schema.tables WHERE table_schema='public'",Integer.class)).isEqualTo(1);
    }

    @Test void generalViewOrInventoryViewAloneDoesNotGrantSetupCandidates() throws Exception {
        warehouse("A","主仓",null);
        for(String permission:List.of("warehouse:view",WorkshopMaterialPermissions.VIEW,"stock:view")) {
            as(permission);
            assertThatThrownBy(service::mainWarehouses).isInstanceOf(ApiException.class)
                    .satisfies(error->assertThat(((ApiException)error).getCode()).isEqualTo(ErrorCode.FORBIDDEN));
        }
        assertThat(WorkshopMaterialSettingsController.class.getMethod("mainWarehouses").getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('workshop_material:setup')");
        as(WorkshopMaterialPermissions.SETUP);
        assertThat(new WorkshopMaterialSettingsController(service).mainWarehouses()).hasSize(1);
    }

    @Test void whenNoEligibleMainExistsAnEmptyListDoesNotInventAPlacement() {
        UUID inactive=warehouse("OFF","禁用主仓",null);
        db.update("UPDATE warehouses SET status='禁用' WHERE id=?",inactive);
        assertThat(service.mainWarehouses()).isEmpty();
    }

    private void as(String... permissions) {
        when(user.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"setup-only",
                Set.of(permissions),false,true,false)));
    }
    private UUID warehouse(String code,String name,UUID parent) {
        UUID id=UUID.randomUUID();db.update("INSERT INTO warehouses(id,code,name,parent_id) VALUES (?,?,?,?)",id,code,name,parent);return id;
    }
}
