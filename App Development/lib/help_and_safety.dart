import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fall_protection_vest_app/app_colors.dart';

class HelpAndSafetyPage extends StatelessWidget {
  const HelpAndSafetyPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Help & safety')),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
      children: [
        Text(
          'Learn the essentials',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            color: AppColors.ink,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.4,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'A quick guide for vest wearers, family, and caregivers.',
          style: TextStyle(color: AppColors.muted, height: 1.4),
        ),
        const SizedBox(height: 20),
        const _QuickGuidePlayer(),
        const SizedBox(height: 24),
        Text(
          'Getting started',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            color: AppColors.ink,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        const _GuideStep(
          number: '01',
          title: 'Start the vest gateway',
          description:
              'The computer connected to the vest must be running the Python gateway.',
          icon: Icons.computer_rounded,
        ),
        const _GuideStep(
          number: '02',
          title: 'Connect on the Device tab',
          description:
              "Keep your phone and gateway on the same trusted Wi-Fi. Enter the computer's local IP address and tap Connect.",
          icon: Icons.wifi_rounded,
        ),
        const _GuideStep(
          number: '03',
          title: 'Check the live status',
          description:
              'Wait for Connected before interpreting sensor updates. This prototype uses a local network connection, not Bluetooth or cloud sync.',
          icon: Icons.sensors_rounded,
        ),
        const SizedBox(height: 18),
        Text(
          'Important safety notes',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            color: AppColors.ink,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        const _SafetyNote(
          icon: Icons.warning_amber_rounded,
          title: 'Alerts are experimental',
          description:
              'A fall candidate can be a false positive and is not a confirmed emergency. Follow your established safety and emergency procedures; do not rely on this app as your only protection.',
        ),
        const SizedBox(height: 10),
        const _SafetyNote(
          icon: Icons.call_outlined,
          title: 'No calls or family notifications are sent',
          description:
              'Local system alerts can be enabled in Settings for fall and connection issues. This prototype does not contact family, caregivers, or emergency services.',
        ),
        const SizedBox(height: 10),
        const _SafetyNote(
          icon: Icons.location_searching_rounded,
          title: 'Verify location before acting',
          description:
              'Directions are available only with real vest GPS data. Choosing Apple Maps or Google Maps shares the live vest destination with that selected app.',
        ),
        const SizedBox(height: 10),
        const _SafetyNote(
          icon: Icons.build_circle_outlined,
          title: 'No vest hardware controls',
          description:
              'This prototype has no reset control and cannot trigger or reset vest inflation hardware.',
        ),
        const SizedBox(height: 10),
        const _SafetyNote(
          icon: Icons.info_outline_rounded,
          title: 'Missing values are not estimates',
          description:
              'Battery may show Not reported because the current firmware does not measure battery voltage. An unavailable value should not be treated as a normal reading.',
        ),
      ],
    ),
  );
}

class _QuickGuidePlayer extends StatefulWidget {
  const _QuickGuidePlayer();

  @override
  State<_QuickGuidePlayer> createState() => _QuickGuidePlayerState();
}

class _QuickGuidePlayerState extends State<_QuickGuidePlayer> {
  static const _scenes = <_GuideScene>[
    _GuideScene(
      title: 'Connect your vest',
      description: 'Use the Device tab and connect through your local gateway.',
      icon: Icons.settings_input_antenna_rounded,
      accent: AppColors.gold,
    ),
    _GuideScene(
      title: 'Read the live status',
      description: 'Offline means no live sensor feed is reaching the app.',
      icon: Icons.monitor_heart_outlined,
      accent: AppColors.success,
    ),
    _GuideScene(
      title: 'Understand alerts',
      description: 'Fall candidates are experimental and may be false alarms.',
      icon: Icons.warning_amber_rounded,
      accent: AppColors.danger,
    ),
    _GuideScene(
      title: 'Know what is unavailable',
      description:
          'Demo locations and missing sensor values are not live hardware data.',
      icon: Icons.shield_outlined,
      accent: AppColors.info,
    ),
  ];

  Timer? _timer;
  int _sceneIndex = 0;
  bool _playing = true;

  @override
  void initState() {
    super.initState();
    _startPlayback();
  }

