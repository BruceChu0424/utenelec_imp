package com.uten.imp.legacy.migration;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;
import java.util.function.Supplier;

/**
 * 老库 → 新库 <b>一键迁移总入口</b>。
 *
 * <p>串行调用各模块 Migrator（各自独立 {@code @Transactional} 事务，互不影响），
 * 汇总每个模块的报告；某模块失败不中断其他模块，失败信息记入报告。
 *
 * <p><b>新增分类树模块</b>（员工 / 工资…；扁平主档如颜色/单位走 shell，不经本类）：
 * <ol>
 *   <li>实现对应 Migrator（仿 {@link MaterialCategoryMigrator}，按 {@code legacy_id} 幂等 upsert）；</li>
 *   <li>在 {@link #migrateAll()} 注册一行 {@code run(...)}；</li>
 *   <li>在 {@code docs/数据迁移/README.md} 模块清单表登记一行。</li>
 * </ol>
 *
 * <p>触发：{@code POST /api/admin/legacy-migration/all}（超管），见
 * {@link com.uten.imp.legacy.web.LegacyMigrationController}。
 */
@Service
@RequiredArgsConstructor
@Slf4j
public class LegacyMigrationOrchestrator {

    private final MaterialCategoryMigrator materialCategoryMigrator;
    private final MouldCategoryMigrator mouldCategoryMigrator;
    private final ClientCategoryMigrator clientCategoryMigrator;
    private final SupplierCategoryMigrator supplierCategoryMigrator;

    // 注：颜色(colors)/单位(units)为扁平字典，不走 Java Migrator（本类只迁 SystemItem 分类树），
    // 其主档由 shell 批量灌入（migrate.sh --color-data / --unit-data，见 docs/数据迁移/11、13）。

    /** 一键迁移结果：各模块报告 + 整体是否成功 + 失败汇总。 */
    public record FullMigrationReport(Map<String, Object> modules, boolean success, String error) {}

    /** 一键迁移全部已实现模块。 */
    public FullMigrationReport migrateAll() {
        Map<String, Object> modules = new LinkedHashMap<>();
        StringBuilder err = new StringBuilder();

        run("materialCategory.goods", materialCategoryMigrator::migrateGoods, modules, err);
        run("mould.category", mouldCategoryMigrator::migrateMoulds, modules, err);
        run("client.category", clientCategoryMigrator::migrateClients, modules, err);
        run("supplier.category", supplierCategoryMigrator::migrateSuppliers, modules, err);

        return new FullMigrationReport(
                modules,
                err.length() == 0,
                err.length() == 0 ? null : "部分迁移模块执行失败；错误编号：" + err);
    }

    /** 跑一个模块：成功记报告，失败记 error 并继续下一个。 */
    private void run(String name, Supplier<?> task, Map<String, Object> modules, StringBuilder err) {
        try {
            modules.put(name, task.get());
        } catch (Exception e) {
            String referenceId = UUID.randomUUID().toString();
            log.error(
                    "Legacy migration module failed: module={}, referenceId={}",
                    name,
                    referenceId,
                    e);
            modules.put(
                    name,
                    Map.of(
                            "status", "failed",
                            "errorCode", "LEGACY_MIGRATION_MODULE_FAILED",
                            "referenceId", referenceId));
            if (!err.isEmpty()) {
                err.append(", ");
            }
            err.append(name).append('=').append(referenceId);
        }
    }
}
