package com.uten.imp.features.master.goods.importing;

import java.util.UUID;

/** Identity-only projection deliberately excludes legacy goods image/blob columns. */
public record GoodsImportIdentity(UUID id, long version, String code, String name, UUID categoryId,
                                  boolean deleted, UUID ownerEmployeeId) {}
