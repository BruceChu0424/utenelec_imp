package com.uten.imp.migration;

import com.uten.imp.common.history.ImportedBusinessDocumentScope;
import com.uten.imp.testsupport.TestFlyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;
import java.util.TreeSet;
import java.util.UUID;
import java.util.regex.Pattern;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** Compare the exact V926 classifier and the deduplicated walk on real protected FK graphs. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class ImportedDocumentAncestryWalkPostgresTest {
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine")
            .withCommand("postgres","-c","track_functions=all");
    private static final String PASSWORD="graph-runtime-"+UUID.randomUUID();

    @BeforeAll static void schema() throws Exception {
        PG.start();
        TestFlyway.configure().dataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword()).load().migrate();
        try(var connection=owner();var sql=connection.createStatement()) {
            String source=Files.readString(Path.of("src/main/resources/db/migration/V926__imported_business_documents_archive_only.sql"));
            int start=source.indexOf("CREATE FUNCTION public.fn_imported_business_document_row_internal(");
            int end=source.indexOf("\nEND $$;",start);
            assertThat(start).isNotNegative();assertThat(end).isGreaterThan(start);
            sql.execute(source.substring(start,end+"\nEND $$;".length())
                    .replace("fn_imported_business_document_row_internal","test_only_archive_walk_reference"));
            int tableStart=source.indexOf("CREATE FUNCTION public.fn_imported_business_document_table(");
            int tableEnd=source.indexOf("\n$$;",tableStart);
            assertThat(tableStart).isNotNegative();assertThat(tableEnd).isGreaterThan(tableStart);
            sql.execute(source.substring(tableStart,tableEnd+"\n$$;".length())
                    .replace("fn_imported_business_document_table","test_only_archive_table_reference"));
            sql.execute("""
                    CREATE TABLE fixture_origin_dag (
                        id uuid PRIMARY KEY, legacy_id integer, legacy_import_run_id uuid,
                        left_parent uuid REFERENCES fixture_origin_dag(id),
                        right_parent uuid REFERENCES fixture_origin_dag(id),
                        sales_order_id uuid REFERENCES sales_orders(id),
                        source_table text, source_id uuid, payload text)
                    """);
            sql.execute("""
                    CREATE TRIGGER trg_00_imported_business_archive_only
                    BEFORE INSERT OR UPDATE OR DELETE ON fixture_origin_dag
                    FOR EACH ROW EXECUTE FUNCTION public.fn_guard_imported_business_document_archive()
                    """);
            sql.execute("ALTER TABLE fixture_origin_dag ENABLE ALWAYS TRIGGER trg_00_imported_business_archive_only");
            try(var secret=connection.prepareStatement("SELECT set_config('uten.fixture_graph_password',?,false)")) {
                secret.setString(1,PASSWORD);secret.execute();
            }
            sql.execute("""
                    DO $runtime$
                    BEGIN
                      IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='uten') THEN
                        CREATE ROLE uten LOGIN NOSUPERUSER NOINHERIT;
                      END IF;
                      EXECUTE format('ALTER ROLE uten LOGIN NOSUPERUSER NOINHERIT PASSWORD %L',
                                     current_setting('uten.fixture_graph_password'));
                    END $runtime$;
                    """);
            sql.execute("GRANT SELECT,UPDATE ON fixture_origin_dag TO uten");
        }
    }

    @AfterAll static void stop(){PG.stop();}

    @Test void sharedNativeAncestorsAreVisitedOnceWithoutChangingTheReferenceVerdict() throws Exception {
        UUID root=graph(10).getLast();
        try(var connection=owner();var sql=connection.createStatement()) {
            sql.execute("SELECT pg_stat_reset_single_function_counters('public.test_only_archive_walk_reference(text,jsonb,text[])'::regprocedure)");
            sql.execute("SELECT pg_stat_reset_single_function_counters('public.fn_imported_business_document_row_internal(text,jsonb,text[])'::regprocedure)");
            assertThat(classify(connection,root,true)).isFalse();
            assertThat(classify(connection,root,false)).isFalse();
            sql.execute("SELECT pg_stat_force_next_flush()");
        }
        try(var observer=owner()) {
            long reference=calls(observer,"test_only_archive_walk_reference");
            long actual=calls(observer,"fn_imported_business_document_row_internal");
            assertThat(reference).as("the old path-local recursion repeats the same shared ancestors").isGreaterThan(100);
            assertThat(actual).as("one call-local graph walk replaces the recursive expansion").isEqualTo(1);
        }
    }

    @Test void indexedMembershipMatchesTheOriginalCatalogForAllRelationsAndMalformedNames() throws Exception {
        List<String> names=new ArrayList<>();
        try(var connection=owner();var sql=connection.createStatement();
            var result=sql.executeQuery("SELECT c.relname::text FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public'")) {
            while(result.next()) names.add(result.getString(1));
        }
        names.add(null);names.add("");names.add("not_a_real_relation");
        names.add("fixture_origin_dag; DROP TABLE goods");
        names.add("\"fixture_origin_dag\"");names.add("x".repeat(64));
        try(var connection=owner();var query=connection.prepareStatement("SELECT public.test_only_archive_table_reference(?),public.fn_imported_business_document_table(?)")) {
            for(String name:names) {
                query.setString(1,name);query.setString(2,name);
                try(var result=query.executeQuery()) {
                    assertThat(result.next()).isTrue();
                    assertThat(result.getBoolean(2)).as("exact catalog membership: %s",name).isEqualTo(result.getBoolean(1));
                }
            }
        }
    }

    @Test void directInheritedRunAndPolymorphicOriginsMatchTheUnmodifiedReference() throws Exception {
        List<UUID> nodes=graph(5);UUID root=nodes.getLast(),leaf=nodes.getFirst();
        try(var connection=owner()) {
            assertSame(connection,root,false);
            try(var update=connection.prepareStatement("UPDATE fixture_origin_dag SET legacy_id=42 WHERE id=?")) {
                update.setObject(1,leaf);update.executeUpdate();
            }
            assertSame(connection,root,true);
            try(var update=connection.prepareStatement("UPDATE fixture_origin_dag SET legacy_id=NULL,legacy_import_run_id=? WHERE id=?")) {
                update.setObject(1,UUID.randomUUID());update.setObject(2,leaf);update.executeUpdate();
            }
            assertSame(connection,root,true);
            UUID typed=graph(1).getFirst();
            try(var update=connection.prepareStatement("UPDATE fixture_origin_dag SET source_table='fixture_origin_dag',source_id=? WHERE id=?")) {
                update.setObject(1,leaf);update.setObject(2,typed);update.executeUpdate();
            }
            assertSame(connection,typed,true);
        }
    }

    @Test void nativeCyclesTerminateAndTheExistingDepthBoundaryStillFailsClosed() throws Exception {
        List<UUID> cycle=graph(4);
        try(var connection=owner();var update=connection.prepareStatement("UPDATE fixture_origin_dag SET left_parent=?,right_parent=? WHERE id=?")) {
            update.setObject(1,cycle.getLast());update.setObject(2,cycle.getLast());update.setObject(3,cycle.getFirst());update.executeUpdate();
            assertSame(connection,cycle.getLast(),false);
        }
        UUID deep=graph(67).getLast();
        for(boolean reference:List.of(true,false)) {
            try(var connection=owner()) {
                assertThatThrownBy(()->classify(connection,deep,reference)).isInstanceOf(SQLException.class)
                        .extracting(error->((SQLException)error).getSQLState()).isEqualTo("54001");
            }
        }
    }

    @Test void authenticatedRuntimeCannotModifyInheritedHistoryOrSpoofTheMaintenanceException() throws Exception {
        List<UUID> nodes=graph(5);UUID root=nodes.getLast();
        try(var connection=owner();var update=connection.prepareStatement("UPDATE fixture_origin_dag SET legacy_id=99 WHERE id=?")) {
            update.setObject(1,nodes.getFirst());update.executeUpdate();
        }
        try(var runtime=DriverManager.getConnection(PG.getJdbcUrl(),"uten",PASSWORD);var sql=runtime.createStatement()) {
            try(var role=sql.executeQuery("SELECT session_user,rolsuper FROM pg_roles WHERE rolname=session_user")) {
                assertThat(role.next()).isTrue();assertThat(role.getString(1)).isEqualTo("uten");assertThat(role.getBoolean(2)).isFalse();
            }
            sql.execute("SELECT set_config('app.legacy_import','true',false)");
            try(var update=runtime.prepareStatement("UPDATE fixture_origin_dag SET payload='must not persist' WHERE id=?")) {
                update.setObject(1,root);
                assertThatThrownBy(update::executeUpdate).isInstanceOf(SQLException.class)
                        .extracting(error->((SQLException)error).getSQLState()).isEqualTo("55000");
            }
        }
        try(var connection=owner();var query=connection.prepareStatement("SELECT payload FROM fixture_origin_dag WHERE id=?")) {
            query.setObject(1,root);try(var result=query.executeQuery()){assertThat(result.next()).isTrue();assertThat(result.getString(1)).isNull();}
        }
    }

    @Test void fullPhysicalRowEntrypointMatchesDirectInheritedRunDeletedUnknownAndNullFacts() throws Exception {
        var chain=graph(4);UUID leaf=chain.getFirst(),inherited=chain.getLast(),nativeId=graph(1).getFirst();
        try(var connection=owner();var sql=connection.createStatement()) {
            sql.execute("ALTER TABLE fixture_origin_dag ADD COLUMN IF NOT EXISTS is_deleted boolean NOT NULL DEFAULT false");
            try(var update=connection.prepareStatement("UPDATE fixture_origin_dag SET legacy_id=41 WHERE id=?")) {update.setObject(1,leaf);update.executeUpdate();}
            compareEntrypoints(connection,inherited,true);compareEntrypoints(connection,nativeId,false);compareEntrypoints(connection,leaf,true);
            try(var update=connection.prepareStatement("UPDATE fixture_origin_dag SET legacy_id=NULL,legacy_import_run_id=?,is_deleted=true WHERE id=?")) {update.setObject(1,UUID.randomUUID());update.setObject(2,leaf);update.executeUpdate();}
            compareEntrypoints(connection,leaf,true);compareEntrypoints(connection,inherited,true);
            try(var query=connection.prepareStatement("SELECT fn_imported_business_document('fixture_origin_dag',id),fn_imported_business_document_row('fixture_origin_dag',jsonb_build_object('id',id)),fn_imported_business_document_row('employees',to_jsonb(node)) FROM fixture_origin_dag node WHERE id=?")) {
                query.setObject(1,inherited);try(var result=query.executeQuery()) {assertThat(result.next()).isTrue();assertThat(result.getBoolean(1)).isTrue();assertThat(result.getBoolean(2)).as("partial rows discard inherited source fields").isFalse();assertThat(result.getBoolean(3)).as("wrong table aliases do not identify the real source graph").isFalse();}
            }
            UUID deleted=graph(1).getFirst();try(var delete=connection.prepareStatement("DELETE FROM fixture_origin_dag WHERE id=?")){delete.setObject(1,deleted);delete.executeUpdate();}
            for(UUID absent:List.of(deleted,UUID.randomUUID()))try(var query=connection.prepareStatement("SELECT fn_imported_business_document('fixture_origin_dag',?),fn_imported_business_document_row('fixture_origin_dag',NULL::jsonb)")) {query.setObject(1,absent);try(var result=query.executeQuery()){result.next();assertThat(result.getBoolean(1)).isFalse();assertThat(result.getBoolean(2)).isFalse();}}
            try(var result=sql.executeQuery("SELECT fn_imported_business_document('fixture_origin_dag',NULL::uuid),fn_imported_business_document_row('fixture_origin_dag',NULL::jsonb)")){result.next();assertThat(result.getBoolean(1)).isFalse();assertThat(result.getBoolean(2)).isFalse();}
        }
    }

    @Test void runtimeRlsAndArchiveWriteGuardsRemainOutsideBothReadEntrypoints() throws Exception {
        UUID imported=graph(2).getLast(),visibleCurrent=UUID.randomUUID(),visibleHistory=UUID.randomUUID(),hidden=UUID.randomUUID();
        try(var connection=owner();var sql=connection.createStatement()) {
            try(var update=connection.prepareStatement("UPDATE fixture_origin_dag SET legacy_id=73 WHERE id=?")){update.setObject(1,imported);update.executeUpdate();}
            sql.execute("CREATE TABLE fixture_origin_rls(id uuid PRIMARY KEY,legacy_id integer,parent_id uuid REFERENCES fixture_origin_dag(id),visible boolean NOT NULL,payload text)");
            sql.execute("CREATE TRIGGER trg_00_imported_business_archive_only BEFORE INSERT OR UPDATE OR DELETE ON fixture_origin_rls FOR EACH ROW EXECUTE FUNCTION fn_guard_imported_business_document_archive()");
            try(var insert=connection.prepareStatement("INSERT INTO fixture_origin_rls(id,parent_id,visible) VALUES (?,?,?)")) {for(UUID id:List.of(visibleCurrent,visibleHistory,hidden)){insert.setObject(1,id);insert.setObject(2,id.equals(visibleHistory)?imported:null);insert.setBoolean(3,!id.equals(hidden));insert.executeUpdate();}}
            sql.execute("ALTER TABLE fixture_origin_rls ENABLE ROW LEVEL SECURITY");
            sql.execute("CREATE POLICY runtime_visible ON fixture_origin_rls TO uten USING(visible) WITH CHECK(visible)");
            sql.execute("GRANT SELECT,UPDATE ON fixture_origin_rls TO uten");
        }
        try(var runtime=DriverManager.getConnection(PG.getJdbcUrl(),"uten",PASSWORD)) {
            for(String origin:List.of("CURRENT","LEGACY","ALL")) {
                var before=originRows(runtime,"fixture_origin_rls",origin,false);
                var after=originRows(runtime,"fixture_origin_rls",origin,true);
                assertThat(after).isEqualTo(before).doesNotContain(hidden);
                assertThat(after).containsExactlyInAnyOrderElementsOf(origin.equals("ALL")?List.of(visibleCurrent,visibleHistory):List.of(origin.equals("CURRENT")?visibleCurrent:visibleHistory));
            }
            try(var update=runtime.prepareStatement("UPDATE fixture_origin_rls SET payload='forbidden history write' WHERE id=?")) {update.setObject(1,visibleHistory);assertThatThrownBy(update::executeUpdate).isInstanceOf(SQLException.class).extracting(error->((SQLException)error).getSQLState()).isEqualTo("55000");}
        }
    }

    @Test void multiLineRowEntrypointEliminatesTopLevelReadsWithoutCachingTheAncestryDecision() throws Exception {
        var chain=graph(3);UUID root=chain.getLast();List<Long> physicalScans=new ArrayList<>();
        // Transaction-local counters are synchronous; cumulative cross-session statistics flush asynchronously.
        // https://www.postgresql.org/docs/16/monitoring-stats.html
        for(boolean row:List.of(false,true))try(var connection=owner()) {
            connection.setAutoCommit(false);
            long beforeScans=xactScans(connection),beforeEntry=xactCalls(connection,"fn_imported_business_document"),
                    beforeWalk=xactCalls(connection,"fn_imported_business_document_row_internal");
            String expression=row?"fn_imported_business_document_row('fixture_origin_dag',to_jsonb(document))":"fn_imported_business_document('fixture_origin_dag',document.id)";
            try(var query=connection.prepareStatement("SELECT count(*),count(*) FILTER(WHERE "+expression+") FROM fixture_origin_dag document CROSS JOIN generate_series(1,40) detail WHERE document.id=?")){query.setObject(1,root);try(var result=query.executeQuery()){result.next();assertThat(result.getLong(1)).isEqualTo(40);assertThat(result.getLong(2)).isZero();}}
            long entryCalls=xactCalls(connection,"fn_imported_business_document")-beforeEntry,
                    walkCalls=xactCalls(connection,"fn_imported_business_document_row_internal")-beforeWalk,
                    scans=xactScans(connection)-beforeScans;
            assertThat(entryCalls).isEqualTo(row?0:40);assertThat(walkCalls).isEqualTo(40);physicalScans.add(scans);
            System.out.println("ORIGIN-ROW-READS entry="+(row?"row":"table-id")+" lines=40 topLevelCalls="+entryCalls+" ancestryWalks="+walkCalls+" transactionLocalPhysicalScans="+scans);
            connection.rollback();
        }
        assertThat(physicalScans.getFirst()-physicalScans.getLast()).as("one actual root-table read removed per detail, ancestor reads retained").isEqualTo(40);
        try(var connection=owner();var update=connection.prepareStatement("UPDATE fixture_origin_dag SET legacy_id=101 WHERE id=?")){update.setObject(1,chain.getFirst());update.executeUpdate();compareEntrypoints(connection,root,true);}
    }
    private static long xactCalls(Connection connection,String name) throws SQLException {
        try(var query=connection.prepareStatement("SELECT COALESCE(sum(calls),0) FROM pg_stat_xact_user_functions WHERE schemaname='public' AND funcname=?")){query.setString(1,name);try(var rows=query.executeQuery()){rows.next();return rows.getLong(1);}}
    }
    private static long xactScans(Connection connection) throws SQLException {
        try(var query=connection.createStatement();var rows=query.executeQuery("SELECT seq_scan+idx_scan FROM pg_stat_xact_user_tables WHERE relname='fixture_origin_dag'")){rows.next();return rows.getLong(1);}
    }

    @Test void migratedNativeRowCallersTargetPhysicalRelationsWithNonNullUuidIdentity() throws Exception {
        var pattern = Pattern.compile(
                "ImportedBusinessDocumentScope\\s*\\.\\s*(?:nativeTable|nativeRowsByKey|nativePredicate)"
                        + "\\s*\\(\\s*\"([a-z_][a-z_0-9]*)\"");
        var tables = new TreeSet<String>();
        int occurrences = 0;
        try (var files = Files.walk(Path.of("src/main/java"))) {
            for (Path file : files.filter(path -> path.toString().endsWith(".java")).toList()) {
                var caller = pattern.matcher(Files.readString(file));
                while (caller.find()) {
                    tables.add(caller.group(1));
                    occurrences++;
                }
            }
        }
        assertThat(tables).isNotEmpty().doesNotContain("platform_record_fields");
        for (String table : tables) {
            assertThat(ImportedBusinessDocumentScope.nativePredicate(table, "archive_origin"))
                    .endsWith("NOT fn_imported_business_document_row('" + table + "',to_jsonb(archive_origin))");
        }
        try(var connection=owner();var query=connection.prepareStatement("SELECT c.relkind,a.attnotnull,a.atttypid='uuid'::regtype,EXISTS(SELECT 1 FROM pg_index pk WHERE pk.indrelid=c.oid AND pk.indisprimary AND pk.indnkeyatts=1 AND pk.indkey[0]=a.attnum) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_attribute a ON a.attrelid=c.oid AND a.attname='id' AND NOT a.attisdropped WHERE n.nspname='public' AND c.relname=?")) {for(String table:tables){query.setString(1,table);try(var result=query.executeQuery()){assertThat(result.next()).as(table).isTrue();assertThat(result.getString(1)).isIn("r","p");assertThat(result.getBoolean(2)).as(table+" id NOT NULL").isTrue();assertThat(result.getBoolean(3)).as(table+" id UUID").isTrue();assertThat(result.getBoolean(4)).as(table+" unique primary identity").isTrue();}}}
        System.out.println("ORIGIN-ROW-CATALOG physicalTables="+tables.size()+" verifiedCompleteRowCallers="+occurrences);
    }

    private static void compareEntrypoints(Connection connection,UUID id,boolean expected) throws SQLException {
        try(var query=connection.prepareStatement("SELECT fn_imported_business_document('fixture_origin_dag',node.id),fn_imported_business_document_row('fixture_origin_dag',to_jsonb(node)) FROM fixture_origin_dag node WHERE id=?")){query.setObject(1,id);try(var result=query.executeQuery()){assertThat(result.next()).isTrue();assertThat(result.getBoolean(1)).isEqualTo(expected);assertThat(result.getBoolean(2)).isEqualTo(expected);}}
    }
    private static List<UUID> originRows(Connection connection,String table,String origin,boolean row) throws SQLException {
        String imported=row?"fn_imported_business_document_row('"+table+"',to_jsonb(archive_origin))":"fn_imported_business_document('"+table+"',archive_origin.id)";
        String predicate=origin.equals("ALL")?"TRUE":origin.equals("CURRENT")?"NOT "+imported:imported;
        List<UUID> result=new ArrayList<>();try(var query=connection.createStatement();var rows=query.executeQuery("SELECT id FROM "+table+" archive_origin WHERE "+predicate+" ORDER BY id")){while(rows.next())result.add(rows.getObject(1,UUID.class));}return result;
    }

    private static List<UUID> graph(int size) throws SQLException {
        List<UUID> ids=new ArrayList<>();
        try(var connection=owner();var insert=connection.prepareStatement("INSERT INTO fixture_origin_dag(id,left_parent,right_parent) VALUES (?,?,?)")) {
            for(int index=0;index<size;index++) {
                UUID id=UUID.randomUUID(),parent=ids.isEmpty()?null:ids.getLast();
                insert.setObject(1,id);insert.setObject(2,parent);insert.setObject(3,parent);insert.executeUpdate();ids.add(id);
            }
        }
        return ids;
    }

    private static boolean classify(Connection connection,UUID id,boolean reference) throws SQLException {
        String statement=reference
                ? "SELECT public.test_only_archive_walk_reference('fixture_origin_dag',to_jsonb(node),ARRAY[]::text[]) FROM fixture_origin_dag node WHERE id=?"
                : "SELECT public.fn_imported_business_document('fixture_origin_dag',?)";
        try(var query=connection.prepareStatement(statement)) {
            query.setObject(1,id);try(var rows=query.executeQuery()){assertThat(rows.next()).isTrue();return rows.getBoolean(1);}
        }
    }

    private static void assertSame(Connection connection,UUID id,boolean expected) throws SQLException {
        assertThat(classify(connection,id,true)).isEqualTo(expected);
        assertThat(classify(connection,id,false)).isEqualTo(expected);
    }

    private static long calls(Connection connection,String name) throws SQLException {
        try(var query=connection.prepareStatement("SELECT COALESCE(sum(calls),0) FROM pg_stat_user_functions WHERE schemaname='public' AND funcname=?")) {
            query.setString(1,name);try(var rows=query.executeQuery()){rows.next();return rows.getLong(1);}
        }
    }

    private static Connection owner() throws SQLException {
        return DriverManager.getConnection(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
    }
}
