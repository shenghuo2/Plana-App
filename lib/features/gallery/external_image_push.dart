/// Gallery-level orchestration for external image push uploads.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_info.dart';
import '../../core/net/external_image_push_client.dart';
import '../../core/net/external_image_push_config.dart';
import 'models.dart';

final externalImagePushClientProvider = Provider<ExternalImagePushClient>(
  (_) => ExternalImagePushClient(),
);

/// IDs currently uploading. Keeping this in state prevents accidental
/// duplicate taps while still allowing different gallery images to upload.
final externalImagePushUploadsProvider =
    NotifierProvider<ExternalImagePushUploadsNotifier, Set<String>>(
      ExternalImagePushUploadsNotifier.new,
    );

class ExternalImagePushUploadsNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => const <String>{};

  Future<ExternalImagePushReceipt> upload({
    required ResultImage result,
    required Uint8List imageBytes,
  }) async {
    if (state.contains(result.id)) {
      throw const ExternalImagePushException('图片正在上传');
    }

    final settings = await ref.read(externalImagePushSettingsProvider.future);
    final credentials = await ref
        .read(externalImagePushSettingsProvider.notifier)
        .credentials();
    if (!settings.isConfigured || credentials == null) {
      throw const ExternalImagePushException('请先在「我的 → 云存储」配置 API 地址和 Token');
    }

    final capturedAt = result.createdAt > 0
        ? DateTime.fromMillisecondsSinceEpoch(result.createdAt, isUtc: true)
        : DateTime.now().toUtc();
    final source = <String, dynamic>{
      'adapter': 'plana-app',
      // Gallery images are produced by the NovelAI client. We intentionally do
      // not copy image prompt/reference URLs into source metadata.
      'page_url': 'https://novelai.net/',
      'captured_at': capturedAt.toIso8601String(),
      'source_name': credentials.sourceName,
      if (result.seed >= 0) 'seed_hint': result.seed,
      'metadata': {
        'gallery_id': result.id,
        'width': result.width,
        'height': result.height,
        'badge': result.badge.name,
        'app_version': kAppVersion,
      },
    };

    state = {...state, result.id};
    try {
      return await ref
          .read(externalImagePushClientProvider)
          .upload(
            endpoint: externalImagePushAssetUri(credentials.endpoint),
            token: credentials.token,
            imageBytes: imageBytes,
            source: source,
            fileName: '${result.id}.png',
          );
    } finally {
      state = {...state}..remove(result.id);
    }
  }
}
