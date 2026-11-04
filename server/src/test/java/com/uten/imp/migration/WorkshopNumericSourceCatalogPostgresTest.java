package com.uten.imp.migration;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;
import static org.junit.jupiter.api.Assertions.*;

/** Read-only catalog receipt from a fresh isolated current-schema database. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class WorkshopNumericSourceCatalogPostgresTest {
 @Test void captureTheCurrentGeneratedSourcesBeforeAnyVersionedMigration() throws Exception{
  try(var database=MigratedSchemaBaseline.openDatabase("wm_numeric_catalog")){
   var db=new JdbcTemplate(new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword()));
   var columns=db.queryForList("""
    SELECT c.relname table_name,a.attname column_name,format_type(a.atttypid,a.atttypmod) data_type,
      a.attgenerated generated,pg_get_expr(d.adbin,d.adrelid) expression,a.attnotnull not_null
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped
    LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum
    WHERE n.nspname='public' AND c.relname IN('workshop_material_count_lines','workshop_material_period_lines','workshop_material_count_adjustment_postings')
    ORDER BY c.relname,a.attnum
    """);
   var triggers=db.queryForList("""
    SELECT c.relname table_name,t.tgname trigger_name,pg_get_triggerdef(t.oid) trigger_definition,p.proname function_name,pg_get_functiondef(p.oid) function_definition
    FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_proc p ON p.oid=t.tgfoid
    WHERE NOT t.tgisinternal AND c.relname IN('workshop_material_count_lines','workshop_material_period_lines','workshop_material_count_adjustment_postings')
    ORDER BY c.relname,t.tgname
    """);
   var constraints=db.queryForList("""
    SELECT c.relname table_name,k.conname constraint_name,pg_get_constraintdef(k.oid) definition
    FROM pg_constraint k JOIN pg_class c ON c.oid=k.conrelid
    WHERE c.relname IN('workshop_material_count_lines','workshop_material_period_lines','workshop_material_count_adjustment_postings') ORDER BY 1,2
    """);
   assertFalse(columns.isEmpty());assertFalse(triggers.isEmpty());assertFalse(constraints.isEmpty());
   String schemaVersion=db.queryForObject("SELECT version FROM flyway_schema_history WHERE success AND version IS NOT NULL ORDER BY installed_rank DESC LIMIT 1",String.class);
   var target=Path.of("..","tmp","finance-applications","wm-generated-catalog-current-v"+schemaVersion+".json");Files.createDirectories(target.getParent());
   new ObjectMapper().writerWithDefaultPrettyPrinter().writeValue(target.toFile(),Map.of("version",1,"schemaVersion",schemaVersion,"columns",columns,"triggers",triggers,"constraints",constraints));
  }
 }
 @Test void sourceAwareDerivationRequiresExplicitChoiceAtTheFinalBoundary() throws Exception {
  try(var database=MigratedSchemaBaseline.openDatabase("wm_numeric_source_draft")){
   var db=new JdbcTemplate(new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword()));
   assertEquals(0,db.queryForObject("SELECT count(*) FROM pg_attribute WHERE attrelid IN('workshop_material_count_lines'::regclass,'workshop_material_count_adjustment_postings'::regclass) AND attname IN('qty_base','signed_qty') AND attgenerated<>''",Integer.class));
   assertEquals(3,db.queryForObject("SELECT count(*) FROM pg_trigger WHERE tgname='trg_zz_wm_exact_derived_quantity'",Integer.class));
   var exact=db.queryForObject("SELECT fn_workshop_material_derived_quantity('workshop_material_count_lines',?::jsonb,fn_business_precision_snapshot())",java.math.BigDecimal.class,
    "{\"line_kind\":\"FULL_BAGS\",\"bag_count\":\"1.000000000000000000000001\",\"bag_net_qty\":\"2\"}");
   assertEquals(0,new java.math.BigDecimal("2.000000000000000000000002").compareTo(exact));
   assertThrows(org.springframework.dao.DataAccessException.class,()->db.queryForObject("SELECT fn_workshop_material_derived_quantity('workshop_material_count_lines',?::jsonb,fn_business_precision_snapshot())",java.math.BigDecimal.class,
    "{\"line_kind\":\"FULL_BAGS\",\"bag_count\":\"0.000000000000000000000001\",\"bag_net_qty\":\"0.000000000000000000000001\"}"));
   var selected=db.queryForObject("SELECT fn_workshop_material_derived_quantity('workshop_material_count_lines',?::jsonb,?::jsonb)",java.math.BigDecimal.class,
    "{\"line_kind\":\"FULL_BAGS\",\"bag_count\":\"0.000000000000000000000001\",\"bag_net_qty\":\"0.000000000000000000000001\"}",
    "{\"version\":1,\"choices\":{\"workshop.material.count-quantity\":{\"scale\":24,\"rounding\":\"DOWN\"}}}");
   assertEquals(0,selected.signum());
   assertThrows(org.springframework.dao.DataAccessException.class,()->db.queryForObject("SELECT fn_workshop_material_derived_quantity('workshop_material_count_lines',?::jsonb,fn_business_precision_snapshot())",java.math.BigDecimal.class,
    "{\"line_kind\":\"WEIGHED\",\"weighed_qty\":\"NaN\"}"));
  }
 }

}
