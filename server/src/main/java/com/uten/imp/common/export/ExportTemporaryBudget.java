package com.uten.imp.common.export;

import java.io.*;
import java.nio.file.*;
import java.util.*;

/** The existing XLSX temporary-write budget, shared by all document writers. */
final class ExportTemporaryBudget {
    final Path directory;
    final List<Path> files=new ArrayList<>();
    private long bytes;
    private long checked;
    ExportTemporaryBudget(Path directory) {this.directory=Objects.requireNonNull(directory);}
    long bytes(){return bytes;}
    long remaining(){return Math.max(0,ExportResourceLimits.SHEET_TEMP_BYTES-bytes);}
    void before(int amount)throws IOException {
        bytes+=amount;
        if(bytes>ExportResourceLimits.SHEET_TEMP_BYTES)throw new IOException("Export temporary space limit exceeded");
        if(bytes-checked>=1024*1024){checked=bytes;requireFreeReserve();}
    }
    void requireFreeReserve()throws IOException {
        if(Files.getFileStore(directory).getUsableSpace()<ExportResourceLimits.FREE_RESERVE_BYTES)
            throw new IOException("Export free space reserve reached");
    }
    OutputStream guard(OutputStream output) {
        return new FilterOutputStream(output){
            @Override public void write(int value)throws IOException{before(1);out.write(value);}
            @Override public void write(byte[] value,int offset,int length)throws IOException{before(length);out.write(value,offset,length);}
        };
    }
    void cleanupFiles()throws IOException {
        IOException failure=null;
        for(Path file:files)try{Files.deleteIfExists(file);}catch(IOException error){
            if(failure==null)failure=error;else failure.addSuppressed(error);
        }
        if(failure!=null)throw failure;
    }

    static OutputStream artifactOutput(OutputStream output,Path directory,Runnable checkpoint)throws IOException {
        return artifactOutput(output,directory,checkpoint,ExportResourceLimits.ARTIFACT_BYTES);
    }
    static OutputStream artifactOutput(OutputStream output,Path directory,Runnable checkpoint,long maximumBytes)throws IOException {
        if(maximumBytes<1||maximumBytes>ExportResourceLimits.ARTIFACT_BYTES)throw new IllegalArgumentException("Invalid export output bound");
        if(directory!=null&&Files.getFileStore(directory).getUsableSpace()<ExportResourceLimits.FREE_RESERVE_BYTES)
            throw new IOException("Export free space reserve reached");
        return new FilterOutputStream(output) {
            long bytes,spaceCheck,nextCheckpoint;
            private void before(int amount)throws IOException {
                if(Thread.currentThread().isInterrupted())throw new java.util.concurrent.CancellationException();
                bytes+=amount;
                if(bytes>maximumBytes)throw new IOException("Export file size limit exceeded");
                long now=System.nanoTime();
                if(now>=nextCheckpoint){checkpoint.run();nextCheckpoint=now+java.util.concurrent.TimeUnit.SECONDS.toNanos(1);}
                if(directory!=null&&bytes-spaceCheck>=1024*1024){
                    spaceCheck=bytes;
                    if(Files.getFileStore(directory).getUsableSpace()<ExportResourceLimits.FREE_RESERVE_BYTES)
                        throw new IOException("Export free space reserve reached");
                }
            }
            @Override public void write(int value)throws IOException{before(1);out.write(value);}
            @Override public void write(byte[] value,int offset,int length)throws IOException{before(length);out.write(value,offset,length);}
        };
    }
}
