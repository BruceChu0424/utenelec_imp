package com.uten.imp.features.expenseclaim;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.FinanceApplicationExpensePort;
import com.uten.imp.common.platformcolumns.PlatformColumnContracts;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import org.springframework.jdbc.core.BeanPropertyRowMapper;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;

import java.math.BigDecimal;
import java.sql.Timestamp;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Genuine original claim rows, captured without booting current ORM mappings.
 * Plain fixtures have no custom values; the production snapshot codec remains
 * the single owner of their commercial fields and full decimal text. */
public final class HistoricalExpenseSourceJdbc {
    private HistoricalExpenseSourceJdbc() { }

    /** Original capture can read actual facts, never run a pre-upgrade workflow. */
    public static FinanceApplicationExpensePort readOnlyPort(JdbcTemplate db,ObjectMapper json) {
        return new FinanceApplicationExpensePort() {
            @Override public Source source(UUID id,boolean forUpdate) {
                if(forUpdate)throw unsupported();
                return HistoricalExpenseSourceJdbc.source(db,json,id);
            }
            @Override public void verifyInvoice(UUID claim,UUID invoice,Long version,String result,String remark){throw unsupported();}
            @Override public Map<String,Object> detail(UUID claim){throw unsupported();}
            @Override public java.util.Optional<Map<String,Object>> optionalDetail(UUID claim){throw unsupported();}
            @Override public void submit(UUID id){throw unsupported();}
            @Override public void withdraw(UUID id){throw unsupported();}
            @Override public void decideFromApplication(UUID id,boolean approved,String reason){throw unsupported();}
            @Override public UUID pay(UUID id,UUID account,UUID style,java.time.LocalDate date,com.uten.imp.common.finance.AccountingExpensePurpose purpose){throw unsupported();}
            @Override public void paymentReversed(UUID id,UUID payment,String reason){throw unsupported();}
        };
    }

    private static UnsupportedOperationException unsupported() {
        return new UnsupportedOperationException("Historical claim capture cannot execute business commands");
    }

    public static String snapshot(JdbcTemplate db,UUID id) {
        var claim=db.queryForObject("""
                SELECT id,title,expense_kind,applicant_department_id,applicant_name_snapshot,remark,total_amount
                FROM expense_claims WHERE id=?
                """,BeanPropertyRowMapper.newInstance(ExpenseClaim.class),id);
        var items=db.query("SELECT id,line_no,category,amount,expense_date,description FROM expense_claim_items WHERE claim_id=? ORDER BY line_no,id",
                BeanPropertyRowMapper.newInstance(ExpenseClaimItem.class),id);
        var invoices=db.query("""
                SELECT id,line_no,invoice_type,invoice_code,invoice_no,issue_date,seller_name,seller_tax_no,buyer_name,buyer_tax_no,
                    amount_excl_tax,tax_amount,total_amount,attachment_id,remark
                FROM expense_claim_invoices WHERE claim_id=? ORDER BY line_no,id
                """,BeanPropertyRowMapper.newInstance(ExpenseClaimInvoice.class),id);
        var identities=new LinkedHashSet<UUID>();identities.add(id);items.forEach(item->identities.add(item.getId()));
        Long custom=new NamedParameterJdbcTemplate(db).queryForObject("""
                SELECT count(*) FROM platform_record_fields
                WHERE scope IN('expense_claim','expense_claim_item') AND record_id IN(:ids)
                """,Map.of("ids",identities),Long.class);
        if(custom==null||custom!=0)throw new IllegalArgumentException("Historical plain claim fixture contains custom values");
        var itemFields=new LinkedHashMap<UUID,PlatformColumnContracts.Row>();
        items.forEach(item->itemFields.put(item.getId(),new PlatformColumnContracts.Row(item.getId(),0,false,List.of())));
        String captured=ExpenseClaimSubmissionSnapshot.capture(claim,items,invoices,itemFields,
                new PlatformColumnContracts.Row(id,0,false,List.of()));
        // Golden checks observe the owning codec's actual output. They do not
        // duplicate its monetary conversion or serialized field construction.
        try {
            var json=com.uten.imp.config.Jackson2ObjectMapperAutoConfiguration.domainObjectMapper().readTree(captured);
            org.assertj.core.api.Assertions.assertThat(json.path("title").asText()).isEqualTo(claim.getTitle());
            org.assertj.core.api.Assertions.assertThat(json.path("totalAmount").asText()).isEqualTo(claim.getTotalAmount().toPlainString());
            org.assertj.core.api.Assertions.assertThat(json.path("items").size()).isEqualTo(items.size());
            org.assertj.core.api.Assertions.assertThat(json.path("invoices").size()).isEqualTo(invoices.size());
            for(int i=0;i<items.size();i++)org.assertj.core.api.Assertions.assertThat(json.path("items").get(i).path("amount").asText()).isEqualTo(items.get(i).getAmount().toPlainString());
            for(int i=0;i<invoices.size();i++)org.assertj.core.api.Assertions.assertThat(json.path("invoices").get(i).path("attachmentId").asText()).isEqualTo(invoices.get(i).getAttachmentId().toString());
        } catch(java.io.IOException failure) {throw new IllegalStateException("Owning original snapshot codec returned invalid JSON",failure);}
        return captured;
    }

    public static FinanceApplicationExpensePort.Source source(JdbcTemplate db,ObjectMapper json,UUID id) {
        var header=db.queryForMap("""
                SELECT id,claim_no,applicant_id,applicant_name_snapshot,applicant_department_id,title,status,created_at,total_amount,remark
                FROM expense_claims WHERE id=? AND NOT is_deleted
                """,id);
        var currencies=db.queryForList("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted",UUID.class);
        if(currencies.size()!=1)throw new IllegalStateException("Historical claim base currency must be explicit");
        var facts=new LinkedHashMap<String,Object>();
        for(String key:List.of("id","claim_no","applicant_id","applicant_name_snapshot","applicant_department_id","title","remark"))facts.put(key,header.get(key));
        BigDecimal amount=(BigDecimal)header.get("total_amount");facts.put("amountOriginal",amount.toPlainString());
        facts.put("items",db.queryForList("SELECT id,line_no,category,expense_date,description,amount::text FROM expense_claim_items WHERE claim_id=? ORDER BY line_no,id",id));
        facts.put("submittedFacts",snapshot(db,id));
        String fingerprint;
        try { fingerprint=ImmutableDocumentStore.digest(json.writeValueAsBytes(facts)); }
        catch(Exception failure) { throw new IllegalStateException("Cannot capture historical claim facts",failure); }
        return new FinanceApplicationExpensePort.Source(id,header.get("claim_no").toString(),(UUID)header.get("applicant_id"),
                header.get("applicant_name_snapshot").toString(),(UUID)header.get("applicant_department_id"),header.get("title").toString(),
                header.get("status").toString(),((Timestamp)header.get("created_at")).toInstant(),currencies.getFirst(),amount,fingerprint,facts);
    }
}
