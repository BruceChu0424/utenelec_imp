package com.uten.imp.migration;

import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import org.flywaydb.core.Flyway;
import org.testcontainers.containers.PostgreSQLContainer;

@org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class FinancialExactAmountMigrationHelperPostgresTest {
    static final String ALIAS="[{'table':'financial_exact_fixture','column':'amount'}]".replace('\'', '"');
    @org.junit.jupiter.api.Test
    void preservesExactAmountsAndDependentViewAuthority() throws Exception {
        try(var pg=new PostgreSQLContainer<>("postgres:16-alpine")
                .withDatabaseName("financial_exact_helper").withUsername("uten").withPassword("test-only")) {
            pg.start();
            Flyway.configure().dataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword())
                    .locations("filesystem:src/main/resources/db/migration").target("508").load().migrate();
            try(var connection=DriverManager.getConnection(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword())) {
                String migration=sourceMigration();
                int start=migration.indexOf("CREATE OR REPLACE FUNCTION fn_financial_amount_is_exact");
                execute(connection,migration.substring(start,migration.indexOf("$$;",start)+3));
                int bookStart=migration.indexOf("CREATE OR REPLACE FUNCTION fn_financial_book_amount_is_exact");
                require(bookStart>=0,"V510 book amount validator missing");
                execute(connection,migration.substring(bookStart,migration.indexOf("$$;",bookStart)+3));
                int helperStart=migration.indexOf("CREATE OR REPLACE FUNCTION fn_migrate_financial_amount_columns");
                require(helperStart>=0,"V510 migration helper missing");
                execute(connection,migration.substring(helperStart,migration.indexOf("$$;",helperStart)+3));
                execute(connection,"CREATE ROLE exact_view_reader; CREATE ROLE exact_default_reader; CREATE ROLE exact_view_owner;");
                execute(connection,"CREATE TABLE financial_exact_fixture(id integer PRIMARY KEY,amount numeric(18,4)); INSERT INTO financial_exact_fixture VALUES(1,0.1250);");
                execute(connection,"CREATE VIEW financial_exact_inner(view_id,actual_amount) WITH(security_barrier=true) AS SELECT id,amount FROM financial_exact_fixture;");
                execute(connection,"CREATE VIEW financial_exact_outer WITH(security_invoker=true) AS SELECT view_id,actual_amount+0 AS reported_amount FROM financial_exact_inner;");
                execute(connection,"CREATE MATERIALIZED VIEW financial_exact_mv WITH(fillfactor=70) AS SELECT id,SUM(amount) amount FROM financial_exact_fixture GROUP BY id;");
                execute(connection,"CREATE UNIQUE INDEX financial_exact_mv_uq ON financial_exact_mv(id); COMMENT ON INDEX financial_exact_mv_uq IS 'stable index comment';");
                execute(connection,"COMMENT ON VIEW financial_exact_outer IS 'outer comment'; COMMENT ON COLUMN financial_exact_outer.reported_amount IS 'money column comment';");
                execute(connection,"GRANT USAGE ON SCHEMA public TO exact_view_owner; GRANT SELECT ON financial_exact_inner TO exact_view_owner; ALTER VIEW financial_exact_outer OWNER TO exact_view_owner;");
                execute(connection,"SET ROLE exact_view_owner; GRANT SELECT ON financial_exact_outer TO exact_view_reader WITH GRANT OPTION; RESET ROLE;");
                execute(connection,"GRANT SELECT ON financial_exact_inner,financial_exact_mv TO exact_view_reader;");
                execute(connection,"CREATE VIEW unrelated_financial_exact_view AS SELECT 42 AS stable;");
                String unrelated=scalar(connection,"SELECT 'unrelated_financial_exact_view'::regclass::oid::text");
                String acl=acl(connection,"financial_exact_outer");
                execute(connection,"ALTER DEFAULT PRIVILEGES GRANT SELECT ON TABLES TO exact_default_reader;");
                String changed=migrate(connection,ALIAS);
                require(changed.contains("financial_exact_inner")&&changed.contains("financial_exact_outer")&&changed.contains("financial_exact_mv"),"Missing dependency");
                require(unrelated.equals(scalar(connection,"SELECT 'unrelated_financial_exact_view'::regclass::oid::text")),"Unrelated view changed");
                require(acl.equals(acl(connection,"financial_exact_outer")),"Owner/grantor/grantee/grant-option ACL differs");
                require("false".equals(scalar(connection,"SELECT has_table_privilege('exact_default_reader','financial_exact_outer','SELECT')::text")),"Default privileges leaked");
                require("exact_view_owner".equals(scalar(connection,"SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid='financial_exact_outer'::regclass")),"Owner changed");
                require("outer comment".equals(scalar(connection,"SELECT obj_description('financial_exact_outer'::regclass)")),"View comment changed");
                require("money column comment".equals(scalar(connection,"SELECT col_description('financial_exact_outer'::regclass,2)")),"Column comment changed");
                require("stable index comment".equals(scalar(connection,"SELECT obj_description('financial_exact_mv_uq'::regclass)")),"Index comment changed");
                require("{security_invoker=true}".equals(scalar(connection,"SELECT reloptions::text FROM pg_class WHERE oid='financial_exact_outer'::regclass")),"View options changed");
                require("{fillfactor=70}".equals(scalar(connection,"SELECT reloptions::text FROM pg_class WHERE oid='financial_exact_mv'::regclass")),"Materialized options changed");
                require(new BigDecimal("0.1250").compareTo(new BigDecimal(scalar(connection,"SELECT amount::text FROM financial_exact_mv")))==0,"Materialized data lost");
                execute(connection,"UPDATE financial_exact_fixture SET amount=0.123456789012345678901234 WHERE id=1;");
                require("0.123456789012345678901234".equals(scalar(connection,"SELECT actual_amount::text FROM financial_exact_inner")),"Finite amount changed");
                try {
                    execute(connection,"UPDATE financial_exact_fixture SET amount=0.1234567890123456789012345 WHERE id=1;");
                    throw new AssertionError("25 significant fractional digits accepted");
                } catch(java.sql.SQLException expected) { require("23514".equals(expected.getSQLState()),"Wrong precision rejection"); }
                execute(connection,"CREATE TABLE financial_book_fixture(amount numeric(18,4));");
                migrate(connection,"[{\"table\":\"financial_book_fixture\",\"column\":\"amount\",\"kind\":\"book\"}]");
                execute(connection,"INSERT INTO financial_book_fixture VALUES(0.000000000000000000000000000001);");
                require("0.000000000000000000000000000001".equals(scalar(connection,"SELECT amount::text FROM financial_book_fixture")),"Derived thirtieth decimal was lost");
                try{
                    execute(connection,"INSERT INTO financial_book_fixture VALUES(0.0000000000000000000000000000001);");
                    throw new AssertionError("31 book fractional digits accepted");
                }catch(java.sql.SQLException expected){require("23514".equals(expected.getSQLState()),"Wrong book precision rejection");}
                execute(connection,"CREATE TABLE financial_unsupported_fixture(amount numeric(18,4)); CREATE VIEW financial_unsupported_view AS SELECT amount FROM financial_unsupported_fixture; GRANT SELECT(amount) ON financial_unsupported_view TO exact_view_reader;");
                String unsupportedOid=scalar(connection,"SELECT 'financial_unsupported_view'::regclass::oid::text");
                try {
                    migrate(connection,"[{\"table\":\"financial_unsupported_fixture\",\"column\":\"amount\"}]");
                    throw new AssertionError("Unsupported column ACL accepted");
                } catch(java.sql.SQLException expected) { require("0A000".equals(expected.getSQLState()),"Wrong unsupported-object rejection"); }
                require(unsupportedOid.equals(scalar(connection,"SELECT 'financial_unsupported_view'::regclass::oid::text")),"Unsupported view changed before rejection");
                require(!"-1".equals(scalar(connection,"SELECT atttypmod::text FROM pg_attribute WHERE attrelid='financial_unsupported_fixture'::regclass AND attname='amount'")),"Unsupported target type changed");

                StringBuilder targets=new StringBuilder("[");
                for(String table:new String[]{"purchase_orders","subcontract_orders","purchase_receipts","subcontract_receipts"})
                    for(String column:new String[]{"total_original","total_local"})target(targets,table,column);
                for(String table:new String[]{"purchase_order_items","subcontract_order_items","purchase_receipt_items","subcontract_receipt_items"})
                    for(String column:new String[]{"amount_original","amount_local"})target(targets,table,column);
                target(targets,"procurement_order_approval_cases","amount_snapshot");
                for(String table:new String[]{"purchase_order_items","subcontract_order_items","purchase_receipt_items","subcontract_receipt_items"})
                    target(targets,table,"price");
                targets.append(']');
                System.out.println("ACTUAL PROJECT DEPENDENCIES: "+migrate(connection,targets.toString()));
                System.out.println("FINANCIAL EXACT MIGRATION HELPER PASSED: layered view, owner/ACL/options/comments, materialized data/index, unchanged unrelated view, unsupported column ACL rejection, 21 actual project columns");
            }
        }
    }
    private static String sourceMigration() throws Exception {
        String staged=System.getProperty("uten.test.financial.migration");
        if(staged!=null&&!staged.isBlank())return Files.readString(Path.of(staged));
        try(var stream=FinancialExactAmountMigrationHelperPostgresTest.class.getClassLoader()
                .getResourceAsStream("db/migration/V518__procurement_iqc_replacement_consideration.sql")) {
            require(stream!=null,"The complete V518 migration must be published in test resources");
            return new String(stream.readAllBytes(),java.nio.charset.StandardCharsets.UTF_8);
        }
    }
    static void target(StringBuilder json,String table,String column){if(json.length()>1)json.append(',');json.append("{\"table\":\"").append(table).append("\",\"column\":\"").append(column).append("\"}");}
    static String migrate(Connection c,String targets)throws Exception{try(var s=c.prepareStatement("SELECT fn_migrate_financial_amount_columns(CAST(? AS jsonb))::text")){s.setString(1,targets);try(var r=s.executeQuery()){r.next();return r.getString(1);}}}
    static void execute(Connection c,String sql)throws Exception{try(var s=c.createStatement()){s.execute(sql);}}
    static String scalar(Connection c,String sql)throws Exception{try(var s=c.createStatement();var r=s.executeQuery(sql)){r.next();return r.getString(1);}}
    static String acl(Connection c,String name)throws Exception{return scalar(c,"SELECT jsonb_agg(jsonb_build_array(grantor,grantee,privilege_type,is_grantable) ORDER BY grantor,grantee,privilege_type,is_grantable)::text FROM pg_class CROSS JOIN LATERAL aclexplode(COALESCE(relacl,acldefault('r',relowner))) WHERE oid='"+name+"'::regclass");}
    static void require(boolean condition,String message){if(!condition)throw new AssertionError(message);}
}
