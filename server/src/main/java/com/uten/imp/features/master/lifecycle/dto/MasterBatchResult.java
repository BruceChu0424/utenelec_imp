package com.uten.imp.features.master.lifecycle.dto;

import java.util.List;
import java.util.UUID;

/**
 * 主档批量命令的逐条结果(ADR-111)。
 *
 * <p>{@code succeeded + failed} 恒等于去重后的请求条数；失败条目的 {@code reason} 是给人看的
 * 中文原因(被哪些单据/货品引用、已被他人修改、没有权限……)，前端逐条展示，不再吞掉。
 * {@code label} 是服务端读到的编号+名称，前端不必为展示失败行再去查详情。
 */
public record MasterBatchResult(int succeeded, int failed, List<ItemResult> results) {

    public record ItemResult(UUID id, String label, boolean ok, String reason) {
    }

    public static MasterBatchResult of(List<ItemResult> results) {
        int ok = (int) results.stream().filter(ItemResult::ok).count();
        return new MasterBatchResult(ok, results.size() - ok, List.copyOf(results));
    }
}
