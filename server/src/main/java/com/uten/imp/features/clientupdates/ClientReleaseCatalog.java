package com.uten.imp.features.clientupdates;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.StorageProperties;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import org.springframework.stereotype.Component;

/** Bounded file catalog, atomic receipts and an OS lock shared by processes using this directory. */
@Component
public class ClientReleaseCatalog {
    private final ClientUpdateProperties properties;
    private final StorageProperties storage;
    private final ObjectMapper mapper;

    public ClientReleaseCatalog(ClientUpdateProperties properties, StorageProperties storage, ObjectMapper mapper) {
        this.properties = properties;
        this.storage = storage;
        this.mapper = mapper;
    }

    synchronized <T> T locked(Operation<T> operation) {
        try {
            Path root = root();
            try (FileChannel channel = FileChannel.open(root.resolve(".catalog.lock"),
                    StandardOpenOption.CREATE, StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS);
                 var ignored = channel.lock()) {
                return operation.run(root);
            }
        } catch (IOException failure) {
            throw new ApiException(ErrorCode.PRIMARY_UNAVAILABLE, "客户端更新目录暂不可用，请联系管理员检查持久化存储");
        }
    }

    List<ClientReleaseDto.Release> list(Path root) throws IOException {
        List<ClientReleaseDto.Release> result = new ArrayList<>();
        try (var directories = Files.list(root)) {
            for (Path directory : directories.filter(path -> path.getFileName().toString()
                    .matches("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")).toList()) {
                if (result.size() >= properties.getMaxReleases())
                    throw new ApiException(ErrorCode.CONFLICT, "客户端版本目录已达到上限，请联系管理员归档历史版本");
                if (!Files.isDirectory(directory, LinkOption.NOFOLLOW_LINKS)) throw new IOException("Invalid release directory");
                Path metadata = directory.resolve("release.json");
                if (Files.isRegularFile(metadata, LinkOption.NOFOLLOW_LINKS)) result.add(read(metadata));
            }
        }
        return List.copyOf(result);
    }

    ClientReleaseDto.Release require(Path root, UUID id) throws IOException {
        Path directory = directory(root, id);
        Path metadata = directory.resolve("release.json");
        if (!Files.isDirectory(directory, LinkOption.NOFOLLOW_LINKS)
                || !Files.isRegularFile(metadata, LinkOption.NOFOLLOW_LINKS))
            throw new ApiException(ErrorCode.NOT_FOUND, "客户端版本不存在");
        ClientReleaseDto.Release release = read(metadata);
        if (!id.equals(release.id())) throw new IOException("Release identity mismatch");
        return release;
    }

    Path directory(Path root, UUID id) { return root.resolve(id.toString()); }

    void write(Path root, ClientReleaseDto.Release release) throws IOException {
        Path directory = directory(root, release.id());
        if (!Files.exists(directory, LinkOption.NOFOLLOW_LINKS)) Files.createDirectory(directory);
        if (!Files.isDirectory(directory, LinkOption.NOFOLLOW_LINKS)) throw new IOException("Invalid release directory");
        byte[] bytes = mapper.writeValueAsBytes(release);
        Path temporary = directory.resolve(".metadata-" + UUID.randomUUID() + ".tmp");
        try {
            try (FileChannel output = FileChannel.open(temporary, StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE)) {
                ByteBuffer buffer = ByteBuffer.wrap(bytes);
                while (buffer.hasRemaining()) output.write(buffer);
                output.force(true);
            }
            replace(temporary, directory.resolve("release.json"));
        } finally {
            Files.deleteIfExists(temporary);
        }
    }

    static void replace(Path source, Path destination) throws IOException {
        try {
            Files.move(source, destination, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
        } catch (AtomicMoveNotSupportedException unsupported) {
            Files.move(source, destination, StandardCopyOption.REPLACE_EXISTING);
        }
    }

    private ClientReleaseDto.Release read(Path metadata) throws IOException {
        if (Files.size(metadata) > 65536) throw new IOException("Oversized release metadata");
        return mapper.readValue(metadata.toFile(), ClientReleaseDto.Release.class);
    }

    private Path root() throws IOException {
        String configured = properties.getDirectory();
        Path root;
        if (configured != null && !configured.isBlank()) {
            root = Path.of(configured).toAbsolutePath().normalize();
        } else if ("internal".equals(storage.getProvider())) {
            if (storage.getInternal().getRoot() == null || storage.getInternal().getRoot().isBlank())
                throw new IOException("Durable internal storage is not configured");
            root = Path.of(storage.getInternal().getRoot()).toAbsolutePath().normalize().resolve("client-releases");
        } else if ("local".equals(storage.getProvider())) {
            root = Path.of(storage.getLocalDir()).toAbsolutePath().normalize().resolve("client-releases");
        } else {
            throw new IOException("A private durable client release directory must be configured");
        }
        Files.createDirectories(root);
        return root.toRealPath();
    }

    @FunctionalInterface
    interface Operation<T> { T run(Path root) throws IOException; }
}
