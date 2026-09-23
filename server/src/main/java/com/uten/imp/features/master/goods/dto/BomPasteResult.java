package com.uten.imp.features.master.goods.dto;

import java.util.List;
import java.util.UUID;

/**
 * 粘贴组件信息的结果：逐个目标报「删掉几行、加了几行」。
 * 失败不走这里——失败时一条都没写，按 409 + 逐条原因(fieldErrors)返回。
 */
public record BomPasteResult(int targets, int added, int removed, List<Target> results) {

    public record Target(UUID goodsId, String label, int removed, int added) {
    }
}
