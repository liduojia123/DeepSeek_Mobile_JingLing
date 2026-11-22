import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/api.dart';
import '../core/providers.dart';

class PairPage extends ConsumerStatefulWidget {
  const PairPage({super.key});

  @override
  ConsumerState<PairPage> createState() => _PairPageState();
}

class _PairPageState extends ConsumerState<PairPage> {
  final TextEditingController _serverUrl = TextEditingController();
  final TextEditingController _code = TextEditingController();
  final TextEditingController _deviceName = TextEditingController(text: kIsWeb ? '我的电脑' : '我的手机');
  bool _busy = false;
  String? _error;

  /// Web 端默认服务器地址:从当前页面来源推导(…/jingling/web/ → …/jingling),仍可手改。
  static String? _webServerUrl() {
    final base = Uri.base;
    if (base.host.isEmpty) return null;
    var path = base.path;
    final webIndex = path.lastIndexOf('/web');
    if (webIndex > 0) path = path.substring(0, webIndex);
    return '${base.scheme}://${base.authority}${path == '/' ? '' : path}';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final stored = ref.read(settingsProvider).value?.serverUrl;
      final prefill = (kIsWeb ? _webServerUrl() : null) ?? stored;
      if (prefill != null && mounted) _serverUrl.text = prefill;
    });
  }

  @override
  void dispose() {
    _serverUrl.dispose();
    _code.dispose();
    _deviceName.dispose();
    super.dispose();
  }

  Future<void> _pair() async {
    final code = _code.text.trim();
    if (code.isEmpty) {
      setState(() => _error = '请输入服务器控制台打印的配对码');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // 先落服务器地址,配对请求才会打到正确的地方
      await ref.read(settingsProvider.notifier).saveServerUrl(_serverUrl.text);
      await ref.read(settingsProvider.notifier).pairWithCode(
            code: code,
            deviceName: _deviceName.text,
          );
      // 成功:settingsProvider 变为已配对,StartupGate 自动切到会话列表
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
          children: [
            Icon(Icons.water, size: 64, color: theme.colorScheme.primary),
            const SizedBox(height: 12),
            Text(
              '鲸灵',
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              '你的随身精灵',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 40),
            TextField(
              controller: _serverUrl,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: '服务器地址',
                hintText: 'http://192.168.1.10:3000',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _code,
              textCapitalization: TextCapitalization.characters,
              onSubmitted: (_) => _pair(),
              decoration: const InputDecoration(
                labelText: '一次性配对码',
                hintText: '服务器启动时打印在控制台',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _deviceName,
              decoration: const InputDecoration(
                labelText: '设备名称',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _busy ? null : _pair,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(_busy ? '配对中…' : '配对'),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: 32),
            Text(
              '第一次使用:在服务器上运行 npm run dev,\n控制台会打印一次性配对码。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
            ),
          ],
        ),
      ),
    );
  }
}
