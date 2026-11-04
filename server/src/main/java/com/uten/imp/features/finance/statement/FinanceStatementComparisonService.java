package com.uten.imp.features.finance.statement;

import com.uten.imp.common.web.*;
import com.uten.imp.features.finance.report.FinanceTemplateSourceReader;
import com.uten.imp.features.finance.report.FinanceTemplateSourceService;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.*;
import java.math.BigDecimal;
import java.time.*;
import java.time.format.DateTimeFormatter;
import java.util.*;
import static com.uten.imp.features.finance.statement.FinanceStatementDocumentContracts.Context;

/** Read-only comparison of source cells with a fingerprinted, complete original report.
 * Row associations are explicit; importing a statement never creates a debt twice. */
@Service @RequiredArgsConstructor
@Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
public class FinanceStatementComparisonService {
    private static final Set<String> TEMPLATES=Set.of("subcontractStatement","supplierStatement","clientStatement");
    private final FinanceTemplateSourceService sources;
    private final FinanceStatementDocumentService documents;
    public record Selection(int sourceRow,int reportRowNumber){ }
    public record Input(UUID sourceImportId,Context context,String expectedSourceFingerprint,List<Selection> rows){ }

    public Map<String,Object> preview(Input input){
        var original=source(input);var snapshot=documents.preview(input.context());
        return Map.of("source",original,"actual",snapshot,"basis","按原行手选对应；全部原列逐项比对，不执行原文件公式，不改库存、往来、银行或总账");
    }
    public Map<String,Object> compare(Input input){
        var original=source(input);
        if(input.rows()==null||input.rows().isEmpty()||input.rows().size()>2000)throw invalid("请选择最多2000条原行与实际行的明确对应");
        var snapshot=documents.preview(input.context());
        if(!Objects.equals(snapshot.get("sourceFingerprint"),input.expectedSourceFingerprint()))
            throw new ApiException(ErrorCode.CONFLICT,"原业务、账载余额或打印资料已变化，请先刷新完整原件；原文件和行对应保留");
        var columns=maps(snapshot.get("columns"));var actual=maps(snapshot.get("rows"));
        if(columns.size()!=original.headers().size())throw invalid("原文件与实际原表列数不一致");
        var sourceRows=new HashMap<Integer,FinanceTemplateSourceReader.Row>();original.rows().forEach(row->sourceRows.put(row.sourceRow(),row));
        var seen=new HashSet<Integer>();var used=new HashSet<Integer>();var results=new ArrayList<Map<String,Object>>();
        for(var selection:input.rows()){
            if(selection==null||!seen.add(selection.sourceRow())||!used.add(selection.reportRowNumber()))throw invalid("原行与实际行不能重复对应");
            var row=sourceRows.get(selection.sourceRow());
            if(row==null||selection.reportRowNumber()<1||selection.reportRowNumber()>actual.size())throw invalid("所选原行或实际行不存在，请保留输入重新核对");
            var fact=actual.get(selection.reportRowNumber()-1);var cells=new ArrayList<Map<String,Object>>();
            for(int index=0;index<columns.size();index++){
                final int column=index+1;var definition=columns.get(index);String key=Objects.toString(definition.get("key"),"");
                var cell=row.cells().stream().filter(value->value.column()==column).findFirst().orElse(null);
                Object value=fact.getOrDefault(key+"Exact",fact.get(key));String raw=cell==null?"":cell.number()==null?cell.text():cell.number();
                String status=compareCell(cell,raw,value,Objects.toString(definition.get("type"),"text"));
                var result=new LinkedHashMap<String,Object>();result.put("column",column);result.put("label",original.headers().get(index));
                result.put("source",raw);result.put("sourceKind",cell==null?"BLANK":cell.kind());result.put("actual",value);result.put("status",status);cells.add(result);
            }
            boolean pending=!original.issues().isEmpty()||!row.issues().isEmpty()||cells.stream().anyMatch(cell->cell.get("status").equals("PENDING"));
            String status=pending?"PENDING":cells.stream().allMatch(cell->cell.get("status").equals("EQUAL"))?"EQUAL":"DIFFERENT";
            results.add(Map.of("sourceRow",selection.sourceRow(),"reportRowNumber",selection.reportRowNumber(),"status",status,"sourceIssues",row.issues(),"cells",cells));
        }
        return Map.of("sourceImportId",original.importId(),"sourceSha256",original.sha256(),"sourceIssues",original.issues(),
            "sourceFingerprint",snapshot.get("sourceFingerprint"),"results",results,
            "unmappedSourceRows",original.rows().stream().filter(row->!seen.contains(row.sourceRow())).map(FinanceTemplateSourceReader.Row::sourceRow).toList(),
            "unmappedActualRows",java.util.stream.IntStream.rangeClosed(1,actual.size()).filter(number->!used.contains(number)).boxed().toList(),
            "basis","原数字及公式缓存逐列只读比对；未知/错误不补零，不据外部对账单重复立账或过账");
    }
    private FinanceTemplateSourceReader.Preview source(Input input){
        if(input==null||input.sourceImportId()==null||input.context()==null||!TEMPLATES.contains(input.context().templateKey()))throw invalid("请选择原19列委外、原8列供应商或原8列客户对账文件与完整原件范围");
        var source=sources.get(input.sourceImportId());
        if(!source.template().equals(input.context().templateKey())||input.context().dateTo()==null||
            !YearMonth.from(input.context().dateTo()).toString().equals(source.period()))throw invalid("原文件入口或会计月份与当前原件不一致");
        return source;
    }
    static String compareCell(FinanceTemplateSourceReader.Cell source,String raw,Object actual,String type){
        if(source!=null&&"ERROR".equals(source.kind()))return "PENDING";
        if(Set.of("money","number","int").contains(type)){
            if(actual==null||raw==null||raw.isBlank())return "PENDING";
            try{return new BigDecimal(raw.strip()).compareTo(new BigDecimal(actual.toString()))==0?"EQUAL":"DIFFERENT";}
            catch(NumberFormatException invalid){return "PENDING";}
        }
        if(type.equals("date")&&!Objects.toString(actual,"").isBlank()&&!Objects.toString(raw,"").isBlank()){
            LocalDate expected=date(raw),found=date(actual.toString());
            if(expected==null||found==null)return "PENDING";return expected.equals(found)?"EQUAL":"DIFFERENT";
        }
        return Objects.toString(raw,"").strip().equals(Objects.toString(actual,"").strip())?"EQUAL":"DIFFERENT";
    }
    private static LocalDate date(String text){for(String format:List.of("uuuu-MM-dd","uuuu/M/d","uuuu年M月d日"))try{return LocalDate.parse(text.strip(),DateTimeFormatter.ofPattern(format).withResolverStyle(java.time.format.ResolverStyle.STRICT));}catch(java.time.format.DateTimeParseException ignored){ }return null;}
    private static List<Map<String,Object>> maps(Object value){if(!(value instanceof List<?> rows))throw invalid("原件结构缺少完整原行");var result=new ArrayList<Map<String,Object>>();for(var row:rows){if(!(row instanceof Map<?,?> map))throw invalid("原件行结构无效");var item=new LinkedHashMap<String,Object>();map.forEach((key,cell)->item.put(key.toString(),cell));result.add(item);}return result;}
    private static ApiException invalid(String text){return new ApiException(ErrorCode.VALIDATION_FAILED,text);}
}
