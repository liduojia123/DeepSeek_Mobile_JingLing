import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/api.dart';
import '../core/providers.dart';
import '../core/reminders.dart';
import '../design/components/empty_state.dart';

/// 设置 →「提醒」:列出手机上已经排好的闹钟,可取消。
///
/// 时间以**手机本地已排闹钟**为准(服务端的 fire_at 可能因为"稍后提醒"落后),
/// 服务端只用来发现"还没排进来"的提醒。
class RemindersPage extends ConsumerStatefulWidget {
  const RemindersPage({super.key});

  @override
  ConsumerState<RemindersPage> createState() => _RemindersPageState();
}

class _RemindersPageState extends ConsumerState<RemindersPage> {
  List<ReminderAlarm> _alarms = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    final api = ref.read(apiProvider);
    // 先把服务端还欠着的排进来,再看本地(顺序很重要:排完本地列表才是全的)
    if (api != null) {
      final tombstones = await ReminderTombstones.load();
      try {
        await syncReminders(api: api, tombstones: tombstones);
      } on ApiException catch (error) {
        if (mounted) setState(() => _error = error.message);
      }
    }
    final alarms = await RemindersChannel.listScheduled();
    if (!mounted) return;
    setState(() {
      _alarms = alarms;
      _loading = false;
    });
  }

  Future<void> _cancel(ReminderAlarm alarm) async {
    await RemindersChannel.cancel(alarm.id);
    await ReminderTombstones.add(alarm.id);
    final api = ref.read(apiProvider);
    if (api != null) {
      try {
        await api.ackReminder(alarm.id, status: 'cancelled');
      } on ApiException {
        // 墓碑会在下次补排时重试
      }
    }
    await _load();
  }

  Future<void> _openExactAlarmSettings() async {
    await RemindersChannel.openExactAlarmSettings();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('提醒'),
        actions: [
          IconButton(onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    '到点由手机本地闹钟提醒,App 不需要开着。关机重启后会自动排回来;'
                    '在系统里「强行停止」鲸灵会清掉闹钟。',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text('同步失败:$_error', style: TextStyle(color: theme.colorScheme.error)),
                    ),
                  if (_alarms.isEmpty)
                    const EmptyState(
                      icon: Icons.alarm,
                      title: '还没有待响的提醒',
                      body: '跟鲸灵说「20 分钟后提醒我关火」',
                    ),
                  for (final alarm in _alarms)
                    Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: const Icon(Icons.alarm),
                        title: Text(alarm.text),
                        subtitle: Text(_formatTime(alarm.fireAtMs)),
                        trailing: TextButton(
                          onPressed: () => _cancel(alarm),
                          child: const Text('取消'),
                        ),
                      ),
                    ),
                  const Divider(height: 32),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.schedule),
                    title: const Text('精确闹钟权限'),
                    subtitle: const Text('Android 12 起需要允许,否则到点可能不准'),
                    trailing: TextButton(
                      onPressed: _openExactAlarmSettings,
                      child: const Text('去设置'),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  static String _formatTime(int ms) {
    final at = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(at.month)}-${two(at.day)} ${two(at.hour)}:${two(at.minute)}';
  }
}

