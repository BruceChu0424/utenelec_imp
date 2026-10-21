package com.uten.imp.features.admin.materialforecast;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.config.props.MaterialForecastProperties;
import com.uten.imp.config.props.StorageProperties;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.ByteArrayInputStream;
import java.nio.file.Files;
import java.nio.file.Path;
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

    private Path repository()throws Exception {
        Path repository=Files.createDirectory(directory.resolve("checkout"));
        Files.createFile(repository.resolve(".git"));
        Files.createDirectories(repository.resolve("server"));Files.createFile(repository.resolve("server/pom.xml"));
        Files.createDirectories(repository.resolve("services/material_forecast"));
        Files.createFile(repository.resolve("services/material_forecast/build_payload.py"));
        return repository.toRealPath();
    }
}
