package com.uten.imp.features.master.goods.importing;

import java.util.List;

/**
 * 组装信息导入提交结果（一次事务内按层写入）。
 *
 * @param targets 写入的父货品数（目标货品 + 文件里作为父级的各层组件）
 * @param added   新建组件行总数
 * @param removed 替换模式下删掉的旧组件行总数
 * @param levels  文件里出现的层数（1 = 只有顶层）
 * @param warnings 写入后的提醒(不拦写入)，如整批领料的料的单个重量与货品资料单重相差 20% 以上
 */
public record BomImportResult(int targets, int added, int removed, int levels, List<String> warnings) {

    public BomImportResult {
        warnings = warnings == null ? List.of() : List.copyOf(warnings);
    }
}
