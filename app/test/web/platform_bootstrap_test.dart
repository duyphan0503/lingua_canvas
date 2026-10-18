import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/widgets/platform_bootstrap_gate.dart';

void main() {
  testWidgets('learning starts only after durable initialization', (
    tester,
  ) async {
    final ready = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: PlatformBootstrapGate(
          initialize: () => ready.future,
          child: const Text('Learning ready'),
        ),
      ),
    );
    expect(find.text('Learning ready'), findsNothing);
    ready.complete();
    await tester.pumpAndSettle();
    expect(find.text('Learning ready'), findsOneWidget);
  });
  testWidgets('storage errors are visible and retry initializes once', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: PlatformBootstrapGate(
          initialize: () async {
            if (++calls == 1) {
              throw StateError('another tab active');
            }
          },
          child: const Text('Learning ready'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Learning ready'), findsNothing);
    expect(find.textContaining('another tab active'), findsOneWidget);
    await tester.tap(find.text('Thử lại'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('Learning ready'), findsOneWidget);
  });
}
