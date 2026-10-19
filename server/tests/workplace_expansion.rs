use server::data::get_seed_lessons;
use std::collections::{HashMap, HashSet};
#[test]
fn workplace_expansion_preserves_all_155_existing_lessons_and_adds_200_distinct_entries() {
    let lessons = get_seed_lessons();
    let old = serde_json::to_vec(&lessons[..155]).unwrap();
    let digest = old.iter().fold(0xcbf29ce484222325u64, |h, b| {
        (h ^ u64::from(*b)).wrapping_mul(0x100000001b3)
    });
    assert_eq!(
        digest, 0x20dd77ae157b7505,
        "the legacy catalog order/content changed"
    );
    assert_eq!(lessons.len(), 355);
    assert_eq!(
        lessons.iter().map(|l| &l.id).collect::<HashSet<_>>().len(),
        355
    );
    let added = &lessons[155..];
    let mut groups = HashMap::new();
    for lesson in added {
        *groups
            .entry((lesson.language.as_str(), lesson.category.as_str()))
            .or_insert(0usize) += 1;
        for text in [
            &lesson.target_text,
            &lesson.phonetic_or_kana,
            &lesson.meaning_vi,
            &lesson.workplace_context,
            &lesson.workplace_context_vi,
        ] {
            assert!(!text.trim().is_empty(), "{}", lesson.id);
            assert!(!text.contains("TODO"));
            assert!(!text.contains("placeholder"));
        }
        assert!(
            lesson.workplace_context.len() > lesson.target_text.len(),
            "{} needs an actual contextual example",
            lesson.id
        );
        assert!(lesson.stroke_order_hints.len() >= 2);
        assert!((2..=3).contains(&lesson.difficulty_level));
        assert_ne!(lesson.category, "custom");
        if lesson.language == "ja" {
            assert!(lesson
                .phonetic_or_kana
                .chars()
                .any(|c| ('\u{3040}'..='\u{30ff}').contains(&c)));
        } else {
            assert!(lesson.phonetic_or_kana.starts_with('/'));
        }
    }
    assert_eq!(
        added
            .iter()
            .map(|l| (&l.language, &l.target_text))
            .collect::<HashSet<_>>()
            .len(),
        200
    );
    assert_eq!(added.iter().filter(|l| l.language == "ja").count(), 100);
    assert_eq!(added.iter().filter(|l| l.language == "en").count(), 100);
    for language in ["en", "ja"] {
        for category in [
            "horenso_writing",
            "cloud_systems",
            "requirements_negotiation",
        ] {
            assert!(
                groups
                    .get(&(language, category))
                    .copied()
                    .unwrap_or_default()
                    >= 30
            );
        }
    }
}
