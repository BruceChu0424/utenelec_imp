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
            TestFlyway.configure().dataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword()).target("1071").load().migrate();
            try(var db=DriverManager.getConnection(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword())) {
                String quantityBefore=definition(db,"fn_guard_document_quantity_adoption()");
                String weightBefore=definition(db,"fn_validate_receipt_weight_adoption()");
                assertThat(quantityBefore).contains("fn_unapproval_frozen_fields","fn_unapproval_source_item");
                assertThat(weightBefore).contains("fn_unapproval_source_item");
                TestFlyway.configure().dataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword()).target("1072").load().migrate();
                String quantityAfter=definition(db,"fn_guard_document_quantity_adoption()");
                String weightAfter=definition(db,"fn_validate_receipt_weight_adoption()");
                String legacyQuantity=" IF TG_OP='INSERT' AND TG_TABLE_SCHEMA='public' AND NEW.legacy_id IS NOT NULL\n"
                        +"    AND public.fn_accept_verified_legacy_quantity_adoption(TG_TABLE_NAME,to_jsonb(NEW)) THEN\n"
                        +"  NEW.quantity_adoption_version:=1; NEW.quantity_precision_policy:=NULL; RETURN NEW;\n END IF;\n";
                String legacyWeight=" IF TG_OP='INSERT' AND TG_TABLE_SCHEMA='public' AND NEW.quantity_adoption_version=1\n"
                        +"    AND public.fn_accept_verified_legacy_quantity_adoption(TG_TABLE_NAME,to_jsonb(NEW)) THEN RETURN NULL; END IF;\n";
                assertThat(occurrences(quantityAfter,legacyQuantity)).isEqualTo(1);
                assertThat(occurrences(weightAfter,legacyWeight)).isEqualTo(1);
                assertThat(quantityAfter.replace(legacyQuantity,"")).isEqualTo(quantityBefore);
                assertThat(weightAfter.replace(legacyWeight,"")).isEqualTo(weightBefore);
                assertThat(quantityAfter.indexOf("fn_unapproval_source_item")).isLessThan(quantityAfter.indexOf("fn_accept_verified_legacy_quantity_adoption"));
                assertThat(weightAfter.indexOf("fn_unapproval_source_item")).isLessThan(weightAfter.indexOf("fn_accept_verified_legacy_quantity_adoption"));
                TestFlyway.configure().dataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword()).load().migrate();
                assertThat(definition(db,"fn_guard_document_quantity_adoption()")).isEqualTo(quantityAfter);
                assertThat(definition(db,"fn_validate_receipt_weight_adoption()")).isEqualTo(weightAfter);
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
    private static int occurrences(String value,String needle){return (value.length()-value.replace(needle,"").length())/needle.length();}
    private static String sha(String text) throws Exception{return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(text.getBytes(StandardCharsets.UTF_8)));}
}
