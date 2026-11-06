package com.uten.imp.migration;

import com.uten.imp.testsupport.TestFlyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.sql.Connection;
import java.sql.DriverManager;
import java.util.HexFormat;
import static org.assertj.core.api.Assertions.assertThat;

/** The forward legacy exception must leave the actual Main unapproval/native guards byte-exact. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class LegacyQuantityUnapprovalCompositionPostgresTest {
    @Test void actualForwardDefinitionsRetainEveryUnapprovalAndNativeGuardAfterRemovingOnlyLegacyBranches() throws Exception {
        try(var pg=new PostgreSQLContainer("postgres:16-alpine").withDatabaseName("legacy_clone_composition")) {
            pg.start();
            TestFlyway.configure().dataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword()).target("1075").load().migrate();
            try(var db=DriverManager.getConnection(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword())) {
                String quantityBefore=definition(db,"fn_guard_document_quantity_adoption()");
                String weightBefore=definition(db,"fn_validate_receipt_weight_adoption()");
                assertThat(quantityBefore).contains("fn_unapproval_frozen_fields","fn_unapproval_source_item");
                assertThat(weightBefore).contains("fn_unapproval_source_item");
                TestFlyway.configure().dataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword()).target("1076").load().migrate();
                String mainQuantity=definition(db,"fn_guard_document_quantity_adoption()");
                String mainWeight=definition(db,"fn_validate_receipt_weight_adoption()");
                String mainLegacyQuantity=" IF TG_OP='INSERT' AND TG_TABLE_NAME IN('purchase_receipt_items','subcontract_receipt_items')\n    AND (to_jsonb(NEW)->>'legacy_id' IS NOT NULL OR to_jsonb(NEW)->>'legacy_import_run_id' IS NOT NULL) THEN\n  PERFORM public.fn_assert_legacy_receipt_import_source(TG_TABLE_NAME,to_jsonb(NEW));\n  IF NEW.quantity_adoption_version IS DISTINCT FROM 2 OR NEW.quantity_precision_policy IS NOT NULL\n     OR TG_TABLE_NAME='purchase_receipt_items' AND (\n       to_jsonb(NEW)->>'quantity_semantics' IS DISTINCT FROM 'LEGACY_RECORDED'\n       OR to_jsonb(NEW)->>'charged_base_qty' IS NOT NULL OR to_jsonb(NEW)->>'gift_base_qty' IS NOT NULL)\n     OR TG_TABLE_NAME='subcontract_receipt_items' AND to_jsonb(NEW)->>'adopted_base_qty' IS NOT NULL THEN\n   RAISE EXCEPTION 'historical receipt cannot supply a new quantity adoption or invented derived values' USING ERRCODE='23514';\n  END IF;\n  NEW.quantity_adoption_version:=1;\n  NEW.quantity_precision_policy:=NULL;\n  RETURN NEW;\n END IF;\n";
                String mainLegacyWeight=" IF TG_OP='INSERT' AND TG_TABLE_NAME IN('purchase_receipt_items','subcontract_receipt_items')\n    AND (to_jsonb(NEW)->>'legacy_id' IS NOT NULL OR to_jsonb(NEW)->>'legacy_import_run_id' IS NOT NULL) THEN\n  PERFORM public.fn_assert_legacy_receipt_import_source(TG_TABLE_NAME,to_jsonb(NEW));\n  RETURN NULL;\n END IF;\n";
                assertThat(occurrences(mainQuantity,mainLegacyQuantity)).isEqualTo(1);
                assertThat(occurrences(mainWeight,mainLegacyWeight)).isEqualTo(1);
                assertThat(mainQuantity.replace(mainLegacyQuantity,"")).isEqualTo(quantityBefore);
                assertThat(mainWeight.replace(mainLegacyWeight,"")).isEqualTo(weightBefore);
                // Preserve the latest committed finance source/frozen-facts authority, not only the old1075 baseline.
                TestFlyway.configure().dataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword()).target("1090").load().migrate();
                String latestQuantity=definition(db,"fn_guard_document_quantity_adoption()");
                String latestWeight=definition(db,"fn_validate_receipt_weight_adoption()");
                assertThat(occurrences(latestQuantity,mainLegacyQuantity)).isEqualTo(1);
                assertThat(occurrences(latestWeight,mainLegacyWeight)).isEqualTo(1);
                assertThat(latestQuantity.replace(mainLegacyQuantity,"")).isEqualTo(quantityBefore);
                assertThat(latestWeight.replace(mainLegacyWeight,"")).isEqualTo(weightBefore);
                var preservedFinance=financeAuthority(db);
                TestFlyway.configure().dataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword()).target("1091").load().migrate();
                String quantityAfter=definition(db,"fn_guard_document_quantity_adoption()");
                String weightAfter=definition(db,"fn_validate_receipt_weight_adoption()");
                String legacyQuantity=" IF TG_OP='INSERT' AND TG_TABLE_SCHEMA='public'\n"
                        +"    AND (NEW.legacy_id IS NOT NULL OR to_jsonb(NEW)->>'legacy_import_run_id' IS NOT NULL\n"
                        +"         OR to_jsonb(NEW)->>'legacy_counter_import_run_id' IS NOT NULL)\n"
                        +"    AND public.fn_accept_verified_legacy_quantity_adoption(TG_TABLE_NAME,to_jsonb(NEW),'QUANTITY') THEN\n"
                        +"  NEW.quantity_adoption_version:=1; NEW.quantity_precision_policy:=NULL; RETURN NEW;\n END IF;\n";
                String legacyWeight=" IF TG_OP='INSERT' AND TG_TABLE_SCHEMA='public' AND NEW.quantity_adoption_version=1\n"
                        +"    AND public.fn_accept_verified_legacy_quantity_adoption(TG_TABLE_NAME,to_jsonb(NEW),'WEIGHT') THEN RETURN NULL; END IF;\n";
                assertThat(quantityAfter).doesNotContain(mainLegacyQuantity);
                assertThat(weightAfter).doesNotContain(mainLegacyWeight);
                assertThat(occurrences(quantityAfter,legacyQuantity)).isEqualTo(1);
                assertThat(occurrences(weightAfter,legacyWeight)).isEqualTo(1);
                assertThat(quantityAfter.replace(legacyQuantity,"")).isEqualTo(quantityBefore);
                assertThat(weightAfter.replace(legacyWeight,"")).isEqualTo(weightBefore);
                assertThat(quantityAfter.replace(legacyQuantity,"")).isEqualTo(latestQuantity.replace(mainLegacyQuantity,""));
                assertThat(weightAfter.replace(legacyWeight,"")).isEqualTo(latestWeight.replace(mainLegacyWeight,""));
                assertThat(financeAuthority(db)).isEqualTo(preservedFinance);
                assertThat(quantityAfter.indexOf("fn_unapproval_source_item")).isLessThan(quantityAfter.indexOf("fn_accept_verified_legacy_quantity_adoption"));
                assertThat(weightAfter.indexOf("fn_unapproval_source_item")).isLessThan(weightAfter.indexOf("fn_accept_verified_legacy_quantity_adoption"));
                TestFlyway.configure().dataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword()).load().migrate();
                assertThat(definition(db,"fn_guard_document_quantity_adoption()")).isEqualTo(quantityAfter);
                assertThat(definition(db,"fn_validate_receipt_weight_adoption()")).isEqualTo(weightAfter);
                assertThat(financeAuthority(db)).isEqualTo(preservedFinance);
                System.out.println("legacy-unapproval-runtime-definition-proof quantity-main="+sha(quantityBefore)
                        +" quantity-composed="+sha(quantityAfter)+" weight-main="+sha(weightBefore)+" weight-composed="+sha(weightAfter));
            }
        }
    }
    private static String definition(Connection db,String function) throws Exception {
        try(var sql=db.prepareStatement("SELECT pg_get_functiondef(CAST(? AS regprocedure))")) {
            sql.setString(1,function);try(var row=sql.executeQuery()){assertThat(row.next()).isTrue();return row.getString(1);}
        }
    }
    private static java.util.Map<String,String> financeAuthority(Connection db) throws Exception {
        var facts=new java.util.LinkedHashMap<String,String>();
        for(String function:java.util.List.of("fn_unapproval_source_profiles()","fn_unapproval_source_profile(text)",
                "fn_unapproval_source_item(text,jsonb,boolean)","fn_unapproval_frozen_fields(text,jsonb)",
                "fn_guard_unapproval_source_item()","fn_guard_unapproval_creation_proof()","fn_validate_unapproval_source_completion()",
                "fn_guard_sales_return_quantity_adoption()","fn_guard_financial_unapproval_initial_header()",
                "fn_guard_financial_unapproval_initial_line()","fn_unapproval_financial_headers_match(text,jsonb,jsonb,uuid,boolean)")) {
            try(var statement=db.prepareStatement("SELECT pg_get_functiondef(oid)||E'\\n'||jsonb_build_object('owner',pg_get_userbyid(proowner),'acl',proacl::text,'config',proconfig)::text FROM pg_proc WHERE oid=CAST(? AS regprocedure)")) {
                statement.setString(1,function);
                try(var row=statement.executeQuery()){assertThat(row.next()).as(function).isTrue();facts.put(function,row.getString(1));}
            }
        }
        return facts;
    }
    private static int occurrences(String value,String needle){return (value.length()-value.replace(needle,"").length())/needle.length();}
    private static String sha(String text) throws Exception{return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(text.getBytes(StandardCharsets.UTF_8)));}
}
