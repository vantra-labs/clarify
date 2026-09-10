import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../core/localization.dart';
import '../core/theme/design_tokens.dart';
import 'clarify_button.dart';
import 'clarify_glass.dart';
import 'clarify_surface.dart';
import 'clarify_toast.dart';

/// Окно профиля пользователя — по клику на аватар (сейчас: участники команды).
/// Содержание продумано по запросу пользователя, SOCIAL_PLAN.md §4.4: аватар+имя,
/// код друга скрыт, если это не собственный профиль, роль в команде — только если
/// открыто из контекста конкретной команды, кнопка добавить в друзья/написать в
/// зависимости от текущего статуса дружбы, свой профиль — кнопка в Настройки.
void showUserProfileModal({
  required BuildContext context,
  required String userId,
  required String currentLang,
  String? teamRole,
  VoidCallback? onOpenOwnSettings,
  void Function(String userId, String name)? onOpenConversation,
}) {
  showClarifyResponsiveSurface(
    context: context,
    builder: (context) => _UserProfileModal(
      userId: userId,
      currentLang: currentLang,
      teamRole: teamRole,
      onOpenOwnSettings: onOpenOwnSettings,
      onOpenConversation: onOpenConversation,
    ),
  );
}

class _UserProfileModal extends StatefulWidget {
  final String userId;
  final String currentLang;
  final String? teamRole;
  final VoidCallback? onOpenOwnSettings;
  final void Function(String userId, String name)? onOpenConversation;

  const _UserProfileModal({required this.userId, required this.currentLang, this.teamRole, this.onOpenOwnSettings, this.onOpenConversation});

  @override
  State<_UserProfileModal> createState() => _UserProfileModalState();
}

class _UserProfileModalState extends State<_UserProfileModal> {
  Map<String, dynamic>? _profile;
  String _friendshipStatus = 'none';
  bool _isSelf = false;
  bool _isLoading = true;
  bool _isActing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final me = Supabase.instance.client.auth.currentUser?.id;
    _isSelf = me == widget.userId;
    try {
      final profile = await Supabase.instance.client.from('profiles').select().eq('user_id', widget.userId).maybeSingle();
      final status = _isSelf ? 'self' : await Supabase.instance.client.rpc('get_friendship_status', params: {'other_id': widget.userId}) as String;
      if (mounted) {
        setState(() {
          _profile = profile;
          _friendshipStatus = status;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _addFriend() async {
    final code = _profile?['friend_code'] as String?;
    if (code == null || _isActing) return;
    setState(() => _isActing = true);
    try {
      final response = await Supabase.instance.client.rpc('send_friend_request', params: {'target_code': code});
      if (mounted) {
        ClarifyToast.show(context, response.toString(), variant: response.toString().startsWith('Успех') ? ClarifyToastVariant.success : ClarifyToastVariant.danger);
        if (response.toString().startsWith('Успех')) setState(() => _friendshipStatus = 'pending_sent');
      }
    } catch (e) {
      if (mounted) ClarifyToast.show(context, '${'Ошибка сети: '.tr(widget.currentLang)}$e', variant: ClarifyToastVariant.danger);
    } finally {
      if (mounted) setState(() => _isActing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final name = (_profile?['full_name'] as String?)?.trim();
    final displayName = (name == null || name.isEmpty) ? 'Без имени'.tr(widget.currentLang) : name;
    final avatarUrl = _profile?['avatar_url'] as String?;

    final content = _isLoading
        ? const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 40,
                backgroundColor: t.accentSoft,
                backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl) : null,
                child: avatarUrl == null ? Text(displayName[0].toUpperCase(), style: TextStyle(color: t.accent, fontSize: 30, fontWeight: FontWeight.bold)) : null,
              ),
              const SizedBox(height: 16),
              Text(displayName, style: TextStyle(fontFamily: 'Golos Text', fontSize: 20, fontWeight: FontWeight.w700, color: t.text), textAlign: TextAlign.center),
              if (widget.teamRole != null) ...[
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(color: t.accentSoft, borderRadius: BorderRadius.circular(ClarifyRadius.pill)),
                  child: Text(widget.teamRole!, style: TextStyle(color: t.accent, fontSize: 12, fontWeight: FontWeight.bold)),
                ),
              ],
              if (_isSelf && _profile?['friend_code'] != null) ...[
                const SizedBox(height: 12),
                Text("${'Код друга: '.tr(widget.currentLang)}${_profile!['friend_code']}", style: TextStyle(color: t.text3, fontSize: 13, letterSpacing: 1)),
              ],
              const SizedBox(height: 24),
              _buildActions(t),
            ],
          );

    // Раньше — всегда десктопная плавающая карточка фиксированной ширины
    // (showClarifySurface), даже на мобильном: на большом тёмном экране это
    // читалось как "сначала полноэкранная загрузка, потом маленькая плашка"
    // — единственный диалог в приложении без адаптива под мобильный шторкой.
    if (isClarifyDialogMobile(context)) {
      return Padding(
        padding: EdgeInsets.fromLTRB(24, 4, 24, MediaQuery.of(context).padding.bottom + 24),
        child: content,
      );
    }

    return Center(
      child: Material(
        color: Colors.transparent,
        child: ClarifyGlass(
          borderRadius: BorderRadius.circular(ClarifyRadius.lg),
          padding: const EdgeInsets.all(28),
          child: SizedBox(width: 340, child: content),
        ),
      ),
    );
  }

  Widget _buildActions(ClarifyTokens t) {
    if (_isSelf) {
      return ClarifyButton(
        label: 'Настройки профиля'.tr(widget.currentLang),
        variant: ClarifyButtonVariant.outline,
        fullWidth: true,
        onPressed: () {
          Navigator.of(context).pop();
          widget.onOpenOwnSettings?.call();
        },
      );
    }

    if (_friendshipStatus == 'accepted') {
      return ClarifyButton(
        icon: LucideIcons.messageCircle,
        label: 'Написать'.tr(widget.currentLang),
        variant: ClarifyButtonVariant.filled,
        fullWidth: true,
        onPressed: widget.onOpenConversation == null
            ? null
            : () {
                Navigator.of(context).pop();
                final name = (_profile?['full_name'] as String?)?.trim() ?? 'Без имени'.tr(widget.currentLang);
                widget.onOpenConversation!(widget.userId, name);
              },
      );
    }

    if (_friendshipStatus == 'pending_sent') {
      return ClarifyButton(
        label: 'Заявка отправлена'.tr(widget.currentLang),
        variant: ClarifyButtonVariant.outline,
        fullWidth: true,
        onPressed: null,
      );
    }

    if (_friendshipStatus == 'pending_received') {
      return Text('Этот пользователь уже отправил вам заявку — примите её в разделе «Друзья».'.tr(widget.currentLang), textAlign: TextAlign.center, style: TextStyle(color: t.text3, fontSize: 13));
    }

    return ClarifyButton(
      icon: LucideIcons.userPlus,
      label: 'Добавить в друзья'.tr(widget.currentLang),
      variant: ClarifyButtonVariant.filled,
      fullWidth: true,
      loading: _isActing,
      onPressed: _isActing ? null : _addFriend,
    );
  }
}
