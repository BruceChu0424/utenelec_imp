package com.uten.imp.features.master;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.Objects;
import java.util.UUID;

/** Runtime access to the UUID-authoritative system category registry. */
@Component
@RequiredArgsConstructor
public class SystemMasterCategoryRegistry {

    private final SystemMasterCategoryRegistryRepository repository;

    public UUID materialCategoryId() {
        return requireRegistry().getMaterialCategoryId();
    }

    public UUID clientCategoryId() {
        return requireRegistry().getClientCategoryId();
    }

    public UUID mouldCategoryId() {
        return requireRegistry().getMouldCategoryId();
    }

    public UUID supplierCategoryId() {
        return requireRegistry().getSupplierCategoryId();
    }

    public boolean isClientCategory(UUID categoryId) {
        return Objects.equals(categoryId, clientCategoryId());
    }

    /** V718 起货品未分类根已脱钩（列为空）：列空 = 没有受保护的货品系统根。 */
    public boolean isMaterialCategory(UUID categoryId) {
        UUID root = materialCategoryId();
        return root != null && Objects.equals(categoryId, root);
    }

    public boolean isMouldCategory(UUID categoryId) {
        return Objects.equals(categoryId, mouldCategoryId());
    }

    public boolean isSupplierCategory(UUID categoryId) {
        return Objects.equals(categoryId, supplierCategoryId());
    }

    private SystemMasterCategoryRegistryEntry requireRegistry() {
        return repository.findById(SystemMasterCategories.REGISTRY_ID)
                .orElseThrow(() -> new ApiException(
                        ErrorCode.INTERNAL,
                        "系统未分类 UUID 注册表缺失"));
    }
}
