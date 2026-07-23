package com.uten.imp.common.web;

import lombok.AllArgsConstructor;
import lombok.Getter;
import org.springframework.data.domain.Page;

import java.util.List;

/** 分页响应。 */
@Getter
@AllArgsConstructor
public class PageResponse<T> {

    private final List<T> items;
    private final int page;
    private final int size;
    private final long total;
    private final int totalPages;

    public static <T> PageResponse<T> of(Page<T> page) {
        return new PageResponse<>(
                page.getContent(),
                page.getNumber() + 1,   // Spring Data 页码从 0 起，对外从 1 起
                page.getSize(),
                page.getTotalElements(),
                page.getTotalPages());
    }
}
