package com.uten.imp.features.finance.payroll;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.FinancePayrollPaymentPort.*;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.util.FinancialExactAmount;
import com.uten.imp.common.web.*;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import java.math.BigDecimal;
import java.util.*;

/** Original approved payroll facts, called only from the trusted application bridge. */
@Component @RequiredArgsConstructor
final class FinancePayrollSourceReader {
    private final JdbcTemplate db;
    private final ObjectMapper json;
    private final Object transactionCacheKey=new Object();

    Source read(UUID id,boolean lock){
        if(id==null)throw invalid("请选择原工资批次");
        var cached=lockedCache(false);if(cached!=null&&cached.containsKey(id))return cached.get(id);
        if(lock&&!TransactionSynchronizationManager.isActualTransactionActive())throw new IllegalStateException("工资源锁须保留在业务事务内");
        var batches=db.queryForList("SELECT * FROM payroll_batches WHERE id=?"+(lock?" FOR UPDATE":""),id);
        if(batches.size()!=1)throw invalid("原工资批次不存在");
        var batch=batches.getFirst();String status=Objects.toString(batch.get("status"),"");
        if(!Set.of("APPROVED","PUBLISHED").contains(status))throw invalid("只能使用已审核或已发布的原工资批次");
        var currencies=db.queryForList("SELECT id FROM currencies WHERE is_base_currency AND status='使用' AND NOT is_deleted",UUID.class);
        if(currencies.size()!=1)throw invalid("请先核对唯一启用的本位币，不能把工资金额当作其他币种");
        var rows=db.queryForList("SELECT * FROM payroll_slips WHERE batch_id=? AND active ORDER BY employee_code_snapshot,id",id);
        if(rows.isEmpty()||((Number)batch.get("headcount")).intValue()!=rows.size())throw invalid("原工资人数与有效工资条不一致，请先核对工资批次");
        var items=db.queryForList("SELECT i.* FROM payroll_items i JOIN payroll_slips s ON s.id=i.slip_id WHERE s.batch_id=? AND s.active ORDER BY s.employee_code_snapshot,s.id,i.line_no,i.id",id);
        Map<UUID,List<Item>> bySlip=new LinkedHashMap<>();
        for(var item:items)bySlip.computeIfAbsent((UUID)item.get("slip_id"),ignored->new ArrayList<>()).add(new Item(
                (UUID)item.get("id"),Objects.toString(item.get("item_code"),""),Objects.toString(item.get("name"),""),
                Objects.toString(item.get("item_type"),""),amount(item,"amount"),Objects.toString(item.get("source_type"),""),Objects.toString(item.get("description"),null)));
        List<Slip> slips=new ArrayList<>(rows.size());
        for(var row:rows){
            UUID slipId=(UUID)row.get("id");var detail=List.copyOf(bySlip.getOrDefault(slipId,List.of()));
            BigDecimal gross=amount(row,"gross_income"),deductions=amount(row,"total_deduction"),net=amount(row,"net_income");
            if(gross.subtract(deductions).compareTo(net)!=0||sumItems(detail,"EARNING").compareTo(gross)!=0
                    ||sumItems(detail,"DEDUCTION").compareTo(deductions)!=0)throw invalid("原工资条与原项目合计不一致："+row.get("employee_code_snapshot"));
            slips.add(new Slip(slipId,(UUID)row.get("employee_id"),Objects.toString(row.get("employee_code_snapshot"),""),
                    Objects.toString(row.get("employee_name_snapshot"),""),(UUID)row.get("department_id_snapshot"),Objects.toString(row.get("department_name_snapshot"),""),gross,deductions,net,detail));
        }
        BigDecimal gross=amount(batch,"gross_income"),deductions=amount(batch,"total_deduction"),net=amount(batch,"net_income");
        if(gross.subtract(deductions).compareTo(net)!=0||sum(slips,0).compareTo(gross)!=0||sum(slips,1).compareTo(deductions)!=0
                ||sum(slips,2).compareTo(net)!=0)throw invalid("原工资批次与有效工资条合计不一致");
        String period=String.format(Locale.ROOT,"%04d-%02d",((Number)batch.get("payroll_year")).intValue(),((Number)batch.get("payroll_month")).intValue());
        // Publication and view/download timestamps are intentionally absent: only salary facts own this identity.
        var identity=new LinkedHashMap<String,Object>();identity.put("batchId",id);identity.put("period",period);
        identity.put("generatedBy",batch.get("generated_by"));identity.put("departmentId",batch.get("department_id"));
        identity.put("currencyId",currencies.getFirst());identity.put("gross",gross.toPlainString());
        identity.put("deductions",deductions.toPlainString());identity.put("net",net.toPlainString());identity.put("slips",slips);
        var source=new Source(id,period,status,(UUID)batch.get("generated_by"),(UUID)batch.get("department_id"),currencies.getFirst(),
                gross,deductions,net,hash(identity),List.copyOf(slips));
        if(lock){var cache=lockedCache(true);if(cache!=null)cache.put(id,source);}
        return source;
    }
    @SuppressWarnings("unchecked")
    private Map<UUID,Source> lockedCache(boolean create){
        if(!TransactionSynchronizationManager.isActualTransactionActive()||!TransactionSynchronizationManager.isSynchronizationActive())return null;
        var existing=(Map<UUID,Source>)TransactionSynchronizationManager.getResource(transactionCacheKey);
        if(existing!=null||!create)return existing;
        Map<UUID,Source> cache=new HashMap<>();TransactionSynchronizationManager.bindResource(transactionCacheKey,cache);
        TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization(){
            @Override public void suspend(){if(TransactionSynchronizationManager.getResource(transactionCacheKey)==cache)TransactionSynchronizationManager.unbindResource(transactionCacheKey);}
            @Override public void resume(){TransactionSynchronizationManager.bindResource(transactionCacheKey,cache);}
            @Override public void afterCompletion(int status){if(TransactionSynchronizationManager.getResource(transactionCacheKey)==cache)TransactionSynchronizationManager.unbindResource(transactionCacheKey);}
        });
        return cache;
    }
    private String hash(Object value){try{return ImmutableDocumentStore.digest(json.writeValueAsBytes(value));}
        catch(Exception failure){throw new IllegalStateException("原工资事实无法核对",failure);}}
    private static BigDecimal amount(Map<String,Object> row,String key){
        Object value=row.get(key);if(!(value instanceof BigDecimal amount))throw invalid("原工资缺少明确金额："+key);
        return FinancialExactAmount.require(amount,"原工资金额");
    }
    private static BigDecimal sumItems(List<Item> items,String type){return items.stream().filter(item->type.equals(item.type())).map(Item::amount).reduce(BigDecimal.ZERO,BigDecimal::add);}
    private static BigDecimal sum(List<Slip> slips,int kind){return slips.stream().map(s->kind==0?s.grossIncome():kind==1?s.totalDeduction():s.netIncome()).reduce(BigDecimal.ZERO,BigDecimal::add);}
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
}
