import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/router.dart';
import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../../ui/fd.dart';
import '../add/add_sheet.dart';
import 'ask_router.dart';
import 'ask_widgets.dart';

enum _AskState { thinking, answered, notFound, failed, noDocuments }

/// One question and what came back.
class _Exchange {
  _Exchange(this.question);
  final String question;
  _AskState state = _AskState.thinking;
  Document? doc;
  ChatTurn? turn;
  Object? error;
}

/// Ask tab. The backend answers per document, so each question is routed to the
/// best-matching document and asked in that document's chat session.
class AskScreen extends ConsumerStatefulWidget {
  const AskScreen({super.key, this.initialQuestion});
  final String? initialQuestion;

  @override
  ConsumerState<AskScreen> createState() => _AskScreenState();
}

class _AskScreenState extends ConsumerState<AskScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _exchanges = <_Exchange>[];

  /// Chat session id per document id, for this screen's lifetime.
  final _chats = <String, String>{};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _askInitial(widget.initialQuestion);
  }

  @override
  void didUpdateWidget(AskScreen old) {
    super.didUpdateWidget(old);
    if (widget.initialQuestion != old.initialQuestion) _askInitial(widget.initialQuestion);
  }

  void _askInitial(String? q) {
    final text = q?.trim();
    if (text == null || text.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _send(text);
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    });
  }

  void _update(VoidCallback fn) {
    if (!mounted) return;
    setState(fn);
    _scrollToEnd();
  }

  String? get _lastDocId {
    for (final e in _exchanges.reversed) {
      if (e.doc != null) return e.doc!.id;
    }
    return null;
  }

  Future<void> _send(String raw, {_Exchange? retry}) async {
    final text = raw.trim();
    if (text.isEmpty || _busy) return;
    final ex = retry ?? _Exchange(text);
    final previousDoc = _lastDocId;
    _update(() {
      _busy = true;
      if (retry == null) {
        _exchanges.add(ex);
        _input.clear();
      }
      ex
        ..state = _AskState.thinking
        ..error = null
        ..turn = null;
    });

    try {
      final docs = await ref.read(documentsProvider.future);
      final candidates = askableDocuments(docs);
      final doc = ex.doc ?? pickDocument(text, candidates, fallbackId: previousDoc);
      if (doc == null) {
        _update(() => ex.state = _AskState.noDocuments);
        return;
      }
      _update(() => ex.doc = doc);

      final repo = ref.read(repositoryProvider);
      var chatId = _chats[doc.id];
      if (chatId == null) {
        chatId = (await repo.createChat(doc.id)).id;
        _chats[doc.id] = chatId;
      }
      ChatTurn turn;
      try {
        turn = await repo.ask(chatId, text);
      } on ApiException catch (e) {
        // The session may have gone away: start a fresh one once.
        if (!e.isNotFound) rethrow;
        chatId = (await repo.createChat(doc.id)).id;
        _chats[doc.id] = chatId;
        turn = await repo.ask(chatId, text);
      }
      final hasAnswer = turn.answered && (turn.answer?.trim().isNotEmpty ?? false);
      _update(() {
        ex.turn = turn;
        ex.state = hasAnswer ? _AskState.answered : _AskState.notFound;
      });
    } catch (e) {
      _update(() {
        ex.state = _AskState.failed;
        ex.error = e;
      });
    } finally {
      _update(() => _busy = false);
    }
  }

  Document? _docById(String id, List<Document> docs) {
    for (final d in docs) {
      if (d.id == id) return d;
    }
    return null;
  }

  Widget _answerFor(_Exchange ex, List<Document> docs) {
    final c = context.fd;
    final docName = ex.doc?.displayName;
    switch (ex.state) {
      case _AskState.thinking:
        return AskAnswer(children: [AskThinking(docName == null ? 'Looking through your documents…' : 'Looking through $docName…')]);
      case _AskState.noDocuments:
        return AskAnswer(children: [
          FdNotice(
            icon: FdIcons.file,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('You don’t have any documents I can read yet.'),
              const SizedBox(height: FdSpace.s3),
              FdButton.secondary('Add a document', icon: FdIcons.plus, compact: true, onPressed: () => showAddSheet(context)),
            ]),
          ),
        ]);
      case _AskState.failed:
        final msg = ex.error is ApiException ? (ex.error as ApiException).message : 'Something went wrong. Try again.';
        return AskAnswer(children: [
          FdNotice(
            kind: FdNoticeKind.danger,
            icon: FdIcons.alert,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(msg),
              const SizedBox(height: FdSpace.s3),
              FdButton.secondary('Try again', icon: FdIcons.retry, compact: true, onPressed: _busy ? null : () => _send(ex.question, retry: ex)),
            ]),
          ),
        ]);
      case _AskState.notFound:
        final answer = ex.turn?.answer?.trim();
        return AskAnswer(children: [
          FdNotice(
            icon: FdIcons.search,
            child: Text(answer != null && answer.isNotEmpty ? answer : 'I couldn’t find this in ${docName ?? 'your documents'}.'),
          ),
        ]);
      case _AskState.answered:
        final turn = ex.turn!;
        final sources = <Widget>[];
        if (turn.citations.isEmpty && ex.doc != null) {
          sources.add(AskSourceChip(name: ex.doc!.displayName, onTap: () => openDocument(context, ex.doc!)));
        }
        for (final cite in turn.citations) {
          final d = _docById(cite.documentId, docs) ?? (cite.documentId == ex.doc?.id ? ex.doc : null);
          sources.add(AskSourceChip(
            name: d?.displayName ?? docName ?? 'Document',
            quote: cite.quote,
            onTap: d == null ? null : () => openDocument(context, d),
          ));
        }
        return AskAnswer(children: [
          Text(turn.answer!.trim(), style: FdType.body.copyWith(color: c.ink)),
          if (sources.isNotEmpty) Wrap(spacing: FdSpace.s2, runSpacing: FdSpace.s2, children: sources),
        ]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    final docsAsync = ref.watch(documentsProvider);
    final docs = docsAsync.valueOrNull ?? const <Document>[];
    final showSuggestions = _exchanges.isEmpty && (docsAsync.hasValue || docsAsync.hasError);
    final suggestions = showSuggestions ? suggestionsFor(askableDocuments(docs)) : const <String>[];
    final bottomSafe = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      backgroundColor: c.canvas,
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          const FdAppBar(title: 'Ask', showBack: false),
          Expanded(
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(FdSpace.s5, FdSpace.s2, FdSpace.s5, FdSpace.s6),
              children: [
                FdGapColumn(
                  gap: FdSpace.s4,
                  children: [
                    for (final ex in _exchanges) ...[
                      AskUserBubble(ex.question),
                      _answerFor(ex, docs),
                    ],
                  ],
                ),
                if (suggestions.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.only(top: _exchanges.isEmpty ? 0 : FdSpace.s2),
                    child: FdGapColumn(
                      gap: FdSpace.s2,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Try asking', style: FdType.meta.copyWith(color: c.inkSecondary)),
                        for (final s in suggestions) FdChip(s, multiline: true, onTap: () => _send(s)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          // .fd-footer without the top border; clears the floating bottom bar.
          Container(
            color: c.canvas,
            padding: EdgeInsets.fromLTRB(FdSpace.s5, FdSpace.s3, FdSpace.s5, FdSpace.s3 + FdSize.navBar + FdSpace.s3 + bottomSafe),
            child: FdGapColumn(gap: FdSpace.s2, children: [
              FdComposer(controller: _input, busy: _busy, onSend: () => _send(_input.text)),
              Text(
                'Answers come only from documents you can open.',
                textAlign: TextAlign.center,
                style: FdType.meta.copyWith(color: c.inkSecondary),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
