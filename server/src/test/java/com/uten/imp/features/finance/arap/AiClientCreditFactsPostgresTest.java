package com.uten.imp.features.finance.arap;

import com.uten.imp.application.port.ClientCreditFactsPort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.ai.AiPlatformPostgresTestSupport;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.ClientCreditReadAccess;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;

/** Full migrated disposable PostgreSQL: actual client scope, balance port and credit SQL. */
class AiClientCreditFactsPostgresTest extends AiPlatformPostgresTestSupport {
    @Autowired private ClientCreditFactsPort credit;
    private UUID employee, otherEmployee, actor, owned, foreign, currency;

    @BeforeEach void customerFixture() {
        employee = employee(); otherEmployee = employee(); actor = UUID.randomUUID();
        jdbc.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,status) VALUES(?,?,?,'test-only',false,'active')",
                actor, employee, "credit-" + actor);
        owned = client(employee); foreign = client(otherEmployee);
        currency = jdbc.queryForObject("SELECT id FROM currencies WHERE is_base_currency", UUID.class);
        login(Set.of("client:view", ClientCreditReadAccess.VIEW));
    }
    @AfterEach void clearPrincipal() { SecurityContextHolder.clearContext(); }

    @Test void overdueMissingDatesReceiptsAndPrepaymentsRetainTheirSeparateAuthoritativeMeaning() {
        LocalDate today = BusinessTime.today();
        ledger(owned, "RECEIVABLE", "SALES_SHIPMENT", "100", "20", today.minusDays(1), false);
        ledger(owned, "RECEIVABLE", "SALES_SHIPMENT", "50", "0", null, false);
        ledger(owned, "CUSTOMER_PREPAYMENT", "DIRECT_RECEIPT", "0", "200", today.minusDays(20), false);
        ledger(owned, "RECEIVABLE", "SALES_SHIPMENT", "30", "30", today.minusDays(5), true);
        ledger(foreign, "RECEIVABLE", "SALES_SHIPMENT", "9999", "0", today.minusDays(50), false);

        var facts = credit.read(owned);
        var balance = facts.balances().forDocument(owned, currency, new BigDecimal("100"));
        assertThat(facts.formalRows()).isEqualTo(3);
        assertThat(facts.openRows()).isEqualTo(2);
        assertThat(facts.overdueRows()).isEqualTo(1);
        assertThat(facts.overdueLocal()).isEqualByComparingTo("80");
        assertThat(facts.missingDueDateRows()).isEqualTo(1);
        assertThat(facts.receivedLocal()).isEqualByComparingTo("50");
        assertThat(facts.latestSettledDate()).isEqualTo(today.minusDays(1));
        assertThat(balance.openBookLocal()).isEqualByComparingTo("130");
        assertThat(balance.creditOriginal()).isEqualByComparingTo("200");
        assertThat(balance.overCredit()).as("credit exposure uses gross formal AR, not AR minus prepayments").isTrue();
        assertThat(facts.balances().parties()).containsOnlyKeys(owned);
    }

    @Test void narrowGrantCannotReadAnotherCustomerOrDetectWhetherTheirUuidExists() {
        ledger(foreign, "RECEIVABLE", "SALES_SHIPMENT", "9999", "0", BusinessTime.today().minusDays(1), false);
        ApiException hidden = catchThrowableOfType(() -> credit.read(foreign), ApiException.class);
        ApiException missing = catchThrowableOfType(() -> credit.read(UUID.randomUUID()), ApiException.class);
        assertThat(hidden.getCode()).isEqualTo(ErrorCode.NOT_FOUND);
        assertThat(missing.getCode()).isEqualTo(hidden.getCode());
        assertThat(missing.getMessage()).isEqualTo(hidden.getMessage());
        assertThat(credit.read(owned).formalRows()).isZero();
        jdbc.update("UPDATE clients SET owner_employee_id=? WHERE id=?", otherEmployee, owned);
        assertThatThrownBy(() -> credit.read(owned)).isInstanceOfSatisfying(ApiException.class,
                failure -> assertThat(failure.getCode()).isEqualTo(ErrorCode.NOT_FOUND));
    }

    @Test void customerVisibilityWithoutCreditAuthorityStillCannotReadAmounts() {
        ledger(owned, "RECEIVABLE", "SALES_SHIPMENT", "900", "0", BusinessTime.today().minusDays(1), false);
        login(Set.of("client:view"));
        assertThatThrownBy(() -> credit.read(owned)).isInstanceOfSatisfying(ApiException.class,
                failure -> assertThat(failure.getCode()).isEqualTo(ErrorCode.FORBIDDEN));
    }

    private void login(Set<String> permissions) {
        var principal = new AuthUser(actor, employee, "credit-test", permissions, false, true, false);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(principal, null, principal.getAuthorities()));
    }
    private UUID employee() {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                SELECT ?,?,'信用查询测试','其他',id,CURRENT_DATE,'active','regular' FROM departments WHERE code='DEPT_SALES'
                """, id, "CREDIT-" + id);
        return id;
    }
    private UUID client(UUID owner) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO clients(id,code,name,status,code_sequence,owner_employee_id)
                VALUES(?,?,?,'使用',(SELECT COALESCE(max(code_sequence),0)+1 FROM clients),?)
                """, id, "CREDIT-" + id, "信用依据客户", owner);
        return id;
    }
    private void ledger(UUID client, String kind, String type, String original, String received, LocalDate due, boolean settled) {
        UUID id = UUID.randomUUID(); BigDecimal amount = new BigDecimal(original), cash = new BigDecimal(received), balance = amount.subtract(cash);
        jdbc.update("""
                INSERT INTO ar_ap_ledger(id,direction,business_type,open_item_kind,source_doc_type,bill_no,bill_date,due_date,
                    client_id,currency_id,exchange_rate,amount_original,amount_original_local,amount_settled,
                    amount_received_original,amount_received_local,amount_write_off_original,amount_write_off_local,
                    amount_balance_original,amount_balance,is_settled,settled_date,status,is_deleted)
                VALUES(?,'AR','SALES',?,?,?,CURRENT_DATE,?,?,?,1,?,?,?,?,?,0,0,?,?,?, ?,1,FALSE)
                """, id, kind, type, "XC-CREDIT-" + id, due, client, currency, amount, amount, cash, cash, cash,
                balance, balance, settled, settled ? BusinessTime.today().minusDays(1) : null);
    }
}
