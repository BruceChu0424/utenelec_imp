package com.uten.imp.features.admin.serveroperations;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Clock;

/** Owns only the anonymous host projection file; the production controller and HTTP filters stay real. */
public final class PublicMaintenanceTestFixture {
    private final Path statusFile;

    public PublicMaintenanceTestFixture() throws IOException {
        statusFile = Files.createTempFile("uten-http-maintenance-", ".json");
        statusFile.toFile().deleteOnExit();
        available();
    }

    public PublicMaintenanceController controller() {
        return new PublicMaintenanceController(new ObjectMapper(), statusFile, Clock.systemUTC());
    }

    public void available() throws IOException {
        Files.writeString(statusFile, "{\"schemaVersion\":1,\"state\":\"available\"}", StandardCharsets.UTF_8);
    }

    public void unavailable() throws IOException {
        Files.deleteIfExists(statusFile);
    }
}
