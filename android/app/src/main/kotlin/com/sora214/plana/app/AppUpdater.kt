package com.sora214.plana.app

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
import java.security.MessageDigest

/** 校验缓存中的 APK,并把安装交给 Android 系统安装器。 */
object AppUpdater {

    /**
     * 只接受应用私有 cache/updates 下的文件,随后检查包名、递增版本码与签名链。
     * SHA-256 已在 Dart 下载层核过;这里再钉住 Android 真正关心的身份信息。
     */
    fun validate(activity: Activity, rawPath: String): File {
        val root = File(activity.cacheDir, "updates").canonicalFile
        val apk = File(rawPath).canonicalFile
        val insideRoot = apk.path.startsWith(root.path + File.separator)
        require(insideRoot && apk.isFile && apk.extension.equals("apk", ignoreCase = true)) {
            "安装包不在受信任的更新缓存中"
        }

        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            @Suppress("DEPRECATION")
            PackageManager.GET_SIGNATURES
        }
        @Suppress("DEPRECATION")
        val archive = activity.packageManager.getPackageArchiveInfo(apk.path, flags)
            ?: error("Android 无法解析安装包")
        require(archive.packageName == activity.packageName) { "安装包的应用 ID 不匹配" }

        @Suppress("DEPRECATION")
        val installed = activity.packageManager.getPackageInfo(activity.packageName, flags)
        require(versionCode(archive) > versionCode(installed)) { "安装包版本码没有高于当前版本" }

        val installedCurrent = currentSignerDigests(installed)
        val archiveHistory = signerHistoryDigests(archive)
        require(installedCurrent.isNotEmpty() && archiveHistory.containsAll(installedCurrent)) {
            "安装包签名与当前应用不一致"
        }
        return apk
    }

    /** 返回 false 时已打开“允许此来源”设置页,调用方应在应用恢复后重试。 */
    fun launch(activity: Activity, apk: File): Boolean {
        if (!canInstallPackages(activity)) {
            activity.startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:${activity.packageName}"),
                ),
            )
            return false
        }

        val uri = FileProvider.getUriForFile(
            activity,
            "${activity.packageName}.update_files",
            apk,
        )
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        require(intent.resolveActivity(activity.packageManager) != null) { "系统中没有可用的安装器" }
        activity.startActivity(intent)
        return true
    }

    fun canInstallPackages(activity: Activity): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            activity.packageManager.canRequestPackageInstalls()

    private fun versionCode(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }

    private fun currentSignerDigests(info: PackageInfo): Set<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.signingInfo?.apkContentsSigners.orEmpty().mapTo(mutableSetOf(), ::digest)
        } else {
            @Suppress("DEPRECATION")
            info.signatures.orEmpty().mapTo(mutableSetOf(), ::digest)
        }

    private fun signerHistoryDigests(info: PackageInfo): Set<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val signing = info.signingInfo ?: return emptySet()
            val signatures = if (signing.hasMultipleSigners()) {
                signing.apkContentsSigners
            } else {
                signing.signingCertificateHistory
            }
            signatures.orEmpty().mapTo(mutableSetOf(), ::digest)
        } else {
            @Suppress("DEPRECATION")
            info.signatures.orEmpty().mapTo(mutableSetOf(), ::digest)
        }

    private fun digest(signature: android.content.pm.Signature): String =
        MessageDigest.getInstance("SHA-256")
            .digest(signature.toByteArray())
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }
}
