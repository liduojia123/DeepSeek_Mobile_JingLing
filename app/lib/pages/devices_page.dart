import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/api.dart';
import '../core/providers.dart';
import '../models/models.dart';

/// 设备管理:列出已配对设备,可吊销任意一台(吊销本机等于远程把自己踢下线)。
class DevicesPage extends ConsumerStatefulWidget {
  const DevicesPage({super.key});

  @override
  ConsumerState<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends ConsumerState<DevicesPage> {
  List<Device> _devices = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = ref.read(apiProvider);
    if (api == null) {
      setState(() {
        _loading = false;
        _error = '当前未配对';
      });
      return;
    }
    if (mounted) setState(() => _loading = true);
    try {
      final devices = await api.devices();
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _loading = false;
        _error = null;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.message;
      });
    }
  }

  Future<void> _revoke(Device device) async {
    final isSelf = device.current;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(isSelf ? '吊销本机令牌?' : '吊销「${device.name}」?'),
        content: Text(
          isSelf
              ? '本机将立即失去访问权限,需要重新输入配对码才能使用。'
              : '该设备下次请求会被拒绝(401),需要重新配对才能使用。',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('吊销')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final api = ref.read(apiProvider);
    if (api == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await api.revokeDevice(device.id);
    } on ApiException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('吊销失败:${error.message}')));
      return;
    }
    if (!mounted) return;
    if (isSelf) {
      await ref.read(settingsProvider.notifier).unpair();
      if (!mounted) return;
      Navigator.of(context).popUntil((route) => route.isFirst);
      return;
    }
    messenger.showSnackBar(SnackBar(content: Text('已吊销「${device.name}」')));
    await _load();
  }

  static String _formatTime(String? iso) {
    if (iso == null || iso.isEmpty) return '未知';
    final parsed = DateTime.tryParse(iso)?.toLocal();
    if (parsed == null) return iso;
    String two(int value) => value.toString().padLeft(2, '0');
    return '${parsed.year}-${two(parsed.month)}-${two(parsed.day)} ${two(parsed.hour)}:${two(parsed.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('设备管理'),
        actions: [
          IconButton(onPressed: _loading ? null : _load, tooltip: '刷新', icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        FilledButton(onPressed: _load, child: const Text('重试')),
                      ],
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: Text(
                        '这里的每一条都是一次配对换来的令牌(服务端只存哈希)。吊销后旧令牌立即失效,想再用要重新配对。',
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                    for (final device in _devices)
                      ListTile(
                        leading: Icon(
                          device.current ? Icons.smartphone : Icons.devices_other,
                          color: device.current ? theme.colorScheme.primary : null,
                        ),
                        title: Row(
                          children: [
                            Flexible(child: Text(device.name, overflow: TextOverflow.ellipsis)),
                            if (device.current) ...[
                              const SizedBox(width: 8),
                              Chip(
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                label: Text('本机', style: theme.textTheme.labelSmall),
                              ),
                            ],
                          ],
                        ),
                        subtitle: Text(
                          '上次活跃:${_formatTime(device.lastSeen ?? device.pairedAt)}',
                          style: theme.textTheme.bodySmall,
                        ),
                        trailing: TextButton(
                          onPressed: () => _revoke(device),
                          style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
                          child: const Text('吊销'),
                        ),
                      ),
                    if (_devices.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: Text('没有已配对的设备')),
                      ),
                    const Divider(height: 32),
                    ListTile(
                      leading: Icon(Icons.link_off, color: theme.colorScheme.error),
                      title: Text('仅在本机解除配对', style: TextStyle(color: theme.colorScheme.error)),
                      subtitle: const Text('只清除本机保存的令牌,服务端记录保留(适合临时换机)'),
                      onTap: () async {
                        await ref.read(settingsProvider.notifier).unpair();
                        if (!context.mounted) return;
                        Navigator.of(context).popUntil((route) => route.isFirst);
                      },
                    ),
                  ],
                ),
    );
  }
}
