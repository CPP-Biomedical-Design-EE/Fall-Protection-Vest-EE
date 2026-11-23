import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_native_contact_picker/flutter_native_contact_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _emergencyContactsKey = 'emergency_contacts';

String _phoneDigits(String value) => value.replaceAll(RegExp(r'[^0-9]'), '');

class EmergencyContact {
  const EmergencyContact({required this.name, required this.phoneNumber});

  final String name;
  final String phoneNumber;

  Map<String, String> toJson() => {'name': name, 'phoneNumber': phoneNumber};

  factory EmergencyContact.fromJson(Map<String, dynamic> json) =>
      EmergencyContact(
        name: json['name'] as String,
        phoneNumber: json['phoneNumber'] as String,
      );
}

abstract interface class EmergencyContactPicker {
  bool get supportsNativePicker;

  Future<EmergencyContact?> pickContact();
}

class NativeEmergencyContactPicker implements EmergencyContactPicker {
  NativeEmergencyContactPicker() : _picker = FlutterNativeContactPicker();

  final FlutterNativeContactPicker _picker;

  @override
  bool get supportsNativePicker =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  Future<EmergencyContact?> pickContact() async {
    final selected = await _picker.selectPhoneNumber();
    if (selected == null) return null;

    final name = selected.fullName?.trim() ?? '';
    final phoneNumber = selected.selectedPhoneNumber?.trim() ?? '';
    if (name.isEmpty || phoneNumber.isEmpty) {
      throw const FormatException(
        'Select a contact with a name and phone number.',
      );
    }

    return EmergencyContact(name: name, phoneNumber: phoneNumber);
  }
}

Future<void> showEmergencyContactsSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => const EmergencyContactsSheet(),
    );

class EmergencyContactsSheet extends StatefulWidget {
  const EmergencyContactsSheet({this.picker, super.key});

  final EmergencyContactPicker? picker;

  @override
  State<EmergencyContactsSheet> createState() => _EmergencyContactsSheetState();
}

class _EmergencyContactsSheetState extends State<EmergencyContactsSheet> {
  late final EmergencyContactPicker _picker =
      widget.picker ?? NativeEmergencyContactPicker();
  List<EmergencyContact> _contacts = [];
  bool _loading = true;
  bool _adding = false;
  String? _error;

  bool get _supportsNativePicker => _picker.supportsNativePicker;

  @override
  void initState() {
    super.initState();
    _loadContacts();
  }

  Future<void> _loadContacts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getStringList(_emergencyContactsKey) ?? [];
      final contacts = saved.map((value) {
        final decoded = jsonDecode(value);
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('Saved contact has an invalid format.');
        }
        return EmergencyContact.fromJson(decoded);
      }).toList();
      if (!mounted) return;
      setState(() {
        _contacts = contacts;
        _loading = false;
      });
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load saved contacts: $error';
      });
    }
  }

  Future<void> _addContact() async {
    setState(() {
      _adding = true;
      _error = null;
    });
    try {
      final contact = _supportsNativePicker
          ? await _picker.pickContact()
          : await _showManualContactDialog(context);
      if (contact == null) return;

      if (_contacts.any(
        (existing) =>
            _phoneDigits(existing.phoneNumber) ==
            _phoneDigits(contact.phoneNumber),
      )) {
        setState(() => _error = 'That phone number is already on this list.');
        return;
      }

      final updated = [..._contacts, contact];
      await _saveContacts(updated);
      if (!mounted) return;
      setState(() => _contacts = updated);
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() => _error = 'Could not add that contact: $error');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _removeContact(EmergencyContact contact) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove emergency contact?'),
        content: Text('Remove ${contact.name} from this device?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final updated = _contacts.where((item) => item != contact).toList();
    try {
      await _saveContacts(updated);
      if (mounted) setState(() => _contacts = updated);
    } on Exception catch (error) {
      if (mounted) {
        setState(() => _error = 'Could not remove that contact: $error');
      }
    }
  }

  Future<void> _saveContacts(List<EmergencyContact> contacts) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _emergencyContactsKey,
      contacts.map((contact) => jsonEncode(contact.toJson())).toList(),
    );
  }

  Future<EmergencyContact?> _showManualContactDialog(BuildContext context) =>
      showDialog<EmergencyContact>(
        context: context,
        builder: (_) => const _ManualContactDialog(),
      );

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Emergency contacts',
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        const Text(
          'Saved only on this device. The app does not call or message these contacts.',
          style: TextStyle(color: Color(0xFF687076), height: 1.4),
        ),
        const SizedBox(height: 16),
        if (_error != null) ...[
          Text(
            _error!,
            style: const TextStyle(color: Color(0xFFB42318), height: 1.4),
          ),
          const SizedBox(height: 8),
        ],
        if (_loading)
          const Center(child: CircularProgressIndicator())
        else if (_contacts.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('No emergency contacts added yet.'),
          )
        else
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: _contacts.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final contact = _contacts[index];
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const CircleAvatar(
                    child: Icon(Icons.person_outline_rounded),
                  ),
                  title: Text(contact.name),
                  subtitle: Text(contact.phoneNumber),
                  trailing: IconButton(
                    tooltip: 'Remove ${contact.name}',
                    onPressed: () => _removeContact(contact),
                    icon: const Icon(Icons.delete_outline_rounded),
                  ),
                );
              },
            ),
          ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _loading || _adding ? null : _addContact,
            icon: _adding
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.person_add_alt_1_rounded),
            label: Text(
              _adding
                  ? 'Adding contact...'
                  : _supportsNativePicker
                  ? 'Add from contacts'
                  : 'Add contact',
            ),
          ),
        ),
      ],
    ),
  );
}

class _ManualContactDialog extends StatefulWidget {
  const _ManualContactDialog();

  @override
  State<_ManualContactDialog> createState() => _ManualContactDialogState();
}

class _ManualContactDialogState extends State<_ManualContactDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(
      context,
      EmergencyContact(
        name: _nameController.text.trim(),
        phoneNumber: _phoneController.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Add emergency contact'),
    content: Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextFormField(
            controller: _nameController,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Name'),
            validator: (value) =>
                value?.trim().isNotEmpty == true ? null : 'Enter a name.',
          ),
          TextFormField(
            controller: _phoneController,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'Phone number'),
            validator: (value) {
              if (_phoneDigits(value ?? '').length < 3) {
                return 'Enter a valid phone number.';
              }
              return null;
            },
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _save, child: const Text('Save contact')),
    ],
  );
}
