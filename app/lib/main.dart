import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'core/providers.dart';
import 'core/wait_alert.dart';
import 'pages/conversations_page.dart';
import 'pages/pair_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 前台/后台状态决定"跑完了要不要发系统通知"
  WidgetsBinding.instance.addObserver(_VisibilityObserver());
  runApp(const ProviderScope(child: JingLingApp()));
}

class _VisibilityObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    AppVisibility.foreground = state == AppLifecycleState.resumed;
  }
}

class JingLingApp extends StatelessWidget {
  const JingLingApp({super.key});

  static const Color _seed = Color(0xFF2F6FED);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '鲸灵',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: _seed),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: _seed, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: const StartupGate(),
    );
  }
}

/// 根据本地是否已配对决定进配对页还是会话列表(声明式路由,不用手动跳转)。
class StartupGate extends ConsumerWidget {
  const StartupGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);

    return settings.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (error, _) => Scaffold(
        body: Center(child: Text('读取本地配置失败:$error')),
      ),
      data: (value) => value.paired ? const ConversationsPage() : const PairPage(),
    );
  }
}
