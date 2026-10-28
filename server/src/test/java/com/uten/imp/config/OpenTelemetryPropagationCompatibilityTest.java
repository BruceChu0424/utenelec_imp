package com.uten.imp.config;

import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.SpanContext;
import io.opentelemetry.api.trace.propagation.W3CTraceContextPropagator;
import io.opentelemetry.context.Context;
import io.opentelemetry.context.propagation.TextMapGetter;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.Timeout;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.mock.web.MockHttpServletRequest;

import java.util.LinkedHashMap;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/** Exercises the actual managed API used transitively by the Aliyun trace client. */
class OpenTelemetryPropagationCompatibilityTest {
    private static final String TRACE_ID="4bf92f3577b34da6a3ce929d0e0e4736";
    private static final String SPAN_ID="00f067aa0ba902b7";
    private static final String TRACE_PARENT="00-"+TRACE_ID+"-"+SPAN_ID+"-01";
    private static final W3CTraceContextPropagator PROPAGATOR=W3CTraceContextPropagator.getInstance();
    private static final TextMapGetter<MockHttpServletRequest> GETTER=MockHttpServletRequest::getHeader;

    @Test
    void realHttpCarrierPreservesRemoteIdentitySamplingOrderAndOutgoingHeaders() {
        var request=request(" \ta=b \t,\tc=d \t");
        Context extracted=PROPAGATOR.extract(Context.root(),request,GETTER);
        SpanContext span=Span.fromContext(extracted).getSpanContext();
        assertTrue(span.isValid());assertTrue(span.isRemote());assertTrue(span.isSampled());
        assertEquals(TRACE_ID,span.getTraceId());assertEquals(SPAN_ID,span.getSpanId());
        Map<String,String> outgoing=new LinkedHashMap<>();
        PROPAGATOR.inject(extracted,outgoing,Map::put);
        assertEquals(Map.of("traceparent",TRACE_PARENT,"tracestate","a=b,c=d"),outgoing);
    }

    @Test
    void invalidTraceStateDoesNotReplaceValidRemoteParentAndInvalidParentIsRejected() {
        var request=request("a=b,a=c");
        SpanContext span=Span.fromContext(PROPAGATOR.extract(Context.root(),request,GETTER)).getSpanContext();
        assertTrue(span.isValid());assertTrue(span.isRemote());assertTrue(span.getTraceState().isEmpty());
        request.removeHeader("traceparent");request.addHeader("traceparent","00-invalid-invalid-01");
        assertFalse(Span.fromContext(PROPAGATOR.extract(Context.root(),request,GETTER)).getSpanContext().isValid());
    }

    @ParameterizedTest
    @ValueSource(strings={" ","\t"})
    @Timeout(5)
    void adversarialWhitespaceIsBoundedAndMaintainsValidStateSemantics(String whitespace) {
        String padding=whitespace.repeat(100_000);
        for(String header:new String[]{"a=b"+padding,padding+"a=b"+padding,"a=b,"+padding}) {
            SpanContext span=Span.fromContext(PROPAGATOR.extract(Context.root(),request(header),GETTER)).getSpanContext();
            assertTrue(span.isValid());assertEquals("b",span.getTraceState().get("a"));
        }
        for(String header:new String[]{"a=b"+padding+"x",padding}) {
            SpanContext span=Span.fromContext(PROPAGATOR.extract(Context.root(),request(header),GETTER)).getSpanContext();
            assertTrue(span.isValid());assertTrue(span.getTraceState().isEmpty());
        }
    }

    private static MockHttpServletRequest request(String traceState) {
        var request=new MockHttpServletRequest("GET","/api/health");
        request.addHeader("traceparent",TRACE_PARENT);request.addHeader("tracestate",traceState);
        return request;
    }
}
