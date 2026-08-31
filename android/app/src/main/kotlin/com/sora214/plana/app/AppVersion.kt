package com.sora214.plana.app

import android.app.Activity
import android.os.Build

/**
 * 读已安装包的真实版本号,供"检查更新"比对用。
 *
 * 为什么不用 Dart 侧的 `kAppVersion` 常量:那是手抄 pubspec 的,只用来显示时
 * 抄错顶多难看;一旦拿它判断"要不要更新",抄错就是全员误判 —— 要么反复提示
 * 已装的版本,要么永远不提示。系统里的版本号是安装器写进去的,不可能对不上。
 *
 * 下载完成后仍由 Android 系统安装器执行覆盖安装;本对象仅提供安装前所需的
 * 当前版本信息,APK 校验与 FileProvider 入口在 [AppUpdater]。
 */
object AppVersion {

    /** 已安装的 versionName(= pubspec 的 `version:` 前半段,如 `1.0.0-beta.1`)。 */
    fun name(activity: Activity): String =
        activity.packageManager.getPackageInfo(activity.packageName, 0).versionName ?: ""

    /** 已安装的 versionCode(= pubspec 的 `+N`)。 */
    fun code(activity: Activity): Long {
        val info = activity.packageManager.getPackageInfo(activity.packageName, 0)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }
    }
}
