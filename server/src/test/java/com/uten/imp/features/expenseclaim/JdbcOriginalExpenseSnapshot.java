package com.uten.imp.features.expenseclaim;

import com.uten.imp.common.platformcolumns.PlatformColumnContracts;
import com.uten.imp.config.Jackson2ObjectMapperAutoConfiguration;
import org.springframework.jdbc.core.JdbcTemplate;

import java.math.BigDecimal;
import java.sql.Date;
import java.util.*;

import static org.assertj.core.api.Assertions.*;

/** Historical SQL facts through the owning native snapshot codec, without booting current JPA on an old schema. */
public final class JdbcOriginalExpenseSnapshot {
    private JdbcOriginalExpenseSnapshot() { }
    public static String capture(JdbcTemplate db,UUID id) {
        assertThat(db.queryForObject("SELECT count(*) FROM platform_column_definitions WHERE scope IN('expense_claim','expense_claim_item')",Integer.class))
            .as("this original fixture has no custom definitions; never invent missing historical platform facts").isZero();
        assertThat(db.queryForObject("SELECT count(*) FROM platform_record_fields WHERE scope IN('expense_claim','expense_claim_item')",Integer.class)).isZero();
        var source=db.queryForMap("SELECT id,title,expense_kind,applicant_department_id,applicant_name_snapshot,remark,total_amount FROM expense_claims WHERE id=?",id);
        var claim=new ExpenseClaim();claim.setId(id);claim.setTitle((String)source.get("title"));claim.setExpenseKind((String)source.get("expense_kind"));
        claim.setApplicantDepartmentId((UUID)source.get("applicant_department_id"));claim.setApplicantNameSnapshot((String)source.get("applicant_name_snapshot"));
        claim.setRemark((String)source.get("remark"));claim.setTotalAmount((BigDecimal)source.get("total_amount"));
        var items=new ArrayList<ExpenseClaimItem>();
        for(var row:db.queryForList("SELECT id,line_no,category,amount,expense_date,description FROM expense_claim_items WHERE claim_id=? ORDER BY line_no,id",id)){
            var item=new ExpenseClaimItem();item.setId((UUID)row.get("id"));item.setLineNo(((Number)row.get("line_no")).intValue());item.setCategory((String)row.get("category"));
            item.setAmount((BigDecimal)row.get("amount"));item.setExpenseDate(((Date)row.get("expense_date")).toLocalDate());item.setDescription((String)row.get("description"));items.add(item);
        }
        var invoices=new ArrayList<ExpenseClaimInvoice>();
        for(var row:db.queryForList("SELECT id,line_no,invoice_type,invoice_code,invoice_no,issue_date,seller_name,seller_tax_no,buyer_name,buyer_tax_no,amount_excl_tax,tax_amount,total_amount,attachment_id,remark FROM expense_claim_invoices WHERE claim_id=? ORDER BY line_no,id",id)){
            var invoice=new ExpenseClaimInvoice();invoice.setId((UUID)row.get("id"));invoice.setLineNo(((Number)row.get("line_no")).intValue());
            invoice.setInvoiceType((String)row.get("invoice_type"));invoice.setInvoiceCode((String)row.get("invoice_code"));invoice.setInvoiceNo((String)row.get("invoice_no"));
            invoice.setIssueDate(((Date)row.get("issue_date")).toLocalDate());invoice.setSellerName((String)row.get("seller_name"));invoice.setSellerTaxNo((String)row.get("seller_tax_no"));
            invoice.setBuyerName((String)row.get("buyer_name"));invoice.setBuyerTaxNo((String)row.get("buyer_tax_no"));invoice.setAmountExclTax((BigDecimal)row.get("amount_excl_tax"));
            invoice.setTaxAmount((BigDecimal)row.get("tax_amount"));invoice.setTotalAmount((BigDecimal)row.get("total_amount"));invoice.setAttachmentId((UUID)row.get("attachment_id"));invoice.setRemark((String)row.get("remark"));invoices.add(invoice);
        }
        // V1039 already owns platform storage. Its genuinely empty records have
        // exactly this owning Row representation; no new stored values are created.
        var platform=new LinkedHashMap<UUID,PlatformColumnContracts.Row>();
        for(var item:items)platform.put(item.getId(),new PlatformColumnContracts.Row(item.getId(),0,false,List.of()));
        String captured=ExpenseClaimSubmissionSnapshot.capture(claim,items,invoices,platform,new PlatformColumnContracts.Row(id,0,false,List.of()));
        try{
            var json=Jackson2ObjectMapperAutoConfiguration.domainObjectMapper().readTree(captured);
            assertThat(json.path("title").asText()).isEqualTo(source.get("title"));
            assertThat(json.path("totalAmount").asText()).isEqualTo(((BigDecimal)source.get("total_amount")).toPlainString());
            assertThat(json.path("items").size()).isEqualTo(items.size());assertThat(json.path("invoices").size()).isEqualTo(invoices.size());
            for(int i=0;i<items.size();i++)assertThat(json.path("items").get(i).path("amount").asText()).isEqualTo(items.get(i).getAmount().toPlainString());
            for(int i=0;i<invoices.size();i++)assertThat(json.path("invoices").get(i).path("attachmentId").asText()).isEqualTo(invoices.get(i).getAttachmentId().toString());
        }catch(java.io.IOException failure){throw new IllegalStateException("Owning original snapshot codec returned invalid JSON",failure);}
        return captured;
    }
}
