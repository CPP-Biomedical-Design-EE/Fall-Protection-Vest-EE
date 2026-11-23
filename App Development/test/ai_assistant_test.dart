import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fall_protection_vest_app/ai_assistant.dart';
import 'package:fall_protection_vest_app/ai_assistant_page.dart';

void main() {
  testWidgets('streams an app-support answer into the assistant chat', (
    tester,
  ) async {
    final service = _FakeAssistantService();
    await tester.pumpWidget(
      MaterialApp(home: AIAssistantPage(service: service)),
    );

    await tester.enterText(find.byType(TextField), 'How do I connect?');
    await tester.tap(find.byTooltip('Send message'));
    await tester.pumpAndSettle();

    expect(service.messages, ['How do I connect?']);
    expect(find.text('How do I connect?'), findsOneWidget);
    expect(
      find.text('Open Device, then choose Wi-Fi or Bluetooth.'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Questions go to Firebase AI Logic'),
      findsOneWidget,
    );
  });

  testWidgets('explains when Firebase AI Logic is not configured', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: AIAssistantPage()));

    expect(
      find.text('Firebase AI Logic is not configured for this build.'),
      findsOneWidget,
    );
    expect(find.byTooltip('Send message'), findsOneWidget);
  });
}

class _FakeAssistantService implements AssistantService {
  final List<String> messages = [];

  @override
  Stream<String> replyTo(String message) async* {
    messages.add(message);
    yield 'Open Device, then ';
    yield 'choose Wi-Fi or Bluetooth.';
  }
}
