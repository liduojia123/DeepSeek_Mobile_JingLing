import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingling/pages/home_page.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('首页:打开即见问候语、输入框与两个快捷开关', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: HomePage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('欢迎回来,想从哪里开始?'), findsOneWidget);
    expect(find.text('深度思考'), findsOneWidget);
    expect(find.text('智能搜索'), findsOneWidget);
    expect(find.byIcon(Icons.menu), findsOneWidget); // 左上角抽屉入口
  });

  testWidgets('输入为空时发送钮禁用,输入后可用', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: HomePage()),
      ),
    );
    await tester.pumpAndSettle();

    Finder send() => find.ancestor(of: find.byTooltip('发送'), matching: find.byType(IconButton));
    expect(
      tester.widget<IconButton>(send()).onPressed,
      isNull,
      reason: '空输入不该能发',
    );

    await tester.enterText(find.byType(TextField), '你好');
    await tester.pump();
    expect(tester.widget<IconButton>(send()).onPressed, isNotNull);
  });
}
