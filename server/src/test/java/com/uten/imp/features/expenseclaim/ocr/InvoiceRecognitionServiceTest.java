package com.uten.imp.features.expenseclaim.ocr;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.config.props.ExpenseOcrProperties;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.mock.web.MockMultipartFile;
import java.util.Optional;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class InvoiceRecognitionServiceTest {
    @SuppressWarnings("unchecked")
    private final ObjectProvider<InvoiceOcrClient> provider = mock(ObjectProvider.class);
    private final ExpenseOcrProperties properties = new ExpenseOcrProperties();
    private final InvoiceRecognitionService service = new InvoiceRecognitionService(provider, properties);

    @Test
    void localOnlyEndpointRejectsOutboundDestinationsAndCredentials() {
        for (String endpoint : new String[]{"https://example.com", "http://127.0.0.1.evil/", "http://user@127.0.0.1", "http://127.0.0.1/?url=x"}) {
            properties.setEndpoint(endpoint);
            assertThat(properties.isLocalEndpoint()).isFalse();
            assertThatThrownBy(() -> new PaddleOcrClient(properties)).isInstanceOf(IllegalArgumentException.class);
        }
        properties.setEndpoint("http://127.0.0.1:8501");
        assertThat(properties.isLocalEndpoint()).isTrue();
    }

    @Test
    void spoofedMimeAndActiveImageTypesNeverReachOcr() {
        var client = mock(InvoiceOcrClient.class);
        when(provider.getIfAvailable()).thenReturn(client);
        assertThatThrownBy(() -> service.recognize(new MockMultipartFile("file", "f.png", "image/png", new byte[12])))
                .isInstanceOf(ApiException.class).hasMessageContaining("内容");
        assertThatThrownBy(() -> service.recognize(new MockMultipartFile("file", "f.svg", "image/svg+xml", "<svg/>".getBytes())))
                .isInstanceOf(ApiException.class).hasMessageContaining("仅支持");
        verifyNoInteractions(client);
    }

    @Test
    void engineFailureIsSanitizedAndReleasesConcurrencySlot() {
        var client = mock(InvoiceOcrClient.class);
        when(provider.getIfAvailable()).thenReturn(client);
        when(client.recognize(any(), any())).thenThrow(new IllegalStateException("private invoice data"))
                .thenReturn(Optional.empty());
        byte[] bytes = png();
        var file = new MockMultipartFile("file", "f.png", "image/png", bytes);
        for (int index = 0; index < 2; index++) {
            assertThatThrownBy(() -> service.recognize(file)).isInstanceOf(ApiException.class)
                    .hasMessageContaining("识别失败").hasMessageNotContaining("private");
        }
        verify(client, times(2)).recognize(any(), any());
    }
    @Test
    void dimensionsAndTruncatedHeadersAreRejectedBeforeCallingTheSidecar() {
        var client = mock(InvoiceOcrClient.class);
        when(provider.getIfAvailable()).thenReturn(client);
        byte[] tooManyPixels = png();
        java.nio.ByteBuffer.wrap(tooManyPixels).putInt(16, 10000).putInt(20, 10000);
        byte[] tooWide = png();
        java.nio.ByteBuffer.wrap(tooWide).putInt(16, 30001).putInt(20, 1);
        byte[] overflow = png();
        java.nio.ByteBuffer.wrap(overflow).putInt(16, -1).putInt(20, -1);
        byte[] incomplete = java.util.Arrays.copyOf(png(), 12);
        for (byte[] bytes : new byte[][]{tooManyPixels, tooWide, overflow, incomplete}) {
            assertThatThrownBy(() -> service.recognize(new MockMultipartFile("file", "f.png", "image/png", bytes)))
                    .isInstanceOf(ApiException.class).hasMessageContaining("尺寸");
        }
        byte[] webp = new byte[30];
        System.arraycopy("RIFF".getBytes(java.nio.charset.StandardCharsets.US_ASCII), 0, webp, 0, 4);
        System.arraycopy("WEBPVP8X".getBytes(java.nio.charset.StandardCharsets.US_ASCII), 0, webp, 8, 8);
        // 30001 x 1: below 40 MP but over the per-edge cap.
        webp[24] = 0x30; webp[25] = 0x75;
        assertThatThrownBy(() -> service.recognize(new MockMultipartFile("file", "f.webp", "image/webp", webp)))
                .isInstanceOf(ApiException.class).hasMessageContaining("尺寸");
        verifyNoInteractions(client);
    }

    @Test
    void aRealImagePassesTheSharedGuardWithoutDecodingIt() {
        var client = mock(InvoiceOcrClient.class);
        when(provider.getIfAvailable()).thenReturn(client);
        var invoice = new com.uten.imp.features.expenseclaim.dto.RecognizedInvoiceDto(
                null, null, "12345678", null, null, null, null, null, null, null, null, null);
        when(client.recognize(any(), eq("image/png"))).thenReturn(Optional.of(invoice));
        assertThat(service.recognize(new MockMultipartFile("file", "f.png", "image/png", png()))).isEqualTo(invoice);
        verify(client).recognize(any(), eq("image/png"));
    }

    private static byte[] png() {
        return java.util.Base64.getDecoder().decode(
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=");
    }

}
