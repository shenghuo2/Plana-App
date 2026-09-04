import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plana_app/core/net/external_image_push_client.dart';
import 'package:plana_app/core/net/external_image_push_config.dart';

void main() {
  group('externalImagePushAssetUri', () {
    test('accepts a service root or the full assets endpoint', () {
      expect(
        externalImagePushAssetUri('https://images.example'),
        Uri.parse('https://images.example/api/v1/assets'),
      );
      expect(
        externalImagePushAssetUri('https://images.example/base/api/v1/assets/'),
        Uri.parse('https://images.example/base/api/v1/assets'),
      );
    });

    test('rejects non-web URLs and URL-borne credentials', () {
      expect(
        () => externalImagePushAssetUri('ftp://images.example'),
        throwsA(isA<ExternalImagePushException>()),
      );
      expect(
        () => externalImagePushAssetUri('https://token@images.example'),
        throwsA(isA<ExternalImagePushException>()),
      );
      expect(
        () => externalImagePushAssetUri('https://images.example/?token=x'),
        throwsA(isA<ExternalImagePushException>()),
      );
    });
  });

  group('normalizeExternalImagePushSourceName', () {
    test('uses PlanaAPP when no name is provided', () {
      expect(normalizeExternalImagePushSourceName('  '), 'PlanaAPP');
    });

    test('rejects server-invalid control characters', () {
      expect(
        () => normalizeExternalImagePushSourceName('Plana\nAPP'),
        throwsA(isA<ExternalImagePushConfigException>()),
      );
    });

    test('splits the supplied pmat token and source name form', () {
      expect(splitExternalImagePushTokenInput('pmat_abc123:PlanaAPP'), (
        token: 'pmat_abc123',
        sourceName: 'PlanaAPP',
      ));
    });

    test('does not split an unrelated Bearer token containing a colon', () {
      expect(splitExternalImagePushTokenInput('Bearer:opaque-value'), (
        token: 'Bearer:opaque-value',
        sourceName: null,
      ));
    });
  });

  group('ExternalImagePushClient', () {
    test('sends exactly the API multipart contract', () async {
      late http.MultipartRequest seen;
      final client = ExternalImagePushClient(
        requestSender: (request) async {
          seen = request;
          return http.StreamedResponse(
            Stream<List<int>>.value(
              utf8.encode('{"id":"asset-1","deduplicated":false}'),
            ),
            201,
          );
        },
      );

      final receipt = await client.upload(
        endpoint: Uri.parse('https://images.example/api/v1/assets'),
        token: 'test-token',
        imageBytes: Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]),
        fileName: 'gen42.png',
        source: {
          'adapter': 'plana-app',
          'page_url': 'https://novelai.net/',
          'captured_at': '2026-08-26T00:00:00.000Z',
          'source_name': 'PlanaAPP',
          'metadata': {'gallery_id': 'gen42'},
        },
      );

      expect(receipt.id, 'asset-1');
      expect(receipt.deduplicated, isFalse);
      expect(seen.method, 'POST');
      expect(seen.url.path, '/api/v1/assets');
      expect(seen.headers['Authorization'], 'Bearer test-token');
      expect(seen.fields, hasLength(1));
      expect(seen.fields, containsPair('source', isNotEmpty));
      expect(jsonDecode(seen.fields['source']!), {
        'adapter': 'plana-app',
        'page_url': 'https://novelai.net/',
        'captured_at': '2026-08-26T00:00:00.000Z',
        'source_name': 'PlanaAPP',
        'metadata': {'gallery_id': 'gen42'},
      });
      expect(seen.files, hasLength(1));
      expect(seen.files.single.field, 'file');
      expect(seen.files.single.filename, 'gen42.png');
      expect(seen.files.single.length, 4);
    });

    test(
      'surfaces the server error message without exposing request details',
      () async {
        final client = ExternalImagePushClient(
          requestSender: (_) async => http.StreamedResponse(
            Stream<List<int>>.value(
              utf8.encode(
                '{"error":{"code":"unauthorized","message":"Token 已撤销"}}',
              ),
            ),
            401,
          ),
        );

        await expectLater(
          client.upload(
            endpoint: Uri.parse('https://images.example/api/v1/assets'),
            token: 'test-token',
            imageBytes: Uint8List.fromList([1]),
            fileName: 'image.png',
            source: const <String, dynamic>{},
          ),
          throwsA(
            isA<ExternalImagePushException>().having(
              (e) => e.message,
              'message',
              'Token 已撤销',
            ),
          ),
        );
      },
    );
  });
}
