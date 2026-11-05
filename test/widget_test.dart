import 'package:flutter_test/flutter_test.dart';
import 'package:frontdesk_scanner/main.dart';

void main() {
  testWidgets('FrontdeskScannerApp smoke test builds cleanly', (WidgetTester tester) async {
    await tester.pumpWidget(const FrontdeskScannerApp(hasSavedSession: false));
    expect(find.byType(FrontdeskScannerApp), findsOneWidget);
  });
}
