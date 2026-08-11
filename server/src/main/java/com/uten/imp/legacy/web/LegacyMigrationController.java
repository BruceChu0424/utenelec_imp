package com.uten.imp.legacy.web;

import com.uten.imp.legacy.migration.LegacyMigrationOrchestrator;
import com.uten.imp.legacy.migration.LegacyMigrationOrchestrator.FullMigrationReport;
import com.uten.imp.legacy.migration.ClientCategoryMigrator;
import com.uten.imp.legacy.migration.MaterialCategoryMigrator;
import com.uten.imp.legacy.migration.MaterialCategoryMigrator.MigrationReport;
import com.uten.imp.legacy.migration.MouldCategoryMigrator;
import com.uten.imp.legacy.migration.SupplierCategoryMigrator;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 老库数据迁移触发端点（超管手动触发，幂等可重跑）。
 *
 * <p>{@code POST /api/admin/legacy-migration/all} —— 一键迁移全部已实现模块（推荐）；
 * 单模块端点（如 {@code /material-category}）可单独触发或排错。
 *
 * <p>正式迁移 / 老库新增数据后增量同步：直接再调一次即可（按 legacy_id 幂等）。
 */
@RestController
@RequestMapping("/api/admin/legacy-migration")
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
public class LegacyMigrationController {

    private final MaterialCategoryMigrator migrator;
    private final MouldCategoryMigrator mouldMigrator;
    private final ClientCategoryMigrator clientMigrator;
    private final SupplierCategoryMigrator supplierMigrator;
    private final LegacyMigrationOrchestrator orchestrator;

    /** 一键迁移全部已实现模块（超管）。各模块独立事务，互不影响。 */
    @PostMapping("/all")
    public FullMigrationReport migrateAll() {
        return orchestrator.migrateAll();
    }

    /** 迁移老库货品分类树（SystemItem.ItemclassID=1）→ material_categories。 */
    @PostMapping("/material-category")
    public MigrationReport migrateGoods() {
        return migrator.migrateGoods();
    }

    /** 迁移老库模具系列分类（SystemItem.ItemclassID=18）→ mould_categories。 */
    @PostMapping("/mould-category")
    public MouldCategoryMigrator.MigrationReport migrateMoulds() {
        return mouldMigrator.migrateMoulds();
    }

    /** 迁移老库客户分类（SystemItem.ItemclassID=2，外贸/区域/省份）→ client_categories。 */
    @PostMapping("/client-category")
    public ClientCategoryMigrator.MigrationReport migrateClients() {
        return clientMigrator.migrateClients();
    }

    /** 迁移老库供应商分类（SystemItem.ItemclassID=3，五金/塑胶/玻璃面板）→ supplier_categories。 */
    @PostMapping("/supplier-category")
    public SupplierCategoryMigrator.MigrationReport migrateSuppliers() {
        return supplierMigrator.migrateSuppliers();
    }
}
