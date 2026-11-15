import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/providers.dart';
import '../core/update.dart';
import 'computer_page.dart';
import 'memory_page.dart';
import 'usage_page.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  String _versionLabel = '';
  final TextEditingController _serverUrl = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final url = ref.read(settingsProvider).value?.serverUrl;
      if (url != null && mounted) _serverUrl.text = url;
      UpdateService.currentVersion().then((version) {
        if (mounted) setState(() => _versionLabel = 'v${version.name}+${version.code}');
      });
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


  Future<void> _checkUpdate() async {
    final api = ref.read(apiProvider);
    if (api == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final latest = await UpdateService.check(api);
    if (!mounted) return;
    if (latest == null) {
      messenger.showSnackBar(const SnackBar(content: Text('已是最新版本')));
      return;
    }
    final sizeMb = (latest.size / 1024 / 1024).toStringAsFixed(1);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('发现新版本 v${latest.versionName}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('大小:$sizeMb MB'),
              if (latest.notes.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(latest.notes.trim()),
              ],
              const SizedBox(height: 8),
              const Text('下载后点安装即可升级,不需要连电脑。', style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('下载并安装')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final progress = ValueNotifier<double>(0);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('正在下载更新…'),
        content: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (builderContext, value, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: value <= 0 ? null : value),
              const SizedBox(height: 8),
              Text('${(value * 100).toStringAsFixed(0)}%'),
            ],
          ),
        ),
      ),
    );

    try {
      final path = await UpdateService.download(
        api,
        release: latest,
        onProgress: (value) => progress.value = value,
      );
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      progress.dispose();
      final canInstall = await UpdateService.canInstall();
      if (!canInstall) {
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('需要开启安装权限'),
            content: const Text('系统需要允许「鲸灵」安装应用才能升级。点「去开启」后在列表里允许鲸灵,再回来重新检查更新。'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('知道了')),
              FilledButton(
                onPressed: () {
                  Navigator.pop(dialogContext);
                  UpdateService.openInstallPermission();
                },
                child: const Text('去开启'),
              ),
            ],
          ),
        );
        return;
      }
      await UpdateService.install(path);
    } catch (error) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      progress.dispose();
      messenger.showSnackBar(SnackBar(content: Text('更新失败:$error')));
    }
  }

  Future<void> _showUsage() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const UsagePage()),
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
          Text('功能', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.psychology_outlined),
            title: const Text('记忆'),
            subtitle: const Text('查看、搜索、删除鲸灵记住的关于你的信息'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const MemoryPage()),
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.insights_outlined),
            title: const Text('用量看板'),
            subtitle: const Text('今日费用与预算、近 7 天趋势、工具调用、Top 会话'),
            onTap: _showUsage,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.desktop_windows_outlined),
            title: const Text('电脑(dsh 远程开发)'),
            subtitle: const Text('查看电脑上的 dsh 工作区/会话、派任务、逐条确认'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const ComputerPage()),
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.record_voice_over_outlined),
            title: const Text('语音'),
            subtitle: const Text('聊天页麦克风:按住说话/点按录音;自动朗读在聊天页右上角切换'),
            onTap: () => ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('打开任一会话,使用输入框左侧麦克风;朗读开关在会话右上角')),
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.system_update_outlined),
            title: const Text('检查更新'),
            subtitle: Text(_versionLabel.isEmpty ? '从服务器下载新版本并安装(免插线)' : '当前 $_versionLabel · 从服务器下载并安装'),
            onTap: _checkUpdate,
          ),
          const Divider(height: 32),
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
            leading: Icon(Icons.link_off, color: theme.colorScheme.error),
            title: Text('解除配对', style: TextStyle(color: theme.colorScheme.error)),
            subtitle: Text(settings?.paired == true ? '当前设备已配对' : '当前未配对'),
            onTap: _unpair,
          ),
          const Divider(height: 32),
          Center(
            child: Text(
              '鲸灵 JingLing${_versionLabel.isEmpty ? '' : ' · $_versionLabel'}\n你的随身精灵',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
            ),
          ),
        ],
      ),
    );
  }
}
