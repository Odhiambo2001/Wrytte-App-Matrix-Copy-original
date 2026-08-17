import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wrytte/ui/auth/kface_access_result_page.dart';

void main() {
  testWidgets('shows accepted login result', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: KFaceAccessResultPage(
          accepted: true,
          retryPageBuilder: (_) => const SizedBox(),
        ),
      ),
    );

    expect(find.text('Access accepted'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
  });

  testWidgets('shows retry result and reopens supplied scanner page', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: KFaceAccessResultPage(
          accepted: false,
          retryPageBuilder:
              (_) => const Scaffold(body: Text('Scanner reopened')),
        ),
      ),
    );

    expect(find.text('Try again'), findsNWidgets(2));
    await tester.tap(find.widgetWithText(ElevatedButton, 'Try again'));
    await tester.pumpAndSettle();
    expect(find.text('Scanner reopened'), findsOneWidget);
  });
}
