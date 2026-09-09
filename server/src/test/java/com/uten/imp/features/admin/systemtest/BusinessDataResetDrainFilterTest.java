package com.uten.imp.features.admin.systemtest;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;
import java.time.Duration;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import static org.junit.jupiter.api.Assertions.*;

class BusinessDataResetDrainFilterTest {
    @Test void onlyExactResetAndPreparationPathsAreExempt() throws Exception {
        var gate=new BusinessDataResetDrainGate();var filter=new BusinessDataResetDrainFilter(gate,new ObjectMapper());
        assertTrue(gate.beginDrain(100));
        for(String path:new String[]{BusinessDataResetDrainFilter.RESET_PATH,BusinessDataResetDrainFilter.ATTACHMENT_PREPARE_PATH}){
            var request=new MockHttpServletRequest("POST","/erp"+path);request.setContextPath("/erp");
            var called=new AtomicBoolean();filter.doFilter(request,new MockHttpServletResponse(),(a,b)->called.set(true));assertTrue(called.get());
        }
        for(String path:new String[]{"/api/sales/orders",BusinessDataResetDrainFilter.ATTACHMENT_PREPARE_PATH+"/extra","/api/system-test/business-data/attachments/preview"}){
            var response=new MockHttpServletResponse();filter.doFilter(new MockHttpServletRequest("GET",path),response,(a,b)->fail("Unexpected admitted request"));assertEquals(503,response.getStatus());
        }
        gate.endReset();
    }

    @Test void admittedHttpRequestCompletesBeforeDrainAndItsExceptionStillReleasesTheGate() throws Exception {
        var gate=new BusinessDataResetDrainGate();var filter=new BusinessDataResetDrainFilter(gate,new ObjectMapper());
        var entered=new CountDownLatch(1);var release=new CountDownLatch(1);
        try(var executor=Executors.newFixedThreadPool(2)){
            var request=executor.submit(()->{
                assertThrows(jakarta.servlet.ServletException.class,()->filter.doFilter(new MockHttpServletRequest("GET","/api/goods"),
                    new MockHttpServletResponse(),(a,b)->{entered.countDown();try{assertTrue(release.await(5,TimeUnit.SECONDS));}
                        catch(InterruptedException interrupted){Thread.currentThread().interrupt();throw new IllegalStateException(interrupted);}
                        throw new jakarta.servlet.ServletException("expected request failure");}));
            });
            assertTrue(entered.await(5,TimeUnit.SECONDS));
            var drained=executor.submit(()->gate.beginDrain(5_000));
            org.awaitility.Awaitility.await().atMost(Duration.ofSeconds(2)).until(gate::blockingNewRequests);
            assertFalse(drained.isDone());assertFalse(gate.tryEnter());
            release.countDown();request.get(5,TimeUnit.SECONDS);assertTrue(drained.get(5,TimeUnit.SECONDS));
        } finally {release.countDown();gate.endReset();}
        assertTrue(gate.tryEnter());gate.leave();assertTrue(gate.beginDrain(100));gate.endReset();
    }
}
