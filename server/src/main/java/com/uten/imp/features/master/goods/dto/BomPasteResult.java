package com.uten.imp.features.master.goods.dto;

import java.util.List;
import java.util.UUID;

/**
 * 粘贴组件信息的结果：逐个目标报「替换掉几个原有组件、写入几个组件」(替换模式里同一组件
 * 原地覆盖也按替换计，与全删再全建同口径)。
 * 失败不走这里——失败时一条都没写，按 409 + 逐条原因(fieldErrors)返回。
 *
 * @param warnings 写入后的提醒(不拦写入)，如整批领料的料的单个重量与货品资料单重相差 20% 以上
 */
public record BomPasteResult(int targets, int added, int removed, List<Target> results, List<String> warnings) {

    public BomPasteResult {
        warnings = warnings == null ? List.of() : List.copyOf(warnings);
    }

    public record Target(UUID goodsId, String label, int removed, int added) {
    }
}
