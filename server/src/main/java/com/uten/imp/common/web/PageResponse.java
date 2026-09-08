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

    /** Return the page actually queried, including its normalized size and index. */
    public PageResponse(List<T> items, Page<?> result) {
        this(items, result.getNumber() + 1, result.getSize(),
                result.getTotalElements(), result.getTotalPages());
    }
}
