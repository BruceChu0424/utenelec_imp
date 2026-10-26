package com.uten.imp.common.export;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import java.nio.channels.FileChannel;
import java.nio.file.*;
import java.nio.file.attribute.FileTime;
import java.time.*;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;

class ExportDownloadFilesTest {
    @TempDir Path root;
    @Test void anOldActiveDownloadIsProtectedByItsOperatingSystemLease() throws Exception {
        try(var active=ExportDownloadFiles.open(root,UUID.randomUUID())) {
            Files.write(active.file(),new byte[]{1,2,3});
            Files.setLastModifiedTime(active.file().getParent(),FileTime.from(Instant.now().minus(Duration.ofHours(3))));
            ExportDownloadFiles.reap(root,Instant.now());
            assertArrayEquals(new byte[]{1,2,3},Files.readAllBytes(active.file()));
        }
        try(var files=Files.list(root)) {assertEquals(0,files.count());}
    }
    @Test void aCrashedPrivateCopyIsReapedWhileUnknownFilesAndNewCreatorsRemain() throws Exception {
        Path orphan=Files.createDirectory(root.resolve(UUID.randomUUID()+"-download-"+UUID.randomUUID()));
        Files.write(orphan.resolve("active.lease"),new byte[0]);Files.write(orphan.resolve("download.tmp"),new byte[]{7});
        Files.setLastModifiedTime(orphan,FileTime.from(Instant.now().minus(Duration.ofHours(2))));
        Path unknown=Files.createDirectory(root.resolve(UUID.randomUUID()+"-download-"+UUID.randomUUID()));
        Files.writeString(unknown.resolve("original.txt"),"keep");
        Files.setLastModifiedTime(unknown,FileTime.from(Instant.now().minus(Duration.ofHours(2))));
        Path newDirectory=Files.createDirectory(root.resolve(UUID.randomUUID()+"-download-"+UUID.randomUUID()));
        ExportDownloadFiles.reap(root,Instant.now());
        assertFalse(Files.exists(orphan));assertTrue(Files.exists(newDirectory));
        assertEquals("keep",Files.readString(unknown.resolve("original.txt")));
    }
    @Test void aCreatorPausedBeforeAcquiringItsLeaseMustObserveTheReaperTombstone() throws Exception {
        Path orphan=Files.createDirectory(root.resolve(UUID.randomUUID()+"-download-"+UUID.randomUUID()));
        Path lease=Files.write(orphan.resolve("active.lease"),new byte[0]);
        try(var creator=FileChannel.open(lease,StandardOpenOption.READ,StandardOpenOption.WRITE)) {
            Files.setLastModifiedTime(orphan,FileTime.from(Instant.now().minus(Duration.ofHours(2))));
            try {ExportDownloadFiles.reap(root,Instant.now());} catch(java.nio.file.FileSystemException sharingOnWindows) {
                // Windows may retain the leased namespace until the paused creator closes its handle.
            }
            assertEquals(1,creator.size());
        }
        ExportDownloadFiles.reap(root,Instant.now());
        assertFalse(Files.exists(orphan));
    }
    @Test void pdfScratchIsProtectedWhileActiveAndRemovedAfterACrash() throws Exception {
        Path directory;
        try(var active=ExportDownloadFiles.open(root,UUID.randomUUID())) {
            directory=active.file().getParent();
            Path scratch=Files.createDirectory(directory.resolve("report-download-pdf-"+UUID.randomUUID()));
            Files.write(scratch.resolve("pdfbox.tmp"),new byte[]{4,2});
            Files.setLastModifiedTime(directory,FileTime.from(Instant.now().minus(Duration.ofHours(3))));
            ExportDownloadFiles.reap(root,Instant.now());
            assertTrue(Files.exists(scratch.resolve("pdfbox.tmp")));
        }
        assertFalse(Files.exists(directory));
        Path orphan=Files.createDirectory(root.resolve(UUID.randomUUID()+"-download-"+UUID.randomUUID()));
        Files.write(orphan.resolve("active.lease"),new byte[0]);
        Path scratch=Files.createDirectory(orphan.resolve("report-download-pdf-"+UUID.randomUUID()));
        Files.write(scratch.resolve("pdfbox.tmp"),new byte[]{9});
        Files.setLastModifiedTime(orphan,FileTime.from(Instant.now().minus(Duration.ofHours(2))));
        ExportDownloadFiles.reap(root,Instant.now());assertFalse(Files.exists(orphan));
        Path unknown=Files.createDirectory(root.resolve("private-business"));
        assertThrows(java.io.IOException.class,()->ExportDownloadFiles.removeDocumentScratch(unknown));
        assertTrue(Files.exists(unknown));
    }
}
