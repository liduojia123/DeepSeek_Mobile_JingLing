import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingling/pages/auth_page.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  Widget wrap() => const ProviderScope(child: MaterialApp(home: AuthPage()));

  testWidgets('登录页:邮箱/密码与注册、忘记密码入口', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.text('登录鲸灵'), findsOneWidget);
    expect(find.widgetWithText(TextField, ''), findsWidgets);
    expect(find.text('注册账号'), findsOneWidget);
    expect(find.text('忘记密码'), findsOneWidget);
    expect(find.textContaining('配对码'), findsOneWidget);
  });

  testWidgets('切到注册:密码提示变 8 位,提交按钮变注册', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.tap(find.text('注册账号'));
    await tester.pumpAndSettle();

    expect(find.text('注册账号'), findsOneWidget); // 标题
    expect(find.text('注册并发送验证码'), findsOneWidget);
    expect(find.text('密码(至少 8 位)'), findsOneWidget);
  });
}
