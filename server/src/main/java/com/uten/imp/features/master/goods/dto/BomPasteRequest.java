package com.uten.imp.features.master.goods.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.util.List;
import java.util.UUID;

/**
 * 粘贴组件信息(ADR-111)：把剪贴板里的一组组件行一次写到 1~50 个目标货品上。
 *
 * <p>整批原子：任何一个目标、任何一行不合格(重复、成环、组件停用/已删、用量非法、目标已被
 * 他人改过……)就一条都不写，并逐条说明原因；全部合格才在一个事务里替换或追加。
 *
 * @param mode    REPLACE=先删掉目标现有组件再写入；APPEND=在现有组件后追加(与现有组件重复算不合格)
 * @param targets 目标货品；{@code expectedItemIds} 是客户端读到的目标现有组件行 id(乐观锁)，
 *                与服务端当前不一致即「已被他人修改」；为 null 表示不比对(批量粘贴不逐个预读)
 * @param items   组件行，字段口径同单行新增
 */
public record BomPasteRequest(
        @NotNull Mode mode,
        @NotEmpty @Size(max = 50) List<@Valid @NotNull Target> targets,
        @NotEmpty @Size(max = 200) List<@Valid @NotNull BomItemSaveRequest> items) {

    public enum Mode { REPLACE, APPEND }

    public record Target(@NotNull UUID goodsId, @Size(max = 500) List<UUID> expectedItemIds) {
    }
}
