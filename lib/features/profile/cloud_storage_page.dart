import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/external_image_push_config.dart';
import '../../core/theme/app_theme.dart';
import '../../core/util/haptics.dart';
import '../generate/widgets/common.dart' show confirmDialog, hintSnack;
import 'widgets/settings_ui.dart';

/// Configuration for pushing original gallery images to a pic-manager server.
class CloudStoragePage extends ConsumerStatefulWidget {
  const CloudStoragePage({super.key});

  @override
  ConsumerState<CloudStoragePage> createState() => _CloudStoragePageState();
}

class _CloudStoragePageState extends ConsumerState<CloudStoragePage> {
  final _endpoint = TextEditingController();
  final _token = TextEditingController();
  final _sourceName = TextEditingController();

  bool _seeded = false;
  bool _seeding = false;
  bool _obscure = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _endpoint.addListener(_onChanged);
    _token.addListener(_onChanged);
    _sourceName.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted && !_seeding) setState(() {});
  }

  @override
  void dispose() {
    _endpoint
      ..removeListener(_onChanged)
      ..dispose();
    _token
      ..removeListener(_onChanged)
      ..dispose();
    _sourceName
      ..removeListener(_onChanged)
      ..dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final parsed = splitExternalImagePushTokenInput(_token.text);
      var sourceName = _sourceName.text;
      if (parsed.sourceName != null &&
          (sourceName.trim().isEmpty ||
              sourceName.trim() == kDefaultExternalImagePushSourceName)) {
        sourceName = parsed.sourceName!;
        _sourceName.text = sourceName;
      }
      await ref
          .read(externalImagePushSettingsProvider.notifier)
          .save(
            endpoint: _endpoint.text,
            sourceName: sourceName,
            token: parsed.token.isEmpty ? null : parsed.token,
          );
      if (!mounted) return;
      _token.clear(); // Never leave a raw token visible after persistence.
      FocusScope.of(context).unfocus();
      Haptics.selection();
      hintSnack(context, '云存储配置已保存', icon: Icons.check_circle_outline);
    } on ExternalImagePushConfigException catch (e) {
      if (mounted) hintSnack(context, e.message, icon: Icons.error_outline);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _clearToken() async {
    final ok = await confirmDialog(
      context,
      title: '清除云存储 Token',
      message: '将从本机删除已保存的 Token,图库上传会停止直到重新填写。',
      confirmLabel: '清除',
    );
    if (!ok) return;
    try {
      await ref.read(externalImagePushSettingsProvider.notifier).clearToken();
      if (!mounted) return;
      _token.clear();
      Haptics.medium();
      hintSnack(context, '已清除云存储 Token', icon: Icons.check_circle_outline);
    } on ExternalImagePushConfigException catch (e) {
      if (mounted) hintSnack(context, e.message, icon: Icons.error_outline);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(externalImagePushSettingsProvider);
    final settings = async.value;
    if (!_seeded && settings != null) {
      _seeding = true;
      _endpoint.text = settings.endpoint;
      _sourceName.text = settings.sourceName;
      _seeded = true;
      _seeding = false;
    }

    final hasToken = settings?.hasToken ?? false;
    final isConfigured = settings?.isConfigured ?? false;
    final canSave =
        _endpoint.text.trim().isNotEmpty &&
        _sourceName.text.trim().isNotEmpty &&
        (hasToken || _token.text.trim().isNotEmpty) &&
        !_saving;

    return Scaffold(
      appBar: AppBar(title: const Text('云存储')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
        children: [
          const SettingsLabel('连接'),
          SettingsCard(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 13, 16, 8),
                child: TextField(
                  controller: _endpoint,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'API 地址',
                    hintText: 'http://host:3210 或 .../api/v1/assets',
                    prefixIcon: Icon(Icons.link),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 15),
                child: TextField(
                  controller: _sourceName,
                  textInputAction: TextInputAction.next,
                  maxLength: 64,
                  decoration: const InputDecoration(
                    labelText: '来源名称',
                    prefixIcon: Icon(Icons.sell_outlined),
                  ),
                ),
              ),
              SettingsRow(
                icon: isConfigured
                    ? Icons.cloud_done_outlined
                    : Icons.cloud_off_outlined,
                title: '连接状态',
                value: isConfigured ? '已配置' : '待填写',
                valueColor: isConfigured
                    ? context.scheme.primary
                    : context.scheme.onSurfaceVariant,
              ),
            ],
          ),
          const SizedBox(height: 16),
          const SettingsLabel('凭据'),
          SettingsCard(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 13, 16, 14),
                child: TextField(
                  controller: _token,
                  obscureText: _obscure,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.visiblePassword,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) {
                    if (canSave) unawaited(_save());
                  },
                  decoration: InputDecoration(
                    labelText: hasToken ? 'Token (已保存)' : 'Token',
                    prefixIcon: const Icon(Icons.key_outlined),
                    suffixIcon: IconButton(
                      tooltip: _obscure ? '显示 Token' : '隐藏 Token',
                      onPressed: () => setState(() => _obscure = !_obscure),
                      icon: Icon(
                        _obscure ? Icons.visibility : Icons.visibility_off,
                      ),
                    ),
                  ),
                ),
              ),
              if (hasToken)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: _clearToken,
                      icon: const Icon(Icons.key_off_outlined),
                      label: const Text('清除 Token'),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: canSave ? _save : null,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            label: Text(_saving ? '保存中' : '保存配置'),
          ),
        ],
      ),
    );
  }
}
