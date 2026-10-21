package com.uten.imp.businesschain;

import ch.qos.logback.classic.Level;
import ch.qos.logback.classic.Logger;
import ch.qos.logback.classic.spi.ILoggingEvent;
import ch.qos.logback.core.read.ListAppender;
import org.junit.jupiter.api.Test;
import org.slf4j.LoggerFactory;
import org.springframework.aop.support.AopUtils;
import org.springframework.beans.factory.config.BeanDefinition;
import org.springframework.context.annotation.AnnotationConfigApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.EnableAspectJAutoProxy;

import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/** The measurement advisor is infrastructure, while real business calls still cross its advice. */
class MaterialOrderServiceTimingContractTest {
    @Test
    void infrastructureAdvisorSurvivesJdbcPostProcessorCreationAndStillMeasuresSuccessAndFailure() {
        Logger checker = (Logger) LoggerFactory.getLogger(
                "org.springframework.context.support.PostProcessorRegistrationDelegate$BeanPostProcessorChecker");
        ListAppender<ILoggingEvent> events = new ListAppender<>();
        events.start();
        checker.addAppender(events);
        try {
            try (var context = new AnnotationConfigApplicationContext()) {
                context.register(MaterialOrderServiceTiming.Configuration.class,
                        ProductionJdbcMeasurement.Configuration.class, ProbeConfiguration.class);
                context.refresh();
                assertEquals(BeanDefinition.ROLE_INFRASTRUCTURE,
                        context.getBeanFactory().getBeanDefinition("materialOrderTimingAdvisor").getRole());
                var service = context.getBean(MaterialAnalysisCommandService.class);
                assertTrue(AopUtils.isAopProxy(service), "Infrastructure role must not remove business advice");

                assertEquals(42, service.work(21));
                assertTrue(MaterialOrderServiceTiming.end().isEmpty(), "Inactive measurements stay inactive");
                MaterialOrderServiceTiming.begin();
                Map<String, Map<String, Number>> timings;
                try {
                    assertEquals(42, service.work(21));
                    assertThrows(IllegalArgumentException.class, service::fail);
                } finally {
                    timings = MaterialOrderServiceTiming.end();
                }
                assertEquals(1, timings.get("MaterialAnalysisCommandService.work").get("calls").longValue());
                assertEquals(1, timings.get("MaterialAnalysisCommandService.fail").get("calls").longValue());
                assertEquals(2, timings.size());
            }
            assertTrue(events.list.stream().noneMatch(event -> event.getLevel().isGreaterOrEqual(Level.WARN)),
                    () -> "Measurement infrastructure was created too early: "
                            + events.list.stream().map(ILoggingEvent::getFormattedMessage).toList());
        } finally {
            MaterialOrderServiceTiming.end();
            checker.detachAppender(events);
            events.stop();
        }
    }

    @Configuration(proxyBeanMethods = false)
    @EnableAspectJAutoProxy(proxyTargetClass = true)
    static class ProbeConfiguration {
        @Bean MaterialAnalysisCommandService measuredBusinessService() {
            return new MaterialAnalysisCommandService();
        }
    }

    /** Matches the existing timing pointcut without loading a database or a business Spring context. */
    public static class MaterialAnalysisCommandService {
        public int work(int value) { return value * 2; }
        public int fail() { throw new IllegalArgumentException("expected business refusal"); }
    }
}
