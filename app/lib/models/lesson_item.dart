class LessonItem {
  final String id;
  final String language; // "en" or "ja"
  final String
  category; // "alphabet", "kanji", "vocabulary_core", "it_workplace"
  final String targetText;
  final String phoneticOrKana;
  final String meaningVi;
  final String workplaceContext;
  final String workplaceContextVi;
  final List<String> strokeOrderHints;
  final int difficultyLevel;

  LessonItem({
    required this.id,
    required this.language,
    required this.category,
    required this.targetText,
    required this.phoneticOrKana,
    required this.meaningVi,
    required this.workplaceContext,
    required this.workplaceContextVi,
    required this.strokeOrderHints,
    required this.difficultyLevel,
  });

  factory LessonItem.fromJson(Map<String, dynamic> json) {
    return LessonItem(
      id: json['id'] as String,
      language: json['language'] as String,
      category: json['category'] as String,
      targetText: json['target_text'] as String,
      phoneticOrKana: json['phonetic_or_kana'] as String,
      meaningVi: json['meaning_vi'] as String,
      workplaceContext: json['workplace_context'] as String,
      workplaceContextVi: json['workplace_context_vi'] as String,
      strokeOrderHints:
          (json['stroke_order_hints'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      difficultyLevel: (json['difficulty_level'] as num?)?.toInt() ?? 1,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'language': language,
      'category': category,
      'target_text': targetText,
      'phonetic_or_kana': phoneticOrKana,
      'meaning_vi': meaningVi,
      'workplace_context': workplaceContext,
      'workplace_context_vi': workplaceContextVi,
      'stroke_order_hints': strokeOrderHints,
      'difficulty_level': difficultyLevel,
    };
  }
}
