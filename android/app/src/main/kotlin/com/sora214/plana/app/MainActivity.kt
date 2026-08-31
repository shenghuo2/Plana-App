package com.sora214.plana.app

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val updateExecutor = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 启动即建通道:否则装完到第一次生成之间,系统设置里的「通知类别」是空的,
        // 用户想预先开横幅/声音/振动都没得开。
        LiveProgressService.ensureChannels(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        LiveProgressService.start(
                            this,
                            call.argument("title"),
                            call.argument("text"),
                            call.argument<Int>("total") ?: 0,
                        )
                        result.success(null)
                    }

                    "update" -> {
                        LiveProgressService.update(
                            call.argument<Int>("cur") ?: 0,
                            call.argument<Int>("total") ?: 0,
                            call.argument<Boolean>("indeterminate") ?: false,
                            call.argument<String>("title") ?: "Plana",
                            call.argument<String>("text") ?: "",
                            call.argument<String>("short") ?: "",
                        )
                        result.success(null)
                    }

                    "finish" -> {
                        LiveProgressService.finish(
                            call.argument<String>("title") ?: "Plana",
                            call.argument<String>("text") ?: "",
                            call.argument<String>("short") ?: "",
                            call.argument<Boolean>("keep") ?: true,
                        )
                        result.success(null)
                    }

                    "stop" -> {
                        LiveProgressService.stop()
                        result.success(null)
                    }

                    "capabilities" -> result.success(
                        mapOf(
                            "sdkInt" to Build.VERSION.SDK_INT,
                            "canPromote" to LiveProgressService.canPromote(this),
                        ),
                    )

                    "requestNotificationPermission" -> {
                        if (Build.VERSION.SDK_INT >= 33 &&
                            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
                            PackageManager.PERMISSION_GRANTED
                        ) {
                            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1001)
                        }
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }

        // 更新:版本号从系统读;APK 解析放工作线程,避免签名校验卡住 Flutter UI。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, UPDATE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "info" -> result.success(
                        mapOf(
                            "versionCode" to AppVersion.code(this),
                            "versionName" to AppVersion.name(this),
                        ),
                    )

                    "install" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("invalid_update", "缺少安装包路径", null)
                        } else {
                            updateExecutor.execute {
                                try {
                                    val apk = AppUpdater.validate(this, path)
                                    runOnUiThread {
                                        try {
                                            val launched = AppUpdater.launch(this, apk)
                                            result.success(
                                                if (launched) "launched" else "permission_required",
                                            )
                                        } catch (e: Exception) {
                                            result.error(
                                                "update_install_failed",
                                                e.message ?: "无法打开系统安装窗口",
                                                null,
                                            )
                                        }
                                    }
                                } catch (e: Exception) {
                                    runOnUiThread {
                                        result.error(
                                            "invalid_update",
                                            e.message ?: "安装包校验失败",
                                            null,
                                        )
                                    }
                                }
                            }
                        }
                    }

                    "canInstallPackages" -> result.success(AppUpdater.canInstallPackages(this))

                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        updateExecutor.shutdownNow()
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "plana/live_progress"
        private const val UPDATE_CHANNEL = "plana/update"
    }
}
