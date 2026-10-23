package com.uten.uten_imp

import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.concurrent.Executors

/** Installs an update over the existing package; never uninstalls or clears data. */
@Suppress("DEPRECATION")
internal class ClientUpdateBridge(
    private val activity: FlutterActivity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "com.uten.imp/client_update")
    private val worker = Executors.newSingleThreadExecutor()
    @Volatile private var closed = false
    @Volatile private var installing = false

    init { channel.setMethodCallHandler(this) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getInstallContext" -> {
                val installed = installedPackage()
                val staging = stagingDirectory()
                val primaryAbi = Build.SUPPORTED_ABIS.firstOrNull().orEmpty()
                val architecture = when (primaryAbi) {
                    "arm64-v8a" -> "arm64"
                    "x86_64" -> "x64"
                    else -> primaryAbi
                }
                result.success(mapOf(
                    "platform" to "android",
                    "architecture" to architecture,
                    "currentVersion" to (installed.versionName ?: ""),
                    "currentBuild" to versionCode(installed),
                    "stagingDirectory" to staging.absolutePath,
                    "supportsInPlaceUpdate" to true,
                    "requiresSystemConfirmation" to true,
                ))
            }
            "installUpdate" -> install(call, result)
            else -> result.notImplemented()
        }
    }

    private fun install(call: MethodCall, result: MethodChannel.Result) {
        val packagePath = call.argument<String>("packagePath")
        val expectedHash = call.argument<String>("sha256")
        val expectedBuild = call.argument<Number>("buildNumber")?.toLong() ?: 0L
        if (packagePath == null || expectedHash == null ||
            !expectedHash.matches(Regex("^[a-f0-9]{64}$")) || expectedBuild <= 0L) {
            result.error("INVALID_UPDATE", "Update path, SHA-256 or build is invalid.", null)
            return
        }
        if (installing) {
            result.error("UPDATE_IN_PROGRESS", "An update is already being prepared.", null)
            return
        }
        // Android requires the user to trust this installation source. Return a
        // distinct error so Flutter can explain the setting and offer retry.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !activity.packageManager.canRequestPackageInstalls()) {
            try {
                activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:${activity.packageName}")))
                result.error("INSTALL_PERMISSION_REQUIRED",
                    "Allow updates from this app in Android settings, then retry.", null)
            } catch (failure: Exception) {
                result.error("INSTALL_PERMISSION_UNAVAILABLE", failure.message, null)
            }
            return
        }
        installing = true
        worker.execute {
            try {
                val apk = verifyAndStage(packagePath, expectedHash, expectedBuild)
                activity.runOnUiThread {
                    installing = false
                    if (closed) return@runOnUiThread
                    try {
                        val uri = FileProvider.getUriForFile(activity,
                            "${activity.packageName}.clientupdates", apk)
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, "application/vnd.android.package-archive")
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            putExtra(Intent.EXTRA_NOT_UNKNOWN_SOURCE, true)
                        }
                        activity.startActivity(intent)
                        // This is an installer handoff, not proof of installation.
                        // Version is checked again when the client resumes/restarts.
                        result.success(mapOf("status" to "installerOpened"))
                    } catch (failure: Exception) {
                        result.error("INSTALLER_UNAVAILABLE", failure.message, null)
                    }
                }
            } catch (failure: Exception) {
                installing = false
                activity.runOnUiThread {
                    if (!closed) result.error("UPDATE_VERIFICATION_FAILED", failure.message, null)
                }
            }
        }
    }

    private fun verifyAndStage(path: String, expectedHash: String, expectedBuild: Long): File {
        val staging = stagingDirectory().canonicalFile
        val source = File(path)
        require(source.isAbsolute && source.extension == "apk" && source.isFile) {
            "Update must be a local APK."
        }
        val canonical = source.canonicalFile
        require(canonical.path.startsWith(staging.path + File.separator) &&
            canonical.path == source.absoluteFile.normalize().path) {
            "Update must be inside private app staging without links."
        }
        require(canonical.length() in 1L..(512L * 1024L * 1024L)) { "APK size is invalid." }
        val verifiedDirectory = File(staging, "verified").apply { mkdirs() }.canonicalFile
        require(verifiedDirectory.path == File(staging, "verified").absolutePath) {
            "Verified directory must not be a link."
        }
        val verified = File(verifiedDirectory, "$expectedHash.apk")
        // A distinct immutable copy prevents a download retry replacing the APK
        // after it has been checked and handed to the package installer.
        val temporary = File.createTempFile("verify-", ".apk", verifiedDirectory)
        try {
            val digest = MessageDigest.getInstance("SHA-256")
            FileInputStream(canonical).use { input ->
                FileOutputStream(temporary).use { output ->
                    val buffer = ByteArray(65536)
                    var total = 0L
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        total += count
                        require(total <= 512L * 1024L * 1024L) { "APK size exceeds 512 MiB." }
                        digest.update(buffer, 0, count)
                        output.write(buffer, 0, count)
                    }
                    output.fd.sync()
                }
            }
            val actualHash = digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
            require(actualHash == expectedHash) { "Downloaded APK SHA-256 does not match." }
            val manager = activity.packageManager
            val candidate = manager.getPackageArchiveInfo(temporary.path, signatureFlags())
                ?: throw IllegalArgumentException("APK metadata or signing information is invalid.")
            val installed = installedPackage()
            require(candidate.packageName == activity.packageName) { "APK belongs to another application." }
            require(versionCode(candidate) == expectedBuild && expectedBuild > versionCode(installed)) {
                "APK versionCode must match this newer release."
            }
            val currentSigners = signers(installed)
            val candidateSigners = signers(candidate)
            require(currentSigners.isNotEmpty() && currentSigners == candidateSigners) {
                "APK must be signed with the currently installed application's signing certificate."
            }
            if (verified.exists()) require(verified.delete()) { "Could not replace previous verified APK." }
            require(temporary.renameTo(verified)) { "Could not finish APK staging." }
            verified.setReadable(true, true)
            verified.setWritable(false, false)
            return verified
        } finally { temporary.delete() }
    }

    private fun stagingDirectory(): File = File(activity.cacheDir, "client-updates").apply {
        check(isDirectory || mkdirs()) { "Could not create app update staging." }
    }

    private fun installedPackage(): PackageInfo =
        activity.packageManager.getPackageInfo(activity.packageName, signatureFlags())

    private fun signatureFlags(): Int = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
        PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES

    private fun versionCode(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode else info.versionCode.toLong()

    private fun signers(info: PackageInfo): Set<String> {
        val values = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
            info.signingInfo?.apkContentsSigners else info.signatures
        return values.orEmpty().map { signature ->
            MessageDigest.getInstance("SHA-256").digest(signature.toByteArray())
                .joinToString("") { "%02x".format(it.toInt() and 255) }
        }.toSet()
    }

    fun close() {
        closed = true
        channel.setMethodCallHandler(null)
        worker.shutdown()
    }
}
