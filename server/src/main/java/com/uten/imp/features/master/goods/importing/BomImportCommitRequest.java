package com.uten.imp.features.master.goods.importing;

import java.util.Set;

/** JSON transports the workbook as base64 without putting a large selection in the URL. */
public record BomImportCommitRequest(byte[] file, String stateFingerprint, String mode,
                                     Set<String> replaceRowKeys) {}
