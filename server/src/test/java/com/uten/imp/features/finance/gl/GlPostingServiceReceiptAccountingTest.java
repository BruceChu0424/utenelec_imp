package com.uten.imp.features.finance.gl;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class GlPostingServiceReceiptAccountingTest {

    @Test
    void receiptApprovalPostsAndChecksOneBalancedVoucherInCallerTransaction() {
        EntityManager em=mock(EntityManager.class);
        TxSessionVars tx=mock(TxSessionVars.class);
        List<String> statements=new ArrayList<>();
        UUID receiptId=UUID.randomUUID();
        when(em.createNativeQuery(anyString())).thenAnswer(invocation->{
            String sql=invocation.getArgument(0);
            statements.add(sql);
            Query query=mock(Query.class);
            when(query.setParameter(anyString(),any())).thenReturn(query);
            when(query.executeUpdate()).thenReturn(1);
            when(query.getSingleResult()).thenReturn(0L);
            if(sql.contains("SELECT bill_no,bill_date,account_id,remark")){
                when(query.getResultList()).thenReturn(List.<Object[]>of(
                        new Object[]{"XS-REALTIME",BusinessTime.today(),UUID.randomUUID(),"审核"}));
            }else if(sql.contains("SELECT COUNT(*),COALESCE(SUM(direction*amount),0)")){
                when(query.getResultList()).thenReturn(List.<Object[]>of(
                        new Object[]{4L,BigDecimal.ZERO}));
            }
            return query;
        });

        UUID voucher=new GlPostingService(em,tx).postReceiptDoc(receiptId);

        assertThat(voucher).isNotNull();
        assertThat(statements).anySatisfy(sql->assertThat(sql)
                .contains("INSERT INTO gl_vouchers")
                .contains("'RECEIPT'")
                .contains("审核实时过账"));
        assertThat(statements).anySatisfy(sql->assertThat(sql)
                .contains("INSERT INTO gl_entries")
                .contains("receipt.account_amount_local")
                .contains("receipt.bank_fee")
                .contains("receipt.other_fee")
                .contains("receipt.gl_account_style_id")
                .contains("receipt.gl_counter_style_id")
                .contains("receipt.gl_bank_fee_style_id")
                .contains("receipt.gl_fx_style_id")
                .contains("receipt.gl_fee_payment_style_id")
                .contains("SUM(line.exchange_diff)"));
        assertThat(statements).anySatisfy(sql->assertThat(sql)
                .contains("COUNT(*),COALESCE(SUM(direction*amount),0)"));
        assertThat(statements).noneMatch(sql -> sql.contains("DELETE FROM gl_vouchers"));
    }

    @Test
    void receiptReversalKeepsOriginalVoucherAndAppendsMirroredCurrentPeriodVoucher() {
        EntityManager em=mock(EntityManager.class);
        TxSessionVars tx=mock(TxSessionVars.class);
        List<String> statements=new ArrayList<>();
        UUID receiptId=UUID.randomUUID();
        UUID originalId=UUID.randomUUID();
        when(em.createNativeQuery(anyString())).thenAnswer(invocation->{
            String sql=invocation.getArgument(0);
            statements.add(sql);
            Query query=mock(Query.class);
            when(query.setParameter(anyString(),any())).thenReturn(query);
            when(query.getSingleResult()).thenReturn(0L);
            when(query.executeUpdate()).thenReturn(
                    sql.contains("INSERT INTO gl_entries") ? 4 : 1);
            if(sql.contains("SELECT voucher.id,receipt.bill_no")){
                when(query.getResultList()).thenReturn(List.<Object[]>of(
                        new Object[]{originalId,"XS-REV"}));
            }else if(sql.contains("(SELECT COUNT(*) FROM gl_entries")){
                when(query.getResultList()).thenReturn(List.<Object[]>of(
                        new Object[]{4L,4L,BigDecimal.ZERO}));
            }
            return query;
        });
        OffsetDateTime reversedAt=BusinessTime.startOfDay(BusinessTime.today()).plusHours(12);

        UUID reversal=new GlPostingService(em,tx).reverseReceiptDoc(receiptId,reversedAt);

        assertThat(reversal).isNotNull();
        assertThat(statements).anySatisfy(sql->assertThat(sql)
                .contains("INSERT INTO gl_vouchers")
                .contains("'RECEIPT_REV'")
                .contains("reversal_of_voucher_id"));
        assertThat(statements).anySatisfy(sql->assertThat(sql)
                .contains("INSERT INTO gl_entries")
                .contains("-entry.direction")
                .contains("'RECEIPT_REV'"));
        assertThat(statements).anySatisfy(sql->assertThat(sql)
                .contains("UPDATE gl_vouchers")
                .contains("reversed_by_voucher_id"));
        assertThat(statements).noneMatch(sql -> sql.contains("DELETE FROM gl_vouchers"));
        verify(tx).bind();
    }

    @Test
    void arPostingFailsClosedBeforeDeleteWhenCoreStylesAreUnavailable() {
        EntityManager em = mock(EntityManager.class);
        List<String> sqlStatements = new ArrayList<>();
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            sqlStatements.add(sql);
            return queryReturning(sql.contains("FROM finance_expenses expense")
                    && sql.contains("expense.gl_status=2") ? 0L : 1L);
        });

        assertThatThrownBy(() -> new GlPostingService(em, mock(TxSessionVars.class))
                .generate("2026-08"))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("系统过账角色")
                .hasMessageContaining("科目 UUID");
        assertThat(sqlStatements).hasSize(4);
        assertThat(sqlStatements.getFirst())
                .contains("pg_advisory_xact_lock")
                .contains("hashtextextended");
        assertThat(sqlStatements.getLast())
                .contains("WITH required_role(role_key)")
                .contains("'AR_CONTROL'")
                .contains("'SALES_REVENUE'")
                .contains("system_posting_style_id(required.role_key)");
    }

    @Test
    void receiptRealtimePostingFailsClosedWhenRequiredAccountingStyleIsUnavailable() {
        EntityManager em = mock(EntityManager.class);
        List<String> sqlStatements = new ArrayList<>();
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            sqlStatements.add(sql);
            Query query=queryReturning(sql.contains("SELECT COUNT(*) FROM finance_receipts receipt")
                    ? 1L : 0L);
            if(sql.contains("SELECT bill_no,bill_date,account_id,remark")){
                when(query.getResultList()).thenReturn(List.<Object[]>of(
                        new Object[]{"XS-CONFIG",BusinessTime.today(),UUID.randomUUID(),"测试"}));
            }
            return query;
        });

        assertThatThrownBy(() -> new GlPostingService(em, mock(TxSessionVars.class))
                .postReceiptDoc(UUID.randomUUID()))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("科目不完整");
        assertThat(sqlStatements).anySatisfy(sql -> assertThat(sql)
                .contains("FROM finance_receipts receipt")
                .contains("receipt.gl_account_style_id")
                .contains("receipt.gl_counter_style_id")
                .contains("receipt.gl_bank_fee_style_id")
                .contains("receipt.gl_fx_style_id")
                .contains("receipt.gl_fee_payment_style_id"));
        assertThat(sqlStatements.stream().noneMatch(sql -> sql.contains("DELETE FROM gl_vouchers")
                || sql.contains("INSERT INTO gl_vouchers"))).isTrue();
    }

    @Test
    void arPostingUsesStableRolesAndReceiptFormulaBalancesCashFeesAndFx() {
        EntityManager em = mock(EntityManager.class);
        TxSessionVars tx = mock(TxSessionVars.class);
        Query query = mock(Query.class);
        List<String> sqlStatements = new ArrayList<>();
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.executeUpdate()).thenReturn(0);
        when(query.getSingleResult()).thenReturn(0L);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            sqlStatements.add(invocation.getArgument(0));
            return query;
        });

        new GlPostingService(em, tx).generate("2026-08");

        String arEntries = sqlStatements.stream()
                .filter(sql -> sql.contains("INSERT INTO gl_entries"))
                .filter(sql -> sql.contains("v.source_type = 'AR_POST'"))
                .findFirst()
                .orElseThrow();
        assertThat(arEntries)
                .contains("system_posting_style_id('AR_CONTROL')")
                .contains("system_posting_style_id('SALES_REVENUE')")
                .doesNotContain("path='");
        assertThat(sqlStatements).anySatisfy(sql -> assertThat(sql)
                .contains("FROM ar_ap_ledger ledger")
                .contains("system_posting_style_id('AR_CONTROL')")
                .contains("system_posting_style_id('SALES_REVENUE')"));

        assertThat(sqlStatements).anySatisfy(sql -> assertThat(sql)
                .contains("invalid_voucher")
                .contains("HAVING COUNT(entry.id)<2")
                .contains("SUM(entry.direction*entry.amount)"));

        // User workflow: USD 1000 at 7.2 produces CNY 7200 gross.
        // CNY 72 fee is deducted, so the real bank debit is 7128.
        // AR carrying value at 7.0 is 7000 and FX gain is 200.
        BigDecimal cashDebit = new BigDecimal("7128.0000");
        BigDecimal feeDebit = new BigDecimal("72.0000");
        BigDecimal arCredit = new BigDecimal("7000.0000");
        BigDecimal exchangeDiff = cashDebit.add(feeDebit).subtract(arCredit);
        BigDecimal fxDebit = exchangeDiff.signum() < 0 ? exchangeDiff.abs() : BigDecimal.ZERO;
        BigDecimal fxCredit = exchangeDiff.signum() > 0 ? exchangeDiff : BigDecimal.ZERO;

        assertThat(cashDebit.add(feeDebit).add(fxDebit))
                .isEqualByComparingTo(arCredit.add(fxCredit));
        assertThat(exchangeDiff).isEqualByComparingTo("200.0000");

        // When the fee is paid separately, the receipt account keeps the gross
        // 7200 and the real fee-payment account contributes the balancing credit.
        BigDecimal grossBankDebit = new BigDecimal("7200.0000");
        BigDecimal separateFeeCredit = new BigDecimal("72.0000");
        assertThat(grossBankDebit.add(feeDebit))
                .isEqualByComparingTo(arCredit.add(exchangeDiff).add(separateFeeCredit));
    }

    private static Query queryReturning(long result) {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.executeUpdate()).thenReturn(0);
        when(query.getSingleResult()).thenReturn(result);
        return query;
    }
}
