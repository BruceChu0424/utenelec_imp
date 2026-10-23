package com.uten.imp.features.master.goods.importing;

import java.util.List;
import java.util.UUID;

/** JSON keeps large review selections out of URL/request-line limits. file is base64 in JSON. */
public record GoodsImportCommitRequest(byte[] file, UUID planId, String filename, List<String> replaceRowKeys) {}
