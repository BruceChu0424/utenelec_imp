package com.uten.imp.legacy.web;

import com.uten.imp.legacy.migration.ClientCategoryMigrator;
import com.uten.imp.legacy.migration.MaterialCategoryMigrator;
import com.uten.imp.legacy.migration.MaterialCategoryMigrator.MigrationReport;
import com.uten.imp.legacy.migration.MouldCategoryMigrator;
import com.uten.imp.legacy.migration.SupplierCategoryMigrator;
import lombok.RequiredArgsConstructor;
import org.springframework.context.annotation.Profile;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 本地开发分类树种子端点。
 *
 * <p>只读取 classpath 中的四份离线分类样例，不是生产迁移、全量导入或增量同步入口。
 */
@RestController
@RequestMapping("/api/admin/dev/legacy-category-seed")
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
@Profile("dev")
public class LegacyMigrationController {

    private final MaterialCategoryMigrator migrator;
    private final MouldCategoryMigrator mouldMigrator;
    private final ClientCategoryMigrator clientMigrator;
    private final SupplierCategoryMigrator supplierMigrator;

    /** 导入货品分类样例（SystemItem.ItemclassID=1）。 */
    @PostMapping("/material-category")
    public MigrationReport migrateGoods() {
        return migrator.migrateGoods();
    }

    /** 导入模具分类样例（SystemItem.ItemclassID=18）。 */
    @PostMapping("/mould-category")
    public MouldCategoryMigrator.MigrationReport migrateMoulds() {
        return mouldMigrator.migrateMoulds();
    }

    /** 导入客户分类样例（SystemItem.ItemclassID=2）。 */
    @PostMapping("/client-category")
    public ClientCategoryMigrator.MigrationReport migrateClients() {
        return clientMigrator.migrateClients();
    }

    /** 导入供应商分类样例（SystemItem.ItemclassID=3）。 */
    @PostMapping("/supplier-category")
    public SupplierCategoryMigrator.MigrationReport migrateSuppliers() {
        return supplierMigrator.migrateSuppliers();
    }
}
