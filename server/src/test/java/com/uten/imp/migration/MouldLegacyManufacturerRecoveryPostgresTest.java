package com.uten.imp.migration;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import com.uten.imp.support.MigratedProjectionSchema;
import org.testcontainers.postgresql.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/** Actual PostgreSQL DML oracle; does not claim the full migration-chain/UAT gate. */
@Testcontainers(disabledWithoutDocker = true)
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class MouldLegacyManufacturerRecoveryPostgresTest {
    @Container
    static final PostgreSQLContainer POSTGRES = new PostgreSQLContainer("postgres:16.15-alpine");

    @Test
    void recoversConfirmedTextOnlyAndKeepsNewerManualAndLinkedFacts() throws Exception {
        try (var connection = java.sql.DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())) {
            var db = new JdbcTemplate(new SingleConnectionDataSource(connection, true));
            // The forward DML starts at its real pre-V972 column/key contract.
            // This remains a narrow oracle, not a substitute for the full migrated
            // business database's CHECK/FK/history-trigger and import safety gates.
            MigratedProjectionSchema.createTables(db, "971", "moulds", "mould_categories",
                    "system_master_category_registry", "category_master_code_sequences");
            // A session-only observer records changed values; the owned connection
            // keeps it alive across JdbcTemplate calls and removes it on close.
            db.execute("""
                    CREATE TEMP TABLE mutation_evidence(mould_id uuid, before_row jsonb, after_row jsonb);
                    CREATE FUNCTION retain_evidence() RETURNS trigger LANGUAGE plpgsql AS $$
                    BEGIN INSERT INTO mutation_evidence VALUES(NEW.id,to_jsonb(OLD),to_jsonb(NEW)); RETURN NEW; END $$;
                    CREATE TRIGGER evidence AFTER UPDATE ON moulds FOR EACH ROW EXECUTE FUNCTION retain_evidence();
                    """);
            // These identities/texts occur in the reviewed backup snapshot.
            var recover = UUID.randomUUID();
            var manual = UUID.randomUUID();
            var changed = UUID.randomUUID();
            var linked = UUID.randomUUID();
            var deleted = UUID.randomUUID();
            var namedManufacturer = UUID.randomUUID();
            var exactWhitespace = UUID.randomUUID();
            db.update("INSERT INTO moulds(id,legacy_id,keeper,code,mstatus,remark) VALUES(?,3796,'双惠','2022-11-170','2023年2月','原备注')", recover);
            db.update("INSERT INTO moulds(id,legacy_id,keeper,manufacturer) VALUES(?,3794,'双惠','人工确认制造商')", manual);
            db.update("INSERT INTO moulds(id,legacy_id,keeper) VALUES(?,3830,'后来修改的保管人')", changed);
            db.update("INSERT INTO moulds(id,legacy_id,keeper,keeper_id) VALUES(?,3797,'双惠',?)", linked, UUID.randomUUID());
            db.update("INSERT INTO moulds(id,legacy_id,keeper,is_deleted) VALUES(?,3798,'双惠',true)", deleted);
            db.update("INSERT INTO moulds(legacy_id,keeper) VALUES(999999,'双惠')");
            db.update("INSERT INTO moulds(id,legacy_id,keeper) VALUES(?,2357,'李海湛')", namedManufacturer);
            db.update("INSERT INTO moulds(id,legacy_id,keeper) VALUES(?,2990,'中山晨欣 ')", exactWhitespace);
            String protectedRows = db.queryForObject("""
                    SELECT jsonb_agg(to_jsonb(m) ORDER BY legacy_id)::text
                    FROM moulds m WHERE legacy_id NOT IN (3796,2357,2990)
                    """, String.class);
            String migration;
            try (var input = getClass().getResourceAsStream("/db/migration/V972__recover_legacy_mould_manufacturer.sql")) {
                if (input == null) throw new IllegalStateException("Missing V972 recovery migration");
                migration = new String(input.readAllBytes(), StandardCharsets.UTF_8);
            }
            db.execute(migration);
            assertThat(db.queryForMap("SELECT manufacturer,keeper,code,mstatus,remark FROM moulds WHERE id=?", recover))
                    .containsEntry("manufacturer", "双惠").containsEntry("keeper", null)
                    .containsEntry("code", "2022-11-170").containsEntry("mstatus", "2023年2月").containsEntry("remark", "原备注");
            assertThat(db.queryForObject("SELECT manufacturer FROM moulds WHERE id=?", String.class, manual))
                    .isEqualTo("人工确认制造商");
            assertThat(db.queryForObject("SELECT keeper FROM moulds WHERE id=?", String.class, changed))
                    .isEqualTo("后来修改的保管人");
            assertThat(db.queryForObject("SELECT manufacturer FROM moulds WHERE id=?", String.class, namedManufacturer)).isEqualTo("李海湛");
            assertThat(db.queryForObject("SELECT manufacturer FROM moulds WHERE id=?", String.class, exactWhitespace)).isEqualTo("中山晨欣 ");
            assertThat(db.queryForObject("SELECT count(*) FROM moulds WHERE manufacturer IS NOT NULL", Integer.class)).isEqualTo(4);
            assertThat(db.queryForObject("SELECT count(*) FROM mutation_evidence", Integer.class)).isEqualTo(3);
            assertThat(db.queryForObject("SELECT before_row->>'keeper' FROM mutation_evidence WHERE mould_id=?", String.class, recover)).isEqualTo("双惠");
            assertThat(db.queryForObject("""
                    SELECT jsonb_agg(to_jsonb(m) ORDER BY legacy_id)::text
                    FROM moulds m WHERE legacy_id NOT IN (3796,2357,2990)
                    """, String.class)).isEqualTo(protectedRows);
            db.execute(migration);
            assertThat(db.queryForObject("SELECT count(*) FROM mutation_evidence", Integer.class)).isEqualTo(3);

            // Exercise the owning offline importer as well: otherwise a future
            // bootstrap would recreate the same semantic error after V972 ran.
            db.execute("""
                    INSERT INTO mould_categories(id,legacy_id,is_deleted)
                    VALUES('00000000-0000-4000-8000-000000000001',-1,false);
                    INSERT INTO system_master_category_registry(id,mould_category_id)
                    VALUES('27500000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000001');
                    """);
            String importer = Files.readString(Path.of("legacy_migration/migrate_mould_data.sql"), StandardCharsets.UTF_8);
            importer = importer.replaceAll("(?m)^\\\\copy mould_stage[^\\r\\n]*", """
                    INSERT INTO mould_stage VALUES
                      (3796,0,'旧模具','OLD-A',NULL,'1',1,'2023年2月','使用','注塑车间','双惠','原备注'),
                      (999999,0,'空制造商','OLD-B',NULL,'1',1,NULL,'使用',NULL,NULL,NULL);
                    """);
            db.execute(importer);
            assertThat(db.queryForMap("SELECT manufacturer,keeper,remark FROM moulds WHERE legacy_id=3796"))
                    .containsEntry("manufacturer", "双惠").containsEntry("keeper", null).containsEntry("remark", "原备注");
            assertThat(db.queryForObject("SELECT manufacturer FROM moulds WHERE legacy_id=999999", String.class)).isNull();
            assertThat(db.queryForObject("SELECT count(*) FROM moulds", Integer.class)).isEqualTo(2);
        }
    }
}
