package com.uten.imp.features.master.goods.dto;

/** One-based page and zero-based row within the same filtered, ordered list. */
public record GoodsPageLocation(boolean found, int page, int rowIndex) {}
