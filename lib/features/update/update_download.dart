library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'update_service.dart';

typedef UpdateProgressCallback = void Function(int received, int total);

class UpdateCancelledException implements Exception {
  const UpdateCancelledException();

  @override
  String toString() => '已取消更新';
}

enum InstallLaunchResult { launched, permissionRequired }

const _channel = MethodChannel('plana/update');
const _maxApkBytes = 512 * 1024 * 1024;
const _maxChecksumBytes = 64 * 1024;
const _requestTimeout = Duration(seconds: 20);
const _idleTimeout = Duration(seconds: 30);

/// 把 Release APK 下载到应用缓存并校验发布页附带的 SHA-256。
class UpdateDownloader {
  UpdateDownloader({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    _client.close();
  }

  void close() => _client.close();

  Future<File> download(
    GithubRelease release, {
    Directory? cacheDirectory,
    UpdateProgressCallback? onProgress,
  }) async {
    try {
      return await _download(
        release,
        cacheDirectory: cacheDirectory,
        onProgress: onProgress,
      );
    } on UpdateCancelledException {
      rethrow;
    } on UpdateException {
      rethrow;
    } on TimeoutException {
      throw const UpdateException('下载更新超时,请重试');
    } on SocketException {
      throw const UpdateException('下载更新失败,请检查网络后重试');
    } on http.ClientException {
      if (_cancelled) throw const UpdateCancelledException();
      throw const UpdateException('下载更新失败,请检查网络后重试');
    } catch (_) {
      if (_cancelled) throw const UpdateCancelledException();
      throw const UpdateException('下载更新失败,请稍后重试');
    }
  }

  Future<File> _download(
    GithubRelease release, {
    Directory? cacheDirectory,
    UpdateProgressCallback? onProgress,
  }) async {
    final apk = findAndroidApk(release);
    if (apk == null) {
      throw const UpdateException('该版本没有唯一的 arm64 Android 安装包');
    }
    final checksumAsset = findChecksumAsset(release);
    if (checksumAsset == null) {
      throw const UpdateException('该版本缺少 SHA256SUMS.txt,无法安全安装');
    }
    if (checksumAsset.size < 0 || checksumAsset.size > _maxChecksumBytes) {
      throw const UpdateException('安装包校验文件大小异常');
    }
    if (apk.size < 0 || apk.size > _maxApkBytes) {
      throw const UpdateException('安装包大小异常');
    }

    _throwIfCancelled();
    final expected = await _fetchExpectedChecksum(checksumAsset, apk.name);
    _throwIfCancelled();

    final root = cacheDirectory ?? await getTemporaryDirectory();
    final updateDir = Directory('${root.path}/updates');
    await updateDir.create(recursive: true);
    final safeTag = release.tag.replaceAll(RegExp(r'[^0-9A-Za-z._-]'), '_');
    final target = File('${updateDir.path}/Plana-$safeTag-arm64-v8a.apk');
    final partial = File('${target.path}.part');
    await _pruneCache(updateDir, keepPath: target.path);

    if (await target.exists()) {
      final length = await target.length();
      if (length <= _maxApkBytes &&
          (apk.size <= 0 || length == apk.size) &&
          await _sha256File(target) == expected) {
        onProgress?.call(length, length);
        return target;
      }
      await target.delete();
    }
    if (await partial.exists()) await partial.delete();

    try {
      await _downloadApk(apk, partial, expected, onProgress);
      _throwIfCancelled();
      return await partial.rename(target.path);
    } on UpdateCancelledException {
      if (await partial.exists()) await partial.delete();
      rethrow;
    } on UpdateException {
      if (await partial.exists()) await partial.delete();
      rethrow;
    } on TimeoutException {
      if (await partial.exists()) await partial.delete();
      throw const UpdateException('下载更新超时,请重试');
    } on SocketException {
      if (await partial.exists()) await partial.delete();
      throw const UpdateException('下载更新失败,请检查网络后重试');
    } on http.ClientException {
      if (await partial.exists()) await partial.delete();
      if (_cancelled) throw const UpdateCancelledException();
      throw const UpdateException('下载更新失败,请检查网络后重试');
    } catch (_) {
      if (await partial.exists()) await partial.delete();
      if (_cancelled) throw const UpdateCancelledException();
      throw const UpdateException('下载更新失败,请稍后重试');
    }
  }

  Future<String> _fetchExpectedChecksum(
    GithubAsset checksumAsset,
    String apkName,
  ) async {
    final request = http.Request('GET', Uri.parse(checksumAsset.url));
    request.headers['Accept'] = 'text/plain';
    final response = await _client.send(request).timeout(_requestTimeout);
    if (response.statusCode != 200) {
      throw UpdateException('获取安装包校验值失败(HTTP ${response.statusCode})');
    }
    if ((response.contentLength ?? 0) > _maxChecksumBytes) {
      throw const UpdateException('安装包校验文件大小异常');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(_idleTimeout)) {
      _throwIfCancelled();
      if (bytes.length + chunk.length > _maxChecksumBytes) {
        throw const UpdateException('安装包校验文件大小异常');
      }
      bytes.add(chunk);
    }
    final digest = checksumForAsset(utf8.decode(bytes.takeBytes()), apkName);
    if (digest == null) {
      throw const UpdateException('校验文件中没有当前安装包的 SHA-256');
    }
    return digest;
  }

  Future<void> _downloadApk(
    GithubAsset apk,
    File partial,
    String expected,
    UpdateProgressCallback? onProgress,
  ) async {
    final request = http.Request('GET', Uri.parse(apk.url));
    request.headers['Accept'] = 'application/octet-stream';
    final response = await _client.send(request).timeout(_requestTimeout);
    if (response.statusCode != 200) {
      throw UpdateException('下载安装包失败(HTTP ${response.statusCode})');
    }

    final responseLength = response.contentLength ?? 0;
    if (responseLength > _maxApkBytes ||
        (apk.size > 0 && responseLength > 0 && apk.size != responseLength)) {
      throw const UpdateException('安装包大小与发布信息不一致');
    }
    final total = apk.size > 0 ? apk.size : responseLength;

    var received = 0;
    final notifyClock = Stopwatch()..start();
    final digestSink = _DigestSink();
    final hashInput = sha256.startChunkedConversion(digestSink);
    final output = await partial.open(mode: FileMode.write);
    try {
      await for (final chunk in response.stream.timeout(_idleTimeout)) {
        _throwIfCancelled();
        received += chunk.length;
        if (received > _maxApkBytes || (total > 0 && received > total)) {
          throw const UpdateException('安装包实际大小异常');
        }
        hashInput.add(chunk);
        await output.writeFrom(chunk);
        if (notifyClock.elapsedMilliseconds >= 100) {
          notifyClock.reset();
          onProgress?.call(received, total);
        }
      }
    } finally {
      hashInput.close();
      await output.close();
    }

    if (total > 0 && received != total) {
      throw const UpdateException('安装包下载不完整');
    }
    if (digestSink.value.toString() != expected) {
      throw const UpdateException('安装包 SHA-256 校验失败');
    }
    onProgress?.call(received, total > 0 ? total : received);
  }

  Future<String> _sha256File(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  Future<void> _pruneCache(
    Directory directory, {
    required String keepPath,
  }) async {
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || entity.path == keepPath) continue;
      try {
        await entity.delete();
      } on FileSystemException {
        // 缓存清理失败不妨碍当前版本下载;目标文件仍会单独校验。
      }
    }
  }

  void _throwIfCancelled() {
    if (_cancelled) throw const UpdateCancelledException();
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? _value;

  Digest get value {
    final digest = _value;
    if (digest == null) throw StateError('SHA-256 尚未完成');
    return digest;
  }

  @override
  void add(Digest data) => _value = data;

  @override
  void close() {}
}

Future<InstallLaunchResult> launchUpdateInstaller(File apk) async {
  try {
    final result = await _channel.invokeMethod<String>('install', {
      'path': apk.path,
    });
    return switch (result) {
      'launched' => InstallLaunchResult.launched,
      'permission_required' => InstallLaunchResult.permissionRequired,
      _ => throw const UpdateException('系统没有返回安装结果'),
    };
  } on PlatformException catch (e) {
    throw UpdateException(e.message ?? '无法打开系统安装窗口');
  } on MissingPluginException {
    throw const UpdateException('当前平台不支持应用内安装');
  }
}

Future<bool> canInstallUpdatePackages() async {
  try {
    return await _channel.invokeMethod<bool>('canInstallPackages') ?? false;
  } on PlatformException catch (e) {
    throw UpdateException(e.message ?? '无法读取应用安装权限');
  } on MissingPluginException {
    return false;
  }
}
