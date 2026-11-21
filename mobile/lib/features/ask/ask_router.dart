import '../../data/categories.dart';
import '../../data/models.dart';

/// Chat on the backend is per document, so Ask picks the document a question is
/// most likely about by word overlap with what we know about each document.

const _stopwords = {
  'the', 'and', 'for', 'are', 'was', 'were', 'what', 'when', 'where', 'which', 'who', 'whom', 'how', 'does', 'did',
  'do', 'is', 'my', 'our', 'your', 'a', 'an', 'of', 'on', 'in', 'to', 'it', 'its', 'this', 'that', 'there', 'about',
  'say', 'says', 'with', 'from', 'have', 'has', 'can', 'will', 'should', 'would', 'any', 'me', 'we', 'us', 'i', 'be',
  'by', 'at', 'or', 'if', 'than', 'then', 'next', 'last', 'much', 'many', 'tell', 'show', 'find', 'need',
};

/// Words that mean the same thing for routing purposes.
const _synonyms = <String, List<String>>{
  'car': ['auto', 'vehicle'],
  'auto': ['car', 'vehicle'],
  'vehicle': ['car', 'auto'],
  'apartment': ['lease', 'rent', 'rental'],
  'rent': ['lease', 'rental', 'renters'],
  'renter': ['renters', 'rent'],
  'landlord': ['lease'],
  'tenant': ['lease'],
  'policy': ['insurance'],
  'insurance': ['policy'],
  'coverage': ['insurance', 'policy'],
  'premium': ['insurance', 'policy'],
  'license': ['licence', 'driver'],
  'id': ['passport', 'license', 'card'],
  'bill': ['utility', 'invoice'],
  'electric': ['utility', 'electricity'],
  'electricity': ['utility', 'electric'],
  'receipt': ['invoice', 'warranty'],
  'warranty': ['receipt', 'guarantee'],
  'registration': ['vehicle'],
  'health': ['medical'],
  'medical': ['health'],
};

String _stem(String w) {
  if (w.length > 4 && w.endsWith('ies')) return '${w.substring(0, w.length - 3)}y';
  if (w.length > 3 && w.endsWith('s') && !w.endsWith('ss')) return w.substring(0, w.length - 1);
  return w;
}

Set<String> _words(String? text) {
  if (text == null || text.isEmpty) return {};
  return text
      .toLowerCase()
      .replaceAll('’', "'")
      .split(RegExp(r"[^a-z0-9']+"))
      .map((w) => w.replaceAll("'s", '').replaceAll("'", ''))
      .where((w) => w.length >= 2 && !_stopwords.contains(w))
      .map(_stem)
      .toSet();
}

/// Documents Ask can answer from: finished reading and not blocked/failed.
List<Document> askableDocuments(List<Document> docs) {
  final out = docs.where((d) => !d.isWorking && (d.reviewStatus == ReviewStatus.ready || d.reviewStatus == ReviewStatus.reviewRequired)).toList()
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return out;
}

int _score(Set<String> question, Document d) {
  final type = docTypeOf(d.category);
  final strong = <String>{
    ..._words(d.title),
    ..._words(d.displayFilename?.replaceAll(RegExp(r'\.[a-z0-9]+$', caseSensitive: false), '')),
    ..._words(type?.label),
    ..._words(type == null ? null : groupOf(d.category).label),
    ..._words(d.category?.replaceAll('_', ' ')),
  };
  final card = d.card;
  final weak = <String>{
    ..._words(card?.issuer),
    ..._words(card?.holder),
    ..._words(card?.title),
    for (final t in card?.topics ?? const <String>[]) ..._words(t),
    for (final f in card?.keyFacts ?? const <String>[]) ..._words(f),
    ..._words(d.summary),
  };
  var score = 0;
  for (final w in question) {
    final variants = {w, ...?_synonyms[w]?.map(_stem)};
    if (variants.any(strong.contains)) {
      score += 3;
    } else if (variants.any(weak.contains)) {
      score += 1;
    }
  }
  return score;
}

/// The best document for [question], or null when there is nothing to ask.
/// Ties go to the most recent document; when nothing matches at all, [fallback]
/// (the document of the previous question) wins over the most recent one.
Document? pickDocument(String question, List<Document> candidates, {String? fallbackId}) {
  if (candidates.isEmpty) return null;
  final q = _words(question);
  Document? best;
  var bestScore = 0;
  for (final d in candidates) {
    final s = _score(q, d);
    if (s > bestScore) {
      best = d;
      bestScore = s;
    }
  }
  if (best != null) return best;
  if (fallbackId != null) {
    for (final d in candidates) {
      if (d.id == fallbackId) return d;
    }
  }
  return candidates.first;
}

String _inSentence(String title) {
  if (title.length > 1 && title[0] == title[0].toUpperCase() && title[1] == title[1].toLowerCase()) {
    return title[0].toLowerCase() + title.substring(1);
  }
  return title;
}

/// "Try asking" chips built from the user's own documents.
List<String> suggestionsFor(List<Document> candidates) {
  if (candidates.isEmpty) {
    return const [
      'When does my car insurance expire?',
      'Which warranties expire next month?',
      'What does my lease say about early termination?',
    ];
  }
  final out = <String>[];
  void add(String s) {
    if (!out.contains(s)) out.add(s);
  }

  final hasLease = candidates.any((d) => d.category?.toUpperCase() == 'LEASE');
  for (final d in candidates) {
    final title = d.title?.trim();
    final name = _inSentence(title != null && title.isNotEmpty ? title : (docTypeOf(d.category)?.label ?? d.displayName));
    final group = groupOf(d.category);
    final code = d.category?.toUpperCase();
    switch (group) {
      case DocGroup.insurance:
        add('When does my $name expire?');
        add('What is the policy number on my $name?');
      case DocGroup.ids:
        add('When does my $name expire?');
      case DocGroup.vehicle:
        add('When do I need to renew my $name?');
      case DocGroup.warranties:
        add(code == 'WARRANTY' ? 'When does my $name end?' : 'What warranty comes with my $name?');
      case DocGroup.home:
        if (code == 'UTILITY_BILL') {
          add('How much is due on my $name?');
        } else if (code != 'LEASE') {
          add('How do I cancel my $name?');
        }
      case DocGroup.other:
        add('What are the key dates in $name?');
    }
    if (out.length >= 3) break;
  }
  if (hasLease) out.insert(out.isEmpty ? 0 : 1, 'What does my lease say about early termination?');
  return out.take(3).toList();
}
