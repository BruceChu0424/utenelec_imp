package com.uten.imp.security;

import java.nio.file.Files;
import java.nio.file.Path;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;

class WarehouseReadScopeMigrationContractTest {
    @Test void ownerExtensionKeepsTheLatestPurchaseAndOtherOwnerSourceAlgorithmIntact() throws Exception {
        String previous=Files.readString(Path.of("src/main/resources/db/migration/V943__purchase_print_read_authorization_profile.sql"));
        String latest=Files.readString(Path.of("src/main/resources/db/migration/V985__warehouse_read_scope_physical_dimensions.sql"));
        String original=function(previous);
        String extension=function(latest)
                .replace("scopes:=ARRAY['purchase','subcontract','production_plan','stock_doc'];","scopes:=ARRAY['purchase','subcontract','production_plan'];")
                .replace("   WHEN 'stock_doc' THEN ARRAY['native_warehouse_tasks']\n","");
        assertThat(extension).isEqualTo(original);
        assertThat(latest).contains("ENABLE ALWAYS TRIGGER trg_native_warehouse_document_dimensions",
                "ENABLE ALWAYS TRIGGER trg_native_warehouse_item_dimensions");
    }
    private String function(String sql) {
        int start=sql.indexOf("CREATE OR REPLACE FUNCTION fn_mark_native_owner_sources()");
        return sql.substring(start,sql.indexOf("END $$;",start)+7).replace("\r\n","\n");
    }
}
