// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:finfinfin/gui.dart';
import 'package:finfinfin/logic.dart';

void main() {
  testWidgets('Counter increments smoke test', (WidgetTester tester) async {
  // Build the real app (BudgetApp) so tests see the same widget tree as runtime.
  await tester.pumpWidget(BudgetApp(logic: AppLogic()));
  await tester.pumpAndSettle();

  // The app's AppBar title should be present.
  expect(find.text('Clickwheel Budget'), findsOneWidget);
  });
}
