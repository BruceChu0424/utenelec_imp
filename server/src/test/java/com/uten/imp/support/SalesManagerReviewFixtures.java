package com.uten.imp.support;

import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.sales.SalesManagerReviewService;
import com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService.FinanceConfirmRequest;
import com.uten.imp.features.sales.quote.SalesQuoteFinanceService;
import com.uten.imp.features.sales.quote.dto.QuoteFinanceDecisionRequest;
import com.uten.imp.security.AuthUser;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;

import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Real manager-stage fixture transitions; no SQL approval or actor/permission substitution. */
public final class SalesManagerReviewFixtures {
    private SalesManagerReviewFixtures() {}

    public static int approveQuoteForFinance(JdbcTemplate db,TaskClaimService claims,
            SalesQuoteFinanceService finance,UUID quoteId,int reviewedRevision) {
        assertEquals("PENDING",db.queryForObject(
                "SELECT manager_review_state FROM sales_quotes WHERE id=?",String.class,quoteId));
        assertEquals(reviewedRevision,db.queryForObject(
                "SELECT review_revision FROM sales_quotes WHERE id=?",Integer.class,quoteId));
        AuthUser actor=(AuthUser)SecurityContextHolder.getContext().getAuthentication().getPrincipal();
        String target="SALES_QUOTE_MANAGER_REVIEW";
        var claim=claims.claim(target,quoteId.toString());
        var approved=finance.confirmManager(quoteId,new QuoteFinanceDecisionRequest(
                reviewedRevision,claim.claimId(),"Fixture manager reviewed"));
        assertEquals("APPROVED",db.queryForObject(
                "SELECT manager_review_state FROM sales_quotes WHERE id=?",String.class,quoteId));
        assertEquals(actor.getEmployeeId(),db.queryForObject(
                "SELECT manager_approved_by FROM sales_quotes WHERE id=?",UUID.class,quoteId));
        assertEquals(claim.claimId(),db.queryForObject(
                "SELECT manager_decision_claim_id FROM sales_quotes WHERE id=?",UUID.class,quoteId));
        assertTrue(claims.activeClaimView(target,quoteId.toString()).isEmpty());
        assertTrue(db.queryForObject("SELECT finance_confirmed_at IS NULL FROM sales_quotes WHERE id=?",Boolean.class,quoteId));
        int financeRevision=reviewedRevision+1;
        assertEquals(financeRevision,approved.reviewRevision());
        assertEquals(financeRevision,db.queryForObject(
                "SELECT review_revision FROM sales_quotes WHERE id=?",Integer.class,quoteId));
        return financeRevision;
    }

    public static long approveOrderForFinance(JdbcTemplate db, TaskClaimService claims,
            SalesManagerReviewService managers, UUID orderId, long reviewedRevision) {
        assertEquals("PENDING",db.queryForObject(
                "SELECT manager_review_state FROM sales_orders WHERE id=?",String.class,orderId));
        assertEquals(reviewedRevision,db.queryForObject(
                "SELECT finance_review_revision FROM sales_orders WHERE id=?",Long.class,orderId));
        AuthUser actor=(AuthUser)SecurityContextHolder.getContext().getAuthentication().getPrincipal();
        var claim=claims.claim(SalesManagerReviewService.ORDER_TARGET,orderId.toString());
        managers.confirmOrder(orderId,new FinanceConfirmRequest("Fixture manager reviewed",reviewedRevision,claim.claimId()));
        assertEquals("APPROVED",db.queryForObject(
                "SELECT manager_review_state FROM sales_orders WHERE id=?",String.class,orderId));
        assertEquals(actor.getEmployeeId(),db.queryForObject(
                "SELECT manager_approved_by FROM sales_orders WHERE id=?",UUID.class,orderId));
        assertEquals(claim.claimId(),db.queryForObject(
                "SELECT manager_decision_claim_id FROM sales_orders WHERE id=?",UUID.class,orderId));
        assertTrue(claims.activeClaimView(SalesManagerReviewService.ORDER_TARGET,orderId.toString()).isEmpty());
        assertFalse(db.queryForObject("SELECT finance_confirmed FROM sales_orders WHERE id=?",Boolean.class,orderId));
        long financeRevision=reviewedRevision+1;
        assertEquals(financeRevision,db.queryForObject(
                "SELECT finance_review_revision FROM sales_orders WHERE id=?",Long.class,orderId));
        return financeRevision;
    }
}
