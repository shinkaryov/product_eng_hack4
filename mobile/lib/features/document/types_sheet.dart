import 'package:flutter/material.dart';

import '../../data/categories.dart';
import '../../ui/fd.dart';
import 'doc_helpers.dart';

/// "What is this document?" sheet (design Types.dc.html). Returns the picked
/// backend type code (e.g. HOME_INSURANCE) or null. With [pickable] false it only
/// shows what we read / don't store (no radio, no "Use this type").
Future<String?> showTypesSheet(BuildContext context, {String? selected, bool pickable = true}) =>
    showFdSheet<String>(context, builder: (_) => _TypesSheet(selected: docTypeOf(selected)?.code, pickable: pickable));

class _TypesSheet extends StatefulWidget {
  const _TypesSheet({this.selected, required this.pickable});
  final String? selected;
  final bool pickable;

  @override
  State<_TypesSheet> createState() => _TypesSheetState();
}

class _TypesSheetState extends State<_TypesSheet> {
  late String? _picked = widget.selected;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    final suggested = docTypeOf(widget.selected);
    final String? meta = !widget.pickable
        ? 'These are the documents we can read.'
        : suggested != null
            ? 'We suggested ${lowerFirst(suggested.label)}. Change it if that’s wrong.'
            : null;

    final children = <Widget>[
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Semantics(header: true, child: Text('What is this document?', style: FdType.headline)),
        if (meta != null) Text(meta, style: FdType.meta.copyWith(color: c.inkSecondary)),
      ]),
    ];

    for (final g in DocGroup.values) {
      final types = docTypes.where((t) => t.group == g).toList();
      if (types.isEmpty) continue;
      children.add(FdGroupLabel(groupSheetLabel(g)));
      children.add(FdList(children: [for (final t in types) _typeRow(t)]));
    }

    children.add(const FdGroupLabel('We don’t store'));
    children.add(FdList(children: [
      for (final (_, title, meta) in blockedTypes)
        FdListRow(
          title: title,
          titleColor: c.inkSecondary,
          meta: meta,
          metaWraps: true,
          leading: FdIcon(FdIcons.ban, color: c.inkSecondary),
        ),
    ]));

    children.add(widget.pickable
        ? FdButton('Use this type', block: true, onPressed: _picked == null ? null : () => Navigator.of(context).pop(_picked))
        : FdButton('Done', block: true, onPressed: () => Navigator.of(context).pop()));

    return FdGapColumn(gap: FdSpace.s4, children: children);
  }

  Widget _typeRow(DocType t) {
    if (!widget.pickable) return FdListRow(title: t.label);
    final on = _picked == t.code;
    return Semantics(
      selected: on,
      inMutuallyExclusiveGroup: true,
      child: FdListRow(
        title: t.label,
        leading: FdRadio(selected: on),
        background: on ? context.fd.brandSoft : null,
        onTap: () => setState(() => _picked = t.code),
      ),
    );
  }
}
