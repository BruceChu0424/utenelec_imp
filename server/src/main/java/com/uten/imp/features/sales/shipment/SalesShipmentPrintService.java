package com.uten.imp.features.sales.shipment;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.*;
import com.uten.imp.features.finance.gl.FinanceTemplateContract;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.*;
import java.util.*;

/** Same authorized document and frozen finance actor feed preview, paper and final authorization. */
@Service @RequiredArgsConstructor
public class SalesShipmentPrintService {
    private final SalesShipmentService shipments;private final EntityManager em;private final ObjectMapper json;private final com.uten.imp.application.port.CompanyBrandingReadPort branding;
    public record Line(UUID id,int lineNo,String goodsCode,String model,String series,String goodsName,String color,String unit,String qty,String price,String discount,String amount,String remark) { }
    public record Signature(String label,String name) { }
    public record Paper(UUID id,String title,String companyName,String formCode,List<String> headers,String billNo,String billDate,String clientName,String shipAddr,String phone,String settlementName,String makerName,String financeAuditorName,
            String financeAuditedAt,boolean priceMasked,String currencyName,List<Line> lines,String totalOriginal,String quantityTotal,List<Signature> signatures,String contentDigest) { }
    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public Paper read(UUID id){
        var d=shipments.detail(id);if(!Short.valueOf((short)1).equals(d.getFinanceAudit())||d.getStatus()==null||d.getStatus()<0)throw conflict("本单尚未财务审核或已反审，不能打印已审发货单");
        var header=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT COALESCE(event.client_name,client.name,''),COALESCE(currency.name,''),event.print_context::text,s.warehouse_approver_name_snapshot
                FROM sales_shipments s JOIN clients client ON client.id=s.client_id
                LEFT JOIN currencies currency ON currency.id=s.currency_id
                LEFT JOIN sales_shipment_finance_release_events event ON event.id=s.finance_release_event_id
                WHERE s.id=:id
                """).setParameter("id",id)).getFirst();
        com.fasterxml.jackson.databind.JsonNode context;try{context=header[2]==null?json.createObjectNode():json.readTree(header[2].toString());}catch(Exception e){throw conflict("原审核打印快照无法读取，请核对原事件");}
        final var source=context;
        List<Line> lines=d.getItems().stream().map(i->{var fields=source.path("lines").path(i.getId().toString());return new Line(i.getId(),i.getLineNo()==null?0:i.getLineNo(),Objects.toString(i.getGoodsCodeSnapshot(),""),fields.path("model").asText(""),fields.path("series").asText(""),Objects.toString(i.getGoodsNameSnapshot(),""),fields.path("color").asText(""),fields.path("unit").asText(""),i.getQtyExact(),i.getPriceExact(),i.getDiscountExact(),i.getAmountOriginalExact(),Objects.toString(i.getRemark(),""));}).toList();
        var template=FinanceTemplateContract.template("customerShipmentReview");List<String> headers=new ArrayList<>();template.required("printHeaders").forEach(x->headers.add(x.asText()));
        List<Signature> signatures=new ArrayList<>();int n=0;for(var label:template.required("printSignatures")){String value=switch(n++){case 1->source.path("makerName").asText("");case 2->d.getFinanceAuditorName()==null||d.getFinanceAuditorName().isBlank()?"历史未留姓名快照":d.getFinanceAuditorName();case 3->Objects.toString(header[3],"");default->"";};signatures.add(new Signature(label.asText(),value));}
        String quantity=null;if(!lines.isEmpty()&&lines.stream().allMatch(l->!l.unit().isBlank()&&l.qty()!=null)&&lines.stream().map(Line::unit).distinct().count()==1)quantity=lines.stream().map(l->new java.math.BigDecimal(l.qty())).reduce(java.math.BigDecimal.ZERO,java.math.BigDecimal::add).stripTrailingZeros().toPlainString();
        var paper=new Paper(id,template.required("printTitle").asText(),branding.currentIdentity().companyName(),template.required("printFormCode").asText(),List.copyOf(headers),d.getBillNo(),d.getBillDate().toString(),header[0].toString(),Objects.toString(d.getShipAddr(),""),Objects.toString(d.getLinkPhone(),""),source.path("settlementName").asText(""),source.path("makerName").asText(""),
                d.getFinanceAuditorName()==null||d.getFinanceAuditorName().isBlank()?"历史未留姓名快照":d.getFinanceAuditorName(),Objects.toString(d.getFinanceAuditedAt(),""),d.isPriceMasked(),header[1].toString(),lines,d.getTotalOriginalExact(),quantity,List.copyOf(signatures),"");
        return new Paper(paper.id(),paper.title(),paper.companyName(),paper.formCode(),paper.headers(),paper.billNo(),paper.billDate(),paper.clientName(),paper.shipAddr(),paper.phone(),paper.settlementName(),paper.makerName(),paper.financeAuditorName(),paper.financeAuditedAt(),paper.priceMasked(),paper.currencyName(),paper.lines(),paper.totalOriginal(),paper.quantityTotal(),paper.signatures(),digest(paper));
    }
    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public void authorize(UUID id,String expected){if(expected==null||!expected.matches("[0-9a-f]{64}")||!read(id).contentDigest().equals(expected))throw conflict("发货内容、审核或访问范围已变化，请重新读取并核对打印预览");}
    private String digest(Paper value){try{return ImmutableDocumentStore.digest(json.writeValueAsBytes(value));}catch(Exception e){throw new IllegalStateException("打印快照无法校验",e);}}
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
}
