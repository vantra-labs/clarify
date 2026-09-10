import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../core/localization.dart';
import '../core/theme/design_tokens.dart';
import 'clarify_button.dart';
import 'clarify_text_field.dart';
import 'clarify_toast.dart';
import 'clarify_list_card.dart';

/// «Друзья» — три вкладки Друзья/Заявки/Найти (SOCIAL_PLAN.md §3/4.2). Общий
/// виджет для десктопа (внутри MainContentArea) и мобильного (отдельная
/// страница, открывается из Настроек — на нижнем таб-баре и так 4 пункта +
/// FAB, добавлять пятый тесно, решение отличается от буквального текста
/// плана "мобильный таб-бар").
class FriendsScreen extends StatefulWidget {
  final String currentLang;
  final double scale;
  // Переход в профиль друга по тапу на строку убран по прямому запросу —
  // единственное действие на строке теперь кнопка "написать" ниже, без
  // промежуточного экрана профиля.
  final void Function(String userId, String name)? onOpenConversation;
  // На десктопе (внутри MainContentArea) заголовок отсюда — единственный.
  // На мобильном экран уже открывается со своим AppBar(title: "Друзья") в
  // MobilePlannerShell — без этого флага заголовок дублировался бы дважды.
  final bool showHeader;

  const FriendsScreen({super.key, required this.currentLang, this.scale = 1.0, this.onOpenConversation, this.showHeader = true});

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(length: 3, vsync: this);
  final _codeController = TextEditingController();
  bool _isSending = false;

  List<Map<String, dynamic>>? _friends;
  List<Map<String, dynamic>>? _requests;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final friends = await Supabase.instance.client.rpc('list_friends');
      final requests = await Supabase.instance.client.rpc('list_friend_requests');
      if (mounted) {
        setState(() {
          _friends = List<Map<String, dynamic>>.from(friends);
          _requests = List<Map<String, dynamic>>.from(requests);
        });
      }
    } catch (e) {
      if (mounted) setState(() { _friends = []; _requests = []; });
    }
  }

  Future<void> _sendRequest() async {
    final code = _codeController.text.trim();
    if (code.isEmpty || _isSending) return;
    setState(() => _isSending = true);
    try {
      final response = await Supabase.instance.client.rpc('send_friend_request', params: {'target_code': code});
      if (mounted) {
        ClarifyToast.show(
          context,
          response.toString(),
          variant: response.toString().startsWith('Успех') ? ClarifyToastVariant.success : ClarifyToastVariant.danger,
        );
        if (response.toString().startsWith('Успех')) _codeController.clear();
      }
    } catch (e) {
      if (mounted) ClarifyToast.show(context, '${'Ошибка сети: '.tr(widget.currentLang)}$e', variant: ClarifyToastVariant.danger);
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _respond(int requestId, bool accept) async {
    try {
      final response = await Supabase.instance.client.rpc('respond_friend_request', params: {'request_id': requestId, 'accept': accept});
      if (mounted) {
        ClarifyToast.show(context, response.toString(), variant: response.toString().startsWith('Успех') ? ClarifyToastVariant.success : ClarifyToastVariant.danger);
      }
      _load();
    } catch (e) {
      if (mounted) ClarifyToast.show(context, '${'Ошибка сети: '.tr(widget.currentLang)}$e', variant: ClarifyToastVariant.danger);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.showHeader)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
            child: Text('Друзья'.tr(widget.currentLang), style: TextStyle(fontFamily: 'Golos Text', fontSize: 22, fontWeight: FontWeight.w700, color: t.text)),
          ),
        TabBar(
          controller: _tabController,
          isScrollable: true,
          labelColor: t.accent,
          unselectedLabelColor: t.text3,
          indicatorColor: t.accent,
          tabs: [
            Tab(text: 'Друзья'.tr(widget.currentLang)),
            Tab(text: 'Заявки'.tr(widget.currentLang)),
            Tab(text: 'Найти'.tr(widget.currentLang)),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildFriendsList(t),
              _buildRequestsList(t),
              _buildFindTab(t),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFriendsList(ClarifyTokens t) {
    if (_friends == null) return const Center(child: CircularProgressIndicator());
    if (_friends!.isEmpty) {
      return Center(child: Text('Пока нет друзей'.tr(widget.currentLang), style: TextStyle(color: t.text3, fontSize: 15)));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(20),
      itemCount: _friends!.length,
      itemBuilder: (context, index) {
        final f = _friends![index];
        final displayName = (f['full_name'] as String?) ?? 'Без имени'.tr(widget.currentLang);
        return _PersonRow(
          name: displayName,
          avatarUrl: f['avatar_url'] as String?,
          trailing: widget.onOpenConversation == null
              ? null
              : IconButton(
                  icon: Icon(LucideIcons.messageCircle, color: t.accent),
                  tooltip: 'Написать'.tr(widget.currentLang),
                  onPressed: () => widget.onOpenConversation!(f['user_id'] as String, displayName),
                ),
        );
      },
    );
  }

  Widget _buildRequestsList(ClarifyTokens t) {
    if (_requests == null) return const Center(child: CircularProgressIndicator());
    if (_requests!.isEmpty) {
      return Center(child: Text('Нет входящих заявок'.tr(widget.currentLang), style: TextStyle(color: t.text3, fontSize: 15)));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(20),
      itemCount: _requests!.length,
      itemBuilder: (context, index) {
        final r = _requests![index];
        return _PersonRow(
          name: (r['full_name'] as String?) ?? 'Без имени',
          avatarUrl: r['avatar_url'] as String?,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(icon: Icon(LucideIcons.check, color: t.success), onPressed: () => _respond(r['request_id'] as int, true)),
              IconButton(icon: Icon(LucideIcons.x, color: t.danger), onPressed: () => _respond(r['request_id'] as int, false)),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFindTab(ClarifyTokens t) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Код друга'.tr(widget.currentLang), style: TextStyle(color: t.text2, fontSize: 13, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: ClarifyTextField(
                  controller: _codeController,
                  style: TextStyle(color: t.text, letterSpacing: 1.5),
                  textCapitalization: TextCapitalization.characters,
                  hintText: 'Введите код друга'.tr(widget.currentLang),
                ),
              ),
              const SizedBox(width: 12),
              ClarifyButton(
                label: 'Добавить'.tr(widget.currentLang),
                variant: ClarifyButtonVariant.filled,
                loading: _isSending,
                onPressed: _isSending ? null : _sendRequest,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PersonRow extends StatelessWidget {
  final String name;
  final String? avatarUrl;
  final Widget? trailing;

  const _PersonRow({required this.name, this.avatarUrl, this.trailing});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // Без стекла: строк в списке много, и каждое размытие стоит отдельного
    // прохода на каждом кадре прокрутки (см. ClarifyListCard).
    return ClarifyListCard(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: CircleAvatar(
          radius: 18,
          backgroundColor: t.accentSoft,
          backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl!) : null,
          child: avatarUrl == null ? Text(name.isNotEmpty ? name[0].toUpperCase() : '?', style: TextStyle(color: t.accent, fontWeight: FontWeight.bold)) : null,
        ),
        title: Text(name, style: TextStyle(color: t.text, fontWeight: FontWeight.w600)),
        trailing: trailing,
      ),
    );
  }
}
