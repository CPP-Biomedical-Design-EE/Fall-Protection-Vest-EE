import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fall_protection_vest_app/emergency_contacts.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('saves a contact selected from the native picker', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final picker = _FakeContactPicker(
      const EmergencyContact(name: 'Sam Caregiver', phoneNumber: '+1 555 1234'),
      supportsNativePicker: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: EmergencyContactsSheet(picker: picker)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add from contacts'));
    await tester.pumpAndSettle();

    expect(picker.pickCount, 1);
    expect(find.text('Sam Caregiver'), findsOneWidget);
    expect(find.text('+1 555 1234'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('emergency_contacts'), hasLength(1));
  });

  testWidgets('allows manual contact entry on macOS', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final picker = _FakeContactPicker(
      const EmergencyContact(name: '', phoneNumber: ''),
      supportsNativePicker: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: EmergencyContactsSheet(picker: picker)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add contact'));
    await tester.pump(const Duration(milliseconds: 500));
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'Alex Family');
    await tester.enterText(fields.at(1), '+1 555 4321');
    await tester.tap(find.text('Save contact'));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Alex Family'), findsOneWidget);
    expect(find.text('+1 555 4321'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('emergency_contacts'), hasLength(1));
  });
}

class _FakeContactPicker implements EmergencyContactPicker {
  _FakeContactPicker(this.contact, {required this.supportsNativePicker});

  final EmergencyContact contact;
  @override
  final bool supportsNativePicker;
  int pickCount = 0;

  @override
  Future<EmergencyContact?> pickContact() async {
    pickCount++;
    return contact;
  }
}
