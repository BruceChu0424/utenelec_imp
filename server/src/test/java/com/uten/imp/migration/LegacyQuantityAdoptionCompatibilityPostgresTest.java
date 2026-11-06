package com.uten.imp.migration;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.uten.imp.support.LegacyFinanceImportFixture;
import com.uten.imp.testsupport.TestFlyway;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.math.BigDecimal;
import java.nio.file.*;
import java.sql.*;
import java.util.*;
import java.util.regex.Pattern;
import static org.assertj.core.api.Assertions.*;

/** Real unchanged guards, verified bootstrap, and the production legacy SQL statements. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class LegacyQuantityAdoptionCompatibilityPostgresTest {
    static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine").withDatabaseName("adoption_base");
    static final String RUNTIME="adoption_runtime",PASSWORD="test-only-"+UUID.randomUUID();
    static final ObjectMapper JSON=new ObjectMapper();
    record Family(String kind,String table,String module,String stage,String parentStage,String parent,long parentLegacy,boolean receipt) { }
    static final List<Family> FAMILIES=List.of(
        new Family("PURCHASE_ORDER_ITEM","purchase_order_items","migrate_purchase.sql","order_item_stage","order_stage","purchase_orders",901401,false),
        new Family("PURCHASE_ITEM","purchase_receipt_items","migrate_purchase.sql","receipt_item_stage",null,"purchase_receipts",901501,true),
        new Family("SUBCONTRACT_ITEM","subcontract_receipt_items","migrate_subcontract.sql","receipt_item_stage",null,"subcontract_receipts",901502,true),
        new Family("PURCHASE_RETURN_ITEM","purchase_return_items","migrate_purchase.sql","return_item_stage","return_stage","purchase_returns",901601,false),
        new Family("SUBCONTRACT_MATERIAL_RETURN_ITEM","subcontract_material_return_items","migrate_subcontract.sql","mreturn_item_stage","mreturn_stage","subcontract_material_returns",901602,false));
    Connection connection;JdbcTemplate db;String database;UUID run,unit,goods;

    @BeforeAll static void migrate() throws Exception {
        PG.start();TestFlyway.configure().dataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword()).load().migrate();
        try(var c=DriverManager.getConnection(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());var sql=c.createStatement()) {
            com.uten.imp.support.PostgresFixtureDdl.execute(c,"CREATE ROLE %I LOGIN NOSUPERUSER NOBYPASSRLS PASSWORD %L",RUNTIME,PASSWORD);
            com.uten.imp.support.PostgresFixtureDdl.execute(c,"GRANT USAGE ON SCHEMA public TO %I",RUNTIME);
            com.uten.imp.support.PostgresFixtureDdl.execute(c,"GRANT SELECT,INSERT,UPDATE ON ALL TABLES IN SCHEMA public TO %I",RUNTIME);
            com.uten.imp.support.PostgresFixtureDdl.execute(c,"GRANT USAGE,SELECT ON SEQUENCE public.audit_log_id_seq TO %I",RUNTIME);
        }
    }
    @AfterAll static void stop(){PG.stop();}
    @BeforeEach void fixture() throws Exception {
        database="legacy_adoption_"+UUID.randomUUID().toString().replace("-","");
        try(var c=admin();var sql=c.createStatement()){com.uten.imp.support.PostgresFixtureDdl.execute(c,"CREATE DATABASE %I TEMPLATE adoption_base",database);}
        connection=DriverManager.getConnection(url(database),PG.getUsername(),PG.getPassword());connection.setAutoCommit(false);
        db=new JdbcTemplate(new SingleConnectionDataSource(connection,true));run=LegacyFinanceImportFixture.context(db);LegacyFinanceImportFixture.seed(db);
        db.update("INSERT INTO units(legacy_id,code,name) VALUES(900301,'ADOPT-U','Original unit')");
        db.update("INSERT INTO warehouses(legacy_id,code,name) VALUES(900201,'ADOPT-W','Original warehouse')");
        for(int legacy:List.of(900101,900102))db.update("INSERT INTO goods(legacy_id,code,name,unit_id,code_sequence) SELECT ?,?,'Original goods',id,(SELECT coalesce(max(code_sequence),0)+1 FROM goods) FROM units WHERE legacy_id=900301",legacy,"ADOPT-G-"+legacy);
        unit=db.queryForObject("SELECT id FROM units WHERE legacy_id=900301",UUID.class);goods=db.queryForObject("SELECT id FROM goods WHERE legacy_id=900101",UUID.class);
        db.execute("CREATE TEMP TABLE operator_ref_stage(legacy_id integer,name text)");db.execute("CREATE TEMP TABLE worker_ref_stage(legacy_id integer,name text)");
        for(Family family:FAMILIES) {
            String file=file(family);db.update("INSERT INTO legacy_migration_run_files(run_id,file_name,sha256,byte_size) VALUES(?,?,repeat('f',64),500) ON CONFLICT DO NOTHING",run,file);
            if(family.receipt())receiptHeader(family);
            else db.update("INSERT INTO public."+family.parent()+"(legacy_id,bill_no,bill_date,status) VALUES(?,?,DATE '2025-01-02',1)",family.parentLegacy(),"OLD-"+family.parentLegacy());
        }
    }
    @AfterEach void clean() throws Exception {
        if(connection!=null){connection.rollback();connection.close();}
        if(database!=null){assertThat(database).startsWith("legacy_adoption_");try(var c=admin();var sql=c.createStatement()){com.uten.imp.support.PostgresFixtureDdl.execute(c,"DROP DATABASE %I WITH (FORCE)",database);}}
    }

    @Test void allFiveProductionLegacySqlEntrypointsKeepOriginalFactsWithoutNewAdoptions() throws Exception {
        int index=0;
        for(Family family:FAMILIES) {
            ObjectNode source=source(family,902001+index++);prepare(family,source);registerSql(family);insertSql(family);
            ObjectNode row=row(family,source.path("legacy_id").asInt());
            assertThat(row.path("quantity_adoption_version").asInt()).isEqualTo(1);
            assertThat(row.path("quantity_precision_policy").isNull()).isTrue();
            assertThat(row.path("qty").decimalValue()).isEqualByComparingTo("2.0000");
            assertThat(row.path("unit_rate").decimalValue()).isEqualByComparingTo("1.250000");
            for(String key:List.of("charged_base_qty","gift_base_qty","adopted_base_qty","quantity_source_proof"))
                assertThat(row.path(key).isMissingNode()||row.path(key).isNull()).as(family.kind()+" "+key).isTrue();
            if(!family.table().equals("subcontract_material_return_items"))assertThat(row.path("amount_original").decimalValue()).isEqualByComparingTo(family.table().equals("subcontract_receipt_items")?"8.75":"7");
            else assertThat(row.path("amount_original").isNull()).isTrue();
            assertThat(row.path("amount_local").decimalValue()).isEqualByComparingTo(family.table().startsWith("subcontract_")?"8.75":"7");
            assertThat(row.path("weight").decimalValue()).isEqualByComparingTo("0.1250");
            dropStages(family);
        }
        db.execute("SET CONSTRAINTS ALL IMMEDIATE");
        assertThat(db.queryForObject("SELECT count(*) FROM business_numeric_input_evidence WHERE owner_kind IN ('PURCHASE_RECEIPT','SUBCONTRACT_RECEIPT')",Long.class)).isZero();
    }

    @Test void verifiedHistoricalUnknownUnitAndRateStayUnknownInsteadOfBecomingOneOrAComputedBase() throws Exception {
        for(Family family:List.of(FAMILIES.get(1),FAMILIES.get(4))) {
            ObjectNode source=source(family,903001+FAMILIES.indexOf(family));source.putNull("unit_legacy_id");source.putNull("unit_rate");
            prepare(family,source);registerSql(family);insertSql(family);ObjectNode row=row(family,source.path("legacy_id").asInt());
            assertThat(row.path("unit_id").isNull()).isTrue();assertThat(row.path("unit_rate").isNull()).isTrue();
            assertThat(row.path("quantity_adoption_version").asInt()).isEqualTo(1);assertThat(row.path("quantity_precision_policy").isNull()).isTrue();
            dropStages(family);
        }
        db.execute("SET CONSTRAINTS ALL IMMEDIATE");
    }

    @Test void exactSourceTamperingAndIndependentAdoptionUpdatesRemainRejected() throws Exception {
        int index=0;
        for(Family family:FAMILIES) {
            ObjectNode source=source(family,904001+index++);prepare(family,source);registerSql(family);
            db.update("UPDATE "+family.stage()+" SET qty=3");
            denied(()->insertSql(family),"23514");
            db.update("UPDATE "+family.stage()+" SET qty=2");insertSql(family);
            ObjectNode before=row(family,source.path("legacy_id").asInt());UUID id=UUID.fromString(before.path("id").asText());
            denied(()->db.update("UPDATE public."+family.table()+" SET quantity_adoption_version=2,quantity_precision_policy='{}'::jsonb WHERE id=?",id),"55000");
            assertThat(row(family,source.path("legacy_id").asInt())).isEqualTo(before);
            dropStages(family);
        }
        db.execute("SET CONSTRAINTS ALL IMMEDIATE");
    }

    @Test void evenTrustedBootstrapNeedsTheExactRowProofAndCannotAttachANewPrecisionPolicy() throws Exception {
        int index=0;
        for(Family family:FAMILIES) {
            ObjectNode source=source(family,907001+index++);prepare(family,source);
            String projection=family.receipt()?"fn_legacy_receipt_source_projection":"fn_legacy_quantity_counter_source_projection";
            ObjectNode payload=(ObjectNode)JSON.readTree(db.queryForObject("SELECT "+projection+"(?,?::jsonb)::text",String.class,family.kind(),source.toString()));
            payload.put("id",UUID.randomUUID().toString());payload.put(family.receipt()?"legacy_import_run_id":"legacy_counter_import_run_id",run.toString());
            payload.put("quantity_adoption_version",family.receipt()?2:1);
            denied(()->insertPayload(family,payload),"23514");
            registerSql(family);
            String proofTable=family.receipt()?"legacy_procurement_receipt_import_sources":"legacy_quantity_counter_import_sources";
            payload.put("id",db.queryForObject("SELECT target_id::text FROM "+proofTable+" WHERE run_id=? AND source_kind=? AND source_legacy_id=?",String.class,run,family.kind(),source.path("legacy_id").asInt()));
            payload.set("quantity_precision_policy",JSON.createObjectNode());
            denied(()->insertPayload(family,payload),"23514");
            assertThat(db.queryForObject("SELECT count(*) FROM "+family.table()+" WHERE legacy_id=?",Long.class,source.path("legacy_id").asInt())).isZero();
            dropStages(family);
        }
    }

    @Test void declaredHistoricalRunCannotFallThroughToNativeWhenItsLegacyIdentityIsMissing() throws Exception {
        for(Family family:FAMILIES) {
            ObjectNode source=source(family,909001+FAMILIES.indexOf(family));prepare(family,source);registerSql(family);
            String projection=family.receipt()?"fn_legacy_receipt_source_projection":"fn_legacy_quantity_counter_source_projection";
            ObjectNode payload=(ObjectNode)JSON.readTree(db.queryForObject("SELECT "+projection+"(?,?::jsonb)::text",String.class,family.kind(),source.toString()));
            String proofTable=family.receipt()?"legacy_procurement_receipt_import_sources":"legacy_quantity_counter_import_sources";
            payload.put("id",db.queryForObject("SELECT target_id::text FROM "+proofTable+" WHERE run_id=? AND source_kind=? AND source_legacy_id=?",String.class,run,family.kind(),source.path("legacy_id").asInt()));
            payload.put(family.receipt()?"legacy_import_run_id":"legacy_counter_import_run_id",run.toString());
            payload.putNull("legacy_id");payload.put("quantity_adoption_version",2);
            denied(()->insertPayload(family,payload),"23514");
            assertThat(db.queryForObject("SELECT count(*) FROM "+family.table()+" WHERE id=?",Long.class,UUID.fromString(payload.path("id").asText()))).isZero();
            dropStages(family);
        }
    }

    @Test void exactRegisteredReceiptCannotStartAtVersionOneButItsAdoptedWeightMustUseVersionOne() throws Exception {
        for(Family family:FAMILIES.stream().filter(Family::receipt).toList()) {
            ObjectNode source=source(family,908001+FAMILIES.indexOf(family));prepare(family,source);registerSql(family);
            ObjectNode payload=(ObjectNode)JSON.readTree(db.queryForObject("SELECT fn_legacy_receipt_source_projection(?,?::jsonb)::text",String.class,family.kind(),source.toString()));
            payload.put("id",db.queryForObject("SELECT target_id::text FROM legacy_procurement_receipt_import_sources WHERE run_id=? AND source_kind=? AND source_legacy_id=?",String.class,run,family.kind(),source.path("legacy_id").asInt()));
            payload.put("legacy_import_run_id",run.toString());payload.put("quantity_adoption_version",1);
            denied(()->insertPayload(family,payload),"23514");
            assertThat(db.queryForObject("SELECT count(*) FROM "+family.table()+" WHERE legacy_id=?",Long.class,source.path("legacy_id").asInt())).isZero();
            payload.put("quantity_adoption_version",2);insertPayload(family,payload);
            ObjectNode saved=row(family,source.path("legacy_id").asInt());
            assertThat(saved.path("quantity_adoption_version").asInt()).isEqualTo(1);
            assertThat(saved.path("weight").decimalValue()).isEqualByComparingTo("0.1250");
            assertThat(saved.path("quantity_precision_policy").isNull()).isTrue();
            db.execute("SET CONSTRAINTS ALL IMMEDIATE");
            assertThat(db.queryForObject("SELECT count(*) FROM business_numeric_input_evidence WHERE owner_kind IN ('PURCHASE_RECEIPT','SUBCONTRACT_RECEIPT')",Long.class)).isZero();
            dropStages(family);
        }
    }

    @Test void realRuntimeSessionCannotForgeLegacyContextAndNativeVersionTwoStillWorks() throws Exception {
        UUID header=UUID.randomUUID();String bill="CD20261101009901";
        db.update("INSERT INTO purchase_orders(id,bill_no,bill_date,status,currency_id,exchange_rate,tax_rate) SELECT ?,?,DATE '2026-11-01',0,id,1,0 FROM currencies WHERE is_base_currency AND NOT is_deleted",header,bill);
        connection.commit();
        try(var runtime=DriverManager.getConnection(url(database),RUNTIME,PASSWORD);var sql=runtime.createStatement()) {
            sql.execute("SET app.legacy_import='true'");try(var configure=runtime.prepareStatement("SELECT set_config('uten.bootstrap_run_id',?,false)")){configure.setString(1,run.toString());try(var row=configure.executeQuery()){assertThat(row.next()).isTrue();}}
            try(var insert=runtime.prepareStatement("INSERT INTO purchase_order_items(id,legacy_id,legacy_counter_import_run_id,order_id,bill_no,bill_date,goods_id,unit_id,unit_rate,qty) VALUES(?,?,?,?,?,DATE '2026-11-01',?,?,1,2)")) {
                insert.setObject(1,UUID.randomUUID());insert.setInt(2,905002);insert.setObject(3,run);insert.setObject(4,header);insert.setString(5,bill);insert.setObject(6,goods);insert.setObject(7,unit);
                SQLException rejected=org.junit.jupiter.api.Assertions.assertThrows(SQLException.class,insert::executeUpdate);
                assertThat(rejected.getSQLState()).isEqualTo("23514");assertThat(rejected.getMessage()).contains("dedicated migration identity");
            }
            try(var insert=runtime.prepareStatement("INSERT INTO purchase_order_items(id,order_id,bill_no,bill_date,goods_id,unit_id,unit_rate,qty,quantity_adoption_version) VALUES(?,?,?,DATE '2026-11-01',?,?,1,2,1)")) {
                insert.setObject(1,UUID.randomUUID());insert.setObject(2,header);insert.setString(3,bill);insert.setObject(4,goods);insert.setObject(5,unit);
                SQLException rejected=org.junit.jupiter.api.Assertions.assertThrows(SQLException.class,insert::executeUpdate);
                assertThat(rejected.getSQLState()).isEqualTo("23514");assertThat(rejected.getMessage()).contains("current exact operation proof");
            }
            UUID nativeId=UUID.randomUUID();
            try(var insert=runtime.prepareStatement("INSERT INTO purchase_order_items(id,order_id,bill_no,bill_date,goods_id,unit_id,unit_rate,qty,price,amount_original,amount_local,goods_code_snapshot,goods_name_snapshot,goods_snapshot_source) VALUES(?,?,?,DATE '2026-11-01',?,?,1,2,3.5,7,7,'ADOPT-G-900101','Original goods','MASTER_AT_SAVE')")) {
                insert.setObject(1,nativeId);insert.setObject(2,header);insert.setString(3,bill);insert.setObject(4,goods);insert.setObject(5,unit);assertThat(insert.executeUpdate()).isEqualTo(1);
            }
            try(var query=runtime.prepareStatement("SELECT quantity_adoption_version,quantity_precision_policy IS NOT NULL,charged_base_qty,gift_base_qty FROM purchase_order_items WHERE id=?")){query.setObject(1,nativeId);try(var row=query.executeQuery()){assertThat(row.next()).isTrue();assertThat(row.getInt(1)).isEqualTo(2);assertThat(row.getBoolean(2)).isTrue();assertThat(row.getBigDecimal(3)).isEqualByComparingTo("2");assertThat(row.getBigDecimal(4)).isZero();}}
        }
    }

    @Test void replayedSourceProofFromAnEarlierTransactionCannotAuthorizeAnInsert() throws Exception {
        Family family=FAMILIES.get(3);ObjectNode source=source(family,906001);prepare(family,source);registerSql(family);
        connection.commit();
        db.queryForObject("SELECT set_config('uten.bootstrap_run_id',?,true)",String.class,run.toString());
        db.execute("SET LOCAL uten.bootstrap_mapping_version='bootstrap-v11'");
        db.queryForObject("SELECT set_config('uten.bootstrap_repository_commit',?,true)",String.class,"a".repeat(40));db.queryForObject("SELECT set_config('uten.bootstrap_manifest_sha',?,true)",String.class,"b".repeat(64));
        db.execute("SELECT pg_advisory_xact_lock(hashtextextended('uten:legacy-bootstrap:'||current_database(),0))");
        denied(()->insertSql(family),"23514");
    }

    ObjectNode source(Family family,int legacy) {
        var value=JSON.createObjectNode();String kindFn=family.receipt()?"fn_legacy_receipt_import_kind":"fn_legacy_quantity_counter_kind";
        db.queryForList("SELECT unnest(source_keys) FROM "+kindFn+"(?)",String.class,family.kind()).forEach(value::putNull);
        put(value,"legacy_id",legacy);put(value,"bill_legacy_id",family.parentLegacy());put(value,"goods_legacy_id",900101);
        put(value,"unit_legacy_id",900301);put(value,"unit_rate",new BigDecimal("1.250000"));put(value,"qty",new BigDecimal("2.0000"));
        put(value,"price",new BigDecimal("3.5"));put(value,"amount_original",new BigDecimal("7.0000"));put(value,"amount_local",new BigDecimal("8.7500"));
        put(value,"received_qty",BigDecimal.ZERO);put(value,"returned_qty",BigDecimal.ZERO);put(value,"gift_qty",BigDecimal.ZERO);put(value,"weight",new BigDecimal("0.1250"));
        put(value,"girth_qty",BigDecimal.ZERO);return value;
    }
    static void put(ObjectNode value,String key,Number number){if(value.has(key))value.set(key,JSON.valueToTree(number));}
    String file(Family f){return db.queryForObject("SELECT source_file FROM "+(f.receipt()?"fn_legacy_receipt_import_kind":"fn_legacy_quantity_counter_kind")+"(?)",String.class,f.kind());}
    String script(Family f) throws Exception{return Files.readString(Path.of("legacy_migration",f.module()));}
    void prepare(Family f,ObjectNode source) throws Exception {
        String script=script(f);stage(script,f.stage(),source);
        if(f.parentStage()!=null){var header=JSON.createObjectNode();header.put("legacy_id",f.parentLegacy());header.put("bill_no","OLD-"+f.parentLegacy());header.put("bill_date","2025-01-02");header.put("exchange_rate",1);header.put("status",1);stage(script,f.parentStage(),header);}
    }
    void stage(String script,String name,ObjectNode value) {
        var matcher=Pattern.compile("CREATE TEMP TABLE "+name+"\\s*\\([^;]*;",Pattern.DOTALL).matcher(script);
        assertThat(matcher.find()).as("actual stage "+name).isTrue();db.execute(matcher.group());
        db.update("INSERT INTO pg_temp."+name+" SELECT * FROM jsonb_populate_record(NULL::pg_temp."+name+",?::jsonb)",value.toString());
    }
    void receiptHeader(Family family) throws Exception {
        String kind=family.kind().replace("ITEM","HEADER"),script=script(family);
        var value=JSON.createObjectNode();value.put("legacy_id",family.parentLegacy());value.put("bill_no","OLD-"+family.parentLegacy());value.put("bill_date","2025-01-02");
        value.put("supplier_legacy_id",900601);value.put("warehouse_legacy_id",900201);value.put("currency_legacy_id",1);value.put("exchange_rate",1);value.put("tax_rate",0);value.put("total_original",7);value.put("status",1);
        String file=db.queryForObject("SELECT source_file FROM fn_legacy_receipt_import_kind(?)",String.class,kind);
        db.update("INSERT INTO legacy_migration_run_files(run_id,file_name,sha256,byte_size) VALUES(?,?,repeat('f',64),500) ON CONFLICT DO NOTHING",run,file);
        stage(script,"receipt_stage",value);db.execute(registerStatement(script,kind));db.execute(insertStatement(script,family.parent()));db.execute("DROP TABLE pg_temp.receipt_stage");
    }
    void registerSql(Family f) throws Exception{db.execute(registerStatement(script(f),f.kind()));}
    void insertSql(Family f) throws Exception{db.execute(insertStatement(script(f),f.table()));}
    static String registerStatement(String script,String kind){var matcher=Pattern.compile("SELECT count\\(fn_register_legacy_(?:receipt_import_source|quantity_counter_source)\\([^;]*'"+kind+"'[^;]*;",Pattern.DOTALL).matcher(script);assertThat(matcher.find()).as("actual register "+kind).isTrue();return matcher.group();}
    static String insertStatement(String script,String table){int start=script.indexOf("INSERT INTO "+table+" (");assertThat(start).isNotNegative();return script.substring(start,script.indexOf(';',start)+1);}
    void dropStages(Family f){db.execute("DROP TABLE pg_temp."+f.stage());if(f.parentStage()!=null)db.execute("DROP TABLE pg_temp."+f.parentStage());}
    ObjectNode row(Family f,int legacy)throws Exception{return (ObjectNode)JSON.readTree(db.queryForObject("SELECT to_jsonb(row)::text FROM public."+f.table()+" row WHERE legacy_id=?",String.class,legacy));}
    void insertPayload(Family family,ObjectNode payload) {
        var fields=new ArrayList<String>();payload.fieldNames().forEachRemaining(fields::add);fields.sort(String::compareTo);
        fields.forEach(field->assertThat(field).matches("[a-z_]+"));String columns=String.join(",",fields);
        db.update("INSERT INTO public."+family.table()+"("+columns+") SELECT "+columns+" FROM jsonb_populate_record(NULL::public."+family.table()+",?::jsonb)",payload.toString());
    }
    void denied(org.assertj.core.api.ThrowableAssert.ThrowingCallable operation,String state)throws Exception {
        var savepoint=connection.setSavepoint();Throwable failure=catchThrowable(operation);assertThat(failure).isNotNull();
        Throwable cause=failure instanceof org.springframework.dao.DataAccessException data?data.getMostSpecificCause():failure;
        assertThat(cause).isInstanceOf(SQLException.class);assertThat(((SQLException)cause).getSQLState()).isEqualTo(state);connection.rollback(savepoint);connection.releaseSavepoint(savepoint);
    }
    static Connection admin()throws SQLException{return DriverManager.getConnection(url("postgres"),PG.getUsername(),PG.getPassword());}
    static String url(String database){return PG.getJdbcUrl().replace("/adoption_base","/"+database);}
}
