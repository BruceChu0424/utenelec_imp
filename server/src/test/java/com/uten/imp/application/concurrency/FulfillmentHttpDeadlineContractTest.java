package com.uten.imp.application.concurrency;

import com.uten.imp.common.web.FulfillmentHttpDeadlineFilter;
import com.uten.imp.config.FulfillmentHttpDeadlineConfig;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;

import java.time.Duration;
import java.util.concurrent.atomic.AtomicLong;

import static org.junit.jupiter.api.Assertions.*;

class FulfillmentHttpDeadlineContractTest {
    @AfterEach void clean(){assertNull(FulfillmentCommandDeadline.current());}

    @Test void authenticationAndPriorReadTransactionConsumeButCannotCompleteTheRequestBudget() {
        AtomicLong time=new AtomicLong();
        try(var request=FulfillmentCommandDeadline.openHttpRequest(Duration.ofSeconds(40),time::get)){
            time.addAndGet(Duration.ofSeconds(7).toNanos());
            try(var auth=FulfillmentCommandDeadline.openCommand(Duration.ofSeconds(40),time::get,false)){
                auth.rootCommitted();
            }
            assertSame(request,FulfillmentCommandDeadline.current());
            try(var command=FulfillmentCommandDeadline.openCommand(Duration.ofSeconds(40),time::get,true)){
                assertEquals(33_000,command.remainingMillis());
                time.addAndGet(Duration.ofSeconds(34).toNanos());
                assertThrows(org.springframework.transaction.TransactionTimedOutException.class,command::check);
            }
        }
    }
    @Test void aCommittedBusinessCommandDoesNotBecomeTimedOutDuringResponseOrAuditProcessing() {
        AtomicLong time=new AtomicLong();
        try(var request=FulfillmentCommandDeadline.openHttpRequest(Duration.ofSeconds(40),time::get)){
            try(var command=FulfillmentCommandDeadline.openCommand(Duration.ofSeconds(40),time::get,true)){
                time.addAndGet(Duration.ofSeconds(39).toNanos());command.rootCommitted();
            }
            time.addAndGet(Duration.ofSeconds(100).toNanos());
            assertNull(FulfillmentCommandDeadline.current());
        }
    }
    @Test void rollbackAndRetryNeverReceiveAFreshHttpBudget() {
        AtomicLong time=new AtomicLong();
        try(var request=FulfillmentCommandDeadline.openHttpRequest(Duration.ofSeconds(40),time::get)){
            try(var first=FulfillmentCommandDeadline.openCommand(Duration.ofSeconds(40),time::get,true)){
                time.addAndGet(Duration.ofSeconds(25).toNanos());
            }
            try(var second=FulfillmentCommandDeadline.openCommand(Duration.ofSeconds(40),time::get,true)){
                assertEquals(15_000,second.remainingMillis());second.limitRemaining(Duration.ofSeconds(10));
                assertEquals(10_000,second.remainingMillis());
            }
        }
    }
    @Test void filtersOnlyCriticalWriteFamiliesAndLeavesReceiptReadAuthAndUploadsUntouched() throws Exception {
        var filter=new FulfillmentHttpDeadlineFilter(Duration.ofSeconds(40));
        for(String path:java.util.List.of("/api/production/daily-reports/x/approve","/api/production/quality-inspections/x/decisions",
                "/api/stock/docs/issue-batch","/api/stock/docs/issue-discovery-batch","/api/procurement/inspection/x/decide-batch")){
            var request=new MockHttpServletRequest("POST",path);
            filter.doFilter(request,new MockHttpServletResponse(),(req,res)->assertNotNull(FulfillmentCommandDeadline.current()));
            assertNull(FulfillmentCommandDeadline.current());
        }
        for(String path:java.util.List.of("/api/stock/docs/issue-batch/receipt","/api/auth/login","/api/attachments/upload")){
            var request=new MockHttpServletRequest(path.contains("receipt")?"GET":"POST",path);
            filter.doFilter(request,new MockHttpServletResponse(),(req,res)->assertNull(FulfillmentCommandDeadline.current()));
        }
    }
    @Test void filterWrapsSecurityAndResetsItsScopeEvenOnRejectedOrFailedRequests() throws Exception {
        var registration=new FulfillmentHttpDeadlineConfig().fulfillmentHttpDeadline("40s");
        assertTrue(registration.getOrder()<org.springframework.boot.autoconfigure.security.SecurityProperties.DEFAULT_FILTER_ORDER);
        var request=new MockHttpServletRequest("POST","/erp/api/stock/docs/issue-batch");request.setContextPath("/erp");
        assertThrows(jakarta.servlet.ServletException.class,()->registration.getFilter().doFilter(request,new MockHttpServletResponse(),
                (req,res)->{assertNotNull(FulfillmentCommandDeadline.current());throw new jakarta.servlet.ServletException("rejected");}));
    }
}
