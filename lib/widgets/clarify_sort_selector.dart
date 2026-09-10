import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/app_settings.dart';
import '../core/localization.dart';
import '../core/task_sort.dart';
import '../core/theme/design_tokens.dart';

/// Выбор способа сортировки списка задач.
///
/// Один виджет на десктоп и на мобильный: до этого переключатель был только на
/// десктопе, был текстовым и знал ровно два состояния («по времени» /
/// «по приоритету»). Способов стало пять, в строку они уже не помещаются, а
/// заводить два разных элемента под одно и то же действие — верный способ
/// получить два разных поведения.
///
/// Меню, а не выпадающий список: у DropdownButton своя типографика и свои
/// отступы, которые пришлось бы переопределять до неузнаваемости, чтобы попасть
/// в остальной интерфейс.
class ClarifySortSelector extends StatelessWidget {
  final String currentLang;
  final double scale;

  /// Компактный вид — только значок, без текущей подписи. Нужен там, где
  /// строка заголовка и так занята (шапка мобильного экрана задач).
  final bool iconOnly;

  const ClarifySortSelector({
    super.key,
    required this.currentLang,
    this.scale = 1.0,
    this.iconOnly = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return ValueListenableBuilder<TaskSortMode>(
      valueListenable: AppSettings.taskSortMode,
      builder: (context, current, _) {
        return PopupMenuButton<TaskSortMode>(
          initialValue: current,
          tooltip: 'Сортировка'.tr(currentLang),
          color: t.surface2,
          position: PopupMenuPosition.under,
          onSelected: AppSettings.setTaskSortMode,
          itemBuilder: (context) => [
            for (final mode in TaskSortMode.values)
              PopupMenuItem<TaskSortMode>(
                value: mode,
                child: Row(
                  children: [
                    // Галочка занимает место всегда, даже у невыбранных: иначе
                    // подписи разъезжаются по горизонтали при смене режима.
                    SizedBox(
                      width: 22 * scale,
                      child: mode == current
                          ? Icon(LucideIcons.check, size: 15 * scale, color: t.accent)
                          : null,
                    ),
                    Text(
                      mode.label.tr(currentLang),
                      style: TextStyle(
                        color: mode == current ? t.accent : t.text,
                        fontWeight:
                            mode == current ? FontWeight.bold : FontWeight.normal,
                        fontSize: 13 * scale,
                      ),
                    ),
                  ],
                ),
              ),
          ],
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.arrowUpDown, size: 15 * scale, color: t.text2),
              if (!iconOnly) ...[
                SizedBox(width: 8 * scale),
                Text(
                  current.label.tr(currentLang),
                  style: TextStyle(
                    color: t.text2,
                    fontSize: 13 * scale,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
