package com.uten.imp.features.stock;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class StockBalanceAdjustmentUuidRelationContractTest {

    @Test
    void v275MigratesTheServiceOwnedMarkerIntoAnAuditedUuidRelation() throws IOException {
        String sql = canonical(source(
                "src/main/resources/db/migration/"
                        + "V275__production_daily_report_source_uuid_guards.sql"));

        assertThat(sql)
                .contains("CREATE TABLE stock_balance_adjustment_requests")
                .contains("id UUID PRIMARY KEY DEFAULT gen_random_uuid()")
                .contains("stock_document_id UUID NOT NULL")
                .contains("FOREIGN KEY (stock_document_id) REFERENCES stock_documents(id)")
                .contains("ON DELETE RESTRICT")
                .contains("SUBSTRING( document.source_doc_no")
                .contains("document.source_doc_no LIKE 'AUTHORIZED_BALANCE_ADJUSTMENT:%'")
                .contains("DROP INDEX IF EXISTS ux_stock_documents_authorized_balance_adjustment_source")
                .contains("CREATE TRIGGER trg_audit_stock_balance_adjustment_requests")
                .contains("EXECUTE FUNCTION fn_audit()")
                .doesNotContain("JOIN stock_documents ON stock_documents.bill_no");
    }

    @Test
    void v275RegistersSystemRootsByUuidAndMakesTheRegistryImmutable() throws IOException {
        String sql = canonical(source(
                "src/main/resources/db/migration/"
                        + "V275__production_daily_report_source_uuid_guards.sql"));

        assertThat(sql)
                .contains("CREATE TABLE system_master_category_registry")
                .contains("material_category_id UUID NOT NULL UNIQUE")
                .contains("client_category_id UUID NOT NULL UNIQUE")
                .contains("mould_category_id UUID NOT NULL UNIQUE")
                .contains("supplier_category_id UUID NOT NULL UNIQUE")
                .contains("FOREIGN KEY (material_category_id) REFERENCES material_categories(id)")
                .contains("FOREIGN KEY (client_category_id) REFERENCES client_categories(id)")
                .contains("FOREIGN KEY (mould_category_id) REFERENCES mould_categories(id)")
                .contains("FOREIGN KEY (supplier_category_id) REFERENCES supplier_categories(id)")
                .contains("CREATE TRIGGER trg_audit_system_master_category_registry")
                .contains("CREATE TRIGGER trg_protect_system_master_category_registry")
                .contains("BEFORE UPDATE OR DELETE ON system_master_category_registry")
                .contains("system master category UUID registry is immutable")
                .contains("registry.material_category_id")
                .contains("registry.client_category_id")
                .contains("registry.mould_category_id")
                .contains("registry.supplier_category_id");
    }

    @Test
    void runtimeUsesTheUuidCommandRelationForReplayAndProtection() throws IOException {
        String service = source(
                "src/main/java/com/uten/imp/features/stock/StockDocService.java");
        String repository = source(
                "src/main/java/com/uten/imp/features/stock/"
                        + "StockBalanceAdjustmentCommandRepository.java");

        assertThat(service)
                .contains("balanceAdjustmentCommands.findByRequestKey(idempotencyKey)")
                .contains("docRepo.findById(command.getStockDocumentId())")
                .contains("balanceAdjustmentCommands.existsByStockDocumentId(document.getId())")
                .doesNotContain("AUTHORIZED_BALANCE_ADJUSTMENT_SOURCE")
                .doesNotContain("findBySourceDocNoAndDeletedFalse")
                .doesNotContain("getSourceDocNo().startsWith");
        assertThat(repository)
                .contains("Optional<StockBalanceAdjustmentCommand> findByRequestKey")
                .contains("boolean existsByStockDocumentId(UUID stockDocumentId)");
    }

    @Test
    void newAdjustmentsPersistCommandUuidWithoutWritingSourceNumber() throws IOException {
        String service = source(
                "src/main/java/com/uten/imp/features/stock/StockDocService.java");

        assertThat(service)
                .contains("StockBalanceAdjustmentCommand command =")
                .contains("command.setRequestKey(balanceAdjustmentRequestKey)")
                .contains("command.setStockDocumentId(d.getId())")
                .contains("balanceAdjustmentCommands.save(command)")
                .doesNotContain("d.setSourceDocNo(balanceAdjustmentRequestKey)")
                .doesNotContain("d.setSourceDocNo(sourceDocNo)");
    }

    @Test
    void systemRootRuntimeAndFlutterUseServerDerivedUuidAuthority() throws IOException {
        String adapter = source(
                "src/main/java/com/uten/imp/features/master/client/"
                        + "WebsiteInquiryClientAdapter.java");
        String clientCategory = source(
                "src/main/java/com/uten/imp/features/master/clientcategory/"
                        + "ClientCategoryService.java");
        String materialCategory = source(
                "src/main/java/com/uten/imp/features/master/materialcategory/"
                        + "MaterialCategoryService.java");
        String flutterGuard = source(
                "../lib/features/basic_data/widgets/system_master_category_guard.dart");

        assertThat(adapter)
                .contains("systemCategories.clientCategoryId()")
                .contains("categoryRepository.findById(categoryId)")
                .doesNotContain("findByLegacyId(SystemMasterCategories.UNCATEGORIZED_LEGACY_ID)");
        assertThat(clientCategory)
                .contains("systemCategories.isClientCategory(category.getId())")
                .contains("n.setSystemManaged(c.getId().equals(systemCategoryId))")
                .doesNotContain("SystemMasterCategories.isUncategorized");
        assertThat(materialCategory)
                .contains("systemCategories.isMaterialCategory(c.getId())")
                .contains("n.setSystemManaged(c.getId().equals(systemCategoryId))")
                .contains("requireMutableCategory")
                .doesNotContain("LEGACY_ORPHAN");
        assertThat(flutterGuard)
                .contains("required bool systemManaged")
                .doesNotContain("legacyId == -1")
                .doesNotContain("SYS_UNCATEGORIZED_CLIENT")
                .doesNotContain("systemUncategorizedCategoryCodes");
        String materialFlutter = source(
                "../lib/features/basic_data/pages/product_category_page.dart");
        assertThat(materialFlutter)
                .contains("_detail?.systemManaged ?? false")
                .contains("systemManaged: detail.systemManaged")
                .doesNotContain("_detail?.code == 'LEGACY_ORPHAN'");
    }

    @Test
    void goodsAndBomLiveWritesCannotResolveLegacyIdsIntoRelations() throws IOException {
        String resolver = source(
                "src/main/java/com/uten/imp/features/master/goods/"
                        + "GoodsMasterRelationshipResolver.java");
        String goodsModel = source("../lib/features/basic_data/models/goods_node.dart");
        String bomTab = source("../lib/features/basic_data/widgets/goods_bom_tab.dart");
        String categoryPage = source("../lib/features/basic_data/pages/product_category_page.dart");

        assertThat(resolver)
                .contains("findById(requiredUuid(id))")
                .contains("当前关联必须提供主档 UUID")
                .doesNotContain("findByLegacyId(")
                .doesNotContain("nonZero(legacyId)");
        assertThat(goodsModel)
                .contains("body.remove(legacyKey);")
                .contains("legacy id 解析成新关联");
        assertThat(bomTab)
                .doesNotContain("'colorLegacyId': e.colorLegacyId")
                .doesNotContain("'vendLegacyId': e.vendLegacyId");
        assertThat(categoryPage)
                .contains("return normalizeGoodsUuidFirstBody(body);")
                .doesNotContain("'colorLegacyId': it.colorLegacyId")
                .doesNotContain("'vendLegacyId': it.vendLegacyId");
    }

    private static String source(String serverRelativePath) throws IOException {
        Path direct = Path.of(serverRelativePath);
        Path path = Files.exists(direct) ? direct : Path.of("server").resolve(serverRelativePath);
        return Files.readString(path.normalize(), StandardCharsets.UTF_8);
    }

    private static String canonical(String value) {
        return value.replaceAll("\\s+", " ").trim();
    }
}
