package com.uten.imp.common.export;

import java.io.IOException;
import java.nio.channels.*;
import java.nio.file.*;
import java.time.*;
import java.util.*;

/** OS locks protect active encryption/download copies even during slow I/O or process pauses. */
public final class ExportDownloadFiles implements AutoCloseable {
    private final Path directory;
    private final FileChannel channel;
    private final FileLock lock;
    private ExportDownloadFiles(Path directory,FileChannel channel,FileLock lock) {
        this.directory=directory;this.channel=channel;this.lock=lock;
    }
    public static ExportDownloadFiles open(Path root,UUID job) throws IOException {
        Path directory=Files.createDirectory(root.resolve(job+"-download-"+UUID.randomUUID()));
        Path lease=directory.resolve("active.lease");
        FileChannel channel=null;
        try {
            channel=FileChannel.open(lease,StandardOpenOption.CREATE_NEW,StandardOpenOption.WRITE);
            FileLock lock=channel.lock();
            if(channel.size()!=0) {lock.close();throw new IOException("Download lease was reclaimed before activation");}
            return new ExportDownloadFiles(directory,channel,lock);
        } catch(IOException|RuntimeException error) {
            if(channel!=null)channel.close();
            Files.deleteIfExists(lease);Files.deleteIfExists(directory);
            throw error;
        }
    }
    public Path file() { return directory.resolve("download.tmp"); }
    @Override public void close() throws IOException {
        try {lock.close();} finally {channel.close();}
        removeOwned(directory);
    }
    /** Bounded maintenance also runs when there is no queued report work. */
    public static void reap(Path root,Instant now) throws IOException {
        int examined=0;
        try(var directories=Files.newDirectoryStream(root, path ->
                path.getFileName().toString().matches("[0-9a-f-]{36}-download-[0-9a-f-]{36}"))) {
            for(Path directory:directories) {
                if(++examined>50)break;
                if(!Files.isDirectory(directory,LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(directory)
                        || Files.getLastModifiedTime(directory,LinkOption.NOFOLLOW_LINKS).toInstant().isAfter(now.minus(Duration.ofHours(1))))continue;
                Path lease=directory.resolve("active.lease");
                if(!knownChildren(directory))continue;
                if(Files.exists(lease,LinkOption.NOFOLLOW_LINKS)) {
                    if(!Files.isRegularFile(lease,LinkOption.NOFOLLOW_LINKS))continue;
                    boolean acquired=false;
                    try(var channel=FileChannel.open(lease,StandardOpenOption.WRITE)) {
                        try(var lock=channel.tryLock()) {
                            acquired=lock!=null;
                            if(acquired) {
                                // A creator paused between opening and locking must observe
                                // this tombstone before it can create any encrypted copy.
                                channel.position(0);channel.write(java.nio.ByteBuffer.wrap(new byte[]{1}));channel.force(true);
                                Files.deleteIfExists(directory.resolve("download.tmp"));
                                removeScratchChildren(directory);
                            }
                        }
                    } catch(OverlappingFileLockException active) {continue;}
                    if(!acquired)continue;
                }
                removeOwned(directory);
            }
        }
    }
    private static boolean knownChildren(Path directory) throws IOException {
        try(var children=Files.newDirectoryStream(directory)) {
            for(Path child:children) {
                String name=child.getFileName().toString();
                if(name.matches("report-download-pdf-[0-9a-f-]{36}")) {
                    if(!Files.isDirectory(child,LinkOption.NOFOLLOW_LINKS)||Files.isSymbolicLink(child))return false;
                } else if(!Set.of("download.tmp","active.lease").contains(name)
                        || !Files.isRegularFile(child,LinkOption.NOFOLLOW_LINKS))return false;
            }
        }
        return true;
    }
    private static void removeOwned(Path directory) throws IOException {
        if(!knownChildren(directory))return;
        removeScratchChildren(directory);
        Files.deleteIfExists(directory.resolve("download.tmp"));
        Files.deleteIfExists(directory.resolve("active.lease"));
        Files.deleteIfExists(directory);
    }
    private static void removeScratchChildren(Path directory)throws IOException {
        try(var children=Files.newDirectoryStream(directory,"report-download-pdf-*")) {
            for(Path child:children)removeDocumentScratch(child);
        }
    }
    /** Caller must own the worker session slot or the private download directory's OS lease. */
    public static void removeDocumentScratch(Path directory)throws IOException {
        if(Files.isSymbolicLink(directory)||!Files.isDirectory(directory,LinkOption.NOFOLLOW_LINKS))
            throw new IOException("Invalid export scratch directory");
        StreamingPdfDocumentWriter.removePrivateDirectory(directory);
    }
}
