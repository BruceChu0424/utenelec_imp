package com.uten.imp.common.util;

import java.util.LinkedHashMap;
import java.util.Map;

/** Search over the shared IQC/FQC event-record projection, after each domain's visibility/effect projection. */
public final class QualityRecordHeaders {
    private QualityRecordHeaders() { }
    public static Map<String,SqlColumnSearch.Field> fields(boolean fqc) {
        var fields=new LinkedHashMap<String,SqlColumnSearch.Field>();
        fields.put("sourceNo",SqlColumnSearch.Field.text("coalesce(record.source_no,'—')"));
        fields.put("referenceNo",SqlColumnSearch.Field.text("coalesce(record.reference_no,'—')"));
        if(fqc) fields.put("sheetNo",SqlColumnSearch.Field.text("coalesce(record.sheet_no,'—')"));
        fields.put("partnerName",SqlColumnSearch.Field.text("coalesce(record.partner_name,'—')"));
        fields.put("goodsName",SqlColumnSearch.Field.text("coalesce(record.goods_name,'—')"));
        fields.put("goodsCode",SqlColumnSearch.Field.text("coalesce(record.goods_code,'—')"));
        fields.put("colorName",SqlColumnSearch.Field.text("coalesce(record.color_name,'—')"));
        fields.put("inspectorName",SqlColumnSearch.Field.text("coalesce(record.inspector_name,'—')"));
        fields.put("passQty",SqlColumnSearch.Field.decimal("record.pass_qty"));
        fields.put("failQty",SqlColumnSearch.Field.decimal("record.fail_qty"));
        fields.put("decidedAt",SqlColumnSearch.Field.instant("record.decided_at"));
        return Map.copyOf(fields);
    }
    public static String orderBy(String sort,String order,boolean fqc) {
        var field=fields(fqc).get(sort==null?"":sort.strip());
        if(field==null) return "ORDER BY record.decided_at DESC, record.record_id DESC";
        return "ORDER BY "+field.expression()+("desc".equalsIgnoreCase(order)?" DESC":" ASC")
                +" NULLS LAST, record.decided_at DESC, record.record_id DESC";
    }
}
