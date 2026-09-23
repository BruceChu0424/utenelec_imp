package com.uten.imp.features.master.lifecycle.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.util.List;
import java.util.UUID;

/**
 * 主档批量命令的请求体(ADR-111)：一次请求、一个事务、逐条结果。
 *
 * <p>上限 500 条：列表一页最多 2000 行，但一次勾选超过 500 条的批量删除/启停在业务上
 * 不合理；定死上限让越界请求在 HTTP 边界就被挡掉，不进服务层、不开事务。
 */
public final class MasterBatchRequests {

    /** 单次批量命令的条数上限。 */
    public static final int MAX_ITEMS = 500;

    private MasterBatchRequests() {
    }

    /**
     * 一条目标记录。{@code version} 是列表行读到的乐观锁版本(货品/客户/供应商)，
     * 与库里不一致的那一条以「已被他人修改」失败，其余照常处理；不带版本表示不比对。
     */
    public record Item(@NotNull UUID id, Long version) {
    }

    /** 批量启用/停用：status 只能是「使用」或「禁用」。 */
    public record StatusRequest(
            @NotBlank String status,
            @NotEmpty @Size(max = MAX_ITEMS) List<@Valid @NotNull Item> items) {
    }

    /** 批量删除(软删)：逐条做对象级授权、版本校验与引用保护。 */
    public record DeleteRequest(
            @NotEmpty @Size(max = MAX_ITEMS) List<@Valid @NotNull Item> items) {
    }
}
