package com.uten.imp.features.ai.client;

import com.uten.imp.application.port.AiCompletionPort.AiCallException;
import com.uten.imp.application.port.AiCompletionPort.AiErrorCategory;
import com.uten.imp.features.ai.AiProperties;
import com.uten.imp.features.ai.provider.AiEndpointPolicy;
import com.uten.imp.features.ai.provider.AiProviderRuntime;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Component;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.net.ConnectException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpConnectTimeoutException;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.net.http.HttpTimeoutException;
import java.nio.ByteBuffer;
import java.nio.channels.UnresolvedAddressException;
import java.time.Duration;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionStage;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Flow;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

/**
 * AI 服务商的 HTTP 出口(ADR-133)。每个 Bean 一个 {@link HttpClient}: 连接超时 10 秒、从不跟随跳转;
 * 每次请求前按 DNS 结果重新检查接口地址({@link AiEndpointPolicy}); 整个请求(含读响应体)受服务商超时约束;
 * 响应体最多 4 MiB。请求头与请求体从不写日志, 异常文字里的密钥一律抹掉。
 */
@Component
public class AiHttpTransport {

    static final int MAX_RESPONSE_BYTES = 4 * 1024 * 1024;
    private static final Duration CONNECT_TIMEOUT = Duration.ofSeconds(10);

    private final HttpClient client;
    private final AiProperties properties;
    private final AiEndpointPolicy.HostResolver resolver;

    @Autowired
    public AiHttpTransport(AiProperties properties) {
        this(properties, AiEndpointPolicy.HostResolver.SYSTEM, HttpClient.newBuilder()
                .connectTimeout(CONNECT_TIMEOUT)
                .followRedirects(HttpClient.Redirect.NEVER)
                // 本机部署(Ollama/vLLM 等)与各家网关对明文 h2c 升级的支持参差不齐, 统一用 HTTP/1.1。
                .version(HttpClient.Version.HTTP_1_1)
                .build());
    }

    public AiHttpTransport(AiProperties properties, AiEndpointPolicy.HostResolver resolver, HttpClient client) {
        this.properties = properties;
        this.resolver = resolver;
        this.client = client;
    }

    /** 一次 HTTP 交换的结果(任何状态码都原样返回, 由调用方判断)。 */
    public record Exchange(int status, byte[] body, long latencyMs) {
        public boolean success() {
            return status >= 200 && status < 300;
        }
    }

