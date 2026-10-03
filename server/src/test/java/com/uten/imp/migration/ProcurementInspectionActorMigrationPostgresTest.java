package com.uten.imp.migration;

import com.uten.imp.features.stock.StockReadSideSeed;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;

/** Applied migration bytes stay unchanged; the forward column never guesses historical command users. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class ProcurementInspectionActorMigrationPostgresTest {
    @Test void forwardMigrationKeepsHistoricalEventExactlyAndUserNullEvenWhenAnEmployeeIsRecorded()throws Exception {
        try(var postgres=new PostgreSQLContainer<>("postgres:16-alpine")){
            postgres.start();var ds=new DriverManagerDataSource(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword());
            Flyway.configure().dataSource(ds).locations("classpath:db/migration").target("772").load().migrate();
            UUID event=UUID.randomUUID(),linkedUser=UUID.randomUUID();
            try(var seed=new StockReadSideSeed(ds)){
                UUID department=UUID.randomUUID(),employee=UUID.randomUUID();
                seed.jdbc().update("INSERT INTO departments(id,code,name,level) VALUES(?,?,?,'一级部门')",department,"IQC-D-"+department,"历史检验部门");
                seed.jdbc().update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES(?,?,?,'其他',?,CURRENT_DATE,'active','regular')",employee,"IQC-E-"+employee,"已记录检验员",department);
                seed.jdbc().update("INSERT INTO users(id,employee_id,login_account,password_hash,status,must_change_password) VALUES(?,?,?,'test-only','active',FALSE)",linkedUser,employee,"iqc-linked-"+linkedUser);
                UUID warehouse=seed.warehouse("历史IQC",null),unit=seed.unit("个",null),goods=seed.goods("历史IQC原件",unit,null),inspection=UUID.randomUUID();
                seed.jdbc().update("""
                        INSERT INTO procurement_inspection_items(id,receipt_type,receipt_id,receipt_item_id,warehouse_id,goods_id,unit_id,unit_rate,received_base_qty)
                        VALUES(?,'PURCHASE',?,?,?,?,?,1,1)
                        """,inspection,UUID.randomUUID(),UUID.randomUUID(),warehouse,goods,unit);
                seed.jdbc().update("INSERT INTO procurement_inspection_events(id,inspection_item_id,action,base_qty,actor_employee_id) VALUES(?,?,'RECEIVED',1,?)",event,inspection,employee);
            }
            var db=new JdbcTemplate(ds);String original=db.queryForObject("SELECT to_jsonb(e)::text FROM procurement_inspection_events e WHERE id=?",String.class,event);
            Flyway.configure().dataSource(ds).locations("classpath:db/migration").target("774").load().migrate();
            assertNull(db.queryForObject("SELECT actor_user_id FROM procurement_inspection_events WHERE id=?",UUID.class,event));
            assertEquals(original,db.queryForObject("SELECT (to_jsonb(e)-'actor_user_id')::text FROM procurement_inspection_events e WHERE id=?",String.class,event));
            assertEquals(774,db.queryForObject("SELECT max(version::int) FROM flyway_schema_history",Integer.class));
            var failure=assertThrows(org.springframework.dao.DataAccessException.class,
                    ()->db.update("UPDATE procurement_inspection_events SET actor_user_id=? WHERE id=?",linkedUser,event));
            assertInstanceOf(java.sql.SQLException.class,failure.getMostSpecificCause());
            assertEquals("55000",((java.sql.SQLException)failure.getMostSpecificCause()).getSQLState(),
                    "A real existing user must still be unable to claim an immutable historical event");
        }
    }
}
