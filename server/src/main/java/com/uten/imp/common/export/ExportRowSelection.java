package com.uten.imp.common.export;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.math.BigDecimal;
import java.util.*;

/** Restricts authoritative, already authorized source rows. Client values never become output cells. */
public final class ExportRowSelection {
    private final List<Map<String,String>> requested;
    private final Set<Integer> matched = new HashSet<>();
    private Map<List<String>,Map<List<String>,Integer>> index;
    private Set<String> numeric;
    public ExportRowSelection(TableColumnProjection projection) {
        requested = projection == null ? null : projection.rowSelection();
        if (requested != null && (requested.isEmpty() || requested.size() > 50000 || requested.stream().anyMatch(
                row -> row == null || row.isEmpty() || row.size() > 320 || row.entrySet().stream().anyMatch(
                        entry -> entry.getKey() == null || entry.getKey().length() > 120 || entry.getValue() != null && entry.getValue().length() > 100000))))
            throw invalid("选中行输出条件无效，请刷新后重选");
        if (requested != null && requested.stream().anyMatch(row -> !row.keySet().equals(requested.getFirst().keySet())))
            throw invalid("选中行字段不一致，请刷新后重选");
    }
    public boolean active() { return requested != null; }
    public List<Map<String,Object>> select(List<ExportColumn> columns,List<Map<String,Object>> rows) {
        if (!active()) return rows;
        if (index == null) {
            Set<String> known=new HashSet<>(); columns.forEach(column -> known.add(column.key()));
            for (var selector:requested) for (String key:selector.keySet()) {
                if (!known.contains(key) && !Set.of("@id","id","rowKey").contains(key) && !key.endsWith("Id"))
                    throw invalid("选中行包含不可输出的筛选字段，请刷新后重选");
            }
            numeric = new HashSet<>();
            columns.stream().filter(column -> ExportColumn.isNumeric(column.type())).forEach(column -> numeric.add(column.key()));
            index = new LinkedHashMap<>();
            for (int i=0;i<requested.size();i++) {
                if (i%40==0) LegacyExportBudget.checkpoint();
                var selector=requested.get(i);
                var keys=selector.keySet().stream().sorted().toList();
                var values=keys.stream().map(key -> canonical(selector.get(key),numeric.contains(key))).toList();
                if (index.computeIfAbsent(keys,ignored -> new HashMap<>()).putIfAbsent(values,i)!=null)
                    throw invalid("选中行的输出身份重复，请刷新后重选");
            }
        }
        List<Map<String,Object>> selected=new ArrayList<>();
        for (var row:rows) {
            LegacyExportBudget.checkpoint();
            Integer found=null;
            for (var group:index.entrySet()) {
                List<String> values=new ArrayList<>();
                for (String key:group.getKey()) {
                    String actual=key;
                    if ("@id".equals(key)) actual=row.containsKey("_platformRecordId")?"_platformRecordId":"id";
                    // An omitted permitted nullable field is JSON null; a non-null selector cannot match it.
                    values.add(canonical(row.get(actual),numeric.contains(key)));
                }
                Integer candidate=group.getValue().get(values);
                if (candidate!=null) {
                    if (found!=null || !matched.add(candidate)) throw invalid("选中行的输出身份不唯一，请刷新后重选");
                    found=candidate;
                }
            }
            if (found!=null) selected.add(row);
        }
        return selected;
    }
    public void verifyComplete() {
        if (active() && matched.size()!=requested.size())
            throw invalid("选中记录已变化或不属于当前筛选，请刷新后重选");
    }
    private static String canonical(Object value,boolean numeric) {
        if (value==null) return null;
        String text=value.toString();
        // Scientific notation keeps untrusted exponents bounded instead of allocating their zero expansion.
        if (numeric) try {return new BigDecimal(text).stripTrailingZeros().toString();}
        catch(NumberFormatException ignored) { }
        return text;
    }
    private static ApiException invalid(String message) {return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
}
