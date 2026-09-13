package com.uten.imp.migration;

import com.uten.imp.audit.AuditRetentionScheduler;
import org.flywaydb.core.Flyway;
import org.flywaydb.core.api.FlywayException;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.time.Instant;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Real V555 -> V556 upgrade; no Spring context or pool outlives the container. */
@Testcontainers(disabledWithoutDocker = true)
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class AuditClassificationMigrationPostgresTest {
    @Container
    static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("audit_v556_template");
    private static final String MIGRATED = "audit_v556_migrated";
    private static String riskExpression;
    private static String categoryExpression;
    private static Snapshot before;

    @BeforeAll
    static void migrateRealHistory() throws Exception {
        flyway(POSTGRES.getDatabaseName(), "555").migrate();
        try (Connection c = connection(POSTGRES.getDatabaseName())) {
            execute(c, """
                    INSERT INTO audit_log(id,action,result,target_type,target_id,"after") VALUES
                    (2000000001,'exportX','success','synthetic','old-1','{"quantity":1.2345}'),
                    (2000000002,'http_get','success','synthetic','blacklist','{"quantity":2.3456}');
                    INSERT INTO audit_log_archive(id,action,result,target_type,risk_level,event_category)
                    VALUES(2000000003,'historical-action','success','synthetic','historic-risk','historic-category');
                    """);
            riskExpression = expression(c, "risk_level");
            categoryExpression = expression(c, "event_category");
        }
        cloneDatabase(MIGRATED);
        try (Connection c = connection(MIGRATED)) {
            before = snapshot(c);
        }
        assertEquals(1, flyway(MIGRATED, "556").migrate().migrationsExecuted);
        flyway(MIGRATED, "556").validate();
    }

    @Test
    void forwardMigrationPreservesHistoryColumnsIndexesAndOriginalAuditFunctions() throws Exception {
        try (Connection c = connection(MIGRATED)) {
            assertEquals(before, snapshot(c));
            assertEquals("11", scalar(c, "SELECT count(*)::text FROM pg_indexes WHERE schemaname='public' AND tablename='audit_log'"));
            assertEquals("0", scalar(c, "SELECT count(*)::text FROM pg_attribute WHERE attrelid='public.audit_log'::regclass AND attgenerated<>''"));
            assertEquals("A", scalar(c, "SELECT tgenabled::text FROM pg_trigger WHERE tgrelid='public.audit_log'::regclass AND tgname='trg_audit_classify'"));
            assertEquals("2", scalar(c, "SELECT count(*)::text FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN('fn_audit_classify','fn_audit_classify_row') AND proconfig=ARRAY['search_path=pg_catalog'] AND NOT prosecdef"));
        }
    }

    @Test
    void historicalGeneratedRulesAndCandidateAgreeAcrossLargeAdversarialInputMatrix() throws Exception {
        try (Connection c = connection(MIGRATED)) {
            c.setAutoCommit(false);
            execute(c, "SET LOCAL statement_timeout='15s'; SET LOCAL jit=off");
            execute(c, "CREATE TEMPORARY TABLE classification_cases(id bigint,action text,result text,target_type text,http_path text,target_id text,status_code integer,"
                    + "risk_level text GENERATED ALWAYS AS (" + riskExpression + ") STORED,"
                    + "event_category text GENERATED ALWAYS AS (" + categoryExpression + ") STORED) ON COMMIT DROP");
            List<Object[]> cases = AuditClassificationCases.create();
            assertTrue(cases.size() >= 33000);
            try (var insert = c.prepareStatement("INSERT INTO classification_cases(id,action,result,target_type,http_path,target_id,status_code) VALUES(?,?,?,?,?,?,?)")) {
                int ordinal = 0;
                for (Object[] row : cases) {
                    insert.setLong(1, ++ordinal);
                    for (int i = 0; i < row.length; i++) insert.setObject(i + 2, row[i]);
                    insert.addBatch();
                    if (ordinal % 1000 == 0) insert.executeBatch();
                }
                insert.executeBatch();
            }
            assertEquals("0", scalar(c, """
                    SELECT count(*)::text FROM classification_cases original
                    CROSS JOIN LATERAL public.fn_audit_classify(action,result,target_type,http_path,target_id,status_code) candidate
                    WHERE original.risk_level IS DISTINCT FROM candidate.risk_level
                       OR original.event_category IS DISTINCT FROM candidate.event_category
                    """));
            assertEquals("4", scalar(c, "SELECT count(DISTINCT risk_level)::text FROM classification_cases"));
            assertEquals("7", scalar(c, "SELECT count(DISTINCT event_category)::text FROM classification_cases"));
            assertClassification(c, "exportX", null, null, null, null, null, "low", "export");
            assertClassification(c, "export_", null, null, null, null, null, "medium", "export");
            assertClassification(c, "xexport_", null, null, null, null, null, "low", "business");
            assertClassification(c, "http_get", "success", null, null, "blacklist", null, "low", "security");
            assertClassification(c, "ordinary", "refresh_reuse", null, null, null, 500, "critical", "business");
            assertClassification(c, "ordinary", null, null, null, "password", null, "low", "business");
            assertClassification(c, "ordinary", null, "password", null, null, null, "low", "authentication");
            c.rollback();
        }
    }

    @Test
    void forgedInsertUpdateAndReplicaWritesAreClassifiedDespiteShadowFunctions() throws Exception {
        try (Connection c = connection(MIGRATED)) {
            c.setAutoCommit(false);
            execute(c, """
                    CREATE SCHEMA classification_shadow;
                    CREATE FUNCTION classification_shadow.fn_audit_classify(text,text,text,text,text,integer,
                        OUT risk_level text,OUT event_category text) RETURNS record LANGUAGE sql AS $$ SELECT 'forged','forged' $$;
                    CREATE FUNCTION classification_shadow.lower(text) RETURNS text LANGUAGE sql AS $$ SELECT 'forged' $$;
                    SET LOCAL search_path=classification_shadow,public,pg_catalog;
                    INSERT INTO public.audit_log(id,action,result,risk_level,event_category)
                    VALUES(2000000010,'delete','success','low','business');
                    """);
            assertEquals("high|data_change", classification(c, 2000000010L));
            execute(c, "UPDATE public.audit_log SET action='ordinary',http_path='/export',risk_level='critical',event_category='security' WHERE id=2000000010");
            assertEquals("medium|export", classification(c, 2000000010L));
            execute(c, "UPDATE public.audit_log SET risk_level='critical',event_category='security' WHERE id=2000000010");
            assertEquals("medium|export", classification(c, 2000000010L));
            execute(c, "SET LOCAL session_replication_role=replica; INSERT INTO public.audit_log(id,action,result,risk_level,event_category) VALUES(2000000011,'delete','success','low','business')");
            assertEquals("high|data_change", classification(c, 2000000011L));
            execute(c, "UPDATE public.audit_log SET action='exportX',risk_level='critical',event_category='security' WHERE id=2000000011");
            assertEquals("low|export", classification(c, 2000000011L));
            c.rollback();
        }
    }

    @Test
    void actualAuditTriggerRedactsAndActualRetentionSqlPreservesTheCompleteSnapshot() throws Exception {
        try (Connection c = connection(MIGRATED)) {
            c.setAutoCommit(false);
            execute(c, """
                    CREATE TABLE audit_v556_material_probe(id uuid PRIMARY KEY,quantity numeric(18,4),description text);
                    CREATE TRIGGER audit_probe AFTER INSERT OR UPDATE OR DELETE ON audit_v556_material_probe
                    FOR EACH ROW EXECUTE FUNCTION public.fn_audit();
                    INSERT INTO audit_v556_material_probe VALUES('60000000-0000-4000-8000-000000000001',1.2345,'synthetic private note');
                    UPDATE audit_v556_material_probe SET quantity=2.3456;
                    DELETE FROM audit_v556_material_probe;
                    """);
            assertEquals("3", scalar(c, "SELECT count(*)::text FROM audit_log WHERE target_type='audit_v556_material_probe'"));
            assertEquals("0", scalar(c, "SELECT count(*)::text FROM audit_log WHERE target_type='audit_v556_material_probe' AND (coalesce(\"before\",'{}') ? 'description' OR coalesce(\"after\",'{}') ? 'description')"));
            assertEquals("high|data_change", scalar(c, "SELECT risk_level||'|'||event_category FROM audit_log WHERE target_type='audit_v556_material_probe' AND action='delete'"));
            assertEquals("1.2345", scalar(c, "SELECT \"after\"->>'quantity' FROM audit_log WHERE target_type='audit_v556_material_probe' AND action='insert'"));
            execute(c, "INSERT INTO audit_log(id,action,result,target_type,created_at,\"after\") VALUES(2000000020,'exportX','success','archive_probe','1900-01-01','{\"quantity\":12.3456}')");
            String expected = scalar(c, "SELECT to_jsonb(h)::text FROM audit_log h WHERE id=2000000020");
            var field = AuditRetentionScheduler.class.getDeclaredField("ARCHIVE_HOT_BATCH_SQL");
            field.setAccessible(true);
            try (var archive = c.prepareStatement((String) field.get(null))) {
                archive.setTimestamp(1, Timestamp.from(Instant.parse("1900-01-02T00:00:00Z")));
                archive.setInt(2, 5000);
                try (var rows = archive.executeQuery()) {
                    assertTrue(rows.next());
                    assertEquals(1, rows.getInt(1));
                    assertEquals(1, rows.getInt(2));
                }
            }
            assertEquals(expected, scalar(c, "SELECT to_jsonb(h)::text FROM audit_log_archive h WHERE id=2000000020"));
            assertEquals("0", scalar(c, "SELECT count(*)::text FROM audit_log WHERE id=2000000020"));
            c.rollback();
        }
    }

    @Test
    void unexpectedColumnsRulesFunctionsAndBeforeTriggersRefuseMigrationAtomically() throws Exception {
        String[] alterations = {
                "ALTER TABLE audit_log ALTER COLUMN risk_level DROP EXPRESSION",
                "ALTER TABLE audit_log DROP COLUMN risk_level; ALTER TABLE audit_log ADD COLUMN risk_level text GENERATED ALWAYS AS ('low'::text) STORED",
                "CREATE FUNCTION public.fn_audit_classify() RETURNS text LANGUAGE sql AS $$ SELECT 'unknown' $$",
                "CREATE FUNCTION public.unknown_audit_before() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$; CREATE TRIGGER unknown_audit_before BEFORE INSERT ON public.audit_log FOR EACH ROW EXECUTE FUNCTION public.unknown_audit_before()",
                "ALTER TABLE audit_log DROP COLUMN risk_level, DROP COLUMN event_category; "
                        + "ALTER TABLE audit_log ALTER COLUMN target_type TYPE text COLLATE \"C\"; "
                        + "ALTER TABLE audit_log ADD COLUMN risk_level text GENERATED ALWAYS AS (" + riskExpression + ") STORED, "
                        + "ADD COLUMN event_category text GENERATED ALWAYS AS (" + categoryExpression + ") STORED"
        };
        for (String alteration : alterations) {
            String database = "audit_v556_reject_" + UUID.randomUUID().toString().replace("-", "");
            cloneDatabase(database);
            String oldRows;
            try (Connection c = connection(database)) {
                execute(c, alteration);
                oldRows = digest(c, "audit_log");
            }
            FlywayException rejected = assertThrows(FlywayException.class, () -> flyway(database, "556").migrate());
            if (alteration.contains("COLLATE")) {
                Throwable cause = rejected;
                while (cause.getCause() != null) cause = cause.getCause();
                assertTrue(cause.getMessage().contains("one shared collation"),
                        "Mixed collations must fail the specific input-collation guard");
            }
            try (Connection c = connection(database)) {
                assertEquals(oldRows, digest(c, "audit_log"));
                assertEquals("0", scalar(c, "SELECT count(*)::text FROM flyway_schema_history WHERE version='556'"));
                assertEquals("0", scalar(c, "SELECT count(*)::text FROM pg_trigger WHERE tgrelid='public.audit_log'::regclass AND tgname='trg_audit_classify'"));
            }
        }
    }

    private record Snapshot(String hot, String archive, String columns, String indexes, String functions, String history, String heap) {}
    private static Snapshot snapshot(Connection c) throws SQLException {
        return new Snapshot(digest(c,"audit_log"), digest(c,"audit_log_archive"),
                scalar(c,"SELECT string_agg(attname||':'||atttypid||':'||atttypmod||':'||attcollation||':'||attnum,',' ORDER BY attnum) FROM pg_attribute WHERE attrelid='public.audit_log'::regclass AND attnum>0 AND NOT attisdropped"),
                scalar(c,"SELECT string_agg(indexname||':'||indexdef,E'\\n' ORDER BY indexname) FROM pg_indexes WHERE schemaname='public' AND tablename='audit_log'"),
                scalar(c,"SELECT pg_get_functiondef('public.fn_audit()'::regprocedure)||pg_get_functiondef('public.fn_audit_redact_row(text,jsonb)'::regprocedure)"),
                scalar(c,"SELECT md5(string_agg(row_to_json(h)::text, E'\\n' ORDER BY installed_rank)) FROM flyway_schema_history h WHERE version<>'556'"),
                scalar(c,"SELECT pg_relation_filenode('public.audit_log'::regclass)::text"));
    }
    private static void assertClassification(Connection c,String action,String result,String type,String path,String id,Integer status,String risk,String category) throws SQLException {
        try(var query=c.prepareStatement("SELECT * FROM public.fn_audit_classify(?,?,?,?,?,?)")) {
            Object[] values={action,result,type,path,id,status};
            for(int i=0;i<values.length;i++) query.setObject(i+1,values[i]);
            try(var rows=query.executeQuery()) { assertTrue(rows.next()); assertEquals(risk,rows.getString(1)); assertEquals(category,rows.getString(2)); assertFalse(rows.next()); }
        }
    }
    private static String classification(Connection c,long id) throws SQLException { return scalar(c,"SELECT risk_level||'|'||event_category FROM public.audit_log WHERE id="+id); }
    private static String expression(Connection c,String name) throws SQLException { return scalar(c,"SELECT pg_get_expr(d.adbin,d.adrelid) FROM pg_attribute a JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum WHERE a.attrelid='public.audit_log'::regclass AND a.attname='"+name+"'"); }
    private static String digest(Connection c,String table) throws SQLException { return scalar(c,"SELECT md5(coalesce(string_agg(to_jsonb(t)::text,E'\\n' ORDER BY id),'')) FROM public."+table+" t"); }
    private static String scalar(Connection c,String sql) throws SQLException { try(var s=c.createStatement();var rows=s.executeQuery(sql)) { assertTrue(rows.next());return rows.getString(1); } }
    private static void execute(Connection c,String sql) throws SQLException { try(var s=c.createStatement()) { s.execute(sql); } }
    private static Connection connection(String database) throws SQLException { return DriverManager.getConnection(url(database),POSTGRES.getUsername(),POSTGRES.getPassword()); }
    private static String url(String database) { String url=POSTGRES.getJdbcUrl(); int query=url.indexOf('?'); String base=query<0?url:url.substring(0,query);return base.substring(0,base.lastIndexOf('/')+1)+database+"?reWriteBatchedInserts=true"; }
    private static Flyway flyway(String database,String target) { return Flyway.configure().dataSource(url(database),POSTGRES.getUsername(),POSTGRES.getPassword()).locations("classpath:db/migration").target(target).cleanDisabled(true).callbacks(new AppliedMigrationCompatibilityCallback(),new AuditFreshStartGuardCallback()).load(); }
    private static void cloneDatabase(String database) throws SQLException { try(Connection c=connection("postgres")) { execute(c,"CREATE DATABASE \""+database+"\" TEMPLATE \""+POSTGRES.getDatabaseName()+"\""); } }
}
