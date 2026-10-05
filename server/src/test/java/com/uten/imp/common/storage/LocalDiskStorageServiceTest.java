package com.uten.imp.common.storage;

import com.uten.imp.config.props.StorageProperties;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.assertThrows;

class LocalDiskStorageServiceTest {

    @TempDir
    Path directory;

    @Test
    void uploadNeverOverwritesAnExistingStorageKey() throws Exception {
        LocalDiskStorageService storage = storage();
        byte[] original = "trusted-original".getBytes(StandardCharsets.UTF_8);
        storage.store("fixed-key.txt", new ByteArrayInputStream(original), original.length, "text/plain");

        byte[] replacement = "attacker-replacement".getBytes(StandardCharsets.UTF_8);
        assertThrows(IllegalStateException.class, () -> storage.store(
                "fixed-key.txt", new ByteArrayInputStream(replacement), replacement.length, "text/plain"));
        assertArrayEquals(original,
                Files.readAllBytes(directory.resolve("staging").resolve("fixed-key.txt")));
    }

    @Test
    void mismatchedDeclaredLengthLeavesNoVisibleObject() throws Exception {
        LocalDiskStorageService storage = storage();
        byte[] bytes = "short".getBytes(StandardCharsets.UTF_8);

        assertThrows(IllegalStateException.class, () -> storage.store(
                "short.txt", new ByteArrayInputStream(bytes), bytes.length + 10L, "text/plain"));
        assertFalse(Files.exists(directory.resolve("staging").resolve("short.txt")));
    }

    @Test
    void presignedRawPathsAreApiBaseRelativeAndStartWithSlash() throws Exception {
        LocalDiskStorageService storage = storage();
        StorageService.PresignedUpload upload = storage.presignUpload(
                new StorageService.UploadRequest(
                        "EXPENSE_CLAIM", "receipt.png", "image/png", 8));

        assertTrue(upload.url().startsWith("/attachments/raw/"));
        assertFalse(upload.url().startsWith("/api/"));
        assertEquals(
                "/attachments/raw/fixed.png",
                storage.presignDownload("fixed.png", null).url());
    }

    @Test
    void promotionCopiesIntoFinalAndLeavesStagingForOutboxCleanup() throws Exception {
        LocalDiskStorageService storage = storage();
        byte[] bytes = "trusted".getBytes(StandardCharsets.UTF_8);
        storage.store("fixed.txt", new ByteArrayInputStream(bytes), bytes.length, "text/plain");
        StorageService.StoredObject staged = storage.describe("fixed.txt");

        StorageService.StoredObject promoted = storage.promoteToFinal("fixed.txt", staged);

        assertEquals(bytes.length, promoted.size());
        assertTrue(Files.exists(directory.resolve("staging").resolve("fixed.txt")));
        assertArrayEquals(bytes,
                Files.readAllBytes(directory.resolve("final").resolve("fixed.txt")));
        try (var input = storage.read("fixed.txt")) {
            assertArrayEquals(bytes, input.readAllBytes());
        }
    }

    @Test
    void inspectObjectClassifiesAbsentPresentDirectoryAndFlatLegacyLayout() throws Exception {
        LocalDiskStorageService storage = storage();
        byte[] bytes = "local original".getBytes(StandardCharsets.UTF_8);
        storage.store("inspect.txt", new ByteArrayInputStream(bytes), bytes.length, "text/plain");
        storage.promoteToFinal("inspect.txt", storage.describe("inspect.txt"));
        assertTrue(storage.inspectObject(StorageService.ObjectLocation.STAGING, "inspect.txt").exists());
        assertEquals(bytes.length, storage.inspectObject(StorageService.ObjectLocation.FINAL, "inspect.txt").size());
        storage.delete("inspect.txt", null);
        assertFalse(storage.inspectObject(StorageService.ObjectLocation.FINAL, "inspect.txt").exists());

        Files.createDirectory(directory.resolve("final").resolve("folder.txt"));
        StorageObjectProblem problem = assertThrows(StorageObjectProblem.class,
                () -> storage.inspectObject(StorageService.ObjectLocation.FINAL, "folder.txt"));
        assertEquals(StorageObjectProblem.Kind.NOT_REGULAR_FILE, problem.kind());

        Files.write(directory.resolve("flat.txt"), bytes);
        assertThrows(StorageLegacyLayoutException.class,
                () -> storage.inspectObject(StorageService.ObjectLocation.FINAL, "flat.txt"));
        assertFalse(storage.inspectPath(directory.resolve("final").resolve("gone.txt")).exists());

        Files.move(directory.resolve("staging"), directory.resolve("staging-offline"));
        assertThrows(StorageResourceUnavailableException.class,
                () -> storage.inspectObject(StorageService.ObjectLocation.STAGING, "inspect.txt"));
    }

    private LocalDiskStorageService storage() throws Exception {
        StorageProperties properties = new StorageProperties();
        properties.setLocalDir(directory.toString());
        LocalDiskStorageService storage = new LocalDiskStorageService(properties);
        storage.init();
        return storage;
    }
}
