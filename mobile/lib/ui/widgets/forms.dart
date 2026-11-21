import 'package:flutter/material.dart';

import '../../core/icons.dart';
import '../../core/theme/fd_colors.dart';
import '../../core/theme/fd_tokens.dart';
import '../../core/theme/fd_typography.dart';

/// .fd-field + .fd-input — label above, help or error below.
class FdTextField extends StatelessWidget {
  const FdTextField({
    super.key,
    required this.label,
    this.controller,
    this.help,
    this.error,
    this.placeholder,
    this.obscure = false,
    this.keyboardType,
    this.textInputAction,
    this.onSubmitted,
    this.onChanged,
    this.autofillHints,
    this.autofocus = false,
    this.enabled = true,
    this.textCapitalization = TextCapitalization.none,
  });

  final String label;
  final TextEditingController? controller;
  final String? help;
  final String? error;
  final String? placeholder;
  final bool obscure;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final Iterable<String>? autofillHints;
  final bool autofocus;
  final bool enabled;
  final TextCapitalization textCapitalization;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    final hasError = error != null;
    OutlineInputBorder border(Color color, [double w = 1]) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(FdRadius.md),
          borderSide: BorderSide(color: color, width: w),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Text(label, style: FdType.fieldLabel.copyWith(color: c.ink)),
      const SizedBox(height: FdSpace.s1),
      SizedBox(
        height: FdSize.control,
        child: TextField(
          controller: controller,
          obscureText: obscure,
          keyboardType: keyboardType,
          textInputAction: textInputAction,
          onSubmitted: onSubmitted,
          onChanged: onChanged,
          autofillHints: autofillHints,
          autofocus: autofocus,
          enabled: enabled,
          textCapitalization: textCapitalization,
          autocorrect: !obscure && keyboardType != TextInputType.emailAddress,
          style: FdType.body.copyWith(color: c.ink),
          cursorColor: c.brand,
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: c.surface,
            hintText: placeholder,
            hintStyle: FdType.body.copyWith(color: c.inkTertiary),
            contentPadding: const EdgeInsets.symmetric(horizontal: FdSpace.s4, vertical: 12),
            enabledBorder: border(hasError ? c.danger : c.lineStrong, hasError ? 2 : 1),
            disabledBorder: border(c.line),
            focusedBorder: border(hasError ? c.danger : c.brand, 2),
          ),
        ),
      ),
      if (hasError) ...[
        const SizedBox(height: FdSpace.s1),
        Semantics(
          liveRegion: true,
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: const EdgeInsets.only(top: 2), child: FdIcon.sm(FdIcons.xCircle, color: c.danger)),
            const SizedBox(width: FdSpace.s1),
            Expanded(child: Text(error!, style: FdType.meta.copyWith(color: c.danger, fontWeight: FontWeight.w500))),
          ]),
        ),
      ] else if (help != null) ...[
        const SizedBox(height: FdSpace.s1),
        Text(help!, style: FdType.meta.copyWith(color: c.inkSecondary)),
      ],
    ]);
  }
}

