import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'core/providers.dart';
import 'core/reminders.dart';
import 'core/wait_alert.dart';
import 'design/theme.dart';
import 'pages/home_page.dart';
import 'pages/pair_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final container = ProviderContainer();
  // 前台/后台状态决定"跑完了要不要发系统通知";回前台顺手补排提醒
  WidgetsBinding.instance.addObserver(_VisibilityObserver(container));
  runApp(UncontrolledProviderScope(container: container, child: const JingLingApp()));
}

class _VisibilityObserver with WidgetsBindingObserver {
  _VisibilityObserver(this._container);

  final ProviderContainer _container;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    AppVisibility.foreground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      syncRemindersInBackground(_container.read(apiProvider));
    }
  }
}

class JingLingApp extends StatelessWidget {
  const JingLingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '鲸灵',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const StartupGate(),
    );
  }
}

/// 根据本地是否已配对决定进配对页还是会话列表(声明式路由,不用手动跳转)。
class StartupGate extends ConsumerStatefulWidget {
  const StartupGate({super.key});

  @override
  ConsumerState<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends ConsumerState<StartupGate> {
  bool _synced = false;

  /// 启动时补排一次提醒(回前台的补排由 _VisibilityObserver 负责)。
  void _syncOnce({required bool paired}) {
    if (_synced || !paired) return;
    _synced = true;
    syncRemindersInBackground(ref.read(apiProvider));
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);

    return settings.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (error, _) => Scaffold(
        body: Center(child: Text('读取本地配置失败:$error')),
      ),
      data: (value) {
        _syncOnce(paired: value.paired);
        return value.paired ? const HomePage() : const PairPage();
      },
    );
  }
}
