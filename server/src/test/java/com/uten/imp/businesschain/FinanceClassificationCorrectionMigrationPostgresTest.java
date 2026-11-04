package com.uten.imp.businesschain;

import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import java.nio.file.*;
import static org.assertj.core.api.Assertions.*;

/** Installs the draft on a full current schema before it is exposed as a live Flyway migration. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class FinanceClassificationCorrectionMigrationPostgresTest {
 @Test void installsOnFullCurrentSchemaAndExecutesTheSharedViewsAndGuards() throws Exception {
  try(var lease=MigratedSchemaBaseline.openDatabase("classification_draft");var connection=lease.openConnection();var sql=connection.createStatement()){
   boolean installed;
   try(var rows=sql.executeQuery("SELECT to_regclass('finance_classification_corrections') IS NOT NULL")){rows.next();installed=rows.getBoolean(1);}
   if(!installed)sql.execute(Files.readString(Path.of("../tmp/finance-classification-graph/V1020__whole_graph_classification_corrections.sql")));
   try(var rows=sql.executeQuery("SELECT to_regclass('v_finance_payable_statement_adjustment_parts_effective') IS NOT NULL")){rows.next();installed=rows.getBoolean(1);}
   if(!installed)sql.execute(Files.readString(Path.of("../tmp/finance-classification-graph/V1029__fee_classification_effective_evidence.sql")));
   try(var rows=sql.executeQuery("SELECT count(*) FROM v_finance_payable_statement_adjustment_parts_effective")){assertThat(rows.next()).isTrue();}
   for(String view:new String[]{"v_finance_supplier_advance_target_parts_effective","v_finance_payable_category_consumption_events","v_finance_classification_actual_references"})try(var rows=sql.executeQuery("SELECT count(*) FROM "+view)){assertThat(rows.next()).isTrue();}
   try(var rows=sql.executeQuery("SELECT fn_finance_payable_classification_exceeds('00000000-0000-0000-0000-000000000001'),fn_finance_receivable_classification_exceeds('00000000-0000-0000-0000-000000000001')")){rows.next();assertThat(rows.getBoolean(1)).isFalse();assertThat(rows.getBoolean(2)).isFalse();}
   assertThatThrownBy(()->sql.execute("SELECT fn_assert_finance_classification_correction('00000000-0000-0000-0000-000000000001')")).hasMessageContaining("Incomplete classification graph receipt");
   for(String kind:new String[]{"SOURCE","AP_PAYMENT","AR_RECEIPT","AP_OFFSET","AR_OFFSET","AP_ADVANCE_TARGET"}){
    try(var statement=sql.getConnection().prepareStatement("SELECT fn_finance_classification_node_batch(?,?)")){statement.setString(1,kind);statement.setString(2,"00000000-0000-0000-0000-000000000001");try(var rows=statement.executeQuery()){rows.next();assertThat(rows.getObject(1)).isNull();}}
    assertThatThrownBy(()->{try(var statement=sql.getConnection().prepareStatement("SELECT fn_finance_classification_node_fact(?,?)")){statement.setString(1,kind);statement.setString(2,"00000000-0000-0000-0000-000000000001");statement.execute();}}).hasMessageContaining("Missing actual classification node");
   }
  }
 }
}
