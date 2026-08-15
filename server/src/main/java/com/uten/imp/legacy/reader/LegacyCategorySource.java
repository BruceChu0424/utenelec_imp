package com.uten.imp.legacy.reader;

import java.util.List;

/**
 * 本地开发分类样例数据源。
 *
 * <p>唯一实现是 {@link LegacyCategoryCsvSource}，且仅在 {@code dev} profile 注册。
 * 正式老库导入由 {@code server/legacy_migration} 的受审离线链执行，运行中 ERP
 * 不连接 SQL Server。
 */
public interface LegacyCategorySource {
    List<LegacyCategoryRow> readCategoryTree(int itemClassId);
}
