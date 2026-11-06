package com.uten.imp.features.finance.statement;

import com.uten.imp.application.port.FinanceStatementOriginalReadPort;
import com.uten.imp.common.web.*;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;

@Service @RequiredArgsConstructor
public class FinanceStatementOriginalReadAdapter implements FinanceStatementOriginalReadPort {
    private final ObjectProvider<FinanceStatementDocumentService> documents;
    private final JdbcTemplate db;
    @Override @Transactional(readOnly=true)
    public Original requireConfirmed(UUID id,String fingerprint){
        if(id==null||fingerprint==null||!fingerprint.matches("[0-9a-f]{64}"))throw invalid("请保留已确认原件编号及其真实来源指纹");
        // The owning service enforces company finance read access and decrypts
        // only this exact original; it does not recalculate a new balance here.
        var review=documents.getObject().review(id);
        if(!Set.of("INTERNAL_CONFIRMED","BOTH_CONFIRMED").contains(review.get("status")))throw invalid("请先由另一财务审核人确认此原件");
        if(!Objects.equals(fingerprint,review.get("source_fingerprint")))throw invalid("所选原件指纹不一致，请读取该原件自己的来源");
        var original=map(review.get("original"));var context=map(original.get("context"));var metadata=map(original.get("documentMetadata"));
        String template=Objects.toString(context.get("templateKey"),"");
        boolean subcontract=template.equals("subcontractStatement");
        if(!subcontract&&!template.equals("supplierStatement")||!"SUPPLIER".equals(context.get("partyRole")))throw invalid("此应付处理只能关联原19列委外或原8列供应商对账原件");
        UUID supplier=uuid(context.get("partyId")),currency=uuid(context.get("currencyId"));
        Object base=metadata.get("periodAmount");if(base==null)throw invalid("原件本期金额仍未知，不能据整户余额替代");
        BigDecimal amount;try{amount=new BigDecimal(base.toString());}catch(NumberFormatException failure){throw invalid("原件本期金额无效，请核对保存的原始记录");}
        Set<UUID> sourceItems=new LinkedHashSet<>();
        for(var row:rows(original.get("rows"))){
            if(subcontract){if(row.get("__receiptItemId")!=null)sourceItems.add(uuid(row.get("__receiptItemId")));}
            else if("PURCHASE_RECEIPT".equals(row.get("__sourceType"))&&row.get("__sourceId")!=null)sourceItems.add(uuid(row.get("__sourceId")));
        }
        if(sourceItems.size()>20000)throw invalid("原件来源超过有界范围，请保留原件分批核对");
        String table=subcontract?"subcontract_receipt_items":"purchase_receipt_items",header=subcontract?"subcontract_receipts":"purchase_receipts";
        var matched=new LinkedHashMap<UUID,Set<UUID>>();var list=new ArrayList<>(sourceItems);
        for(int at=0;at<list.size();at+=500){var part=list.subList(at,Math.min(list.size(),at+500));var args=new ArrayList<Object>(part);args.add(supplier);args.add(currency);
            var records=db.queryForList("SELECT item.id,item.receipt_id FROM "+table+" item JOIN "+header+" document ON document.id=item.receipt_id WHERE item.id IN("+String.join(",",Collections.nCopies(part.size(),"?"))+") AND document.supplier_id=? AND document.currency_id=? AND document.status=1 AND NOT document.is_deleted AND NOT item.is_deleted",args.toArray());
            for(var row:records)matched.computeIfAbsent((UUID)row.get("receipt_id"),ignored->new LinkedHashSet<>()).add((UUID)row.get("id"));
        }
        // Qualify every receipt's complete live item set in bounded batches,
        // instead of repeating one SQL round trip per matched receipt.
        var allItems=new HashMap<UUID,Set<UUID>>();var receiptIds=new ArrayList<>(matched.keySet());
        for(int at=0;at<receiptIds.size();at+=500){
            var part=receiptIds.subList(at,Math.min(receiptIds.size(),at+500));
            var records=db.queryForList("SELECT receipt_id,id FROM "+table+" WHERE receipt_id IN("+String.join(",",Collections.nCopies(part.size(),"?"))+") AND NOT is_deleted",part.toArray());
            for(var row:records)allItems.computeIfAbsent((UUID)row.get("receipt_id"),ignored->new HashSet<>()).add((UUID)row.get("id"));
        }
        var complete=new ArrayList<SourceDocument>();
        for(var entry:matched.entrySet()){
            var actual=allItems.getOrDefault(entry.getKey(),Set.of());
            // A monthly row subset cannot silently stand for an entire AP bill.
            if(actual.equals(entry.getValue()))complete.add(new SourceDocument(subcontract?"SUBCONTRACT_RECEIPT":"PURCHASE_RECEIPT",entry.getKey(),entry.getValue().stream().sorted().toList()));
        }
        return new Original(id,template,"SUPPLIER",supplier,currency,LocalDate.parse(context.get("dateFrom").toString()),LocalDate.parse(context.get("dateTo").toString()),fingerprint,Objects.toString(review.get("document_sha256"),""),amount,complete);
    }
    private static List<Map<String,Object>> rows(Object value){if(!(value instanceof List<?> rows))throw invalid("原件缺少完整来源行");var result=new ArrayList<Map<String,Object>>();for(Object row:rows){result.add(map(row));}return result;}
    private static Map<String,Object> map(Object value){if(!(value instanceof Map<?,?> map))throw invalid("原件结构无效，请核对原保存版本");var result=new LinkedHashMap<String,Object>();map.forEach((key,cell)->result.put(key.toString(),cell));return result;}
    private static UUID uuid(Object value){try{return value instanceof UUID id?id:UUID.fromString(Objects.toString(value,""));}catch(IllegalArgumentException failure){throw invalid("原件缺少真实业务UUID，不能按名称或金额猜配");}}
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
}
