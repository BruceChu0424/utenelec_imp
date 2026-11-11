package com.uten.imp.common.readsnapshot;

import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.servlet.ServletOutputStream;
import jakarta.servlet.WriteListener;
import org.junit.jupiter.api.Test;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.util.LinkedHashMap;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/** 2026-11-10 (G): the complete-stream staging that keeps slow consumers out of the data RR transaction. */
class CompleteStreamStagingTest {
    private final ObjectMapper json = new ObjectMapper();

    private static jakarta.servlet.http.HttpServletResponse recording(ByteArrayOutputStream payload) throws IOException {
        var response = mock(jakarta.servlet.http.HttpServletResponse.class);
        when(response.getOutputStream()).thenReturn(new ServletOutputStream() {
            @Override public boolean isReady() { return true; }
            @Override public void setWriteListener(WriteListener listener) { }
            @Override public void write(int value) { payload.write(value); }
        });
        return response;
    }

    private static Map<String, Object> frame(String type, int value) {
        // A deterministic key order keeps the wire-format assertions exact.
        var frame = new LinkedHashMap<String, Object>();
        frame.put("type", type);
        frame.put("value", value);
        return frame;
    }

    @Test void framesUnderTheMemoryCapStayInMemoryAndReplayInTheDirectFraming() throws Exception {
        try (var staged = new CompleteStreamStaging(json, 1 << 20)) {
            staged.stage(frame("page", 1));
            staged.stage(frame("complete", 2));
            assertThat(staged.spilled()).isFalse();
            var payload = new ByteArrayOutputStream();
            staged.replayTo(recording(payload));
            // Byte-for-byte the direct writeFrame output: one JSON line per frame.
            assertThat(payload.toString())
                    .isEqualTo("{\"type\":\"page\",\"value\":1}\n{\"type\":\"complete\",\"value\":2}\n");
        }
    }

    @Test void framesPastTheMemoryCapSpillToOneTempFileThatCloseRemoves() throws Exception {
        var staged = new CompleteStreamStaging(json, 16);
        staged.stage(frame("page", 1));
        staged.stage(frame("page", 2));
        staged.stage(frame("complete", 2));
        assertThat(staged.spilled()).isTrue();
        var payload = new ByteArrayOutputStream();
        staged.replayTo(recording(payload));
        assertThat(payload.toString())
                .isEqualTo("{\"type\":\"page\",\"value\":1}\n{\"type\":\"page\",\"value\":2}\n{\"type\":\"complete\",\"value\":2}\n");
        var file = staged.spillFile();
        assertThat(file).exists();
        staged.close();
        assertThat(file).doesNotExist();
    }

    @Test void replayIsRepeatableWhileOpenAndStopsAfterClose() throws Exception {
        var staged = new CompleteStreamStaging(json, 16);
        staged.stage(frame("page", 1));
        staged.stage(frame("page", 2));
        var first = new ByteArrayOutputStream();
        staged.replayTo(recording(first));
        var second = new ByteArrayOutputStream();
        staged.replayTo(recording(second));
        assertThat(second.toString()).isEqualTo(first.toString());
        staged.close();
        var after = new ByteArrayOutputStream();
        org.assertj.core.api.Assertions.assertThatThrownBy(() -> staged.replayTo(recording(after)))
                .isInstanceOf(IllegalStateException.class);
        assertThat(after.size()).isZero();
    }
}
