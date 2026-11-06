package com.uten.imp.support;

import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.sales.SalesManagerReviewService;
import com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService;
import com.uten.imp.features.sales.order.SalesOrderService;
import com.uten.imp.features.sales.order.dto.OrderItemLine;
import com.uten.imp.features.sales.order.dto.OrderSaveRequest;
import com.uten.imp.security.AuthUser;
import com.uten.imp.features.auth.PermissionResolver;
import org.springframework.beans.factory.BeanFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.math.BigDecimal;
import java.time.Duration;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** Real approved order sources for cash tests, with a separate synthetic sales actor. */
public final class SalesPrepaymentOrderFixture {
    private SalesPrepaymentOrderFixture() { }

    public static UUID createApproved(BeanFactory beans, JdbcTemplate db,
            UUID client, UUID currency, LocalDate date) {
        boolean ownsPublicTransactions=!TransactionSynchronizationManager.isActualTransactionActive();
        UUID employee=UUID.randomUUID(),user=UUID.randomUUID(),unit=UUID.randomUUID(),goods=UUID.randomUUID();
        String suffix=user.toString().replace("-", "").substring(0,24), login="prepay-"+suffix;
        UUID department=db.queryForObject("SELECT id FROM departments WHERE code='DEPT_FIN'",UUID.class);
        db.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                VALUES(?,?,?,'其他',?,?,'active','regular')
                """,employee,"PA"+suffix,SyntheticEmployeeIdentity.name("预收来源准备",employee),department,date);
        db.update("""
                INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,is_super_admin,status)
                VALUES(?,?,?,'argon2-stub-not-used-in-direct-calls',FALSE,TRUE,'active')
                """,user,employee,login);
        var previous=SecurityContextHolder.getContext().getAuthentication();
        try {
            var snapshot=beans.getBean(PermissionResolver.class).authorizationSnapshot(user,employee,true);
            AuthUser actor=new AuthUser(user,employee,login,snapshot.permissions(),false,true,true);
            SecurityContextHolder.getContext().setAuthentication(
                    new UsernamePasswordAuthenticationToken(actor,null,actor.getAuthorities()));
            db.update("INSERT INTO units(id,code,name,status) VALUES(?,?,?,'使用')",unit,"PU"+suffix,"预收单位-"+suffix);
            db.update("""
                    INSERT INTO goods(id,code,name,source_type,status,unit_id,price,code_sequence)
                    VALUES(?,?,?,'采购','使用',?,100,(SELECT COALESCE(max(code_sequence),0)+1 FROM goods))
                    """,goods,"PG"+suffix,"预收来源货品-"+suffix,unit);
            OrderSaveRequest request=new OrderSaveRequest();
            request.setBillDate(date);request.setClientId(client);request.setCurrencyId(currency);
            request.setExchangeRate(BigDecimal.ONE);request.setTaxRate(BigDecimal.ZERO);
            request.setShipmentPolicy("ALLOW_PARTIAL");
            OrderItemLine line=new OrderItemLine();line.setGoodsId(goods);line.setUnitId(unit);
            line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal("100"));
            line.setPrice(new BigDecimal("100"));line.setDiscount(BigDecimal.ONE);
            request.setItems(List.of(line));
            var orders=beans.getBean(SalesOrderService.class);
            UUID order=orders.create(request).getId();orders.approve(order);
            var claims=beans.getBean(TaskClaimService.class);
            long revision=SalesManagerReviewFixtures.approveOrderForFinance(db,claims,
                    beans.getBean(SalesManagerReviewService.class),order,0L);
            if(ownsPublicTransactions)awaitPendingFinanceNotice(db,order,user);
            var claim=claims.claim("SALES_ORDER_FINANCE_CONFIRM",order.toString());
            beans.getBean(SalesOrderFinanceConfirmService.class).confirm(order,
                    new SalesOrderFinanceConfirmService.FinanceConfirmRequest(null,revision,claim.claimId()));
            return order;
        } finally {SecurityContextHolder.getContext().setAuthentication(previous);}
    }

    /** Await this original event's committed receipt, not a transient empty
     * SKIP LOCKED queue. The real notice worker and claim lock budget stay on. */
    public static UUID awaitPendingFinanceNotice(JdbcTemplate db,UUID order,UUID actor){
        if(TransactionSynchronizationManager.isActualTransactionActive())
            throw new IllegalStateException("An uncommitted outer transaction cannot await its own outbox delivery");
        var events=db.queryForList("""
                SELECT id FROM business_outbox
                WHERE event_type='SALES_ORDER_PENDING_FINANCE_CONFIRM'
                  AND aggregate_type='SALES_ORDER' AND aggregate_id=? AND created_by=?
                """,UUID.class,order,actor);
        if(events.size()!=1)throw new AssertionError("Expected this order and actor's one original pending-finance event");
        UUID event=events.getFirst();
        org.awaitility.Awaitility.await().alias("original pending-finance event committed: "+event)
                .pollInSameThread().pollDelay(Duration.ZERO).pollInterval(Duration.ofMillis(50))
                .atMost(Duration.ofSeconds(20)).until(()->Boolean.TRUE.equals(db.queryForObject("""
                        SELECT status=1 AND processed_at IS NOT NULL FROM business_outbox
                        WHERE id=? AND event_type='SALES_ORDER_PENDING_FINANCE_CONFIRM'
                          AND aggregate_type='SALES_ORDER' AND aggregate_id=? AND created_by=?
                        """,Boolean.class,event,order,actor)));
        return event;
    }
}
