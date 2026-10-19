use server::data::get_seed_lessons;
use std::collections::HashSet;

#[test]
fn phase3_curriculum_supplies_complete_workplace_lessons_without_duplicates() {
    let lessons = get_seed_lessons();
    let expected = [
        ("ja_n4_kaigi", "会議"),
        ("ja_n4_renraku", "連絡"),
        ("ja_n4_soudan", "相談"),
        ("ja_n4_houkoku", "報告"),
        ("ja_n4_shounin", "承認"),
        ("ja_n4_kigen", "期限"),
        ("ja_n4_sekinin", "責任"),
        ("ja_n4_kaizen", "改善"),
        ("ja_n4_shouchi", "承知いたしました"),
        ("ja_n4_irai", "依頼"),
        ("en_biz_negotiate", "negotiate"),
        ("en_biz_agenda", "agenda"),
        ("en_biz_proposal", "proposal"),
        ("en_biz_invoice", "invoice"),
        ("en_biz_consensus", "consensus"),
        ("en_biz_delegate", "delegate"),
        ("en_biz_compliance", "compliance"),
        ("en_biz_postpone", "postpone"),
        ("en_biz_acknowledge", "acknowledge"),
        ("en_biz_objective", "objective"),
    ];
    assert_eq!(
        lessons.iter().map(|l| &l.id).collect::<HashSet<_>>().len(),
        lessons.len()
    );
    for (id, text) in expected {
        let lesson = lessons
            .iter()
            .find(|l| l.id == id)
            .unwrap_or_else(|| panic!("missing {id}"));
        assert_eq!(lesson.target_text, text);
        let japanese = id.starts_with("ja_");
        assert_eq!(lesson.language, if japanese { "ja" } else { "en" });
        assert_eq!(
            lesson.category,
            if japanese {
                "jlpt_n4"
            } else {
                "toeic_business"
            }
        );
        assert!(!lesson.phonetic_or_kana.trim().is_empty());
        assert!(!lesson.meaning_vi.trim().is_empty());
        assert!(!lesson.workplace_context.trim().is_empty());
        assert!(!lesson.workplace_context_vi.trim().is_empty());
        assert!(lesson.stroke_order_hints.len() >= 2);
        assert!(lesson
            .stroke_order_hints
            .iter()
            .all(|h| !h.trim().is_empty()));
        assert!((1..=3).contains(&lesson.difficulty_level));
    }
    assert!(
        lessons.iter().any(|l| l.category == "business_toeic"),
        "legacy category must survive"
    );
}

#[test]
fn phase3_expansion_preserves_the_legacy_prefix_byte_for_byte() {
    let lessons = get_seed_lessons();
    assert_eq!(lessons.len(), 355);
    // FNV-1a snapshot of the JSON of all legacy fields, captured from HEAD
    // before the append. This catches removed, reordered or edited lessons.
    let legacy_json = serde_json::to_vec(&lessons[..135]).unwrap();
    let digest = legacy_json
        .iter()
        .fold(0xcbf29ce484222325u64, |hash, byte| {
            (hash ^ u64::from(*byte)).wrapping_mul(0x100000001b3)
        });
    assert_eq!(digest, 0x0848ae24eb44fe62);
}
