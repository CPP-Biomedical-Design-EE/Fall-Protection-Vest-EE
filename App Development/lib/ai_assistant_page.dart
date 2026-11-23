import 'package:flutter/material.dart';
import 'package:fall_protection_vest_app/ai_assistant.dart';
import 'package:fall_protection_vest_app/app_colors.dart';

class AIAssistantPage extends StatefulWidget {
  const AIAssistantPage({this.service, this.setupError, super.key});

  final AssistantService? service;
  final String? setupError;

  @override
  State<AIAssistantPage> createState() => _AIAssistantPageState();
}

class _AIAssistantPageState extends State<AIAssistantPage> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final List<_AssistantMessage> _messages = [
    const _AssistantMessage(
      isUser: false,
      text:
          'Hi! I can help with setup, accounts, maps, and app features. I cannot diagnose a medical issue or send an emergency alert.',
    ),
  ];
  bool _sending = false;
  String? _error;

  static const _suggestions = [
    'How do I connect my vest?',
    'What does “fall candidate” mean?',
    'Can my family receive alerts?',
  ];

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _sendMessage([String? suggestedMessage]) async {
    final message = (suggestedMessage ?? _messageController.text).trim();
    if (message.isEmpty || _sending) return;
    if (message.length > 1000) {
      setState(() => _error = 'Keep your question under 1,000 characters.');
      return;
    }

    final service = widget.service;
    if (service == null) {
      setState(() {
        _error =
            widget.setupError ??
            'Firebase AI Logic is not available in this build. Check the Firebase setup in Settings or use Help & safety.';
      });
      return;
    }

    _messageController.clear();
    setState(() {
      _error = null;
      _sending = true;
      _messages.add(_AssistantMessage(isUser: true, text: message));
      _messages.add(const _AssistantMessage(isUser: false, text: ''));
    });
    _scrollToLatestMessage();

    final answer = StringBuffer();
    try {
      await for (final chunk in service.replyTo(message)) {
        answer.write(chunk);
        if (!mounted) return;
        setState(() {
          _messages[_messages.length - 1] = _AssistantMessage(
            isUser: false,
            text: answer.toString(),
          );
        });
        _scrollToLatestMessage();
      }
      if (answer.isEmpty) {
        throw StateError('The assistant returned an empty response.');
      }
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        _messages[_messages.length - 1] = _AssistantMessage(
          isUser: false,
          text: answer.isEmpty
              ? 'I could not get an answer. Check that Firebase AI Logic and App Check are configured, then try again.'
              : answer.toString(),
        );
        _error = 'Assistant request failed: $error';
      });
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _scrollToLatestMessage() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('AI assistant')),
    body: SafeArea(
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: AppColors.goldSoft,
            child: const Text(
              'Questions go to Firebase AI Logic for a reply. Chats are not saved by this app; do not share passwords, medical details, or private contact information.',
              style: TextStyle(color: AppColors.primaryDeep, height: 1.35),
            ),
          ),
          if (widget.setupError != null || widget.service == null)
            _NoticeBanner(
              message:
                  widget.setupError ??
                  'Firebase AI Logic is not configured for this build.',
              isError: true,
            ),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              itemCount: _messages.length,
              itemBuilder: (context, index) =>
                  _MessageBubble(message: _messages[index]),
            ),
          ),
          if (_messages.length == 1 && widget.service != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _suggestions
                    .map(
                      (suggestion) => ActionChip(
                        label: Text(suggestion),
                        onPressed: _sending
                            ? null
                            : () => _sendMessage(suggestion),
                      ),
                    )
                    .toList(),
              ),
            ),
          if (_error != null) _NoticeBanner(message: _error!, isError: true),
          Padding(
            padding: EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    enabled: widget.service != null && !_sending,
                    minLines: 1,
                    maxLines: 4,
                    maxLength: 1000,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendMessage(),
                    decoration: const InputDecoration(
                      hintText: 'Ask a question',
                      counterText: '',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(20)),
                      ),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: 'Send message',
                  onPressed: widget.service == null || _sending
                      ? null
                      : () => _sendMessage(),
                  icon: _sending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send_rounded),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _AssistantMessage {
  const _AssistantMessage({required this.isUser, required this.text});

  final bool isUser;
  final String text;
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final _AssistantMessage message;

  @override
  Widget build(BuildContext context) => Align(
    alignment: message.isUser ? Alignment.centerRight : Alignment.centerLeft,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 600),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: message.isUser ? AppColors.goldSoft : AppColors.surface,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(18),
        ),
        child: message.text.isEmpty
            ? const SizedBox(
                width: 28,
                height: 18,
                child: LinearProgressIndicator(),
              )
            : SelectableText(message.text),
      ),
    ),
  );
}

class _NoticeBanner extends StatelessWidget {
  const _NoticeBanner({required this.message, this.isError = false});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: isError ? AppColors.dangerSoft : AppColors.surfaceSoft,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(
      message,
      style: TextStyle(color: isError ? AppColors.danger : AppColors.ink),
    ),
  );
}
