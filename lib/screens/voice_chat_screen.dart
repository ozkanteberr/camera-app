import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil_plus/flutter_screenutil_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../models/chat_message.dart';
import '../providers/voice_chat_provider.dart';

class VoiceChatScreen extends StatefulWidget {
  const VoiceChatScreen({super.key});

  @override
  State<VoiceChatScreen> createState() => _VoiceChatScreenState();
}

class _VoiceChatScreenState extends State<VoiceChatScreen> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _inputFocusNode = FocusNode();
  late final VoiceChatProvider _provider;
  int _lastMessageCount = 0;

  @override
  void initState() {
    super.initState();
    _provider = context.read<VoiceChatProvider>();
    _textController.text = _provider.draft;
    _lastMessageCount = _provider.messages.length;
    _provider.addListener(_handleProviderChange);
  }

  @override
  void dispose() {
    _provider.removeListener(_handleProviderChange);
    unawaited(_provider.leaveScreen());
    _textController.dispose();
    _scrollController.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  void _handleProviderChange() {
    if (_textController.text != _provider.draft) {
      _textController.value = TextEditingValue(
        text: _provider.draft,
        selection: TextSelection.collapsed(offset: _provider.draft.length),
      );
    }
    if (_lastMessageCount != _provider.messages.length) {
      _lastMessageCount = _provider.messages.length;
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
    );
  }

  String get _languageCode => context.locale.languageCode;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: const Color(0xFF111214),
      appBar: AppBar(
        title: Text('voice_chat_title'.tr()),
        centerTitle: true,
        backgroundColor: const Color(0xFF17191D),
        foregroundColor: Colors.white,
        actions: [
          Consumer<VoiceChatProvider>(
            builder: (context, provider, child) => IconButton(
              tooltip: 'voice_chat_auto_read'.tr(),
              onPressed: () => provider.setAutoRead(!provider.autoRead),
              icon: Icon(
                provider.autoRead
                    ? Icons.volume_up_rounded
                    : Icons.volume_off_rounded,
              ),
            ),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'clear') {
                unawaited(_provider.clearConversation());
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'clear',
                child: Text('voice_chat_clear'.tr()),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Consumer<VoiceChatProvider>(
          builder: (context, provider, child) {
            return Column(
              children: [
                if (provider.errorMessage != null) _buildErrorBanner(provider),
                Expanded(
                  child: provider.messages.isEmpty
                      ? _buildEmptyState(provider)
                      : _buildMessageList(provider),
                ),
                if (provider.messages.isNotEmpty)
                  _buildVoiceControl(provider, compact: true),
                _buildComposer(provider),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildEmptyState(VoiceChatProvider provider) {
    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      behavior: HitTestBehavior.opaque,
      child: Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.symmetric(horizontal: 28.w, vertical: 20.h),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'voice_chat_welcome'.tr(),
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 24.sp, fontWeight: FontWeight.w800),
              ),
              SizedBox(height: 10.h),
              Text(
                'voice_chat_welcome_description'.tr(),
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white60, fontSize: 14.sp, height: 1.45),
              ),
              SizedBox(height: 34.h),
              _buildVoiceControl(provider),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMessageList(VoiceChatProvider provider) {
    final extraItem = provider.isSending ? 1 : 0;
    return ListView.builder(
      controller: _scrollController,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.fromLTRB(14.w, 18.h, 14.w, 12.h),
      itemCount: provider.messages.length + extraItem,
      itemBuilder: (context, index) {
        if (index == provider.messages.length) return _buildThinkingBubble();
        return _buildMessageBubble(provider.messages[index], provider);
      },
    );
  }

  Widget _buildMessageBubble(ChatMessage message, VoiceChatProvider provider) {
    final isUser = message.role == ChatRole.user;
    final isSpeaking = provider.speakingMessageId == message.id;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: 318.w),
        margin: EdgeInsets.only(bottom: 12.h),
        padding: EdgeInsets.fromLTRB(15.w, 11.h, isUser ? 15.w : 8.w, 11.h),
        decoration: BoxDecoration(
          color: isUser ? const Color(0xFF3D66F5) : const Color(0xFF23262C),
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(18.r),
            topRight: Radius.circular(18.r),
            bottomLeft: Radius.circular(isUser ? 18.r : 5.r),
            bottomRight: Radius.circular(isUser ? 5.r : 18.r),
          ),
          border: isUser ? null : Border.all(color: Colors.white10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Flexible(
              child: Text(
                message.text,
                style: TextStyle(color: Colors.white, fontSize: 15.sp, height: 1.38),
              ),
            ),
            if (!isUser) ...[
              SizedBox(width: 5.w),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: isSpeaking ? 'voice_chat_stop_speaking'.tr() : 'voice_chat_read_aloud'.tr(),
                onPressed: () => unawaited(provider.speakMessage(message, _languageCode)),
                icon: Icon(isSpeaking ? Icons.stop_circle_outlined : Icons.volume_up_outlined, color: isSpeaking ? Colors.redAccent : Colors.white70, size: 21.r),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildThinkingBubble() => Align(
        alignment: Alignment.centerLeft,
        child: Container(
          margin: EdgeInsets.only(bottom: 12.h),
          padding: EdgeInsets.symmetric(horizontal: 18.w, vertical: 14.h),
          decoration: BoxDecoration(color: const Color(0xFF23262C), borderRadius: BorderRadius.circular(18.r), border: Border.all(color: Colors.white10)),
          child: SizedBox(width: 18.r, height: 18.r, child: CircularProgressIndicator(strokeWidth: 2.r, color: Colors.white70)),
        ),
      );

  Widget _buildVoiceControl(VoiceChatProvider provider, {bool compact = false}) {
    final listening = provider.isListening;
    final preparing = provider.state == VoiceChatState.preparing;
    final disabled = provider.isSending;
    final baseSize = compact ? 58.r : 92.r;
    final scale = listening ? 1.0 + provider.soundLevel * 0.13 : 1.0;
    return Padding(
      padding: EdgeInsets.only(bottom: compact ? 8.h : 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedScale(
            scale: scale,
            duration: const Duration(milliseconds: 100),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: baseSize,
              height: baseSize,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: listening ? Colors.redAccent : const Color(0xFF3D66F5),
                boxShadow: [
                  BoxShadow(
                    color: (listening ? Colors.redAccent : const Color(0xFF3D66F5))
                        .withValues(alpha: listening ? 0.42 : 0.25),
                    blurRadius: listening ? 28.r : 18.r,
                    spreadRadius: listening ? 6.r : 2.r,
                  ),
                ],
              ),
              child: Material(
                color: Colors.transparent,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: disabled ? null : () => unawaited(provider.toggleListening(_languageCode)),
                  child: Center(
                    child: preparing
                        ? SizedBox(width: 27.r, height: 27.r, child: CircularProgressIndicator(strokeWidth: 2.5.r, color: Colors.white))
                        : Icon(listening ? Icons.stop_rounded : Icons.mic_rounded, color: Colors.white, size: compact ? 29.r : 43.r),
                  ),
                ),
              ),
            ),
          ),
          SizedBox(height: compact ? 6.h : 14.h),
          Text(
            _statusKey(provider).tr(),
            textAlign: TextAlign.center,
            style: TextStyle(color: listening ? Colors.redAccent.shade100 : Colors.white60, fontSize: compact ? 11.sp : 14.sp, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _buildComposer(VoiceChatProvider provider) {
    return Container(
      padding: EdgeInsets.fromLTRB(12.w, 10.h, 12.w, 12.h),
      decoration: const BoxDecoration(
        color: Color(0xFF191B20),
        border: Border(top: BorderSide(color: Colors.white10)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _textController,
              focusNode: _inputFocusNode,
              minLines: 1,
              maxLines: 4,
              enabled: !provider.isSending,
              textInputAction: TextInputAction.newline,
              onChanged: provider.updateDraft,
              style: TextStyle(color: Colors.white, fontSize: 15.sp),
              decoration: InputDecoration(
                hintText: 'voice_chat_input_hint'.tr(),
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: const Color(0xFF25282F),
                contentPadding: EdgeInsets.symmetric(horizontal: 15.w, vertical: 12.h),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(22.r), borderSide: BorderSide.none),
              ),
            ),
          ),
          SizedBox(width: 8.w),
          IconButton.filled(
            tooltip: 'voice_chat_send'.tr(),
            onPressed: provider.canSend
                ? () {
                    _inputFocusNode.unfocus();
                    unawaited(provider.sendMessage(_languageCode));
                  }
                : null,
            style: IconButton.styleFrom(backgroundColor: const Color(0xFF3D66F5), disabledBackgroundColor: Colors.white12),
            icon: provider.isSending
                ? SizedBox(width: 20.r, height: 20.r, child: CircularProgressIndicator(strokeWidth: 2.r, color: Colors.white))
                : const Icon(Icons.send_rounded),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBanner(VoiceChatProvider provider) {
    final error = provider.errorMessage!;
    final message = error.startsWith('voice_chat_') ? error.tr() : error;
    final isPermissionError = error == 'voice_chat_microphone_permission';
    return Material(
      color: Colors.red.shade900,
      child: SafeArea(
        top: false,
        child: ListTile(
          dense: true,
          leading: const Icon(Icons.error_outline, color: Colors.white),
          title: Text(message, style: const TextStyle(color: Colors.white)),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isPermissionError)
                IconButton(
                  tooltip: 'voice_chat_open_settings'.tr(),
                  onPressed: openAppSettings,
                  icon: const Icon(Icons.settings, color: Colors.white),
                ),
              IconButton(
                onPressed: provider.clearError,
                icon: const Icon(Icons.close, color: Colors.white),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _statusKey(VoiceChatProvider provider) {
    switch (provider.state) {
      case VoiceChatState.preparing:
        return 'voice_chat_preparing';
      case VoiceChatState.listening:
        return 'voice_chat_listening';
      case VoiceChatState.sending:
        return 'voice_chat_thinking';
      case VoiceChatState.speaking:
        return 'voice_chat_speaking';
      case VoiceChatState.error:
      case VoiceChatState.idle:
        return 'voice_chat_tap_mic';
    }
  }
}