    /**
     * 发送请求。
     *
     * @param path    相对接口地址的路径(以 / 开头), 如 {@code /chat/completions}
     * @param headers 额外请求头(含鉴权头)
     * @param body    JSON 请求体; GET 为空
     */
    public Exchange send(AiProviderRuntime runtime, String method, String path, Map<String, String> headers,
                         byte[] body) {
        try {
            AiEndpointPolicy.checkResolved(runtime.endpoint(), runtime.region(), properties.isAllowLanHttp(),
                    resolver);
        } catch (AiEndpointPolicy.PolicyViolation e) {
            throw new AiCallException(AiErrorCategory.BLOCKED, e.getMessage());
        } catch (AiEndpointPolicy.UnresolvableHost e) {
            throw new AiCallException(AiErrorCategory.NETWORK, e.getMessage());
        }
        Duration timeout = Duration.ofSeconds(Math.max(1, runtime.timeoutSeconds()));
        HttpRequest.Builder builder = HttpRequest.newBuilder(URI.create(runtime.endpoint().normalized() + path))
                .timeout(timeout)
                .header("Accept", "application/json");
        for (Map.Entry<String, String> header : headers.entrySet()) {
            builder.header(header.getKey(), header.getValue());
        }
        if ("POST".equals(method)) {
            builder.header("Content-Type", "application/json");
            builder.POST(HttpRequest.BodyPublishers.ofByteArray(body == null ? new byte[0] : body));
        } else {
            builder.GET();
        }
        long started = System.nanoTime();
        CompletableFuture<HttpResponse<byte[]>> future =
                client.sendAsync(builder.build(), info -> new CappedBody(MAX_RESPONSE_BYTES));
        try {
            HttpResponse<byte[]> response = future.get(timeout.toMillis() + 2_000L, TimeUnit.MILLISECONDS);
            long latency = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started);
            return new Exchange(response.statusCode(), response.body(), latency);
        } catch (TimeoutException e) {
            future.cancel(true);
            throw timeout(runtime);
        } catch (InterruptedException e) {
            future.cancel(true);
            Thread.currentThread().interrupt();
            throw new AiCallException(AiErrorCategory.NETWORK, "AI 调用被中断, 请稍后再试");
        } catch (ExecutionException e) {
            throw translate(e.getCause(), runtime);
        }
    }

    private static AiCallException translate(Throwable cause, AiProviderRuntime runtime) {
        if (hasCause(cause, ResponseTooLarge.class)) {
            return new AiCallException(AiErrorCategory.INVALID_RESPONSE, "AI 服务返回的内容过大, 已放弃");
        }
        if (hasCause(cause, HttpConnectTimeoutException.class)) {
            return new AiCallException(AiErrorCategory.NETWORK, "连接 AI 服务花的时间过长，请检查接口地址或服务器网络");
        }
        if (hasCause(cause, HttpTimeoutException.class)) {
            return timeout(runtime);
        }
        if (hasCause(cause, ConnectException.class) || hasCause(cause, UnresolvedAddressException.class)) {
            return new AiCallException(AiErrorCategory.NETWORK, "连不上 AI 服务, 请检查接口地址或服务器网络");
        }
        if (hasCause(cause, IOException.class)) {
            return new AiCallException(AiErrorCategory.NETWORK, "与 AI 服务的连接中断了, 请稍后再试");
        }
        return new AiCallException(AiErrorCategory.NETWORK, "AI 调用失败, 请稍后再试");
    }

    private static boolean hasCause(Throwable error, Class<? extends Throwable> type) {
        Throwable current = error;
        for (int depth = 0; current != null && depth < 8; depth++) {
            if (type.isInstance(current)) {
                return true;
            }
            current = current.getCause();
        }
        return false;
    }

    private static AiCallException timeout(AiProviderRuntime runtime) {
        return new AiCallException(AiErrorCategory.TIMEOUT, "AI 服务响应时间过长(超过 " + runtime.timeoutSeconds()
                + " 秒)，请稍后再试或在高级设置里调大超时秒数");
    }

    /** 超过上限即取消订阅并以 {@link ResponseTooLarge} 结束。 */
    static final class CappedBody implements HttpResponse.BodySubscriber<byte[]> {
        private final int limit;
        private final ByteArrayOutputStream buffer = new ByteArrayOutputStream();
        private final CompletableFuture<byte[]> result = new CompletableFuture<>();
        private Flow.Subscription subscription;

        CappedBody(int limit) {
            this.limit = limit;
        }

        @Override
        public CompletionStage<byte[]> getBody() {
            return result;
        }

        @Override
        public void onSubscribe(Flow.Subscription subscription) {
            this.subscription = subscription;
            subscription.request(Long.MAX_VALUE);
        }

        @Override
        public void onNext(List<ByteBuffer> items) {
            if (result.isDone()) {
                return;
            }
            for (ByteBuffer item : items) {
                int remaining = item.remaining();
                if (buffer.size() + (long) remaining > limit) {
                    subscription.cancel();
                    result.completeExceptionally(new ResponseTooLarge());
                    return;
                }
                byte[] chunk = new byte[remaining];
                item.get(chunk);
                buffer.write(chunk, 0, chunk.length);
            }
        }

        @Override
        public void onError(Throwable throwable) {
            result.completeExceptionally(throwable);
        }

        @Override
        public void onComplete() {
            result.complete(buffer.toByteArray());
        }
    }

    static final class ResponseTooLarge extends IOException {
        ResponseTooLarge() {
            super("response too large");
        }
    }
}
