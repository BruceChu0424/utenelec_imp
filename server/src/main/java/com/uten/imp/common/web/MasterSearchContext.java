package com.uten.imp.common.web;

import java.util.List;
import java.util.UUID;

/** Bounded category metadata for one authorized master search; a null category remains a real bucket. */
public record MasterSearchContext(long totalMatches, List<CategoryCount> categories, int page, int size,
                                  long totalCategories, int totalPages) {
    public record CategoryCount(UUID categoryId, long count) { }
}
