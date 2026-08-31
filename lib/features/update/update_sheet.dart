import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_info.dart';
import '../../core/theme/app_theme.dart';
import '../generate/widgets/common.dart' show hintSnack;
import '../profile/widgets/settings_ui.dart';
import 'update_download.dart';
import 'update_service.dart';

/// 「检查更新」行。放在关于页,按设置行规范:单行 + 右侧状态,不写副标题。
class UpdateRow extends ConsumerStatefulWidget {
  const UpdateRow({super.key});

  @override
  ConsumerState<UpdateRow> createState() => _UpdateRowState();
}

class _UpdateRowState extends ConsumerState<UpdateRow> {
  bool _checking = false;
  UpdateCheck? _result;
  bool _failed = false;

  Future<void> _check() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _failed = false;
    });
    try {
      final installed = await installedInfo();
      final release = installed.isKnown
          ? await fetchLatestRelease(installed.versionName)
          : null;
      if (!mounted) return;
      final check = UpdateCheck(installed: installed, release: release);
      setState(() => _result = check);
      if (check.hasUpdate) {
        await showUpdateSheet(context, check);
      } else if (kUpdateGithubRepo.isEmpty || !installed.isKnown) {
        // 没填仓库 / 拿不到本机版本 —— 不是错误,别报红
        hintSnack(context, '暂无更新信息', icon: Icons.info_outline);
      } else {
        hintSnack(context, '已是最新版本', icon: Icons.check_circle_outline);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _failed = true);
      hintSnack(context, '$e', icon: Icons.error_outline);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final r = _result;
    final (String value, Color? color) = switch (null) {
      _ when _checking => ('检查中…', null),
      _ when _failed => ('检查失败', scheme.error),
      _ when r != null && r.hasUpdate => (
        '新版本 ${r.release!.display}',
        scheme.tertiary,
      ),
      _ when r != null => ('已是最新', null),
      _ => ('', null),
    };
    return SettingsRow(
      icon: Icons.system_update_alt,
      title: '检查更新',
      value: value,
      valueColor: color,
      onTap: _check,
    );
  }
}

/// 新版本提示。下载与校验留在应用内,最后只唤起 Android 系统安装窗口。
Future<void> showUpdateSheet(BuildContext context, UpdateCheck check) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    builder: (_) =>
        _UpdateSheet(release: check.release!, installed: check.installed),
  );
}

class _UpdateSheet extends StatefulWidget {
  const _UpdateSheet({required this.release, required this.installed});

  final GithubRelease release;
  final InstalledInfo installed;

  @override
  State<_UpdateSheet> createState() => _UpdateSheetState();
}

class _UpdateSheetState extends State<_UpdateSheet> {
  UpdateDownloader? _downloader;
  AppLifecycleListener? _lifecycle;
  File? _apk;
  bool _busy = false;
  bool _waitingPermission = false;
  int _received = 0;
  int _total = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onResume: () {
        if (_waitingPermission && !_busy) {
          unawaited(_continueAfterPermission());
        }
      },
    );
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _downloader?.close();
    super.dispose();
  }

  Future<void> _start() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _waitingPermission = false;
      _error = null;
      if (_apk == null) {
        _received = 0;
        _total = 0;
      }
    });
    try {
      var apk = _apk;
      if (apk == null || !await apk.exists()) {
        _downloader?.close();
        final downloader = UpdateDownloader();
        _downloader = downloader;
        apk = await downloader.download(
          widget.release,
          onProgress: (received, total) {
            if (!mounted) return;
            setState(() {
              _received = received;
              _total = total;
            });
          },
        );
        if (!mounted) return;
        _apk = apk;
      }
      final result = await launchUpdateInstaller(apk);
      if (!mounted) return;
      if (result == InstallLaunchResult.launched) {
        Navigator.pop(context);
      } else {
        setState(() => _waitingPermission = true);
      }
    } on UpdateCancelledException {
      // 用户主动取消,弹层随后关闭,无需再提示错误。
    } catch (e) {
      if (!mounted) return;
      final message = '$e';
      setState(() => _error = message);
      hintSnack(context, message, icon: Icons.error_outline);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _continueAfterPermission() async {
    setState(() {
      _busy = true;
      _waitingPermission = false;
      _error = null;
    });
    try {
      final allowed = await canInstallUpdatePackages();
      if (!mounted) return;
      if (!allowed) {
        setState(() => _error = '未授予安装应用权限');
        return;
      }
      final apk = _apk;
      if (apk == null || !await apk.exists()) {
        setState(() => _error = '更新缓存已失效,请重新下载');
        return;
      }
      final result = await launchUpdateInstaller(apk);
      if (!mounted) return;
      if (result == InstallLaunchResult.launched) {
        Navigator.pop(context);
      } else {
        setState(() => _error = '未授予安装应用权限');
      }
    } catch (e) {
      if (!mounted) return;
      final message = '$e';
      setState(() => _error = message);
      hintSnack(context, message, icon: Icons.error_outline);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _cancelOrClose() {
    if (_busy) {
      _downloader?.cancel();
      setState(() => _busy = false);
    }
    Navigator.pop(context);
  }

  String get _progressText {
    if (_received <= 0) return '准备下载…';
    if (_total <= 0) return '已下载 ${_formatBytes(_received)}';
    return '${_formatBytes(_received)} / ${_formatBytes(_total)}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final progress = _total > 0 ? (_received / _total).clamp(0.0, 1.0) : null;
    final hasCachedApk = _apk != null;
    return PopScope(
      canPop: !_busy,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.system_update_alt,
                      size: 26,
                      color: scheme.tertiary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '新版本 ${widget.release.display}',
                            style: context.texts.titleMedium!.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '当前 ${widget.installed.versionName}',
                            style: context.texts.bodySmall!.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (widget.release.notes.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 260),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: SingleChildScrollView(
                      child: Text(
                        widget.release.notes,
                        style: context.texts.bodySmall!.copyWith(height: 1.55),
                      ),
                    ),
                  ),
                ],
                if (_busy || _waitingPermission || _error != null) ...[
                  const SizedBox(height: 14),
                  if (_busy && !hasCachedApk) ...[
                    LinearProgressIndicator(value: progress),
                    const SizedBox(height: 7),
                    Text(
                      _progressText,
                      textAlign: TextAlign.center,
                      style: context.texts.labelSmall!.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ] else if (_waitingPermission)
                    Text(
                      '授权后返回应用将继续安装',
                      textAlign: TextAlign.center,
                      style: context.texts.bodySmall,
                    )
                  else if (_error != null)
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: context.texts.bodySmall!.copyWith(
                        color: scheme.error,
                      ),
                    ),
                ],
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: _cancelOrClose,
                        child: Text(_busy ? '取消' : '以后再说'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: FilledButton.icon(
                        onPressed: _busy ? null : _start,
                        icon: Icon(
                          hasCachedApk
                              ? Icons.install_mobile_outlined
                              : Icons.download_outlined,
                          size: 18,
                        ),
                        label: Text(hasCachedApk ? '打开安装窗口' : '下载并安装'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
