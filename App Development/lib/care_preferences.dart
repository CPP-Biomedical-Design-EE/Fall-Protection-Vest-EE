import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CarePreferencesPage extends StatefulWidget {
  const CarePreferencesPage({super.key});

  @override
  State<CarePreferencesPage> createState() => _CarePreferencesPageState();
}

class _CarePreferencesPageState extends State<CarePreferencesPage> {
  static const _groups = <_PreferenceGroup>[
    _PreferenceGroup(
      keyName: 'hospital_alert_recipients',
      title: 'Who should be notified first?',
      description:
          'Family and caregiver notifications are not configured; this only saves your preference.',
      options: [
        _PreferenceOption('none', 'No preference'),
        _PreferenceOption('caregiver_only', 'Caregiver only'),
        _PreferenceOption('caregiver_then_family', 'Caregiver, then family'),
        _PreferenceOption('family_then_caregiver', 'Family, then caregiver'),
        _PreferenceOption('person_with_wearer', 'Whoever is with the wearer'),
      ],
    ),
    _PreferenceGroup(
      keyName: 'hospital_emergency_response',
      title: 'Preferred emergency response',
      description:
          'Preference only. This app never calls 911 or emergency services.',
      options: [
        _PreferenceOption('none', 'No preference'),
        _PreferenceOption(
          'caregiver_decides',
          'Caregiver assesses and decides',
        ),
        _PreferenceOption('automatic_911', 'Automatic 911 call'),
        _PreferenceOption('if_alone', 'Depends whether the wearer is alone'),
        _PreferenceOption(
          'fall_type',
          'Depends whether the fall was assisted or independent',
        ),
      ],
    ),
    _PreferenceGroup(
      keyName: 'hospital_alert_timing',
      title: 'When would you prefer an alert?',
      description: 'The current detector cannot detect movement before a fall.',
      options: [
        _PreferenceOption('none', 'No preference'),
        _PreferenceOption('after_candidate', 'After a fall candidate'),
        _PreferenceOption(
          'during_movement',
          'Also during movement, such as standing or turning',
        ),
      ],
    ),
    _PreferenceGroup(
      keyName: 'hospital_battery_threshold',
      title: 'Preferred low-battery alert level',
      description:
          'The current vest firmware does not report battery level or send low-battery alerts.',
      options: [
        _PreferenceOption('none', 'No preference'),
        _PreferenceOption('20', '20%'),
        _PreferenceOption('25', '25%'),
        _PreferenceOption('30', '30%'),
        _PreferenceOption('50', '50%'),
      ],
    ),
    _PreferenceGroup(
      keyName: 'hospital_battery_life',
      title: 'Desired battery life',
      description:
          'This records a product preference; it cannot change battery life.',
      options: [
        _PreferenceOption('none', 'No preference'),
        _PreferenceOption('8_hours', 'At least 8 hours'),
        _PreferenceOption('12_hours', '12 hours'),
        _PreferenceOption('12_to_24_hours', '12–24 hours'),
        _PreferenceOption('48_hours', '48 hours'),
      ],
    ),
    _PreferenceGroup(
      keyName: 'hospital_readiness_indicator',
      title: 'Where would you prefer to see vest readiness?',
      description:
          'The app status is available; a vest light or hardware indicator is not connected.',
      options: [
        _PreferenceOption('none', 'No preference'),
        _PreferenceOption('vest', 'On the vest'),
        _PreferenceOption('app', 'In the app'),
        _PreferenceOption('both', 'On both the vest and in the app'),
      ],
    ),
    _PreferenceGroup(
      keyName: 'hospital_vest_style',
      title: 'Preferred vest style',
      description: 'This preference does not change or configure the vest.',
      options: [
        _PreferenceOption('none', 'No preference'),
        _PreferenceOption('ordinary_clothing', 'Looks like ordinary clothing'),
        _PreferenceOption('protective_vest', 'Looks like a protective vest'),
      ],
    ),
  ];

  static const _vestColors = [
    'Black',
    'Hot pink',
    'Blue',
    'Green',
    'Bright light blue',
    'Light green',
    'Baby blue',
    'Mellow / neutral',
  ];
  static const _colorsKey = 'hospital_vest_colors';

