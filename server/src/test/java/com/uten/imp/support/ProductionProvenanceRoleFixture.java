package com.uten.imp.support;

import com.uten.imp.migration.AppliedMigrationCompatibilityCallback;
import com.uten.imp.migration.AuditFreshStartGuardCallback;
import org.flywaydb.core.Flyway;
import java.nio.file.*;
import java.sql.*;
import java.util.*;

/** Frozen V915 gap / V917 release rehearsal with separated real login roles; synthetic data only. */
public final class ProductionProvenanceRoleFixture {
    private ProductionProvenanceRoleFixture() { }
    private static final String OWNER="uten_migrator", APP="uten", PASSWORD="r1-fixture-only";

    static void require(boolean value,String code) {if(!value)throw new AssertionError(code);}
    static void execute(Connection c,String sql) throws SQLException {try(var s=c.createStatement()){s.execute(sql);}}
    static boolean bool(Connection c,String sql) throws SQLException {try(var s=c.createStatement();var r=s.executeQuery(sql)){r.next();return r.getBoolean(1);}}
    static int number(Connection c,String sql) throws SQLException {try(var s=c.createStatement();var r=s.executeQuery(sql)){r.next();return r.getInt(1);}}
    static List<String> history(Connection c) throws SQLException {var rows=new ArrayList<String>();try(var s=c.createStatement();var r=s.executeQuery("SELECT row_to_json(h)::text FROM flyway_schema_history h ORDER BY installed_rank")){while(r.next())rows.add(r.getString(1));}return rows;}
    static Flyway migration(String url,Path directory,String target,boolean outOfOrder) {
        return Flyway.configure().dataSource(url,OWNER,PASSWORD).locations("filesystem:"+directory)
            .initSql("SET client_min_messages=WARNING").defaultSchema("public").schemas("public")
            .baselineOnMigrate(false).cleanDisabled(true).target(target).outOfOrder(outOfOrder)
            .validateMigrationNaming(true).validateOnMigrate(true).ignoreMigrationPatterns("*:pending")
            .callbacks(new AppliedMigrationCompatibilityCallback(),new AuditFreshStartGuardCallback()).load();
    }
    static void rejects42501(Connection admin,String setup,String proposal,String undo) throws SQLException {
        execute(admin,setup);
        try {try {execute(admin,proposal);throw new AssertionError("unsafe reachable role accepted");}
             catch(SQLException expected){require("42501".equals(expected.getSQLState()),"wrong security SQLSTATE");}}
        finally {execute(admin,undo);}
    }

