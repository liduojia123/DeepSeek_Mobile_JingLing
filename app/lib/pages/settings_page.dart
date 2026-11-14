import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/api.dart';
import '../core/providers.dart';
import '../models/models.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final TextEditingController _serverUrl = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final url = ref.read(settingsProvider).value?.serverUrl;
      if (url != null && mounted) _serverUrl.text = url;
    });
  }

  @override
  void dispose() {
    _serverUrl.dispose();
    super.dispose();
  }

  Future<void> _saveServerUrl() async {
    setState(() => _saving = true);
    await ref.read(settingsProvider.notifier).saveServerUrl(_serverUrl.text);
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('服务器地址已保存')));
  }

  Future<void> _showUsage() async {
    final api = ref.read(apiProvider);
    if (api == null) return;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('用量'),
        content: FutureBuilder<UsageSummary>(
          future: api.usage(days: 30),
          builder: (builderContext, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const SizedBox(
                height: 60,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              final error = snapshot.error;
              return Text(error is ApiException ? error.message : '读取用量失败');
            }
            final usage = snapshot.data;
            if (usage == null) return const Text('暂无用量');
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('最近 30 天 · ${usage.calls} 次调用'),
                const SizedBox(height: 8),
                Text('输入 ${usage.tokensIn} tokens'),
                Text('输出 ${usage.tokensOut} tokens'),
                Text('估算费用 ¥${usage.cost.toStringAsFixed(4)}'),
                const SizedBox(height: 12),
                Text('每日', style: Theme.of(dialogContext).textTheme.labelMedium),
                const SizedBox(height: 4),
                for (final day in usage.days.reversed.take(7))
                  Text(
                    '${day.date}  ${day.calls} 次 · ¥${day.cost.toStringAsFixed(4)}',
                    style: Theme.of(dialogContext).textTheme.bodySmall,
                  ),
              ],
            );
          },
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('关闭')),
        ],
      ),
    );
  }

  Future<void> _unpair() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('解除配对'),
        content: const Text('将清除本机保存的设备令牌，需要重新输入配对码。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('解除')),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(settingsProvider.notifier).unpair();
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = ref.watch(settingsProvider).value;

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('服务器', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          TextField(
            controller: _serverUrl,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: '服务器地址',
              hintText: 'http://192.168.1.10:3000',
              border: OutlineInputBorder(),
              helperText: '改完需要重启会话列表才会连新地址',
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: _saving ? null : _saveServerUrl,
              child: Text(_saving ? '保存中…' : '保存地址'),
            ),
          ),
          const Divider(height: 32),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.insights_outlined),
            title: const Text('用量与费用'),
            subtitle: const Text('token 用量、调用次数与估算费用'),
            onTap: _showUsage,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.link_off, color: theme.colorScheme.error),
            title: Text('解除配对', style: TextStyle(color: theme.colorScheme.error)),
            subtitle: Text(settings?.paired == true ? '当前设备已配对' : '当前未配对'),
            onTap: _unpair,
          ),
          const Divider(height: 32),
          Center(
            child: Text(
              '鲸灵 JingLing · v0.1.0\n你的随身精灵',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
            ),
          ),
        ],
      ),
    );
  }
}
