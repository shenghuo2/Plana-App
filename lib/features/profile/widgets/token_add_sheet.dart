import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/nai_credential_login.dart';
import '../../../core/auth/nai_keys.dart';
import '../../../core/auth/token_probe.dart';
import '../../../core/auth/token_store.dart';
import '../../../core/net/nai_client.dart';
import '../../../core/net/nai_endpoint.dart';
import '../../../core/net/nai_proxy.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/util/haptics.dart';
import 'token_status.dart';
import '../../../l10n/l10n.dart';

/// 添加令牌弹层。返回 true = 加进去了。
///
/// 做成弹层而不是常驻在管理页底部:添加是**偶发**动作,常驻会被令牌列表越推越
/// 靠下,存了十几把时要滚过整页才够得着。
///
/// 三种来路(手贴令牌 / 邮箱登录 / 第三方接口)在**同一个弹层**里切,不是
/// 「弹层里再弹一层」—— 那样两层拖拽条叠着,退回来还得点两次。切换时键盘不落,
/// 弹层高度只补一段过渡,不会看着像重开一次。
///
/// 第三方那一路要的是**地址 + key 一起填**:地址跟着这把令牌存(见
/// [NaiKey.endpoint]),不是全局设置 —— 中转站各有各的地址,做成全局的话
/// 官方那几把会被一起带跑偏。
Future<bool> showTokenAddSheet(BuildContext context) async =>
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const _TokenAddSheet(),
    ) ??
    false;

enum _AddMode { paste, login, third }

enum _ThirdPartyMode { nai, openai, proxy }

class _TokenAddSheet extends ConsumerStatefulWidget {
  const _TokenAddSheet();

  @override
  ConsumerState<_TokenAddSheet> createState() => _TokenAddSheetState();
}

class _TokenAddSheetState extends ConsumerState<_TokenAddSheet> {
  _AddMode _mode = _AddMode.paste;
  _ThirdPartyMode _thirdMode = _ThirdPartyMode.nai;

  final _token = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _url = TextEditingController();
  final _thirdKey = TextEditingController();
  bool _obscureToken = true;
  bool _obscurePw = true;
  bool _obscureThird = true;
  bool _busy = false;
  String? _error;

  /// 添加前的在线校验:输入像样的令牌就防抖直查档位,不等保存。查的是官方 ——
  /// 第三方那一路不校验(见 [_thirdForm])。
  late final TokenProbe _probe = TokenProbe(
    (t) => ref.read(naiClientProvider('')).subscription(t),
  );

  @override
  void initState() {
    super.initState();
    _token.addListener(_onToken);
    _email.addListener(_onEdit);
    _password.addListener(_onEdit);
    _url.addListener(_onEdit);
    _thirdKey.addListener(_onEdit);
    _probe.addListener(_onProbe);
  }

  void _onProbe() {
    if (mounted) setState(() {});
  }

  void _onEdit() => setState(() => _error = null);

  void _onToken() {
    _onEdit();
    _probe.input(_token.text);
  }

  @override
  void dispose() {
    _probe
      ..removeListener(_onProbe)
      ..dispose();
    _token
      ..removeListener(_onToken)
      ..dispose();
    _email
      ..removeListener(_onEdit)
      ..dispose();
    _password
      ..removeListener(_onEdit)
      ..dispose();
    _url
      ..removeListener(_onEdit)
      ..dispose();
    _thirdKey
      ..removeListener(_onEdit)
      ..dispose();
    super.dispose();
  }

