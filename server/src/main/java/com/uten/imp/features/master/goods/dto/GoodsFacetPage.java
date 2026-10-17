package com.uten.imp.features.master.goods.dto;

import java.util.List;

/** Distinct candidates searched over the authorized goods scope, before paging. */
public record GoodsFacetPage(List<FacetBucket> items, boolean hasMore) {}
