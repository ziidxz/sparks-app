import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bigpickle_chat/main.dart';

void main() {
  testWidgets('setup screen offers guest and sign-in', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: SetupScreen(onGuest: () {}, onSignedIn: (_) {})),
    );
    expect(find.text('Sparks'), findsOneWidget);
    expect(find.text('Sign in with Google'), findsOneWidget);
    expect(find.text('Continue as guest'), findsOneWidget);
  });
}