  Future<void> _paste(TextEditingController c) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final t = data?.text?.trim();
    if (t == null || t.isEmpty) return;
    c.text = t;
    c.selection = TextSelection.collapsed(offset: c.text.length);
  }

  /// 手贴的这把不带续期凭证(到期需重贴);凭证跟着每把 Key 存。
  Future<void> _add() async {
    final t = _token.text.trim();
    if (t.isEmpty) return;
    setState(() => _busy = true);
    final added = await ref.read(naiKeysStoreProvider.notifier).add(t);
    if (!mounted) return;
    if (added == null) {
      setState(() {
        _busy = false;
        _error = context.l10n.maxTokensSaved(kMaxNaiKeys);
      });
      return;
    }
    Haptics.selection();
    Navigator.pop(context, true);
  }

  /// 邮箱登录:密码只在本机派生 access key,换 30 天 JWT。
  /// 凭证跟着这把 Key 一起存 —— 日后续期只会换它自己那把的令牌。
  Future<void> _login() async {
    if (!_canLogin) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // 邮箱登录是官方那条流程(中转站不发 NAI 账号),固定打官方(开了代理经代理)。
      final (jwt, key) = await naiCredentialLoginFlow(
        _email.text,
        _password.text,
        proxy: ref.read(naiProxyProvider),
      );
      await ref.read(tokenProvider.notifier).save(jwt, accessKey: key);
      if (!mounted) return;
      Haptics.selection();
      Navigator.pop(context, true);
    } on NaiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = context.l10n.loginFailed('$e');
      });
    }
  }

  /// 第三方:地址 + key 绑成一把存下。
  ///
  /// 形态不对当场挡下(漏协议、把整条 `…/ai/generate-image` 贴进来带了参数);
  /// 通用中转不探测;选 API Proxy 时用其受支持的 `/quota` 验证客户端 key。
  Future<void> _addThird() async {
    final t = _thirdKey.text.trim();
    final proxyApi = _thirdMode == _ThirdPartyMode.proxy;
    final url = switch (_thirdMode) {
      _ThirdPartyMode.nai => naiEndpointFor(_url.text, NaiApiFormat.nai),
      _ThirdPartyMode.openai => naiEndpointFor(_url.text, NaiApiFormat.openai),
      _ThirdPartyMode.proxy => normalizeNaiBase(_url.text),
    };
    if (t.isEmpty || _busy) return;
    if (url.isEmpty || !naiBaseLooksValid(url)) {
      setState(() => _error = context.l10n.urlNeedsHttp);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    NaiKey? added;
    try {
      if (proxyApi) {
        await ref.read(naiClientProvider(url)).proxyQuota(t);
      }
      added = await ref
          .read(naiKeysStoreProvider.notifier)
          .add(t, endpoint: url, proxyApi: proxyApi);
    } on NaiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '代理验证失败: ${e.message}';
      });
      return;
    }
    if (!mounted) return;
    if (added == null) {
      setState(() {
        _busy = false;
        _error = context.l10n.maxTokensSaved(kMaxNaiKeys);
      });
      return;
    }
    Haptics.selection();
    Navigator.pop(context, true);
  }

  bool get _canAdd => _token.text.trim().isNotEmpty && !_busy;
  bool get _canLogin =>
      _email.text.trim().contains('@') && _password.text.isNotEmpty && !_busy;
  bool get _canAddThird =>
      _url.text.trim().isNotEmpty && _thirdKey.text.trim().isNotEmpty && !_busy;

  /// 切模式**不收键盘**:收了之后新表单的 autofocus 又会把它叫回来,
  /// 弹层就跟着「落下去再弹上来」—— 看着像整个弹窗重开了一次。
  /// 三边首个输入框都带 autofocus,焦点直接过户,键盘全程不动。
  void _switchMode(_AddMode m) {
    if (m == _mode) return;
    setState(() {
      _mode = m;
      _error = null;
    });
    Haptics.selection();
  }

  InputDecoration _dec(String hint, {Widget? suffix}) {
    final scheme = context.scheme;
    return InputDecoration(
      isDense: true,
      filled: true,
      fillColor: scheme.surfaceContainerHigh,
      hintText: hint,
      hintStyle: TextStyle(color: scheme.outline),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      suffixIcon: suffix,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return Padding(
      // 键盘弹起时把内容顶上去
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              context.l10n.addToken,
              style: context.texts.titleMedium!.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<_AddMode>(
                segments: [
                  ButtonSegment(
                    value: _AddMode.paste,
                    label: Text(context.l10n.pasteToken),
                  ),
                  ButtonSegment(
                    value: _AddMode.login,
                    label: Text(context.l10n.emailLogin),
                  ),
                  ButtonSegment(
                    value: _AddMode.third,
                    label: Text(context.l10n.thirdParty),
                  ),
                ],
                selected: {_mode},
                showSelectedIcon: false,
                onSelectionChanged: (v) => _switchMode(v.first),
              ),
            ),
            const SizedBox(height: 16),
            // 三种表单高矮不同,换 tab 时补成过渡,不然弹层会啪地跳一下。
            AnimatedSize(
              duration: Motion.fast,
              curve: Motion.standard,
              alignment: Alignment.topCenter,
              child: switch (_mode) {
                _AddMode.paste => _pasteForm(scheme),
                _AddMode.login => _loginForm(scheme),
                _AddMode.third => _thirdForm(scheme),
              },
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: context.texts.labelSmall!.copyWith(color: scheme.error),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: switch (_mode) {
                _AddMode.paste => _canAdd ? _add : null,
                _AddMode.login => _canLogin ? _login : null,
                _AddMode.third => _canAddThird ? _addThird : null,
              },
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(46),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(23),
                ),
              ),
              child: _busy
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: scheme.onPrimary,
                      ),
                    )
                  : Text(
                      _mode == _AddMode.login
                          ? context.l10n.loginAndAdd
                          : context.l10n.add,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pasteForm(ColorScheme scheme) => Column(
    key: const ValueKey('paste'),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        [
          context.l10n.tokenWhere,
          // 开了代理就不必自己够得着官网
          if (!ref.watch(naiProxyProvider)) context.l10n.needNaiAccess,
        ].join(context.l10n.sentenceJoin),
        style: context.texts.labelSmall!.copyWith(color: scheme.outline),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _token,
        enabled: !_busy,
        obscureText: _obscureToken,
        maxLines: _obscureToken ? 1 : 3,
        minLines: 1,
        autofocus: true,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: TextInputType.visiblePassword,
        style: mono(context, size: 13),
        decoration: _dec(
          context.l10n.pasteTokenHint,
          suffix: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                onPressed: () => _paste(_token),
                icon: const Icon(Icons.content_paste, size: 20),
                tooltip: context.l10n.paste,
                color: scheme.onSurfaceVariant,
              ),
              IconButton(
                onPressed: () => setState(() => _obscureToken = !_obscureToken),
                icon: Icon(
                  _obscureToken ? Icons.visibility : Icons.visibility_off,
                  size: 20,
                ),
                tooltip: _obscureToken ? context.l10n.show : context.l10n.hide,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 10),
      // 在线校验:贴进来的这把是哪个档、还剩多少点,加之前就看得见。
      tokenStatusLine(context, _probe, onRetry: () => _probe.run(_token.text)),
      const SizedBox(height: 2),
      Text(
        context.l10n.storedEncryptedLocal,
        style: context.texts.labelSmall!.copyWith(color: scheme.outline),
      ),
    ],
  );

  /// 第三方接口:地址和 key 一起填,绑成一把。
  ///
  /// 通用中转不在线校验;API Proxy 只在保存时请求 `/quota`。
  Widget _thirdForm(ColorScheme scheme) => Column(
    key: const ValueKey('third'),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SegmentedButton<_ThirdPartyMode>(
        segments: [
          ButtonSegment(
            value: _ThirdPartyMode.nai,
            label: Text(
              NaiApiFormat.nai.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ButtonSegment(
            value: _ThirdPartyMode.openai,
            label: Text(
              NaiApiFormat.openai.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const ButtonSegment(
            value: _ThirdPartyMode.proxy,
            label: Text(
              'API Proxy',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
        selected: {_thirdMode},
        showSelectedIcon: false,
        onSelectionChanged: _busy
            ? null
            : (v) {
                setState(() {
                  _thirdMode = v.first;
                  _error = null;
                });
                Haptics.selection();
              },
      ),
      const SizedBox(height: 8),
      Text(
        switch (_thirdMode) {
          _ThirdPartyMode.nai => NaiApiFormat.nai.hint,
          _ThirdPartyMode.openai => NaiApiFormat.openai.hint,
          _ThirdPartyMode.proxy =>
            '填写 NovelAI API Proxy 根地址和管理员签发的客户端 key。'
                '保存时验证 /quota,官方 Token 不会交给代理。',
        },
        style: context.texts.labelSmall!.copyWith(color: scheme.outline),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _url,
        enabled: !_busy,
        autofocus: true,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: TextInputType.url,
        textInputAction: TextInputAction.next,
        style: mono(context, size: 13),
        decoration: _dec(
          switch (_thirdMode) {
            _ThirdPartyMode.nai => 'https://example.com',
            _ThirdPartyMode.openai => 'https://example.com/v1',
            _ThirdPartyMode.proxy => 'https://nai.example.com',
          },
          suffix: IconButton(
            onPressed: () => _paste(_url),
            icon: const Icon(Icons.content_paste, size: 20),
            tooltip: context.l10n.paste,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
      const SizedBox(height: 10),
      TextField(
        controller: _thirdKey,
        enabled: !_busy,
        obscureText: _obscureThird,
        maxLines: _obscureThird ? 1 : 3,
        minLines: 1,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: TextInputType.visiblePassword,
        style: mono(context, size: 13),
        decoration: _dec(
          context.l10n.apiKey,
          suffix: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                onPressed: () => _paste(_thirdKey),
                icon: const Icon(Icons.content_paste, size: 20),
                tooltip: context.l10n.paste,
                color: scheme.onSurfaceVariant,
              ),
              IconButton(
                onPressed: () => setState(() => _obscureThird = !_obscureThird),
                icon: Icon(
                  _obscureThird ? Icons.visibility : Icons.visibility_off,
                  size: 20,
                ),
                tooltip: _obscureThird ? context.l10n.show : context.l10n.hide,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 10),
      Text(
        context.l10n.storedEncryptedLocal,
        style: context.texts.labelSmall!.copyWith(color: scheme.outline),
      ),
    ],
  );

  Widget _loginForm(ColorScheme scheme) => Column(
    key: const ValueKey('login'),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        context.l10n.passwordLocalHint,
        style: context.texts.labelSmall!.copyWith(color: scheme.outline),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _email,
        enabled: !_busy,
        autofocus: true,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: TextInputType.emailAddress,
        textInputAction: TextInputAction.next,
        autofillHints: const [AutofillHints.email],
        decoration: _dec(context.l10n.email),
      ),
      const SizedBox(height: 10),
      TextField(
        controller: _password,
        enabled: !_busy,
        obscureText: _obscurePw,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: TextInputType.visiblePassword,
        textInputAction: TextInputAction.done,
        autofillHints: const [AutofillHints.password],
        onSubmitted: (_) => _login(),
        decoration: _dec(
          context.l10n.password,
          suffix: IconButton(
            onPressed: () => setState(() => _obscurePw = !_obscurePw),
            icon: Icon(
              _obscurePw ? Icons.visibility : Icons.visibility_off,
              size: 20,
            ),
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
    ],
  );
}
