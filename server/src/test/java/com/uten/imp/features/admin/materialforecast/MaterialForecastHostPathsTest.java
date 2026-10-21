package com.uten.imp.features.admin.materialforecast;

import com.uten.imp.config.props.*;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import java.nio.file.*;
import java.util.List;
import static org.assertj.core.api.Assertions.*;

class MaterialForecastHostPathsTest {
    @TempDir Path directory;
    @Test void movingTheCompanyStorageRootDerivesAFreshStateDirectoryWithoutChangingPolicy() {
        var storage=new StorageProperties();storage.setProvider("internal");storage.getInternal().setRoot(directory.resolve("company-one").toString());
        var paths=new MaterialForecastHostPaths(storage,new MaterialForecastProperties());assertThat(paths.stateDirectory()).isEqualTo(directory.resolve("company-one/material-forecast"));
        storage.getInternal().setRoot(directory.resolve("company-two").toString());assertThat(paths.stateDirectory()).isEqualTo(directory.resolve("company-two/material-forecast"));
        assertThat(Files.exists(paths.stateDirectory())).as("Read-only path discovery does not create files").isFalse();
    }
    @Test void explicitSnapshotOverrideIsBootstrapOnlyAndMustBeAbsolute() {
        var properties=new MaterialForecastProperties();properties.setSnapshotDirectory(directory.resolve("diagnostic").toString());
        var paths=new MaterialForecastHostPaths(new StorageProperties(),properties);assertThat(paths.stateDirectory()).isEqualTo(directory.resolve("diagnostic"));
        properties.setSnapshotDirectory("relative");assertThatThrownBy(paths::stateDirectory).isInstanceOf(IllegalStateException.class);
    }
    @Test void theSignedServerJarLayoutNeverDuplicatesTheServerPathSegment() {
        Path release=directory.resolve("releases/v1");
        assertThat(MaterialForecastHostPaths.packagedPayload(release.resolve("server"))).isEqualTo(release.resolve("server/material_forecast"));
        assertThat(MaterialForecastHostPaths.packagedPayload(release)).isEqualTo(release.resolve("server/material_forecast"));
    }
    @Test void childEnvironmentNeverInheritsServerCredentialsOrPythonImportOverrides() {
        var builder=MaterialForecastProcessLauncher.builder(List.of("fixed-python","fixed-worker"),directory);
        assertThat(builder.environment()).doesNotContainKeys("PATH","PYTHONPATH","PYTHONHOME","SPRING_DATASOURCE_PASSWORD","UTEN_JWT_SECRET","UTEN_CRYPTO_KEY","AWS_SECRET_ACCESS_KEY");
        assertThat(builder.environment()).containsEntry("NUMBA_NUM_THREADS","1").containsEntry("PYTHONUTF8","1");
    }
    @Test void structuredPreparationFailuresExposeOnlyTheFixedSafeCode()throws Exception {
        var json=new com.fasterxml.jackson.databind.ObjectMapper();
        assertThat(MaterialForecastProcessLauncher.failureCode(json.readTree("{\"schemaVersion\":1,\"state\":\"ERROR\",\"errorCode\":\"BASE_PYTHON_UNAVAILABLE\"}"))).isEqualTo("BASE_PYTHON_UNAVAILABLE");
        assertThat(MaterialForecastProcessLauncher.failureCode(json.readTree("{\"schemaVersion\":1,\"state\":\"ERROR\",\"errorCode\":\"private path and raw traceback\"}"))).isEqualTo("PREPARATION_FAILED");
    }
}
