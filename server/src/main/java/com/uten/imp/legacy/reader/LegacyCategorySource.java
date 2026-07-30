package com.uten.imp.legacy.reader;

import java.util.List;

/**
 * 老库分类树数据源。
 *
 * <p>两个实现（按 Spring profile 自动选择）：
 * <ul>
 *   <li>{@code dev} profile → {@link LegacyCategoryCsvSource}：读 classpath 离线 CSV
 *       （避开 Java 连 Windows LocalDB 的集成认证 dll 坑）；</li>
 *   <li>其他（prod）→ {@link LegacySystemItemReader}：连老库 SQL Server 实时读。</li>
 * </ul>
 * 迁移逻辑（{@code MaterialCategoryMigrator}）对两者一致。
 */
public interface LegacyCategorySource {
    List<LegacyCategoryRow> readCategoryTree(int itemClassId);
}
