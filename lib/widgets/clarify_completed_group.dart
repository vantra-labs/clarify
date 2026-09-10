import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/app_settings.dart';
import '../core/localization.dart';
import '../core/theme/design_tokens.dart';

/// Блок выполненных задач в конце списка — свёрнутый по умолчанию.
///
/// Выполненные и раньше лежали отдельным блоком внизу, но на длинной истории
/// это десятки зачёркнутых строк, через которые приходится прокручивать. Здесь
/// они остаются на месте и на виду («Выполнено: 14»), но не занимают экран.
///
/// Именно свёртка, а не отдельный раздел в меню: раздел «История» уже есть (для
/// задач старше окна загрузки), и два похожих по названию места человеку
/// пришлось бы различать на глаз.
class ClarifyCompletedGroup extends StatelessWidget {
  final String currentLang;
  final List<Map<String, dynamic>> tasks;
  final Widget Function(Map<String, dynamic> task) buildTaskCard;

  const ClarifyCompletedGroup({
    super.key,
    required this.currentLang,
    required this.tasks,
    required this.buildTaskCard,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return ValueListenableBuilder<bool>(
      valueListenable: AppSettings.completedExpanded,
      builder: (context, expanded, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(ClarifyRadius.sm),
                child: InkWell(
                  onTap: () => AppSettings.setCompletedExpanded(!expanded),
                  borderRadius: BorderRadius.circular(ClarifyRadius.sm),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                    child: Row(
                      children: [
                        // Поворот вместо двух разных значков: так видно, что это
                        // одна и та же стрелка, а не две кнопки.
                        AnimatedRotation(
                          turns: expanded ? 0.25 : 0,
                          duration: ClarifyMotion.base,
                          child: Icon(LucideIcons.chevronRight, size: 18, color: t.text3),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Выполнено'.tr(currentLang),
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: t.text2,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: t.surfaceSunken,
                            borderRadius: BorderRadius.circular(ClarifyRadius.pill),
                          ),
                          child: Text(
                            '${tasks.length}',
                            style: TextStyle(fontSize: 12, color: t.text3, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // Свёрнутый блок не строит карточки вовсе, а не прячет готовые:
            // иначе сотня выполненных задач продолжала бы стоить столько же,
            // сколько и раскрытая.
            if (expanded)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: tasks.map(buildTaskCard).toList(),
              ),
          ],
        );
      },
    );
  }
}
