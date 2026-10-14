use server::data::get_seed_lessons;
use std::collections::HashSet;

#[test]
fn expanded_curriculum_preserves_existing_lessons_and_has_complete_new_content() {
    let lessons = get_seed_lessons();
    for (id, text) in [
        ("ja_hira_a", "あ"),
        ("ja_kata_bug", "バグ"),
        ("ja_it_kaihatsu", "開発"),
        ("en_it_deploy", "deploy"),
        ("en_it_deadline", "deadline"),
        ("en_it_resolve", "resolve"),
    ] {
        assert_eq!(
            lessons.iter().find(|l| l.id == id).unwrap().target_text,
            text
        );
    }
    assert!(
        lessons
            .iter()
            .filter(|l| l.id.starts_with("ja_extra_"))
            .count()
            >= 30
    );
    assert!(
        lessons
            .iter()
            .filter(|l| l.id.starts_with("en_extra_"))
            .count()
            >= 15
    );
    assert_eq!(
        lessons.iter().map(|l| &l.id).collect::<HashSet<_>>().len(),
        lessons.len()
    );
    for lesson in lessons.iter().filter(|l| l.id.contains("_extra_")) {
        assert!(!lesson.target_text.is_empty());
        assert!(!lesson.phonetic_or_kana.is_empty());
        assert!(!lesson.meaning_vi.is_empty());
        assert!(!lesson.workplace_context.is_empty());
        assert!(!lesson.workplace_context_vi.is_empty());
        assert!(lesson.stroke_order_hints.len() >= 2);
        assert!((1..=3).contains(&lesson.difficulty_level));
    }
    for word in [
        "コード",
        "進捗",
        "報告",
        "連絡",
        "相談",
        "standup",
        "idempotent",
        "followup",
    ] {
        assert!(
            lessons.iter().any(|l| l.target_text == word),
            "missing {word}"
        );
    }
}

#[tokio::test]
async fn custom_rows_do_not_prevent_inserting_missing_curriculum_seeds() {
    let Ok(url) = std::env::var("TEST_DATABASE_URL") else {
        return;
    };
    let pool = sqlx::postgres::PgPoolOptions::new()
        .max_connections(1)
        .connect(&url)
        .await
        .unwrap();
    sqlx::migrate!("./migrations").run(&pool).await.unwrap();
    // A session-local table keeps this regression independent of other DB tests.
    sqlx::query("CREATE TEMP TABLE lessons (LIKE public.lessons INCLUDING ALL)")
        .execute(&pool)
        .await
        .unwrap();
    let seeds = get_seed_lessons();
    server::db::seed_lessons_if_empty(&pool, &seeds[..1])
        .await
        .unwrap();
    for id in ["upgrade_custom_1", "upgrade_custom_2"] {
        sqlx::query("INSERT INTO lessons (id, language, category, target_text, phonetic_or_kana, meaning_vi, workplace_context, workplace_context_vi, stroke_order_hints, difficulty_level) SELECT $1, 'custom', 'custom', $1, '', 'Custom card', '', '', '[]'::jsonb, 2 FROM lessons LIMIT 1")
            .bind(id).execute(&pool).await.unwrap();
    }
    sqlx::query("UPDATE lessons SET meaning_vi = 'Preserve cached content' WHERE id = $1")
        .bind(&seeds[0].id)
        .execute(&pool)
        .await
        .unwrap();
    server::db::seed_lessons_if_empty(&pool, &seeds[..3])
        .await
        .unwrap();
    let (count,): (i64,) =
        sqlx::query_as("SELECT COUNT(*) FROM lessons WHERE category != 'custom'")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(count, 3);
    let (meaning,): (String,) = sqlx::query_as("SELECT meaning_vi FROM lessons WHERE id = $1")
        .bind(&seeds[0].id)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(meaning, "Preserve cached content");
}

#[test]
fn compose_stub_content_deserializes_as_backend_dialogue() {
    let output = std::process::Command::new("python3").arg("-B").arg("-c").arg(
        "import sys,json;sys.path.insert(0,'../tests/e2e');from test_ai_stub import AIStubTests;s,b=AIStubTests().request('/v1/chat/completions');print(json.loads(b)['choices'][0]['message']['content'])"
    ).output().unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let dialogue: server::models::DialogueResponse =
        serde_json::from_slice(&output.stdout).unwrap();
    assert!(!dialogue.topic.is_empty());
    assert!(!dialogue.lines.is_empty());
}