  Map<String, String> _values = {};
  List<String> _selectedColors = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _values = {
        for (final group in _groups)
          group.keyName: prefs.getString(group.keyName) ?? 'none',
      };
      _selectedColors = prefs.getStringList(_colorsKey) ?? [];
      _loading = false;
    });
  }

  Future<void> _saveChoice(String keyName, String value) async {
    final prefs = await SharedPreferences.getInstance();
    final saved = await prefs.setString(keyName, value);
    if (!mounted) return;
    if (!saved) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save this preference.')),
      );
      return;
    }
    setState(() => _values[keyName] = value);
  }

  Future<void> _saveColor(String color, bool selected) async {
    final colors = {..._selectedColors};
    if (selected) {
      colors.add(color);
    } else {
      colors.remove(color);
    }
    final orderedColors = _vestColors
        .where(colors.contains)
        .toList(growable: false);
    final prefs = await SharedPreferences.getInstance();
    final saved = await prefs.setStringList(_colorsKey, orderedColors);
    if (!mounted) return;
    if (!saved) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save this preference.')),
      );
      return;
    }
    setState(() => _selectedColors = orderedColors);
  }

  Widget _buildPreferenceCard(_PreferenceGroup group) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            group.title,
            style: const TextStyle(
              color: Color(0xFF202124),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            group.description,
            style: const TextStyle(color: Color(0xFF687076), height: 1.4),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey(group.keyName),
            initialValue: _values[group.keyName],
            isExpanded: true,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Your preference',
            ),
            items: [
              for (final option in group.options)
                DropdownMenuItem(
                  value: option.value,
                  child: Text(option.label, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (value) {
              if (value != null) _saveChoice(group.keyName, value);
            },
          ),
        ],
      ),
    ),
  );

  Widget _buildColorCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Preferred vest colors',
            style: TextStyle(
              color: Color(0xFF202124),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Choose any colors you would consider. This does not change the vest.',
            style: TextStyle(color: Color(0xFF687076), height: 1.4),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final color in _vestColors)
                FilterChip(
                  label: Text(color),
                  selected: _selectedColors.contains(color),
                  onSelected: (selected) => _saveColor(color, selected),
                ),
            ],
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Care preferences')),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
            children: [
              Card(
                color: const Color(0xFFFFF5E5),
                child: const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Optional preferences inspired by hospital interviews. '
                    'They are saved only on this phone and do not activate '
                    'alerts, calls, family sharing, or vest hardware. This app '
                    'never calls 911.',
                    style: TextStyle(height: 1.45),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const _PreferenceHeading('Alerts and emergency planning'),
              for (final group in _groups.take(4)) _buildPreferenceCard(group),
              const SizedBox(height: 8),
              const _PreferenceHeading('Vest preferences'),
              for (final group in _groups.skip(4)) _buildPreferenceCard(group),
              _buildColorCard(),
              Card(
                child: ExpansionTile(
                  leading: const Icon(Icons.science_outlined),
                  title: const Text('Detector research note'),
                  subtitle: const Text(
                    'The T15 comparison is retrospective, not live validation.',
                  ),
                  children: const [
                    Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: Text(
                        'The supplied Python analysis compares model training '
                        'with and without T15 examples using five retrospective '
                        'trials from one participant. Its report notes repeated '
                        'control trials and windows that include the candidate '
                        'impact. It does not test live or pre-impact detection, '
                        'validate the detector clinically, or change its '
                        'thresholds.',
                        style: TextStyle(
                          color: Color(0xFF687076),
                          height: 1.45,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
  );
}

class _PreferenceHeading extends StatelessWidget {
  const _PreferenceHeading(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(2, 8, 2, 8),
    child: Text(
      title,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
        color: const Color(0xFF202124),
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

class _PreferenceGroup {
  const _PreferenceGroup({
    required this.keyName,
    required this.title,
    required this.description,
    required this.options,
  });

  final String keyName;
  final String title;
  final String description;
  final List<_PreferenceOption> options;
}

class _PreferenceOption {
  const _PreferenceOption(this.value, this.label);

  final String value;
  final String label;
}
