package com.uten.imp.common.web;

import org.springframework.data.domain.PageRequest;
import org.springframework.data.domain.Sort;

/** 分页构造统一入口：对外页码从 1 起，每页 1..100 条。 */
public final class Pageables {

    private Pageables() {}

    public static PageRequest of(int page, int size) {
        return PageRequest.of(Math.max(1, page) - 1, Math.min(Math.max(1, size), 100));
    }

    public static PageRequest of(int page, int size, Sort sort) {
        return PageRequest.of(
                Math.max(1, page) - 1,
                Math.min(Math.max(1, size), 100),
                sort);
    }
}
