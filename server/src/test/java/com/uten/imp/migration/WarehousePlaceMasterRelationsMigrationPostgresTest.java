package com.uten.imp.migration;

import com.uten.imp.support.MigratedProjectionSchema;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.UUID;
import static org.assertj.core.api.Assertions.assertThat;

@Testcontainers(disabledWithoutDocker = true)
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS", matches="(?i)true")
class WarehousePlaceMasterRelationsMigrationPostgresTest {
    @Container static final PostgreSQLContainer<?> PG = new PostgreSQLContainer<>("postgres:16-alpine");
    static JdbcTemplate db;
    @BeforeAll static void schema() {
        db = new JdbcTemplate(new DriverManagerDataSource(PG.getJdbcUrl(), PG.getUsername(), PG.getPassword()));
        MigratedProjectionSchema.createTables(db,"622",
                "warehouses",
                "goods",
                "users",
                "user_preferences",
                "production_daily_report_items",
                "production_finished_arrival_registrations",
                "production_finished_arrival_registration_items",
                "production_finished_arrival_registration_reversals",
                "warehouse_goods_place_preferences");
    }
    @BeforeEach void clean() {
        db.execute("TRUNCATE warehouse_goods_place_preferences,production_finished_arrival_registration_items,"
                + "production_finished_arrival_registrations,production_finished_arrival_registration_reversals,"
                + "production_daily_report_items,goods,warehouses,users,user_preferences CASCADE");
    }
    @Test void backfillsOnlyExactWarehouseGoodsColorDimensionsAndKeepsOriginalSourceIdentity() throws Exception {
        UUID warehouse = warehouse(), other = warehouse(), goods = goods(null, false), red=UUID.randomUUID(), blue=UUID.randomUUID();
        UUID registration = register(warehouse,goods,red,1,"RED-1-1","RED-1-1");
        register(warehouse,goods,blue,1,"BLUE-1-1");
        register(warehouse,goods,null,1,"NONE-1-1");
        register(other,goods,red,1,"OTHER-1-1");
        migrate();
        assertThat(db.queryForObject("SELECT count(*) FROM warehouse_goods_place_preferences",Long.class)).isEqualTo(4);
        assertThat(db.queryForObject("SELECT source_registration_id FROM warehouse_goods_place_preferences WHERE warehouse_id=? AND goods_id=? AND color_id=?",
                UUID.class,warehouse,goods,red)).isEqualTo(registration);
        assertThat(db.queryForObject("""
                SELECT preference.last_selected_by=actor.employee_id
                  AND preference.last_selected_by<>registration.receiver_employee_id
                FROM warehouse_goods_place_preferences preference
                JOIN production_finished_arrival_registrations registration ON registration.id=preference.source_registration_id
                JOIN users actor ON actor.id=registration.created_by WHERE registration.id=?
                """,Boolean.class,registration)).isTrue();
        assertThat(db.queryForObject("SELECT place FROM warehouse_goods_place_preferences WHERE warehouse_id=? AND color_id IS NULL",String.class,warehouse)).isEqualTo("NONE-1-1");
        assertThat(db.queryForObject("SELECT stock_place FROM goods WHERE id=?",String.class,goods)).isNull();
        migrate();
        assertThat(db.queryForObject("SELECT count(*) FROM warehouse_goods_place_preferences",Long.class)).isEqualTo(4);
        assertThat(db.queryForObject("SELECT sum(selection_count) FROM warehouse_goods_place_preferences",Long.class)).isEqualTo(4);
        assertThat(db.queryForObject("SELECT count(*) FROM production_finished_arrival_registration_items",Long.class)).isEqualTo(5);
    }
    @Test void neverResurrectsAmbiguousReversedOrOlderThanMasterDefaultsOrOverwritesExistingRelations() throws Exception {
        UUID warehouse=warehouse();
        UUID ambiguous=goods(null,false);
        register(warehouse,ambiguous,null,1,"OLD-1-1");
        register(warehouse,ambiguous,null,2,"A-1-1","B-1-1");
        UUID master=goods("MASTER-9-9",false); register(warehouse,master,null,1,"HISTORY-1-1");
        UUID cleared=goods(null,true); register(warehouse,cleared,null,1,"CLEARED-1-1");
        UUID reversed=goods(null,false);
        UUID reversedRegistration=register(warehouse,reversed,null,1,"REVERSED-1-1");
        db.update("INSERT INTO production_finished_arrival_registration_reversals(id,registration_id) VALUES (?,?)",UUID.randomUUID(),reversedRegistration);
        UUID partial=goods(null,false); register(warehouse,partial,null,1,"A-1-1",null);
        UUID existing=goods(null,false); UUID source=register(warehouse,existing,null,1,"OLD-1-1");
        db.update("""
                INSERT INTO warehouse_goods_place_preferences(warehouse_id,goods_id,place,version,selection_count,
                    source_kind,source_registration_id,source_registered_at,last_selected_by,last_selected_at,created_by,updated_by)
                SELECT warehouse_id,?,'EXPLICIT-2-2',7,9,'FINISHED_ARRIVAL',id,created_at,
                       receiver_employee_id,created_at,created_by,created_by FROM production_finished_arrival_registrations WHERE id=?
                """,existing,source);
        migrate();
        assertThat(db.queryForObject("SELECT count(*) FROM warehouse_goods_place_preferences",Long.class)).isEqualTo(1);
        assertThat(db.queryForObject("SELECT place FROM warehouse_goods_place_preferences",String.class)).isEqualTo("EXPLICIT-2-2");
        assertThat(db.queryForObject("SELECT version FROM warehouse_goods_place_preferences",Long.class)).isEqualTo(7);
        assertThat(db.queryForObject("SELECT stock_place FROM goods WHERE id=?",String.class,master)).isEqualTo("MASTER-9-9");
    }
    @Test void retiresOnlyTheUnscopedShelfMemoryWhilePreservingPersonalWarehouseAndUnrelatedPreferences() throws Exception {
        db.update("INSERT INTO user_preferences(user_id,pref_key,pref_value,updated_at) VALUES (?, 'warehouse.arrivalFill', ?::jsonb, now())", UUID.randomUUID(),
                "{\"warehouseId\":\"warehouse-a\",\"stockPlace\":\"WRONG-FOR-OTHER-GOODS\"}");
        db.update("INSERT INTO user_preferences(user_id,pref_key,pref_value,updated_at) VALUES (?, 'other.preference', ?::jsonb, now())", UUID.randomUUID(), "{\"stockPlace\":\"keep\"}");
        db.update("INSERT INTO user_preferences(user_id,pref_key,pref_value,updated_at) VALUES (?, 'warehouse.arrivalFill', ?::jsonb, now())", UUID.randomUUID(), "\"old scalar value\"");
        migrate();
        assertThat(db.queryForObject("SELECT pref_value FROM user_preferences WHERE pref_key='warehouse.arrivalFill' AND jsonb_typeof(pref_value)='object'",String.class))
                .contains("warehouse-a").doesNotContain("stockPlace");
        assertThat(db.queryForObject("SELECT pref_value FROM user_preferences WHERE pref_key='other.preference'",String.class)).contains("keep");
        assertThat(db.queryForObject("SELECT count(*) FROM user_preferences",Long.class)).isEqualTo(3);
    }
    private void migrate() throws Exception {
        db.execute(Files.readString(Path.of("src/main/resources/db/migration/V623__warehouse_place_master_relations.sql")));
    }
    private UUID warehouse() { UUID id=UUID.randomUUID(); db.update("INSERT INTO warehouses(id) VALUES (?)",id);return id; }
    private UUID goods(String place,boolean newer) {
        UUID id=UUID.randomUUID();db.update("INSERT INTO goods(id,stock_place,updated_at) VALUES (?,?,?::timestamptz)",
                id,place,newer?"2026-09-30T00:00:00Z":"2026-09-01T00:00:00Z");return id;
    }
    private UUID register(UUID warehouse,UUID goods,UUID color,int day,String... places) {
        UUID registration=UUID.randomUUID(),actor=UUID.randomUUID();
        db.update("INSERT INTO users(id,employee_id) VALUES (?,?)",actor,UUID.randomUUID());
        db.update("INSERT INTO production_finished_arrival_registrations(id,warehouse_id,created_at,created_by,receiver_employee_id) VALUES (?,?,?::timestamptz,?,?)",
                registration,warehouse,"2026-09-%02dT00:00:00Z".formatted(day+10),actor,UUID.randomUUID());
        for(String place:places) {
            UUID item=UUID.randomUUID();db.update("INSERT INTO production_daily_report_items(id,goods_id,color_id) VALUES (?,?,?)",item,goods,color);
            db.update("INSERT INTO production_finished_arrival_registration_items(id,registration_id,source_report_item_id,place_snapshot,reversal_id) VALUES (?,?,?,?,NULL)",UUID.randomUUID(),registration,item,place);
        }
        return registration;
    }
}
