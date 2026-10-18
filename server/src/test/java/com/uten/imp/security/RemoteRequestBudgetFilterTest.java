package com.uten.imp.security;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.config.props.DeploymentProperties;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;
import static org.mockito.ArgumentMatchers.any;

class RemoteRequestBudgetFilterTest {
    @Test
    void remoteOverloadCannotQueueOrStarveOfficeRequestsAndPermitIsReturned() throws Exception {
        var deployment = new DeploymentProperties();
        deployment.setRemoteMaxConcurrentRequests(1);
        var origins = mock(TrustedRequestOriginPolicy.class);
        when(origins.isRemoteRequest()).thenAnswer(invocation ->
                Thread.currentThread().getName().startsWith("remote"));
        var registry = new SimpleMeterRegistry();
        var filter = new RemoteRequestBudgetFilter(origins,new ObjectMapper().findAndRegisterModules(),deployment,registry);
        var entered = new CountDownLatch(1);
        var release = new CountDownLatch(1);
        try (var workers = Executors.newSingleThreadExecutor(r -> new Thread(r,"remote-worker"))) {
            var running = workers.submit(() -> {
                filter.doFilter(request(),new MockHttpServletResponse(),(req,res) -> {
                    entered.countDown();
                    try { assertTrue(release.await(5,TimeUnit.SECONDS)); }
                    catch (InterruptedException failure) {Thread.currentThread().interrupt();throw new RuntimeException(failure);}
                });
                return null;
            });
            assertTrue(entered.await(5,TimeUnit.SECONDS));
            String originalName = Thread.currentThread().getName();
            try {
                Thread.currentThread().setName("remote-overflow");
                var denied = new MockHttpServletResponse();
                filter.doFilter(request(),denied,(req,res) -> fail("Excess remote work must never start"));
                assertEquals(429,denied.getStatus());
                assertEquals("REMOTE_CAPACITY_REJECTED",new ObjectMapper().readTree(denied.getContentAsString()).path("code").asText());
                assertEquals("1",denied.getHeader("Retry-After"));
                Thread.currentThread().setName("office");
                boolean[] reached = {false};
                filter.doFilter(request(),new MockHttpServletResponse(),(req,res) -> reached[0]=true);
                assertTrue(reached[0]);
            } finally {
                Thread.currentThread().setName(originalName);
                release.countDown();
            }
            running.get(5,TimeUnit.SECONDS);
            workers.submit(() -> {
                filter.doFilter(request(),new MockHttpServletResponse(),(req,res) -> {});
                return null;
            }).get(5,TimeUnit.SECONDS);
        }
        assertEquals(1,registry.get("uten.remote.request.rejected").counter().count());
        assertEquals(2,registry.get("uten.remote.request.duration").timer().count());
        assertTrue(registry.getMeters().stream().allMatch(m -> m.getId().getTags().stream()
                .allMatch(tag -> "phi".equals(tag.getKey()))),
                "Only Micrometer's fixed percentile label is allowed; never user/path/business labels");
    }

    private MockHttpServletRequest request() { return new MockHttpServletRequest("GET","/%61pi/auth/me"); }

    @Test
    void anonymousReadinessCannotExhaustBusinessCapacityOrBypassProbeBudget() throws Exception {
        var deployment = new DeploymentProperties();
        deployment.setRemoteMaxConcurrentRequests(1);
        var origins = mock(TrustedRequestOriginPolicy.class);
        when(origins.isRemoteRequest()).thenReturn(true);
        when(origins.resolve(any())).thenReturn(TrustedRequestOriginPolicy.Origin.REMOTE);
        var filter = new RemoteRequestBudgetFilter(origins,new ObjectMapper().findAndRegisterModules(),
                deployment,new SimpleMeterRegistry());
        var entered = new CountDownLatch(2);
        var release = new CountDownLatch(1);
        try (var workers = Executors.newFixedThreadPool(2)) {
            java.util.concurrent.Callable<Void> probe = () -> {
                filter.doFilter(new MockHttpServletRequest("GET","/actuator/health/readiness"),
                        new MockHttpServletResponse(),(req,res) -> {
                            entered.countDown();
                            try {assertTrue(release.await(5,TimeUnit.SECONDS));}
                            catch (InterruptedException failure) {Thread.currentThread().interrupt();throw new RuntimeException(failure);}
                        });
                return null;
            };
            var first = workers.submit(probe);var second = workers.submit(probe);
            try {
                assertTrue(entered.await(5,TimeUnit.SECONDS));
                var overflow = new MockHttpServletResponse();
                filter.doFilter(new MockHttpServletRequest("GET","/actuator/%68ealth/readiness"),overflow,
                        (req,res) -> fail("The third anonymous probe must not reach database health checks"));
                assertEquals(429,overflow.getStatus());
                assertEquals("REMOTE_CAPACITY_REJECTED",new ObjectMapper().readTree(overflow.getContentAsString()).path("code").asText());
                assertEquals("1",overflow.getHeader("Retry-After"));
                boolean[] reached = {false};
                filter.doFilter(request(),new MockHttpServletResponse(),(req,res) -> reached[0]=true);
                assertTrue(reached[0],"Two anonymous probes must not consume the business permits");
            } finally {release.countDown();}
            first.get(5,TimeUnit.SECONDS);second.get(5,TimeUnit.SECONDS);
        }
    }
}
