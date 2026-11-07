package com.uten.imp.common.finance;

import com.uten.imp.support.MigratedSchemaBaseline;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import java.nio.file.*;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

/** Source audit for precision migrations. A captured catalog is not a claim
 * that generated expressions or their callers have already been migrated. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class BusinessGeneratedNumericCatalogPostgresTest {
 @Test void currentGeneratedExpressionsAndTheirExactDependenciesAreInspectableWithoutRecomputingAnyBusinessRow()throws Exception{
  try(var database=MigratedSchemaBaseline.openDatabase("business_generated_numeric")){
   var db=new JdbcTemplate(new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword()));
   var generated=db.queryForList("""
    SELECT relation.relname AS table_name,attribute.attname AS column_name,format_type(attribute.atttypid,attribute.atttypmod) AS data_type,
      pg_get_expr(definition.adbin,definition.adrelid) AS expression,
      ARRAY(SELECT source.attname FROM pg_depend dependency JOIN pg_attribute source ON source.attrelid=dependency.refobjid AND source.attnum=dependency.refobjsubid
        WHERE dependency.classid='pg_attrdef'::regclass AND dependency.objid=definition.oid AND dependency.refclassid='pg_class'::regclass
          AND dependency.refobjid=attribute.attrelid AND dependency.refobjsubid>0 ORDER BY source.attnum)::text AS source_columns
    FROM pg_class relation JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
    JOIN pg_attribute attribute ON attribute.attrelid=relation.oid AND attribute.attnum>0 AND NOT attribute.attisdropped
    JOIN pg_attrdef definition ON definition.adrelid=relation.oid AND definition.adnum=attribute.attnum
    WHERE namespace.nspname='public' AND relation.relkind='r' AND attribute.atttypid='numeric'::regtype AND attribute.attgenerated<>''
    ORDER BY relation.relname,attribute.attnum
    """);
   var typmods=db.queryForList("""
    SELECT relation.relname AS table_name,attribute.attname AS column_name,format_type(attribute.atttypid,attribute.atttypmod) AS data_type,
      attribute.attgenerated::text AS generated
    FROM pg_class relation JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
    JOIN pg_attribute attribute ON attribute.attrelid=relation.oid AND attribute.attnum>0 AND NOT attribute.attisdropped
    WHERE namespace.nspname='public' AND relation.relkind='r' AND attribute.atttypid='numeric'::regtype AND attribute.atttypmod>=0
    ORDER BY relation.relname,attribute.attnum
    """);
   assertThat(generated).noneMatch(row->row.get("expression")==null||row.get("source_columns")==null);
   var tables=new HashSet<String>();generated.forEach(row->tables.add(row.get("table_name").toString()));
   var definitions=new ArrayList<Map<String,Object>>();
   for(String table:tables)definitions.addAll(db.queryForList("""
    SELECT relation.relname AS table_name,trigger.tgname,pg_get_triggerdef(trigger.oid) AS trigger_definition,proc.proname,
      pg_get_functiondef(proc.oid) AS function_definition
    FROM pg_trigger trigger JOIN pg_class relation ON relation.oid=trigger.tgrelid JOIN pg_proc proc ON proc.oid=trigger.tgfoid
    WHERE relation.relnamespace='public'::regnamespace AND relation.relname=? AND NOT trigger.tgisinternal ORDER BY trigger.tgname
    """,table));
   var result=Map.of("generated",generated,"remainingTypmods",typmods,"triggers",definitions);
   var output=Path.of(System.getProperty("uten.build.directory","target"),"business-generated-numeric-current.json");
   Files.createDirectories(output.getParent());
   Files.writeString(output,new ObjectMapper().writerWithDefaultPrettyPrinter().writeValueAsString(result));
   assertThat(db.queryForObject("SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND is_generated='ALWAYS'",Integer.class)).isGreaterThanOrEqualTo(generated.size());
  }
 }
}