    public static Map<String,Object> run(String url,String adminUser,String adminPassword,Path source,Path full) throws Exception {
        try(var admin=DriverManager.getConnection(url,adminUser,adminPassword)) {
            execute(admin,"CREATE ROLE uten LOGIN NOINHERIT NOSUPERUSER PASSWORD '"+PASSWORD+"';CREATE ROLE uten_migrator LOGIN NOINHERIT NOSUPERUSER PASSWORD '"+PASSWORD+"';CREATE ROLE fixture_writer NOLOGIN NOINHERIT;");
            String database;try(var s=admin.createStatement();var r=s.executeQuery("SELECT current_database()")){r.next();database=r.getString(1);}
            require(database.matches("[A-Za-z_][A-Za-z0-9_]*"),"safe fixture database name");
            execute(admin,"ALTER DATABASE \""+database+"\" OWNER TO uten_migrator;REVOKE CREATE ON DATABASE \""+database+"\" FROM PUBLIC,uten;REVOKE CREATE ON SCHEMA public FROM PUBLIC,uten;");
            execute(admin,"REVOKE EXECUTE ON FUNCTION pg_catalog.pg_control_system() FROM PUBLIC,uten;GRANT EXECUTE ON FUNCTION pg_catalog.pg_control_system() TO uten_migrator;");
            try(var owner=DriverManager.getConnection(url,OWNER,PASSWORD)) {
                execute(owner,"ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER ON TABLES TO uten;");
                execute(owner,"ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE,SELECT ON SEQUENCES TO uten;");
            }
            int baseline=migration(url,source,"916",false).migrate().migrationsExecuted;
            List<String> original=history(admin);
            require(baseline==original.size()&&baseline>800,"full original schema required");
            require(bool(admin,"SELECT has_table_privilege('uten','legacy_production_plan_counter_import_contexts','TRUNCATE')"),"original V913 default ACL leak not reproduced");
            try(var app=DriverManager.getConnection(url,APP,PASSWORD)) {app.setAutoCommit(false);execute(app,"TRUNCATE public.legacy_production_plan_counter_import_contexts CASCADE");app.rollback();}
            var gap=migration(url,full,"915",true);
            var pending=gap.info().pending();require(pending.length==1&&pending[0].getVersion().getVersion().equals("915"),"exact original915-only gap required");
            require(gap.migrate().migrationsExecuted==1,"one real original915 migration required");
            var normal=migration(url,full,"917",false);require(normal.migrate().migrationsExecuted==1,"one exact normal917 migration required");
            normal.validate();require(normal.migrate().migrationsExecuted==0,"normal false final migrate must be zero");
            var actual=history(admin);require(actual.size()==baseline+2&&actual.subList(0,original.size()).equals(original),"old history changed");
            require(bool(admin,"SELECT NOT rolsuper AND NOT rolinherit FROM pg_roles WHERE rolname='uten'"),"runtime real non-SU required");
            require(bool(admin,"SELECT NOT rolsuper FROM pg_roles WHERE rolname='uten_migrator'"),"owner real non-SU required");
            for(String table:List.of("legacy_production_plan_counter_import_sources","legacy_production_plan_counter_import_contexts")) {
                require(bool(admin,"SELECT has_table_privilege('uten','"+table+"','SELECT')"),"source SELECT lost");
                for(String privilege:List.of("INSERT","UPDATE","DELETE","TRUNCATE","REFERENCES","TRIGGER","SELECT WITH GRANT OPTION"))
                    require(!bool(admin,"SELECT has_table_privilege('uten','"+table+"','"+privilege+"')"),"source write/delegation retained");
                for(String privilege:List.of("INSERT","UPDATE","REFERENCES","SELECT WITH GRANT OPTION"))
                    require(!bool(admin,"SELECT has_any_column_privilege('uten','"+table+"','"+privilege+"')"),"source column write/delegation retained");
            }
            require(!bool(admin,"SELECT has_function_privilege('uten','business_data_reset()','EXECUTE')"),"runtime reset execute retained");
            require(!bool(admin,"SELECT has_function_privilege('uten','pg_catalog.pg_control_system()','EXECUTE')"),"runtime builtin unexpectedly expanded");
            require(bool(admin,"SELECT has_function_privilege('uten_migrator','pg_catalog.pg_control_system()','EXECUTE')"),"definer owner builtin permission absent");
            String observedSystem;try(var s=admin.createStatement();var r=s.executeQuery("SELECT system_identifier::text FROM pg_catalog.pg_control_system()")){r.next();observedSystem=r.getString(1);}
            require(observedSystem.matches("[0-9]+"),"actual control identity required");
            String originQuery="SELECT public.fn_legacy_production_origin_matches('"+observedSystem+"',(SELECT oid FROM pg_database WHERE datname=current_database()),current_database())";
            try(var app=DriverManager.getConnection(url,APP,PASSWORD)) {
                require(bool(app,originQuery),"definer origin helper failed");
            }
            execute(admin,"REVOKE EXECUTE ON FUNCTION pg_catalog.pg_control_system() FROM uten_migrator");
            try(var app=DriverManager.getConnection(url,APP,PASSWORD)) {
                try {bool(app,originQuery);throw new AssertionError("missing definer builtin dependency was hidden");}
                catch(SQLException expected){require("42501".equals(expected.getSQLState()),"actual owner builtin dependency SQLSTATE");}
            } finally {execute(admin,"GRANT EXECUTE ON FUNCTION pg_catalog.pg_control_system() TO uten_migrator");}
            String proposal=Files.readString(full.resolve("V917__production_plan_provenance_runtime_read_only.sql"));
            rejects42501(admin,"GRANT TRUNCATE ON legacy_production_plan_counter_import_sources TO fixture_writer;GRANT fixture_writer TO uten WITH INHERIT FALSE,SET TRUE;",proposal,"REVOKE fixture_writer FROM uten;REVOKE TRUNCATE ON legacy_production_plan_counter_import_sources FROM fixture_writer;");
            rejects42501(admin,"GRANT UPDATE(source_legacy_id) ON legacy_production_plan_counter_import_sources TO fixture_writer;GRANT fixture_writer TO uten WITH INHERIT FALSE,SET TRUE;",proposal,"REVOKE fixture_writer FROM uten;REVOKE UPDATE(source_legacy_id) ON legacy_production_plan_counter_import_sources FROM fixture_writer;");
            rejects42501(admin,"GRANT SELECT(source_legacy_id) ON legacy_production_plan_counter_import_sources TO fixture_writer WITH GRANT OPTION;GRANT fixture_writer TO uten WITH INHERIT FALSE,SET TRUE;",proposal,"REVOKE fixture_writer FROM uten;REVOKE SELECT(source_legacy_id) ON legacy_production_plan_counter_import_sources FROM fixture_writer;");
            ordinaryPlan(url,admin);
            return Map.of("baseline_migrations",baseline,"final_migrations",actual.size(),"maximum_version",917,"original915_out_of_order_applied",1,"normal917_applied",1,"final_normal_migrate",0,"runtime_control_execute",false,"definer_owner_control_execute",true,"ordinary_source_null_crud",true);
        }
    }

    static void ordinaryPlan(String url,Connection admin) throws Exception {
        UUID unit=UUID.randomUUID(),goods=UUID.randomUUID(),plan=UUID.randomUUID(),item=UUID.randomUUID();
        execute(admin,"INSERT INTO units(id,code,name)VALUES('"+unit+"','R1-UNIT','R1 unit');INSERT INTO goods(id,code,name,unit_id,code_sequence)VALUES('"+goods+"','R1-GOODS','R1 current product','"+unit+"',(SELECT COALESCE(max(code_sequence),0)+1 FROM goods));");
        try(var app=DriverManager.getConnection(url,APP,PASSWORD)) {
            app.setAutoCommit(false);
            try {
                execute(app,"INSERT INTO production_plans(id,bill_no,bill_date,status)VALUES('"+plan+"','SJ20261024009171','2026-10-24',0);");
                execute(app,"INSERT INTO production_plan_items(id,plan_id,bill_no,bill_date,product_no,goods_id,unit_id,unit_rate,qty,fqty,iqty)VALUES('"+item+"','"+plan+"','SJ20261024009171','2026-10-24','R1-CURRENT-PRODUCT','"+goods+"','"+unit+"',1,10,0,0);");
                require(bool(app,"SELECT legacy_production_import_run_id IS NULL FROM production_plan_items WHERE id='"+item+"'"),"ordinary source must remain NULL");
                execute(app,"UPDATE production_plan_items SET qty=11 WHERE id='"+item+"';DELETE FROM production_plan_items WHERE id='"+item+"';DELETE FROM production_plans WHERE id='"+plan+"';");
            } finally {app.rollback();}
        }
    }
}
