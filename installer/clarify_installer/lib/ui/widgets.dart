import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme.dart';

/// Кнопка того же языка, что ClarifyButton в самом приложении: pill-форма,
/// акцентная заливка либо обводка, никакого стокового вида Material.
class InstallerButton extends StatefulWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool primary;
  final bool expand;

  const InstallerButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.primary = false,
    this.expand = false,
  });

  @override
  State<InstallerButton> createState() => _InstallerButtonState();
}

class _InstallerButtonState extends State<InstallerButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final background = widget.primary
        ? (_hovered ? InstallerTokens.accentHover : InstallerTokens.accent)
        : (_hovered ? InstallerTokens.surface : Colors.transparent);
    final foreground = widget.primary
        ? InstallerTokens.onAccent
        : (enabled ? InstallerTokens.text : InstallerTokens.text3);

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
        onTap: widget.onPressed,
        child: AnimatedScale(
          scale: _pressed ? 0.98 : 1,
          duration: InstallerMotion.fast,
          curve: InstallerMotion.standard,
          child: AnimatedContainer(
            duration: InstallerMotion.base,
            curve: InstallerMotion.standard,
            width: widget.expand ? double.infinity : null,
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
            decoration: BoxDecoration(
              color: enabled ? background : InstallerTokens.surfaceSunken,
              borderRadius: BorderRadius.circular(InstallerRadius.pill),
              border: Border.all(
                color: widget.primary ? Colors.transparent : InstallerTokens.borderStrong,
              ),
              boxShadow: widget.primary && enabled
                  ? [
                      BoxShadow(
                        color: InstallerTokens.accent.withValues(alpha: _hovered ? 0.45 : 0.28),
                        blurRadius: _hovered ? 26 : 18,
                        offset: const Offset(0, 6),
                      ),
                    ]
                  : null,
            ),
            child: Row(
              mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (widget.icon != null) ...[
                  Icon(widget.icon, size: 18, color: foreground),
                  const SizedBox(width: 10),
                ],
                Text(
                  widget.label,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    height: 1.0,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Переключатель опции установки. Своя отрисовка вместо Switch/Checkbox —
/// стоковые виджеты Material узнаются мгновенно и сразу выдают «сделано на
/// коленке» (то же правило, что и в самом приложении).
class InstallerOption extends StatefulWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final bool value;
  final ValueChanged<bool>? onChanged;

  const InstallerOption({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.value,
    required this.onChanged,
  });

  @override
  State<InstallerOption> createState() => _InstallerOptionState();
}

class _InstallerOptionState extends State<InstallerOption> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onChanged != null;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: enabled ? () => widget.onChanged!(!widget.value) : null,
        child: AnimatedContainer(
          duration: InstallerMotion.base,
          curve: InstallerMotion.standard,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: _hovered ? InstallerTokens.surface : InstallerTokens.surfaceSunken,
            borderRadius: BorderRadius.circular(InstallerRadius.md),
            border: Border.all(
              color: widget.value ? InstallerTokens.accent.withValues(alpha: 0.55) : InstallerTokens.border,
            ),
          ),
          child: Row(
            children: [
              Icon(
                widget.icon,
                size: 18,
                color: widget.value ? InstallerTokens.accent : InstallerTokens.text3,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      style: const TextStyle(
                        color: InstallerTokens.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.subtitle,
                      style: const TextStyle(color: InstallerTokens.text3, fontSize: 12, height: 1.35),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _Check(value: widget.value),
            ],
          ),
        ),
      ),
    );
  }
}

class _Check extends StatelessWidget {
  final bool value;

  const _Check({required this.value});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: InstallerMotion.base,
      curve: InstallerMotion.standard,
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: value ? InstallerTokens.accent : Colors.transparent,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(
          color: value ? InstallerTokens.accent : InstallerTokens.borderStrong,
          width: 1.5,
        ),
      ),
      child: AnimatedOpacity(
        opacity: value ? 1 : 0,
        duration: InstallerMotion.fast,
        child: const Icon(LucideIcons.check, size: 14, color: Colors.white),
      ),
    );
  }
}

/// Полоса прогресса с мягким акцентным свечением — единственный элемент,
/// который человек разглядывает целую минуту, поэтому не стоковый
/// LinearProgressIndicator.
class InstallerProgressBar extends StatelessWidget {
  final double value;

  const InstallerProgressBar({super.key, required this.value});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth * value.clamp(0.0, 1.0);
        return Container(
          height: 6,
          decoration: BoxDecoration(
            color: InstallerTokens.surfaceSunken,
            borderRadius: BorderRadius.circular(InstallerRadius.pill),
            border: Border.all(color: InstallerTokens.border),
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: AnimatedContainer(
              duration: InstallerMotion.slow,
              curve: InstallerMotion.standard,
              width: width,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [InstallerTokens.accent, InstallerTokens.accentHover],
                ),
                borderRadius: BorderRadius.circular(InstallerRadius.pill),
                boxShadow: [
                  BoxShadow(
                    color: InstallerTokens.accent.withValues(alpha: 0.5),
                    blurRadius: 12,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Логотип: та же буквенная марка, что в приложении (Unbounded), в акцентном
/// квадрате со скруглением — узнаётся с первого кадра.
class InstallerLogo extends StatelessWidget {
  final double size;

  const InstallerLogo({super.key, this.size = 56});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [InstallerTokens.accentHover, InstallerTokens.accent],
        ),
        borderRadius: BorderRadius.circular(size * 0.3),
        boxShadow: [
          BoxShadow(
            color: InstallerTokens.accent.withValues(alpha: 0.35),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Center(
        child: Text(
          'C',
          style: TextStyle(
            fontFamily: 'Unbounded',
            fontSize: size * 0.46,
            fontWeight: FontWeight.w700,
            color: Colors.white,
            height: 1.0,
          ),
        ),
      ),
    );
  }
}

/// Кнопки окна. Полноценного тайтлбара у установщика нет — только «свернуть» и
/// «закрыть», разворачивать окно фиксированного размера незачем.
class WindowControls extends StatelessWidget {
  final VoidCallback onMinimize;
  final VoidCallback onClose;
  final bool closeEnabled;

  const WindowControls({
    super.key,
    required this.onMinimize,
    required this.onClose,
    this.closeEnabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _WindowButton(icon: LucideIcons.minus, onTap: onMinimize),
        _WindowButton(
          icon: LucideIcons.x,
          onTap: closeEnabled ? onClose : null,
          danger: true,
        ),
      ],
    );
  }
}

class _WindowButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final bool danger;

  const _WindowButton({required this.icon, required this.onTap, this.danger = false});

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: InstallerMotion.fast,
          width: 42,
          height: 34,
          decoration: BoxDecoration(
            color: !enabled
                ? Colors.transparent
                : _hovered
                    ? (widget.danger ? InstallerTokens.danger.withValues(alpha: 0.9) : InstallerTokens.surface)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(InstallerRadius.sm),
          ),
          child: Icon(
            widget.icon,
            size: 16,
            color: enabled
                ? (_hovered && widget.danger ? Colors.white : InstallerTokens.text2)
                : InstallerTokens.text3.withValues(alpha: 0.4),
          ),
        ),
      ),
    );
  }
}
