package com.uten.imp.features.admin.materialforecast;

import ch.qos.logback.classic.Logger;
import ch.qos.logback.classic.spi.ILoggingEvent;
import ch.qos.logback.core.read.ListAppender;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.config.props.MaterialForecastProperties;
import com.uten.imp.config.props.StorageProperties;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class MaterialForecastDevelopmentPayloadTest {
    @TempDir Path directory;
    private final ObjectMapper json=new ObjectMapper();

    @Test void sourceClassesFindTheirOwnCheckoutWhilePackagedLayoutsNeverUseDeveloperBuilds()throws Exception {
        Path repository=repository();
        Path home=Files.createDirectories(repository.resolve("server/target-development/classes"));
        assertThat(MaterialForecastDevelopmentPayload.sourceCheckout(home)).isEqualTo(repository);
        assertThat(MaterialForecastDevelopmentPayload.sourceCheckout(repository.resolve("server"))).isNull();
        assertThat(MaterialForecastDevelopmentPayload.sourceCheckout(directory.resolve("elsewhere/classes"))).isNull();
        assertThat(MaterialForecastDevelopmentPayload.sourceCheckout(repository.resolve("website/classes"))).isNull();
    }

    @Test void nestedFixtureClassesCannotBorrowAnOuterCheckoutAndCustomBuildNamesStillWork()throws Exception {
        Path repository=repository();
        Path nested=Files.createDirectories(repository.resolve("server/validation-output/tmp/fixture/elsewhere/classes"));
        assertThat(MaterialForecastDevelopmentPayload.sourceCheckout(nested)).isNull();
        Path custom=Files.createDirectories(repository.resolve("server/custom-validation-output/classes"));
        assertThat(MaterialForecastDevelopmentPayload.sourceCheckout(custom)).isEqualTo(repository);
        if(MaterialForecastHostPaths.windows()) {
            assertThat(MaterialForecastDevelopmentPayload.sourceCheckout(
                    repository.resolve("SERVER/custom-validation-output/classes"))).isEqualTo(repository);
        }
        Path anotherModule=Files.createDirectories(repository.resolve("website/server/custom-output/classes"));
        assertThat(MaterialForecastDevelopmentPayload.sourceCheckout(anotherModule)).isNull();
    }

    @Test void everyPreparationUsesTheBuilderReceiptAndNeverTrustsAnExistingCacheDirectory()throws Exception {
        Path repository=repository();
        Path home=Files.createDirectories(repository.resolve("server/target/classes"));
        String identity="a".repeat(64);
        Path cache=Files.createDirectories(directory.resolve("payloads").resolve(identity));
        var resolver=spy(new MaterialForecastDevelopmentPayload(new MaterialForecastProperties(),json));
        Process child=mock(Process.class);
        when(child.waitFor(anyLong(),eq(TimeUnit.MILLISECONDS))).thenReturn(true);
        when(child.exitValue()).thenReturn(0);
        when(child.getInputStream()).thenAnswer(ignored->new ByteArrayInputStream(json.writeValueAsBytes(Map.of(
                "component","material-forecast","verified",true,"payload",cache.toString(),"sourceIdentity",identity))));
        doReturn(child).when(resolver).start(anyList(),eq(repository));
        assertThat(resolver.resolve(home,()->false)).isEqualTo(cache);
        assertThat(resolver.resolve(home,()->false)).isEqualTo(cache);
        verify(resolver,times(2)).start(anyList(),eq(repository));
    }

    @Test void rejectedOrMalformedBuilderOutputCannotSelectAnArbitraryExistingDirectory()throws Exception {
        Path repository=repository();
        Path cache=Files.createDirectories(directory.resolve("a".repeat(64)));
        var receipt=json.valueToTree(Map.of("component","material-forecast","verified",false,
                "payload",cache.toString(),"sourceIdentity","a".repeat(64)));
        assertThatThrownBy(()->MaterialForecastDevelopmentPayload.verifiedDirectory(receipt,repository))
                .isInstanceOf(MaterialForecastProcessLauncher.Failure.class);
        ((com.fasterxml.jackson.databind.node.ObjectNode)receipt).put("verified",true).put("payload",repository.toString());
        assertThatThrownBy(()->MaterialForecastDevelopmentPayload.verifiedDirectory(receipt,repository))
                .isInstanceOf(MaterialForecastProcessLauncher.Failure.class);
        ((com.fasterxml.jackson.databind.node.ObjectNode)receipt).put("payload",cache.toString()).put("sourceIdentity","b".repeat(64));
        assertThatThrownBy(()->MaterialForecastDevelopmentPayload.verifiedDirectory(receipt,repository))
                .isInstanceOf(MaterialForecastProcessLauncher.Failure.class);
    }

    @Test void cancellationBeforePreparationNeverLaunchesADownloader()throws Exception {
        Path repository=repository();
        var resolver=spy(new MaterialForecastDevelopmentPayload(new MaterialForecastProperties(),json));
        assertThatThrownBy(()->resolver.resolve(Files.createDirectories(repository.resolve("server/target/classes")),()->true))
                .isInstanceOf(MaterialForecastProcessLauncher.Failure.class).hasMessage("CONFIGURATION_PENDING");
        verify(resolver,never()).start(anyList(),any());
    }

    @Test void pathInspectionAndExplicitPayloadOverridesNeverStartADeveloperBuild() {
        var properties=new MaterialForecastProperties();
        var paths=new MaterialForecastHostPaths(new StorageProperties(),properties);
        var development=mock(MaterialForecastDevelopmentPayload.class);paths.setDevelopmentPayload(development);
        paths.payloadDirectory();
        verifyNoInteractions(development);
        Path explicit=directory.resolve("operator-payload");properties.setPayloadDirectory(explicit.toString());
        assertThat(paths.payloadDirectory(()->false)).isEqualTo(explicit);
        verifyNoInteractions(development);
    }

    @Test void stdoutMustBeASingleUnambiguousSuccessfulBuilderReceipt()throws Exception {
        Path repository=repository();Path home=Files.createDirectories(repository.resolve("server/target/classes"));
        String identity="a".repeat(64);Path cache=Files.createDirectories(directory.resolve(identity));
        String valid=json.writeValueAsString(Map.of("component","material-forecast","verified",true,
                "payload",cache.toString(),"sourceIdentity",identity));
        var output=new java.util.concurrent.atomic.AtomicReference<>(valid);
        var resolver=spy(new MaterialForecastDevelopmentPayload(new MaterialForecastProperties(),json));
        Process child=mock(Process.class);
        when(child.waitFor(anyLong(),eq(TimeUnit.MILLISECONDS))).thenReturn(true);
        when(child.exitValue()).thenReturn(0);
        when(child.getInputStream()).thenAnswer(ignored->new ByteArrayInputStream(output.get().getBytes(java.nio.charset.StandardCharsets.UTF_8)));
        doReturn(child).when(resolver).start(anyList(),eq(repository));
        for(String invalid:java.util.List.of(valid+"{}","{\"verified\":true,\"verified\":false}")) {
            output.set(invalid);
            assertThatThrownBy(()->resolver.resolve(home,()->false)).isInstanceOf(MaterialForecastProcessLauncher.Failure.class);
        }
        output.set(valid);when(child.exitValue()).thenReturn(1);
        assertThatThrownBy(()->resolver.resolve(home,()->false)).isInstanceOf(MaterialForecastProcessLauncher.Failure.class);
    }

    @Test void rejectedBuilderWithoutJsonReportsItsActualExitOnceInsteadOfAPathDiscoveryFailure()throws Exception {
        List<String> logs=failedPreparationLogs(1,new ByteArrayInputStream(new byte[0]),"PREPARATION_FAILED");
        assertThat(logs).singleElement().satisfies(message->assertThat(message)
                .contains("source=DEVELOPMENT_PAYLOAD", "stage=PROCESS_WAIT", "reason=HELPER_NONZERO_EXIT",
                        "exitCode=1", "stdoutBytes=0", "readerAlive=false", "readerFailed=false")
                .doesNotContain("PATH_DISCOVERY_FAILED"));
    }

    @Test void successfulExitWithInvalidJsonReportsProtocolFailureWithoutEchoingChildOutput()throws Exception {
        String raw="arbitrary private path or credential from a broken helper";
        List<String> logs=failedPreparationLogs(0,new ByteArrayInputStream(raw.getBytes(StandardCharsets.UTF_8)),"PREPARATION_FAILED");
        assertThat(logs).singleElement().satisfies(message->assertThat(message)
                .contains("source=DEVELOPMENT_PAYLOAD", "stage=JSON_PROTOCOL", "reason=INVALID_JSON",
                        "exitCode=0", "stdoutBytes="+raw.length(), "readerAlive=false", "readerFailed=false")
                .doesNotContain(raw,"PATH_DISCOVERY_FAILED"));
    }

    @Test void failedBuilderRetainsItsAllowlistedErrorCodeAndReaderFailuresRemainDistinct()throws Exception {
        byte[] receipt=json.writeValueAsBytes(Map.of("schemaVersion",1,"state","ERROR","errorCode","BASE_PYTHON_UNAVAILABLE"));
        assertThat(failedPreparationLogs(1,new ByteArrayInputStream(receipt),"BASE_PYTHON_UNAVAILABLE"))
                .singleElement().asString().contains("reason=HELPER_NONZERO_EXIT","exitCode=1");
        InputStream broken=new InputStream() {
            @Override public int read()throws IOException {throw new IOException("private child output failure");}
        };
        assertThat(failedPreparationLogs(0,broken,"PREPARATION_FAILED"))
                .singleElement().asString().contains("stage=OUTPUT_READ","reason=OUTPUT_READ_FAILED","readerFailed=true")
                .doesNotContain("private child output failure");
    }

    @Test void interruptedDevelopmentPreparationPreservesCancellationAndTheThreadInterrupt()throws Exception {
        Path repository=repository();Path home=Files.createDirectories(repository.resolve("server/target/classes"));
        var resolver=spy(new MaterialForecastDevelopmentPayload(new MaterialForecastProperties(),json));
        Process child=mock(Process.class);
        when(child.getInputStream()).thenReturn(new ByteArrayInputStream(new byte[0]));
        when(child.waitFor(anyLong(),eq(TimeUnit.MILLISECONDS))).thenThrow(new InterruptedException());
        doReturn(child).when(resolver).start(anyList(),eq(repository));
        try {
            assertThatThrownBy(()->resolver.resolve(home,()->false))
                    .isInstanceOf(MaterialForecastProcessLauncher.Failure.class).hasMessage("CONFIGURATION_PENDING");
            assertThat(Thread.currentThread().isInterrupted()).isTrue();
        } finally { Thread.interrupted(); }
    }

    private List<String> failedPreparationLogs(int exit,InputStream output,String expectedCode)throws Exception {
        Path repository=repository();Path home=Files.createDirectories(repository.resolve("server/target/classes"));
        var properties=new MaterialForecastProperties();
        var resolver=spy(new MaterialForecastDevelopmentPayload(properties,json));
        Process child=mock(Process.class);
        when(child.waitFor(anyLong(),eq(TimeUnit.MILLISECONDS))).thenReturn(true);
        when(child.exitValue()).thenReturn(exit);
        when(child.getInputStream()).thenReturn(output);
        doReturn(child).when(resolver).start(anyList(),eq(repository));
        var paths=mock(MaterialForecastHostPaths.class);
        when(paths.payloadDirectory(any())).thenAnswer(invocation->resolver.resolve(home,invocation.getArgument(0)));
        var captured=new ListAppender<ILoggingEvent>();captured.start();
        var logger=(Logger)org.slf4j.LoggerFactory.getLogger(MaterialForecastProcessLauncher.class);
        logger.addAppender(captured);
        try {
            assertThatThrownBy(()->new MaterialForecastProcessLauncher(paths,properties,json).prepare(()->false))
                    .isInstanceOf(MaterialForecastProcessLauncher.Failure.class).hasMessage(expectedCode);
            return captured.list.stream().map(ILoggingEvent::getFormattedMessage).toList();
        } finally {logger.detachAppender(captured);captured.stop();}
    }

    private Path repository()throws Exception {
        Path repository=Files.createTempDirectory(directory,"checkout-");
        Files.createFile(repository.resolve(".git"));
        Files.createDirectories(repository.resolve("server"));Files.createFile(repository.resolve("server/pom.xml"));
        Files.createDirectories(repository.resolve("services/material_forecast"));
        Files.createFile(repository.resolve("services/material_forecast/build_payload.py"));
        return repository.toRealPath();
    }
}