/// .fd-search — sunken search field with icon.
class FdSearchField extends StatelessWidget {
  const FdSearchField({super.key, this.controller, this.placeholder = 'Search by name', this.onChanged, this.semanticLabel = 'Search documents'});
  final TextEditingController? controller;
  final String placeholder;
  final ValueChanged<String>? onChanged;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    return Container(
      height: FdSize.control,
      padding: const EdgeInsets.symmetric(horizontal: FdSpace.s4),
      decoration: BoxDecoration(color: c.surfaceSunken, borderRadius: BorderRadius.circular(FdRadius.md)),
      child: Row(children: [
        FdIcon(FdIcons.search, color: c.inkSecondary),
        const SizedBox(width: FdSpace.s2),
        Expanded(
          child: Semantics(
            label: semanticLabel,
            textField: true,
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              style: FdType.body.copyWith(color: c.ink),
              cursorColor: c.brand,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: placeholder,
                hintStyle: FdType.body.copyWith(color: c.inkTertiary),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

/// .fd-switch
class FdSwitch extends StatelessWidget {
  const FdSwitch({super.key, required this.value, this.onChanged, required this.semanticLabel});
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    return Semantics(
      toggled: value,
      label: semanticLabel,
      button: true,
      child: GestureDetector(
        onTap: onChanged == null ? null : () => onChanged!(!value),
        child: SizedBox(
          width: 52,
          height: 44,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 44,
              height: 26,
              padding: const EdgeInsets.all(3),
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              decoration: BoxDecoration(
                color: onChanged == null ? c.line : (value ? c.brand : c.lineStrong),
                borderRadius: BorderRadius.circular(FdRadius.full),
              ),
              child: Container(width: 20, height: 20, decoration: BoxDecoration(color: c.surface, shape: BoxShape.circle)),
            ),
          ),
        ),
      ),
    );
  }
}

/// .fd-radio
class FdRadio extends StatelessWidget {
  const FdRadio({super.key, required this.selected});
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    return Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: selected ? c.brand : c.lineStrong, width: selected ? 2 : 1.5),
      ),
      child: selected ? Container(width: 10, height: 10, decoration: BoxDecoration(color: c.brand, shape: BoxShape.circle)) : null,
    );
  }
}

/// .fd-option — radio card.
class FdOption extends StatelessWidget {
  const FdOption({super.key, required this.title, this.subtitle, required this.selected, this.onTap, this.trailing, this.enabled = true});
  final String title;
  final String? subtitle;
  final bool selected;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    final fg = enabled ? c.ink : c.inkTertiary;
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: Container(
          padding: const EdgeInsets.all(FdSpace.s4),
          decoration: BoxDecoration(
            color: enabled ? c.surface : c.source,
            borderRadius: BorderRadius.circular(FdRadius.lg),
            border: Border.all(color: selected ? c.brand : c.lineSoft, width: selected ? 2 : 1),
            boxShadow: enabled ? c.shadowCard : null,
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            FdRadio(selected: selected),
            const SizedBox(width: FdSpace.s3),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: FdType.bodyStrong.copyWith(color: fg)),
                if (subtitle != null) ...[const SizedBox(height: 2), Text(subtitle!, style: FdType.meta.copyWith(color: c.inkSecondary))],
              ]),
            ),
            if (trailing != null) ...[const SizedBox(width: FdSpace.s3), trailing!],
          ]),
        ),
      ),
    );
  }
}

/// .fd-composer — chat input with send button.
class FdComposer extends StatelessWidget {
  const FdComposer({super.key, required this.controller, required this.onSend, this.placeholder = 'Ask about your documents', this.busy = false});
  final TextEditingController controller;
  final VoidCallback onSend;
  final String placeholder;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    return Container(
      padding: const EdgeInsets.fromLTRB(FdSpace.s4, FdSpace.s2, FdSpace.s2, FdSpace.s2),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(FdRadius.lg),
        border: Border.all(color: c.lineStrong),
      ),
      child: Row(children: [
        Expanded(
          child: Semantics(
            label: placeholder,
            textField: true,
            child: TextField(
              controller: controller,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => onSend(),
              style: FdType.body.copyWith(color: c.ink),
              cursorColor: c.brand,
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: placeholder,
                hintStyle: FdType.body.copyWith(color: c.inkTertiary),
              ),
            ),
          ),
        ),
        const SizedBox(width: FdSpace.s2),
        _SendButton(onTap: busy ? null : onSend),
      ]),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({this.onTap});
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    return Semantics(
      button: true,
      label: 'Send',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: onTap == null ? c.surfacePressed : c.brand,
            shape: BoxShape.circle,
            boxShadow: onTap == null ? null : c.shadowButton,
          ),
          child: FdIcon(FdIcons.send, color: onTap == null ? c.inkTertiary : c.onBrand),
        ),
      ),
    );
  }
}
