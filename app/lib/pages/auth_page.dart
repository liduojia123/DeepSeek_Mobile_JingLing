import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/api.dart';
import '../core/config.dart';
import '../core/providers.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import 'pair_page.dart';

enum _AuthMode { login, register, verify, forgot, reset }

/// 邮箱账号(v1.9.0):登录 / 注册(验证码激活)/ 忘记密码 三态合一。
/// 登录/激活成功 → 存设备令牌(与配对同一套),StartupGate 自动进主界面。
class AuthPage extends ConsumerStatefulWidget {
  const AuthPage({super.key});

  @override
  ConsumerState<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends ConsumerState<AuthPage> {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _code = TextEditingController();
  final TextEditingController _newPassword = TextEditingController();
  _AuthMode _mode = _AuthMode.login;
  bool _busy = false;
  String? _info;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _code.dispose();
    _newPassword.dispose();
    super.dispose();
  }

  String get _deviceName => kIsWeb ? '网页端' : '我的手机';

  Future<ApiClient> _client() async {
    final settings = ref.read(settingsProvider).value;
    return ApiClient(baseUrl: settings?.serverUrl ?? SecureStore.defaultServerUrl);
  }

  Future<void> _run(Future<void> Function(ApiClient api) action) async {
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    final api = await _client();
    try {
      await action(api);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) setState(() => _error = '出错了:$error');
    } finally {
      api.dispose();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finishLogin(String token, String? email) async {
    await ref.read(settingsProvider.notifier).loginWithToken(token, email: email ?? _email.text.trim());
    // 成功后 StartupGate 检测到已配对,自动切主界面
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final password = _password.text;
    switch (_mode) {
      case _AuthMode.login:
        if (email.isEmpty || password.isEmpty) {
          setState(() => _error = '邮箱和密码都要填');
          return;
        }
        await _run((api) async {
          final result = await api.loginAccount(email, password, _deviceName);
          if (result.token != null) await _finishLogin(result.token!, result.email ?? email);
        });
      case _AuthMode.register:
        if (email.isEmpty || password.length < 8) {
          setState(() => _error = '邮箱要填,密码至少 8 位');
          return;
        }
        await _run((api) async {
          final result = await api.registerAccount(email, password);
          if (!mounted) return;
          setState(() {
            _mode = _AuthMode.verify;
            _info = result.message ?? '验证码已发送到邮箱,查收后填入激活';
            if (result.debugCode != null) _code.text = result.debugCode!;
          });
        });
      case _AuthMode.verify:
        if (_code.text.trim().isEmpty) {
          setState(() => _error = '填入邮箱收到的验证码');
          return;
        }
        await _run((api) async {
          final result = await api.verifyAccount(email, _code.text, _deviceName);
          if (result.token != null) await _finishLogin(result.token!, email);
        });
      case _AuthMode.forgot:
        if (email.isEmpty) {
          setState(() => _error = '填入注册邮箱');
          return;
        }
        await _run((api) async {
          final result = await api.forgotPassword(email);
          if (!mounted) return;
          setState(() {
            _mode = _AuthMode.reset;
            _info = result.message ?? '如果该邮箱已注册,重置码已发送';
            if (result.debugCode != null) _code.text = result.debugCode!;
          });
        });
      case _AuthMode.reset:
        if (_code.text.trim().isEmpty || _newPassword.text.length < 8) {
          setState(() => _error = '重置码要填,新密码至少 8 位');
          return;
        }
        await _run((api) async {
          final result = await api.resetPassword(email, _code.text, _newPassword.text);
          if (!mounted) return;
          setState(() {
            _mode = _AuthMode.login;
            _info = result.message ?? '密码已重置,请用新密码登录';
            _password.clear();
            _code.clear();
          });
        });
    }
  }

  Future<void> _resend() async {
    await _run((api) async {
      final result = await api.resendCode(_email.text.trim());
      if (!mounted) return;
      setState(() {
        _info = result.message ?? '验证码已发送';
        if (result.debugCode != null) _code.text = result.debugCode!;
      });
    });
  }

  String get _title => switch (_mode) {
        _AuthMode.login => '登录鲸灵',
        _AuthMode.register => '注册账号',
        _AuthMode.verify => '激活邮箱',
        _AuthMode.forgot => '找回密码',
        _AuthMode.reset => '重置密码',
      };

  String get _submitLabel => switch (_mode) {
        _AuthMode.login => '登录',
        _AuthMode.register => '注册并发送验证码',
        _AuthMode.verify => '激活并进入',
        _AuthMode.forgot => '发送重置码',
        _AuthMode.reset => '重置密码',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = colorsOf(context);
    final type = typeOf(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
              children: [
                Icon(Icons.water, size: 56, color: theme.colorScheme.primary),
                const SizedBox(height: 12),
                Text(_title, textAlign: TextAlign.center, style: type.title),
                const SizedBox(height: 32),
                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  enabled: _mode != _AuthMode.verify,
                  decoration: const InputDecoration(
                    labelText: '邮箱',
                    hintText: 'you@example.com',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                if (_mode == _AuthMode.login || _mode == _AuthMode.register)
                  TextField(
                    controller: _password,
                    obscureText: true,
                    onSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      labelText: _mode == _AuthMode.register ? '密码(至少 8 位)' : '密码',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                if (_mode == _AuthMode.verify || _mode == _AuthMode.reset) ...[
                  TextField(
                    controller: _code,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '邮箱验证码',
                      hintText: '6 位数字',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                if (_mode == _AuthMode.reset)
                  TextField(
                    controller: _newPassword,
                    obscureText: true,
                    onSubmitted: (_) => _submit(),
                    decoration: const InputDecoration(
                      labelText: '新密码(至少 8 位)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Text(_busy ? '请稍候…' : _submitLabel),
                  ),
                ),
                if (_info != null) ...[
                  const SizedBox(height: 12),
                  Text(_info!, textAlign: TextAlign.center, style: type.meta.copyWith(color: colors.accent)),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, textAlign: TextAlign.center, style: type.meta.copyWith(color: colors.danger)),
                ],
                const SizedBox(height: 24),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: AppSpace.lg,
                  children: [
                    if (_mode == _AuthMode.login)
                      TextButton(
                        onPressed: () => setState(() => _mode = _AuthMode.register),
                        child: const Text('注册账号'),
                      ),
                    if (_mode == _AuthMode.login)
                      TextButton(
                        onPressed: () => setState(() => _mode = _AuthMode.forgot),
                        child: const Text('忘记密码'),
                      ),
                    if (_mode != _AuthMode.login)
                      TextButton(
                        onPressed: () => setState(() => _mode = _AuthMode.login),
                        child: const Text('返回登录'),
                      ),
                    if (_mode == _AuthMode.verify)
                      TextButton(onPressed: _busy ? null : _resend, child: const Text('重发验证码')),
                  ],
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => const PairPage()),
                  ),
                  child: const Text('用配对码连接(不用账号)'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
