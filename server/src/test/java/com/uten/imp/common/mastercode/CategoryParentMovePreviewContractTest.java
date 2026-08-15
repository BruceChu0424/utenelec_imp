package com.uten.imp.common.mastercode;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class CategoryParentMovePreviewContractTest {

    @Test
    void previewCanResolveTheRequestedParentBeforeCategoryMutation() throws IOException {
        String source = read("src/main/java/com/uten/imp/common/mastercode/CategoryDrivenCodeService.java");
        assertThat(source).contains("CategoryPrefixPreview previewForParent(");
        assertThat(source).contains("effectivePrefixOrFallback(type, requestedParentId)");
        assertThat(source).contains("isDescendantOrSelf(type, categoryId, requestedParentId)");
    }

    @Test
    void allCategoryControllersPassParentIdIntoTheServerPreview() throws IOException {
        for (String type : new String[]{
                "materialcategory/MaterialCategoryController.java",
                "mouldcategory/MouldCategoryController.java",
                "clientcategory/ClientCategoryController.java",
                "suppliercategory/SupplierCategoryController.java"
        }) {
            String source = read("src/main/java/com/uten/imp/features/master/" + type);
            assertThat(source).contains("@RequestParam(required = false) UUID parentId");
            assertThat(source).contains("prefix == null ? \"\" : prefix, parentId");
        }
    }

    @Test
    void allocationAndPreviewConsultLifetimeReservationsNotOnlyCurrentRows()
            throws IOException {
        String source = read("src/main/java/com/uten/imp/common/mastercode/"
                + "CategoryDrivenCodeService.java");

        assertThat(source).contains("FROM master_code_reservations reservation");
        assertThat(source).contains("FROM master_code_reservation_members member");
        assertThat(source).contains(".setParameter(\"masterDomain\", type.name())");
    }

    private static String read(String serverRelativePath) throws IOException {
        Path direct = Path.of(serverRelativePath);
        Path path = Files.exists(direct) ? direct : Path.of("server").resolve(serverRelativePath);
        return Files.readString(path, StandardCharsets.UTF_8);
    }
}
