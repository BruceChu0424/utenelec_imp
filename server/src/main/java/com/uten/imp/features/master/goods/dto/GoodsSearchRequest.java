package com.uten.imp.features.master.goods.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotNull;

/** The existing goods query in a bounded JSON body, so large scopes need no long URL or client-side merge. */
public record GoodsSearchRequest(
        @NotNull @Valid GoodsQueryFilter filter,
        Integer page,
        Integer size,
        String sort,
        String order) {
    public int requestedPage() { return page == null ? 1 : page; }
    public int requestedSize() { return size == null ? 20 : size; }
}
