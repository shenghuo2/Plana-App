import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plana_app/features/update/update_download.dart';
import 'package:plana_app/features/update/update_service.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('plana_update_dl'));
  tearDown(() => tmp.deleteSync(recursive: true));

  const apkName = 'Plana-1.1.0-patch-s.1-arm64-v8a.apk';
  const apkUrl = 'https://github.com/x/y/releases/download/v1.1.0/app.apk';
  const sumsUrl =
      'https://github.com/x/y/releases/download/v1.1.0/SHA256SUMS.txt';
  final apkBytes = utf8.encode('signed apk fixture bytes');

  GithubRelease release({bool withChecksum = true}) => GithubRelease(
    tag: 'v1.1.0-patch-s.1',
    name: 'Plana 1.1.0 patch',
    notes: '',
    url: 'https://github.com/x/y/releases/tag/v1.1.0-patch-s.1',
    prerelease: true,
    assets: [
      GithubAsset(name: apkName, url: apkUrl, size: apkBytes.length),
      if (withChecksum)
        const GithubAsset(name: 'SHA256SUMS.txt', url: sumsUrl, size: 100),
    ],
  );

  test('流式下载并校验 SHA-256', () async {
    final digest = sha256.convert(apkBytes).toString();
    final progress = <(int, int)>[];
    final client = MockClient((request) async {
      if (request.url.toString() == sumsUrl) {
        return http.Response('$digest  $apkName\n', 200);
      }
      if (request.url.toString() == apkUrl) {
        return http.Response.bytes(apkBytes, 200);
      }
      return http.Response('not found', 404);
    });
    final downloader = UpdateDownloader(client: client);
    addTearDown(downloader.close);

    final file = await downloader.download(
      release(),
      cacheDirectory: tmp,
      onProgress: (received, total) => progress.add((received, total)),
    );

    expect(await file.readAsBytes(), apkBytes);
    expect(file.path, contains('/updates/'));
    expect(progress.last, (apkBytes.length, apkBytes.length));
    expect(
      Directory(
        '${tmp.path}/updates',
      ).listSync().whereType<File>().where((f) => f.path.endsWith('.part')),
      isEmpty,
    );
  });

  test('已校验的缓存 APK 不重复下载', () async {
    final digest = sha256.convert(apkBytes).toString();
    var apkRequests = 0;
    final client = MockClient((request) async {
      if (request.url.toString() == sumsUrl) {
        return http.Response('$digest  $apkName\n', 200);
      }
      apkRequests++;
      return http.Response.bytes(apkBytes, 200);
    });
    final downloader = UpdateDownloader(client: client);
    addTearDown(downloader.close);

    final first = await downloader.download(release(), cacheDirectory: tmp);
    final second = await downloader.download(release(), cacheDirectory: tmp);

    expect(second.path, first.path);
    expect(apkRequests, 1);
  });

  test('摘要不一致时拒绝文件并清理临时包', () async {
    final client = MockClient((request) async {
      if (request.url.toString() == sumsUrl) {
        return http.Response('${'0' * 64}  $apkName\n', 200);
      }
      return http.Response.bytes(apkBytes, 200);
    });
    final downloader = UpdateDownloader(client: client);
    addTearDown(downloader.close);

    await expectLater(
      downloader.download(release(), cacheDirectory: tmp),
      throwsA(
        isA<UpdateException>().having(
          (e) => e.message,
          'message',
          contains('SHA-256 校验失败'),
        ),
      ),
    );
    final updateDir = Directory('${tmp.path}/updates');
    expect(updateDir.existsSync() ? updateDir.listSync() : const [], isEmpty);
  });

  test('没有校验文件时不发起下载', () async {
    var requests = 0;
    final downloader = UpdateDownloader(
      client: MockClient((_) async {
        requests++;
        return http.Response('unexpected', 500);
      }),
    );
    addTearDown(downloader.close);

    await expectLater(
      downloader.download(release(withChecksum: false), cacheDirectory: tmp),
      throwsA(isA<UpdateException>()),
    );
    expect(requests, 0);
  });
}
