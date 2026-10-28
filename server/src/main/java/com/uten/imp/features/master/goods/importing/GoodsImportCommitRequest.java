package com.uten.imp.features.master.goods.importing;

import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/** JSON keeps large review selections out of URL/request-line limits. file is base64 in JSON. */
public record GoodsImportCommitRequest(byte[] file, UUID planId, String filename,
                                       List<String> replaceRowKeys, Map<Integer, String> codeCorrections,
                                       Set<Integer> excludedRowNums, Map<Integer, Map<String, String>> cellCorrections,
                                       String mode) {
    public GoodsImportCommitRequest(byte[] file, UUID planId, String filename, List<String> replaceRowKeys) {
        this(file, planId, filename, replaceRowKeys, null, null, null, null);
    }
    public GoodsImportCommitRequest(byte[] file, UUID planId, String filename,
                                     List<String> replaceRowKeys, Map<Integer, String> codeCorrections) {
        this(file, planId, filename, replaceRowKeys, codeCorrections, null, null, null);
    }
    public GoodsImportCommitRequest(byte[] file, UUID planId, String filename,
                                     List<String> replaceRowKeys, Map<Integer, String> codeCorrections,
                                     Set<Integer> excludedRowNums) {
        this(file, planId, filename, replaceRowKeys, codeCorrections, excludedRowNums, null, null);
    }
    public GoodsImportCommitRequest(byte[] file, UUID planId, String filename,
                                     List<String> replaceRowKeys, Map<Integer, String> codeCorrections,
                                     Set<Integer> excludedRowNums, Map<Integer, Map<String, String>> cellCorrections) {
        this(file, planId, filename, replaceRowKeys, codeCorrections, excludedRowNums, cellCorrections, null);
    }
}