  void _startPlayback() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_sceneIndex == _scenes.length - 1) {
        _timer?.cancel();
        setState(() => _playing = false);
      } else {
        setState(() => _sceneIndex++);
      }
    });
  }

  void _togglePlayback() {
    if (_playing) {
      _timer?.cancel();
      setState(() => _playing = false);
      return;
    }

    if (_sceneIndex == _scenes.length - 1) {
      setState(() => _sceneIndex = 0);
    }
    setState(() => _playing = true);
    _startPlayback();
  }

  void _moveScene(int direction) {
    _timer?.cancel();
    final nextIndex = (_sceneIndex + direction).clamp(0, _scenes.length - 1);
    setState(() {
      _sceneIndex = nextIndex;
      if (nextIndex == _scenes.length - 1) _playing = false;
    });
    if (_playing) _startPlayback();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scene = _scenes[_sceneIndex];
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.monitoring,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '20-SECOND WALKTHROUGH',
                  style: TextStyle(
                    color: AppColors.monitoringMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.1,
                  ),
                ),
              ),
              Text(
                '${_sceneIndex + 1} / ${_scenes.length}',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 450),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0.04, 0),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            ),
            child: _GuideArtwork(
              key: ValueKey(_sceneIndex),
              scene: scene,
              index: _sceneIndex,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            scene.title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            scene.description,
            style: const TextStyle(
              color: AppColors.monitoringMuted,
              fontSize: 13,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: LinearProgressIndicator(
              value: (_sceneIndex + 1) / _scenes.length,
              minHeight: 4,
              backgroundColor: Colors.white.withValues(alpha: 0.16),
              color: scene.accent,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              IconButton(
                tooltip: _playing ? 'Pause walkthrough' : 'Play walkthrough',
                onPressed: _togglePlayback,
                color: Colors.white,
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                ),
              ),
              IconButton(
                tooltip: 'Previous step',
                onPressed: _sceneIndex == 0 ? null : () => _moveScene(-1),
                color: Colors.white70,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.skip_previous_rounded),
              ),
              IconButton(
                tooltip: 'Next step',
                onPressed: _sceneIndex == _scenes.length - 1
                    ? null
                    : () => _moveScene(1),
                color: Colors.white70,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.skip_next_rounded),
              ),
              const Spacer(),
              Text(
                _playing ? 'Playing' : 'Paused',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GuideArtwork extends StatelessWidget {
  const _GuideArtwork({required this.scene, required this.index, super.key});

  final _GuideScene scene;
  final int index;

  @override
  Widget build(BuildContext context) => SizedBox(
    key: key,
    height: 126,
    child: Center(
      child: index == 0
          ? Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _ArtworkIcon(Icons.phone_iphone_rounded, scene.accent),
                const SizedBox(width: 8),
                const Icon(
                  Icons.arrow_forward_rounded,
                  color: Colors.white54,
                  size: 18,
                ),
                const SizedBox(width: 8),
                _ArtworkIcon(Icons.wifi_rounded, scene.accent),
                const SizedBox(width: 8),
                const Icon(
                  Icons.arrow_forward_rounded,
                  color: Colors.white54,
                  size: 18,
                ),
                const SizedBox(width: 8),
                _ArtworkIcon(Icons.health_and_safety_rounded, scene.accent),
              ],
            )
          : Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: scene.accent.withValues(alpha: 0.15),
                shape: BoxShape.circle,
                border: Border.all(
                  color: scene.accent.withValues(alpha: 0.5),
                  width: 1.5,
                ),
              ),
              child: Icon(scene.icon, color: scene.accent, size: 42),
            ),
    ),
  );
}

class _ArtworkIcon extends StatelessWidget {
  const _ArtworkIcon(this.icon, this.color);

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 54,
    height: 64,
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(15),
      border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
    ),
    child: Icon(icon, color: color, size: 27),
  );
}

class _GuideStep extends StatelessWidget {
  const _GuideStep({
    required this.number,
    required this.title,
    required this.description,
    required this.icon,
  });

  final String number;
  final String title;
  final String description;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 9),
    child: Padding(
      padding: const EdgeInsets.all(15),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(icon, color: Theme.of(context).colorScheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$number  $title',
                  style: const TextStyle(
                    color: AppColors.ink,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: const TextStyle(
                    color: AppColors.muted,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _SafetyNote extends StatelessWidget {
  const _SafetyNote({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: AppColors.border),
      borderRadius: BorderRadius.circular(18),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: AppColors.primary, size: 22),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: AppColors.ink,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                description,
                style: const TextStyle(
                  color: AppColors.muted,
                  fontSize: 13,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _GuideScene {
  const _GuideScene({
    required this.title,
    required this.description,
    required this.icon,
    required this.accent,
  });

  final String title;
  final String description;
  final IconData icon;
  final Color accent;
}
