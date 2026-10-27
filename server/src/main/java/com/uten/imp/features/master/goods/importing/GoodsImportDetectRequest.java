package com.uten.imp.features.master.goods.importing;

import java.util.Map;
import java.util.Set;

/** The original workbook remains intact; corrections identify source rows and permitted import fields. */
public record GoodsImportDetectRequest(byte[] file, Map<Integer, String> codeCorrections, Set<Integer> excludedRowNums,
                                       Map<Integer, Map<String, String>> cellCorrections) {
    public GoodsImportDetectRequest(byte[] file, Map<Integer, String> codeCorrections) {
        this(file, codeCorrections, null, null);
    }
    public GoodsImportDetectRequest(byte[] file, Map<Integer, String> codeCorrections, Set<Integer> excludedRowNums) {
        this(file, codeCorrections, excludedRowNums, null);
    }
}
