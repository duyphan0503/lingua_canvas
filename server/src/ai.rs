use crate::models::{
    DialogueBreakdown, DialogueLine, DialogueRequest, DialogueResponse, GrammarHint,
    RoleplayRequest, RoleplayResponse,
};
use std::time::Duration;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AIError {
    ServiceUnavailable(String),
}

impl std::fmt::Display for AIError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::ServiceUnavailable(msg) => write!(f, "AI service unavailable: {}", msg),
        }
    }
}

impl std::error::Error for AIError {}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AIProvider {
    OpenAICompatible,
    OllamaNative,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AIConfig {
    pub endpoint: String,
    pub provider: AIProvider,
    pub model: String,
    pub timeout_secs: u64,
    pub connect_timeout_secs: u64,
    pub fallback_enabled: bool,
}

impl Default for AIConfig {
    fn default() -> Self {
        Self {
            endpoint: "http://127.0.0.1:11434/api/generate".to_string(),
            provider: AIProvider::OllamaNative,
            model: "qwen2.5:3b".to_string(),
            timeout_secs: 8,
            connect_timeout_secs: 2,
            fallback_enabled: true,
        }
    }
}

impl AIConfig {
    pub fn from_env() -> Self {
        let (endpoint, provider) = if let Ok(base) = std::env::var("LLAMA_CPP_BASE_URL") {
            (
                format!("{}/v1/chat/completions", base.trim_end_matches('/')),
                AIProvider::OpenAICompatible,
            )
        } else if let Ok(base) = std::env::var("OLLAMA_BASE_URL") {
            (
                format!("{}/v1/chat/completions", base.trim_end_matches('/')),
                AIProvider::OpenAICompatible,
            )
        } else if let Ok(direct) = std::env::var("AI_ENDPOINT") {
            if direct.contains("/api/generate") || direct.contains("/api/chat") {
                (direct, AIProvider::OllamaNative)
            } else if direct.contains("/v1/chat/completions") {
                (direct, AIProvider::OpenAICompatible)
            } else {
                (
                    format!("{}/v1/chat/completions", direct.trim_end_matches('/')),
                    AIProvider::OpenAICompatible,
                )
            }
        } else {
            (
                "http://127.0.0.1:11434/api/generate".to_string(),
                AIProvider::OllamaNative,
            )
        };

        let provider = if let Ok(prov_str) = std::env::var("AI_PROVIDER") {
            match prov_str.trim().to_lowercase().as_str() {
                "openai_compatible" | "openai" | "llama_cpp" => AIProvider::OpenAICompatible,
                "ollama" | "ollama_native" => AIProvider::OllamaNative,
                _ => provider,
            }
        } else {
            provider
        };

        let model = std::env::var("AI_MODEL").unwrap_or_else(|_| "qwen2.5:3b".to_string());
        let timeout_secs = std::env::var("AI_TIMEOUT_SECS")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(8);
        let connect_timeout_secs = std::env::var("AI_CONNECT_TIMEOUT_SECS")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(2);
        let fallback_enabled = std::env::var("AI_FALLBACK_ENABLED")
            .map(|v| v.to_lowercase() != "false")
            .unwrap_or(true);

        Self {
            endpoint,
            provider,
            model,
            timeout_secs,
            connect_timeout_secs,
            fallback_enabled,
        }
    }
}

pub struct AIService {
    client: reqwest::Client,
    config: AIConfig,
}

impl Default for AIService {
    fn default() -> Self {
        Self::new()
    }
}

impl AIService {
    pub fn new() -> Self {
        Self::with_config(AIConfig::from_env())
    }

    pub fn with_config(config: AIConfig) -> Self {
        let client = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(config.connect_timeout_secs))
            .timeout(Duration::from_secs(config.timeout_secs))
            .build()
            .unwrap_or_default();

        Self { client, config }
    }

    pub fn config(&self) -> &AIConfig {
        &self.config
    }

    pub async fn generate_roleplay(
        &self,
        req: &RoleplayRequest,
    ) -> Result<RoleplayResponse, AIError> {
        match self.try_generate_roleplay_llm(req).await {
            Ok(resp) => Ok(resp),
            Err(e) => {
                if self.config.fallback_enabled {
                    tracing::warn!(
                        "AI roleplay generation failed ({}). Using curated fallback.",
                        e
                    );
                    Ok(self.get_curated_roleplay_fallback(req))
                } else {
                    tracing::error!(
                        "AI roleplay generation failed and fallback is disabled: {}",
                        e
                    );
                    Err(AIError::ServiceUnavailable(format!(
                        "LLM roleplay generation failed ({}) and fallback is disabled",
                        e
                    )))
                }
            }
        }
    }

    pub async fn generate_dialogue(
        &self,
        req: &DialogueRequest,
    ) -> Result<DialogueResponse, AIError> {
        match self.try_generate_dialogue_llm(req).await {
            Ok(resp) => Ok(resp),
            Err(e) => {
                if self.config.fallback_enabled {
                    tracing::warn!(
                        "AI dialogue generation failed ({}). Using curated fallback.",
                        e
                    );
                    Ok(self.get_curated_dialogue_fallback(req))
                } else {
                    tracing::error!(
                        "AI dialogue generation failed and fallback is disabled: {}",
                        e
                    );
                    Err(AIError::ServiceUnavailable(format!(
                        "LLM dialogue generation failed ({}) and fallback is disabled",
                        e
                    )))
                }
            }
        }
    }

    async fn try_generate_roleplay_llm(
        &self,
        req: &RoleplayRequest,
    ) -> Result<RoleplayResponse, Box<dyn std::error::Error + Send + Sync>> {
        let system_prompt = format!(
            "You are a bilingual workplace language instructor specializing in {} for the {} industry at {} difficulty level. \
             You must respond with a SINGLE valid JSON object adhering to this schema:\n\
             {{\n  \"reply\": \"natural workplace response in target language\",\n  \
             \"reply_translation_vi\": \"natural Vietnamese translation\",\n  \
             \"breakdown\": [{{\"word\": \"term\", \"meaning_vi\": \"meaning in Vietnamese\", \"kana_or_phonetic\": \"reading or IPA\"}}],\n  \
             \"writing_challenge\": \"single key word or kanji for handwriting practice\",\n  \
             \"grammar_hints\": [{{\"pattern\": \"grammar pattern\", \"explanation_vi\": \"explanation in Vietnamese\", \"example\": \"example sentence\"}}],\n  \
             \"suggested_replies\": [\"suggested follow-up 1\", \"suggested follow-up 2\"]\n}}\n\
             Output strictly JSON without commentary.",
            req.target_language, req.profession, req.user_level
        );

        let user_prompt = if req.user_message.trim().is_empty() {
            format!(
                "Generate an opening scenario greeting and line for a roleplay session about: {} in the {} domain for a {} learner.",
                req.topic, req.profession, req.user_level
            )
        } else {
            let safe_user_message = req.user_message.chars().take(2000).collect::<String>();
            format!(
                "Context/Topic: {}\nUser Message: {}",
                req.topic, safe_user_message
            )
        };

        let raw_response = self.call_llm_api(&system_prompt, &user_prompt).await?;
        let cleaned = clean_json_str(&raw_response);
        let parsed: RoleplayResponse = serde_json::from_str(cleaned)?;
        Ok(parsed)
    }

    async fn try_generate_dialogue_llm(
        &self,
        req: &DialogueRequest,
    ) -> Result<DialogueResponse, Box<dyn std::error::Error + Send + Sync>> {
        let topic_str = req.topic.as_deref().unwrap_or("workplace_collaboration");
        let turns = req.turn_count.unwrap_or(4).clamp(2, 10);

        let system_prompt = format!(
            "You are a curriculum designer generating practical {} workplace dialogues for {} at {} difficulty level. \
             Generate a dialogue scenario with {} conversational turns.\n\
             You must respond with a SINGLE valid JSON object adhering to this schema:\n\
             {{\n  \"topic\": \"{}\",\n  \"profession\": \"{}\",\n  \"difficulty_level\": \"{}\",\n  \
             \"title\": \"Title in target language\",\n  \"title_vi\": \"Title in Vietnamese\",\n  \
             \"lines\": [{{\"speaker\": \"name or role\", \"text\": \"utterance\", \"translation_vi\": \"Vietnamese translation\", \"phonetic_or_romaji\": \"pronunciation reading\"}}],\n  \
             \"vocabulary\": [{{\"word\": \"term\", \"meaning_vi\": \"meaning in Vietnamese\", \"kana_or_phonetic\": \"reading or IPA\"}}],\n  \
             \"grammar_hints\": [{{\"pattern\": \"grammar pattern\", \"explanation_vi\": \"explanation in Vietnamese\", \"example\": \"example sentence\"}}],\n  \
             \"suggested_writing_targets\": [\"target1\", \"target2\"]\n}}\n\
             Output strictly JSON without commentary.",
            req.target_language, req.profession, req.difficulty_level, turns, topic_str, req.profession, req.difficulty_level
        );

        let user_prompt = format!(
            "Create a dialogue about: {} for {} professionals.",
            topic_str, req.profession
        );

        let raw_response = self.call_llm_api(&system_prompt, &user_prompt).await?;
        let cleaned = clean_json_str(&raw_response);
        let parsed: DialogueResponse = serde_json::from_str(cleaned)?;
        Ok(parsed)
    }

    async fn call_llm_api(
        &self,
        system_prompt: &str,
        user_prompt: &str,
    ) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
        match self.config.provider {
            AIProvider::OpenAICompatible => {
                let payload = serde_json::json!({
                    "model": self.config.model,
                    "messages": [
                        {"role": "system", "content": system_prompt},
                        {"role": "user", "content": user_prompt}
                    ],
                    "temperature": 0.7,
                    "response_format": {"type": "json_object"}
                });

                let resp = self
                    .client
                    .post(&self.config.endpoint)
                    .json(&payload)
                    .send()
                    .await?
                    .error_for_status()?;

                let body: serde_json::Value = resp.json().await?;
                let content = body["choices"][0]["message"]["content"]
                    .as_str()
                    .ok_or("Missing choices[0].message.content in OpenAI response")?
                    .to_string();
                Ok(content)
            }
            AIProvider::OllamaNative => {
                let full_prompt = format!("{}\n\nUser: {}", system_prompt, user_prompt);
                let payload = serde_json::json!({
                    "model": self.config.model,
                    "prompt": full_prompt,
                    "stream": false,
                    "format": "json"
                });

                let resp = self
                    .client
                    .post(&self.config.endpoint)
                    .json(&payload)
                    .send()
                    .await?
                    .error_for_status()?;

                let body: serde_json::Value = resp.json().await?;
                if let Some(r) = body.get("response").and_then(|v| v.as_str()) {
                    Ok(r.to_string())
                } else if let Some(msg) = body
                    .get("message")
                    .and_then(|m| m.get("content"))
                    .and_then(|c| c.as_str())
                {
                    Ok(msg.to_string())
                } else {
                    Err("Unrecognized Ollama response format".into())
                }
            }
        }
    }

    pub fn get_curated_roleplay_fallback(&self, req: &RoleplayRequest) -> RoleplayResponse {
        let lang = normalize_language(&req.target_language);
        let prof = normalize_profession(&req.profession);
        let level = normalize_level(&req.user_level);

        match (lang, prof, level) {
            // ==================== JAPANESE IT ====================
            ("ja", "it", "beginner") => RoleplayResponse {
                reply: "お疲れ様です！進捗はどうですか？何かバグや問題があればいつでも相談してください。".to_string(),
                reply_translation_vi: "Chào bạn, vất vả rồi! Tiến độ thế nào rồi? Nếu có bug hay vấn đề gì hãy cứ trao đổi bất cứ lúc nào nhé.".to_string(),
                breakdown: vec![
                    DialogueBreakdown {
                        word: "お疲れ様です".to_string(),
                        meaning_vi: "Chào anh/chị, vất vả rồi (lời chào chốn công sở)".to_string(),
                        kana_or_phonetic: "おつかれさまです (Otsukaresama desu)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "進捗".to_string(),
                        meaning_vi: "Tiến độ công việc".to_string(),
                        kana_or_phonetic: "しんちょく (Shinchoku)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "相談".to_string(),
                        meaning_vi: "Trao đổi, thảo luận xin ý kiến".to_string(),
                        kana_or_phonetic: "そうだん (Soudan)".to_string(),
                    },
                ],
                writing_challenge: "進捗".to_string(),
                grammar_hints: Some(vec![GrammarHint {
                    pattern: "〜はどうですか".to_string(),
                    explanation_vi: "Mẫu câu hỏi thăm tình hình/trạng thái một cách lịch sự".to_string(),
                    example: "進捗はどうですか？".to_string(),
                }]),
                suggested_replies: Some(vec![
                    "順調に進んでいます。(Đang tiến triển thuận lợi.)".to_string(),
                    "少し遅れています。(Đang hơi chậm một chút.)".to_string(),
                ]),
            },
            ("ja", "it", "intermediate") => RoleplayResponse {
                reply: "プルリクエストを確認しました。非同期処理のエラーハンドリングに少し修正が必要です。".to_string(),
                reply_translation_vi: "Tôi đã kiểm tra Pull Request của bạn. Cần chỉnh sửa một chút phần xử lý lỗi của tác vụ bất đồng bộ.".to_string(),
                breakdown: vec![
                    DialogueBreakdown {
                        word: "非同期処理".to_string(),
                        meaning_vi: "Xử lý bất đồng bộ (Asynchronous processing)".to_string(),
                        kana_or_phonetic: "ひどうきしょり (Hidouki shori)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "修正".to_string(),
                        meaning_vi: "Chỉnh sửa, khắc phục".to_string(),
                        kana_or_phonetic: "しゅうせい (Shuusei)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "不具合".to_string(),
                        meaning_vi: "Lỗi bug, khiếm khuyết phần mềm".to_string(),
                        kana_or_phonetic: "ふぐあい (Fuguai)".to_string(),
                    },
                ],
                writing_challenge: "修正".to_string(),
                grammar_hints: Some(vec![GrammarHint {
                    pattern: "〜が必要です".to_string(),
                    explanation_vi: "Biểu đạt sự cần thiết phải làm gì đó".to_string(),
                    example: "修正が必要です。".to_string(),
                }]),
                suggested_replies: Some(vec![
                    "すぐに見直して修正します。(Tôi sẽ xem lại và sửa ngay.)".to_string(),
                    "ご指摘ありがとうございます。(Cảm ơn anh/chị đã góp ý.)".to_string(),
                ]),
            },
            ("ja", "it", "advanced") => RoleplayResponse {
                reply: "本番環境でマイクロサービス間のレイテンシが悪化しています。分散トレーシングのメトリクスを調査してください。".to_string(),
                reply_translation_vi: "Tại môi trường production, độ trễ giữa các microservices đang xấu đi. Hãy điều tra các metric trên distributed tracing.".to_string(),
                breakdown: vec![
                    DialogueBreakdown {
                        word: "本番環境".to_string(),
                        meaning_vi: "Môi trường Production/vận hành thật".to_string(),
                        kana_or_phonetic: "ほんばんかんきょう (Honban kankyou)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "分散".to_string(),
                        meaning_vi: "Phân tán (Distributed)".to_string(),
                        kana_or_phonetic: "ぶんさん (Bunsan)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "障害対応".to_string(),
                        meaning_vi: "Ứng cứu/xử lý sự cố hệ thống".to_string(),
                        kana_or_phonetic: "しょうがいたいおう (Shougai taiou)".to_string(),
                    },
                ],
                writing_challenge: "障害".to_string(),
                grammar_hints: Some(vec![GrammarHint {
                    pattern: "〜てください".to_string(),
                    explanation_vi: "Yêu cầu hành động dứt khoát nhưng lịch sự trong điều phối kỹ thuật".to_string(),
                    example: "メトリクスを調査してください。".to_string(),
                }]),
                suggested_replies: Some(vec![
                    "直ちにログを解析して報告します。(Tôi sẽ phân tích log ngay và báo cáo.)".to_string(),
                    "原因特定のためダッシュボードを確認中です。(Đang kiểm tra dashboard để xác định nguyên nhân.)".to_string(),
                ]),
            },

            // ==================== JAPANESE HOSPITALITY ====================
            ("ja", "hospitality", "beginner") => RoleplayResponse {
                reply: "いらっしゃいませ。リンガホテルへようこそ。ご予約のお名前をお伺いしてもよろしいでしょうか？".to_string(),
                reply_translation_vi: "Kính chào quý khách. Chào mừng quý khách đến với khách sạn Lingua. Tôi có thể xin phép hỏi tên đặt phòng của quý khách được không ạ?".to_string(),
                breakdown: vec![
                    DialogueBreakdown {
                        word: "予約".to_string(),
                        meaning_vi: "Đặt phòng/đặt chỗ trước".to_string(),
                        kana_or_phonetic: "よやく (Yoyaku)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "案内".to_string(),
                        meaning_vi: "Hướng dẫn, đón tiếp".to_string(),
                        kana_or_phonetic: "あんない (Annai)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "朝食".to_string(),
                        meaning_vi: "Bữa ăn sáng".to_string(),
                        kana_or_phonetic: "ちょうしょく (Choushoku)".to_string(),
                    },
                ],
                writing_challenge: "予約".to_string(),
                grammar_hints: Some(vec![GrammarHint {
                    pattern: "〜てもよろしいでしょうか".to_string(),
                    explanation_vi: "Mẫu câu xin phép lịch sự chuẩn mực trong ngành dịch vụ khách sạn".to_string(),
                    example: "お名前をお伺いしてもよろしいでしょうか？".to_string(),
                }]),
                suggested_replies: Some(vec![
                    "チェックインをお願いします。(Làm ơn cho tôi làm thủ tục nhận phòng.)".to_string(),
                    "予約番号はこちらです。(Mã số đặt phòng của tôi ở đây ạ.)".to_string(),
                ]),
            },
            ("ja", "hospitality", "intermediate") => RoleplayResponse {
                reply: "かしこまりました。アレルギー対応のお食事とお部屋の加湿器を手配いたします。".to_string(),
                reply_translation_vi: "Tôi đã hiểu rõ yêu cầu của quý khách. Tôi sẽ sắp xếp bữa ăn không gây dị ứng và máy tạo độ ẩm cho phòng quý khách.".to_string(),
                breakdown: vec![
                    DialogueBreakdown {
                        word: "手配".to_string(),
                        meaning_vi: "Thu xếp, chuẩn bị sắp đặt".to_string(),
                        kana_or_phonetic: "てはい (Tehai)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "対応".to_string(),
                        meaning_vi: "Phục vụ, đối ứng, giải quyết".to_string(),
                        kana_or_phonetic: "たいおう (Taiou)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "満室".to_string(),
                        meaning_vi: "Hết phòng / kín phòng".to_string(),
                        kana_or_phonetic: "まんしつ (Manshitsu)".to_string(),
                    },
                ],
                writing_challenge: "手配".to_string(),
                grammar_hints: Some(vec![GrammarHint {
                    pattern: "お〜いたします".to_string(),
                    explanation_vi: "Khiêm nhường ngữ khi nhân viên phục vụ thực hiện hành động cho khách".to_string(),
                    example: "お食事を手配いたします。".to_string(),
                }]),
                suggested_replies: Some(vec![
                    "助かります、よろしくお願いします。(May quá, nhờ bạn giúp nhé.)".to_string(),
                    "空港への送迎もお願いできますか？(Có thể sắp xếp xe đưa đón ra sân bay không?)".to_string(),
                ]),
            },
            ("ja", "hospitality", "advanced") => RoleplayResponse {
                reply: "大変ご不便をおかけし、誠に申し訳ございません。直ちにスイートルームへお部屋をご用意させていただきます。".to_string(),
                reply_translation_vi: "Vô cùng xin lỗi quý khách vì sự bất tiện này. Chúng tôi xin phép được chuẩn bị phòng Suite cho quý khách ngay lập tức.".to_string(),
                breakdown: vec![
                    DialogueBreakdown {
                        word: "不便".to_string(),
                        meaning_vi: "Bất tiện, phiền toái".to_string(),
                        kana_or_phonetic: "ふべん (Fuben)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "誠に".to_string(),
                        meaning_vi: "Thực sự, chân thành (từ trang trọng)".to_string(),
                        kana_or_phonetic: "まことに (Makoto ni)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "謝罪".to_string(),
                        meaning_vi: "Tạ lỗi, xin lỗi".to_string(),
                        kana_or_phonetic: "しゃざい (Shazai)".to_string(),
                    },
                ],
                writing_challenge: "不便".to_string(),
                grammar_hints: Some(vec![GrammarHint {
                    pattern: "〜させていただきます".to_string(),
                    explanation_vi: "Kính ngữ khiêm nhường bậc cao xin phép được phục vụ đối phương".to_string(),
                    example: "ご用意させていただきます。".to_string(),
                }]),
                suggested_replies: Some(vec![
                    "迅速な対応に感謝します。(Cảm ơn vì sự xử lý nhanh chóng.)".to_string(),
                    "今後は気をつけてください。(Lần sau hãy chú ý hơn nhé.)".to_string(),
                ]),
            },

            // ==================== JAPANESE BUSINESS ====================
            ("ja", "business", "beginner") => RoleplayResponse {
                reply: "初めまして。本日はお時間をいただきありがとうございます。私の名刺をお受け取りください。".to_string(),
                reply_translation_vi: "Rất vui được gặp quý khách. Cảm ơn quý khách đã dành thời gian hôm nay. Xin vui lòng nhận danh thiếp của tôi.".to_string(),
                breakdown: vec![
                    DialogueBreakdown {
                        word: "名刺".to_string(),
                        meaning_vi: "Danh thiếp (Namecard)".to_string(),
                        kana_or_phonetic: "めいし (Meishi)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "挨拶".to_string(),
                        meaning_vi: "Chào hỏi, giao tiếp ban đầu".to_string(),
                        kana_or_phonetic: "あいさつ (Aisatsu)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "弊社".to_string(),
                        meaning_vi: "Công ty chúng tôi (Khiêm xưng)".to_string(),
                        kana_or_phonetic: "へいしゃ (Heisha)".to_string(),
                    },
                ],
                writing_challenge: "名刺".to_string(),
                grammar_hints: Some(vec![GrammarHint {
                    pattern: "〜いただきありがとうございます".to_string(),
                    explanation_vi: "Cảm ơn vì đối phương đã làm điều gì đó cho mình".to_string(),
                    example: "お時間をいただきありがとうございます。".to_string(),
                }]),
                suggested_replies: Some(vec![
                    "頂戴いたします。よろしくお願いいたします。(Tôi xin phép nhận. Rất mong được hợp tác.)".to_string(),
                    "こちらが私の名刺でございます。(Đây là danh thiếp của tôi ạ.)".to_string(),
                ]),
            },
            ("ja", "business", "intermediate") => RoleplayResponse {
                reply: "ご提示いただいた見積書の内容を検討いたしました。納期の短縮が可能であれば契約を前進させたいと考えております。".to_string(),
                reply_translation_vi: "Chúng tôi đã xem xét nội dung báo giá quý đối tác gửi. Nếu có thể rút ngắn thời hạn giao hàng, chúng tôi muốn xúc tiến hợp đồng.".to_string(),
                breakdown: vec![
                    DialogueBreakdown {
                        word: "見積書".to_string(),
                        meaning_vi: "Bản báo giá".to_string(),
                        kana_or_phonetic: "みつもりしょ (Mitsumorisho)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "契約".to_string(),
                        meaning_vi: "Hợp đồng kinh tế".to_string(),
                        kana_or_phonetic: "けいやく (Keiyaku)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "納期".to_string(),
                        meaning_vi: "Thời hạn giao hàng/bàn giao".to_string(),
                        kana_or_phonetic: "のうき (Nouki)".to_string(),
                    },
                ],
                writing_challenge: "契約".to_string(),
                grammar_hints: Some(vec![GrammarHint {
                    pattern: "〜と考えております".to_string(),
                    explanation_vi: "Trình bày suy nghĩ, định hướng một cách trang nhã và chuyên nghiệp".to_string(),
                    example: "前進させたいと考えております。".to_string(),
                }]),
                suggested_replies: Some(vec![
                    "製造部門と納期を調整いたします。(Tôi sẽ làm việc với bộ phận sản xuất để điều chỉnh tiến độ giao.)".to_string(),
                    "前向きなご検討に感謝いたします。(Cảm ơn quý vị đã cân nhắc tích cực.)".to_string(),
                ]),
            },
            ("ja", "business", "advanced") => RoleplayResponse {
                reply: "市場シェア拡大に向けた戦略的資本提携について、取締役会での承認を取り付けました。".to_string(),
                reply_translation_vi: "Về việc liên minh vốn chiến lược nhằm mở rộng thị phần, chúng tôi đã nhận được sự chấp thuận từ Hội đồng Quản trị.".to_string(),
                breakdown: vec![
                    DialogueBreakdown {
                        word: "提携".to_string(),
                        meaning_vi: "Liên minh, hợp tác chiến lược".to_string(),
                        kana_or_phonetic: "ていけい (Teikei)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "承認".to_string(),
                        meaning_vi: "Sự phê chuẩn, tán thành".to_string(),
                        kana_or_phonetic: "しょうにん (Shounin)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "収益性".to_string(),
                        meaning_vi: "Khả năng sinh lời, tính hiệu quả kinh tế".to_string(),
                        kana_or_phonetic: "しゅうえきせい (Shuuekisei)".to_string(),
                    },
                ],
                writing_challenge: "提携".to_string(),
                grammar_hints: Some(vec![GrammarHint {
                    pattern: "〜に向けた".to_string(),
                    explanation_vi: "Hướng tới mục tiêu, kế hoạch lớn".to_string(),
                    example: "拡大に向けた提携について合意しました。".to_string(),
                }]),
                suggested_replies: Some(vec![
                    "双方の企業価値向上につながる素晴らしい決定です。(Đây là quyết định tuyệt vời giúp nâng cao giá trị hai bên.)".to_string(),
                    "調印式のスケジュールを策定しましょう。(Hãy cùng lên lịch trình cho lễ ký kết nhé.)".to_string(),
                ]),
            },

            // ==================== JAPANESE GENERAL ====================
            ("ja", "general", "beginner") => RoleplayResponse {
                reply: "こんにちは！今日の予定はどうですか？昼休みに一緒にカフェへ行きませんか？".to_string(),
                reply_translation_vi: "Chào bạn! Kế hoạch hôm nay thế nào? Trưa nay bạn có muốn cùng đi cà phê nghỉ ngơi không?".to_string(),
                breakdown: vec![
                    DialogueBreakdown {
                        word: "予定".to_string(),
                        meaning_vi: "Dự định, kế hoạch".to_string(),
                        kana_or_phonetic: "よてい (Yotei)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "休憩".to_string(),
                        meaning_vi: "Nghỉ giải lao".to_string(),
                        kana_or_phonetic: "きゅうけい (Kyuukei)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "同僚".to_string(),
                        meaning_vi: "Đồng nghiệp".to_string(),
                        kana_or_phonetic: "どうりょう (Douryou)".to_string(),
                    },
                ],
                writing_challenge: "休憩".to_string(),
                grammar_hints: Some(vec![GrammarHint {
                    pattern: "〜ませんか".to_string(),
                    explanation_vi: "Lời rủ rê, mời mọc lịch sự thân mật".to_string(),
                    example: "一緒に行きませんか？".to_string(),
                }]),
                suggested_replies: Some(vec![
                    "ぜひ行きましょう！(Nhất định cùng đi nhé!)".to_string(),
                    "今日は少し忙しいのでまた今度誘ってください。(Hôm nay mình hơi bận, hẹn dịp khác nhé.)".to_string(),
                ]),
            },
            ("ja", "general", "intermediate") => RoleplayResponse {
                reply: "プロジェクトの進捗共有ミーティングを開催します。各自の課題と解決策をまとめておいてください。".to_string(),
                reply_translation_vi: "Chúng ta sẽ tổ chức cuộc họp chia sẻ tiến độ dự án. Mọi người hãy chuẩn bị sẵn các vấn đề tồn đọng và giải pháp nhé.".to_string(),
                breakdown: vec![
                    DialogueBreakdown {
                        word: "共有".to_string(),
                        meaning_vi: "Chia sẻ thông tin (Share)".to_string(),
                        kana_or_phonetic: "きょうゆう (Kyouyuu)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "課題".to_string(),
                        meaning_vi: "Nhiệm vụ, vấn đề cần giải quyết".to_string(),
                        kana_or_phonetic: "かだい (Kadai)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "解決策".to_string(),
                        meaning_vi: "Giải pháp, biện pháp xử lý".to_string(),
                        kana_or_phonetic: "かいけつさく (Kaiketsusaku)".to_string(),
                    },
                ],
                writing_challenge: "共有".to_string(),
                grammar_hints: Some(vec![GrammarHint {
                    pattern: "〜ておいてください".to_string(),
                    explanation_vi: "Hãy làm trước một hành động để chuẩn bị".to_string(),
                    example: "まとめておいてください。".to_string(),
                }]),
                suggested_replies: Some(vec![
                    "資料を用意して参加します。(Tôi sẽ chuẩn bị tài liệu và tham dự.)".to_string(),
                    "アジェンダを事前に確認できますか？(Tôi có thể xem trước nội dung họp không?)".to_string(),
                ]),
            },
            ("ja", "general", "advanced") => RoleplayResponse {
                reply: "組織改革に伴う各部署の軋轢を解消するため、対話を重視したリーダーシップを発揮しましょう。".to_string(),
                reply_translation_vi: "Để xóa bỏ những bất đồng giữa các phòng ban đi kèm với cải cách tổ chức, chúng ta hãy phát huy năng lực lãnh đạo chú trọng đối thoại.".to_string(),
                breakdown: vec![
                    DialogueBreakdown {
                        word: "改革".to_string(),
                        meaning_vi: "Cải cách, đổi mới tổ chức".to_string(),
                        kana_or_phonetic: "かいかく (Kaikaku)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "対話".to_string(),
                        meaning_vi: "Đối thoại, trao đổi lắng nghe".to_string(),
                        kana_or_phonetic: "たいわ (Taiwa)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "統括".to_string(),
                        meaning_vi: "Thống nhất quản lý, tổng hợp".to_string(),
                        kana_or_phonetic: "とうかつ (Toukatsu)".to_string(),
                    },
                ],
                writing_challenge: "改革".to_string(),
                grammar_hints: Some(vec![GrammarHint {
                    pattern: "〜に伴う".to_string(),
                    explanation_vi: "Kéo theo, đi kèm với sự biến đổi lớn".to_string(),
                    example: "改革に伴う課題を解消しましょう。".to_string(),
                }]),
                suggested_replies: Some(vec![
                    "全社員に向けたタウンホールミーティングを提案します。(Tôi đề xuất tổ chức Town Hall cho toàn công ty.)".to_string(),
                    "各マネージャーとの個別面談を優先します。(Tôi sẽ ưu tiên phỏng vấn 1-1 với từng quản lý.)".to_string(),
                ]),
            },

            // ==================== ENGLISH IT ====================
            ("en", "it", "beginner") => RoleplayResponse {
                reply: "Good morning! Did you push the latest commit to Git? We should test the build before our daily standup.".to_string(),
                reply_translation_vi: "Chào buổi sáng! Bạn đã đẩy commit mới nhất lên Git chưa? Chúng ta nên kiểm tra bản build trước buổi họp daily standup.".to_string(),
                breakdown: vec![
                    DialogueBreakdown {
                        word: "commit".to_string(),
                        meaning_vi: "Lưu lại thay đổi mã nguồn trong Git".to_string(),
                        kana_or_phonetic: "/kəˈmɪt/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "standup".to_string(),
                        meaning_vi: "Cuộc họp nhanh đầu ngày của team Agile".to_string(),
                        kana_or_phonetic: "/ˈstænd.ʌp/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "build".to_string(),
                        meaning_vi: "Bản dựng biên dịch phần mềm".to_string(),
                        kana_or_phonetic: "/bɪld/".to_string(),
                    },
                ],
                writing_challenge: "commit".to_string(),
                grammar_hints: Some(vec![GrammarHint {
                    pattern: "We should + Verb".to_string(),
                    explanation_vi: "Đưa ra lời khuyên hoặc gợi ý hành động cần làm".to_string(),
                    example: "We should test the build before our daily standup.".to_string(),
                }]),
                suggested_replies: Some(vec![
                    "Yes, I pushed the branch 10 minutes ago.".to_string(),
                    "I'm running the tests locally right now.".to_string(),
                ]),
            },
            ("en", "it", "intermediate") => {
                if req.topic.to_lowercase().contains("standup") {
                    RoleplayResponse {
                        reply: "Good morning! Did you push the latest commit to Git? We should test the build before our daily standup.".to_string(),
                        reply_translation_vi: "Chào buổi sáng! Bạn đã đẩy commit mới nhất lên Git chưa? Chúng ta nên kiểm tra bản build trước buổi họp daily standup.".to_string(),
                        breakdown: vec![
                            DialogueBreakdown {
                                word: "commit".to_string(),
                                meaning_vi: "Lưu lại thay đổi mã nguồn trong Git".to_string(),
                                kana_or_phonetic: "/kəˈmɪt/".to_string(),
                            },
                            DialogueBreakdown {
                                word: "standup".to_string(),
                                meaning_vi: "Cuộc họp nhanh đầu ngày của team Agile".to_string(),
                                kana_or_phonetic: "/ˈstænd.ʌp/".to_string(),
                            },
                            DialogueBreakdown {
                                word: "build".to_string(),
                                meaning_vi: "Bản dựng biên dịch phần mềm".to_string(),
                                kana_or_phonetic: "/bɪld/".to_string(),
                            },
                        ],
                        writing_challenge: "commit".to_string(),
                        grammar_hints: Some(vec![GrammarHint {
                            pattern: "We should + Verb".to_string(),
                            explanation_vi: "Đưa ra lời khuyên hoặc gợi ý hành động cần làm".to_string(),
                            example: "We should test the build before our daily standup.".to_string(),
                        }]),
                        suggested_replies: Some(vec![
                            "Yes, I pushed the branch 10 minutes ago.".to_string(),
                            "I'm running the tests locally right now.".to_string(),
                        ]),
                    }
                } else {
                    RoleplayResponse {
                        reply: "I reviewed your pull request. We need to refactor the database query to prevent N+1 performance bottlenecks.".to_string(),
                        reply_translation_vi: "Tôi đã xem qua PR của bạn. Chúng ta cần tái cấu trúc câu truy vấn cơ sở dữ liệu để ngăn chặn điểm nghẽn hiệu năng N+1.".to_string(),
                        breakdown: vec![
                            DialogueBreakdown {
                                word: "refactor".to_string(),
                                meaning_vi: "Tái cấu trúc mã nguồn giữ nguyên hành vi".to_string(),
                                kana_or_phonetic: "/riːˈfæk.tɚ/".to_string(),
                            },
                            DialogueBreakdown {
                                word: "bottleneck".to_string(),
                                meaning_vi: "Điểm nghẽn gây giảm hiệu năng".to_string(),
                                kana_or_phonetic: "/ˈbɑː.t̬əl.nek/".to_string(),
                            },
                            DialogueBreakdown {
                                word: "idempotency".to_string(),
                                meaning_vi: "Tính bất biến khi thực hiện nhiều lần lặp".to_string(),
                                kana_or_phonetic: "/ˌaɪ.dəmˈpoʊ.tən.si/".to_string(),
                            },
                        ],
                        writing_challenge: "refactor".to_string(),
                        grammar_hints: Some(vec![GrammarHint {
                            pattern: "need to + Verb to prevent...".to_string(),
                            explanation_vi: "Chỉ ra sự cần thiết phải làm gì nhằm ngăn ngừa một rủi ro".to_string(),
                            example: "We need to refactor the query to prevent bottlenecks.".to_string(),
                        }]),
                        suggested_replies: Some(vec![
                            "I'll optimize it using an inner join and eager loading.".to_string(),
                            "Good catch! I'll update the PR with benchmark results.".to_string(),
                        ]),
                    }
                }
            }
            ("en", "it", "advanced") => RoleplayResponse {
                reply: "Our production cluster experienced a failover spike. Let's analyze distributed traces to pinpoint the cascading deadlock.".to_string(),
                reply_translation_vi: "Cụm production của chúng ta vừa bị tăng đột biến failover. Hãy cùng phân tích distributed traces để xác định chính xác deadlock dây chuyền.".to_string(),
                breakdown: vec![
                    DialogueBreakdown {
                        word: "failover".to_string(),
                        meaning_vi: "Chuyển đổi dự phòng khi máy chủ chính gặp sự cố".to_string(),
                        kana_or_phonetic: "/ˈfeɪl.oʊ.vɚ/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "deadlock".to_string(),
                        meaning_vi: "Khóa chết tài nguyên giữa các tiến trình song song".to_string(),
                        kana_or_phonetic: "/ˈded.lɑːk/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "scalability".to_string(),
                        meaning_vi: "Khả năng mở rộng quy mô hệ thống".to_string(),
                        kana_or_phonetic: "/ˌskeɪ.ləˈbɪl.ə.t̬i/".to_string(),
                    },
                ],
                writing_challenge: "deadlock".to_string(),
                grammar_hints: Some(vec![GrammarHint {
                    pattern: "Let's + Verb to pinpoint...".to_string(),
                    explanation_vi: "Đề nghị hành động dứt khoát nhằm giải quyết sự cố khẩn cấp".to_string(),
                    example: "Let's analyze traces to pinpoint the cascading deadlock.".to_string(),
                }]),
                suggested_replies: Some(vec![
                    "I'm inspecting the OpenTelemetry spans across service meshes.".to_string(),
                    "Traffic has been diverted to our disaster recovery region.".to_string(),
                ]),
            },

            // ==================== ENGLISH HOSPITALITY ====================
            ("en", "hospitality", "beginner") => RoleplayResponse {
                reply: "Welcome to Lingua Grand Hotel! May I have your name and reservation confirmation number, please?".to_string(),
                reply_translation_vi: "Chào mừng quý khách đến với khách sạn Lingua Grand! Tôi có thể xin tên và mã xác nhận đặt phòng của quý khách được không ạ?".to_string(),
                breakdown: vec![
                    DialogueBreakdown {
                        word: "reservation".to_string(),
                        meaning_vi: "Sự đặt phòng trước".to_string(),
                        kana_or_phonetic: "/ˌrez.ɚˈveɪ.ʃən/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "confirmation".to_string(),
                        meaning_vi: "Giấy/mã xác nhận".to_string(),
                        kana_or_phonetic: "/ˌkɑːn.fɚˈmeɪ.ʃən/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "concierge".to_string(),
                        meaning_vi: "Nhân viên hỗ trợ khách hàng tại tiền sảnh".to_string(),
                        kana_or_phonetic: "/koʊn.siˈerʒ/".to_string(),
                    },
                ],
                writing_challenge: "reservation".to_string(),
                grammar_hints: Some(vec![GrammarHint {
                    pattern: "May I have ..., please?".to_string(),
                    explanation_vi: "Mẫu câu hỏi thông tin lịch sự tiêu chuẩn ngành dịch vụ".to_string(),
                    example: "May I have your name and reservation number, please?".to_string(),
                }]),
                suggested_replies: Some(vec![
                    "Sure, here is my passport and booking voucher.".to_string(),
                    "The reservation is under John Smith.".to_string(),
                ]),
            },
            ("en", "hospitality", "intermediate") => RoleplayResponse {
                reply: "Certainly, sir. I have arranged your private airport shuttle and notified the executive chef regarding your gluten-free preference.".to_string(),
                reply_translation_vi: "Chắc chắn rồi thưa quý khách. Tôi đã bố trí xe đưa đón sân bay riêng và thông báo cho bếp trưởng về yêu cầu ăn kiêng không gluten của quý khách.".to_string(),
                breakdown: vec![
                    DialogueBreakdown {
                        word: "shuttle".to_string(),
                        meaning_vi: "Xe trung chuyển đưa đón tuyến cố định".to_string(),
                        kana_or_phonetic: "/ˈʃʌt̬.əl/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "preference".to_string(),
                        meaning_vi: "Sở thích hoặc yêu cầu ăn uống đặc biệt".to_string(),
                        kana_or_phonetic: "/ˈpref.ər.əns/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "itinerary".to_string(),
                        meaning_vi: "Lịch trình chuyến đi".to_string(),
                        kana_or_phonetic: "/aɪˈtɪn.ə.rer.i/".to_string(),
                    },
                ],
                writing_challenge: "shuttle".to_string(),
                grammar_hints: Some(vec![GrammarHint {
                    pattern: "I have arranged ... and notified ...".to_string(),
                    explanation_vi: "Hiện tại hoàn thành báo cáo các tác vụ phục vụ đã hoàn tất chu đáo".to_string(),
                    example: "I have arranged your shuttle and notified the chef.".to_string(),
                }]),
                suggested_replies: Some(vec![
                    "Thank you for your excellent attention to detail.".to_string(),
                    "Could you also print my boarding pass for tomorrow?".to_string(),
                ]),
            },
            ("en", "hospitality", "advanced") => RoleplayResponse {
                reply: "Please accept our sincerest apologies for the maintenance inconvenience. We have upgraded you to the Presidential Penthouse Suite with our compliments.".to_string(),
                reply_translation_vi: "Xin quý khách nhận lời tạ lỗi chân thành nhất của chúng tôi vì sự bất tiện bảo trì này. Chúng tôi đã nâng cấp phòng của quý khách lên Presidential Penthouse Suite hoàn toàn miễn phí.".to_string(),
                breakdown: vec![
                    DialogueBreakdown {
                        word: "apologies".to_string(),
                        meaning_vi: "Lời xin lỗi chân thành trang trọng".to_string(),
                        kana_or_phonetic: "/əˈpɑː.lə.dʒiz/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "penthouse".to_string(),
                        meaning_vi: "Căn hộ tầng thượng cao cấp".to_string(),
                        kana_or_phonetic: "/ˈpent.haʊs/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "inconvenience".to_string(),
                        meaning_vi: "Sự bất tiện, phiền phức".to_string(),
                        kana_or_phonetic: "/ˌɪn.kənˈviːn.jəns/".to_string(),
                    },
                ],
                writing_challenge: "penthouse".to_string(),
                grammar_hints: Some(vec![GrammarHint {
                    pattern: "Please accept our sincerest apologies for...".to_string(),
                    explanation_vi: "Công thức chuẩn mực xoa dịu khách hàng trong dịch vụ khách sạn 5 sao".to_string(),
                    example: "Please accept our sincerest apologies for the inconvenience.".to_string(),
                }]),
                suggested_replies: Some(vec![
                    "I truly appreciate your professional conflict resolution.".to_string(),
                    "Thank you, that demonstrates exemplary hospitality leadership.".to_string(),
                ]),
            },

            // ==================== ENGLISH BUSINESS ====================
            ("en", "business", "beginner") => RoleplayResponse {
                reply: "Pleased to meet you! Thank you for joining our kickoff call. Here is our project timeline and deliverables schedule.".to_string(),
                reply_translation_vi: "Rất vui được gặp bạn! Cảm ơn bạn đã tham gia cuộc gọi khởi động dự án. Đây là mốc thời gian và kế hoạch bàn giao sản phẩm của chúng tôi.".to_string(),
                breakdown: vec![
                    DialogueBreakdown {
                        word: "deliverable".to_string(),
                        meaning_vi: "Sản phẩm/kết quả bàn giao của dự án".to_string(),
                        kana_or_phonetic: "/dɪˈlɪv.ɚ.ə.bəl/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "timeline".to_string(),
                        meaning_vi: "Tiến độ thời gian".to_string(),
                        kana_or_phonetic: "/ˈtaɪm.laɪn/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "agenda".to_string(),
                        meaning_vi: "Nghị trình, nội dung cuộc họp".to_string(),
                        kana_or_phonetic: "/əˈdʒen.də/".to_string(),
                    },
                ],
                writing_challenge: "deliverable".to_string(),
                grammar_hints: Some(vec![GrammarHint {
                    pattern: "Thank you for + Verb-ing".to_string(),
                    explanation_vi: "Cảm ơn đối tác vì đã thực hiện hành động hợp tác".to_string(),
                    example: "Thank you for joining our kickoff call.".to_string(),
                }]),
                suggested_replies: Some(vec![
                    "The timeline looks achievable. Let's align on weekly sprints.".to_string(),
                    "Could you clarify the milestone deadlines for Phase 1?".to_string(),
                ]),
            },
            ("en", "business", "intermediate") => RoleplayResponse {
                reply: "We evaluated your commercial proposal. If we can negotiate a 10% volume discount, we are prepared to execute a multi-year master service agreement.".to_string(),
                reply_translation_vi: "Chúng tôi đã đánh giá đề xuất thương mại của các bạn. Nếu có thể đàm phán mức chiết khấu 10% theo số lượng, chúng tôi sẵn sàng ký thỏa thuận dịch vụ khung nhiều năm.".to_string(),
                breakdown: vec![
                    DialogueBreakdown {
                        word: "proposal".to_string(),
                        meaning_vi: "Bản đề xuất thương mại".to_string(),
                        kana_or_phonetic: "/prəˈpoʊ.zəl/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "discount".to_string(),
                        meaning_vi: "Mức chiết khấu giảm giá".to_string(),
                        kana_or_phonetic: "/ˈdɪs.kaʊnt/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "agreement".to_string(),
                        meaning_vi: "Hợp đồng, thỏa thuận pháp lý".to_string(),
                        kana_or_phonetic: "/əˈɡriː.mənt/".to_string(),
                    },
                ],
                writing_challenge: "agreement".to_string(),
                grammar_hints: Some(vec![GrammarHint {
                    pattern: "If we can ..., we are prepared to ...".to_string(),
                    explanation_vi: "Mẫu câu đàm phán thương mại có điều kiện (conditional offer)".to_string(),
                    example: "If we can negotiate a discount, we are prepared to sign.".to_string(),
                }]),
                suggested_replies: Some(vec![
                    "We can offer tiered rebates tied to annual purchase commitments.".to_string(),
                    "Let me discuss the pricing model with our finance director.".to_string(),
                ]),
            },
            ("en", "business", "advanced") => RoleplayResponse {
                reply: "The executive committee has greenlit the cross-border merger structure, prioritizing shareholder value accretion and regulatory compliance.".to_string(),
                reply_translation_vi: "Ủy ban điều hành đã bật đèn xanh cho cấu trúc sáp nhập xuyên biên giới, ưu tiên gia tăng giá trị cổ đông và tuân thủ các quy định pháp lý.".to_string(),
                breakdown: vec![
                    DialogueBreakdown {
                        word: "merger".to_string(),
                        meaning_vi: "Sự sáp nhập doanh nghiệp (M&A)".to_string(),
                        kana_or_phonetic: "/ˈmɝː.dʒɚ/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "compliance".to_string(),
                        meaning_vi: "Sự tuân thủ pháp lý và quy định".to_string(),
                        kana_or_phonetic: "/kəmˈplaɪ.əns/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "governance".to_string(),
                        meaning_vi: "Năng lực quản trị doanh nghiệp".to_string(),
                        kana_or_phonetic: "/ˈɡʌv.ɚ.nəns/".to_string(),
                    },
                ],
                writing_challenge: "compliance".to_string(),
                grammar_hints: Some(vec![GrammarHint {
                    pattern: "... has greenlit ..., prioritizing ...".to_string(),
                    explanation_vi: "Diễn tả quyết định chiến lược cấp cao đi kèm mục tiêu cốt lõi".to_string(),
                    example: "The board greenlit the merger, prioritizing compliance.".to_string(),
                }]),
                suggested_replies: Some(vec![
                    "We should proceed with drafting the binding term sheet.".to_string(),
                    "Legal counsel is finalizing our regulatory filings in both jurisdictions.".to_string(),
                ]),
            },

            // ==================== ENGLISH GENERAL ====================
            ("en", "general", "beginner") => RoleplayResponse {
                reply: "Hello! Welcome to our team. Please feel free to ask if you need any help settling into the office.".to_string(),
                reply_translation_vi: "Xin chào! Chào mừng bạn gia nhập đội ngũ. Đừng ngần ngại hỏi nếu bạn cần bất kỳ sự trợ giúp nào để làm quen với văn phòng nhé.".to_string(),
                breakdown: vec![
                    DialogueBreakdown {
                        word: "welcome".to_string(),
                        meaning_vi: "Chào đón nồng hậu".to_string(),
                        kana_or_phonetic: "/ˈwel.kəm/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "colleague".to_string(),
                        meaning_vi: "Đồng nghiệp".to_string(),
                        kana_or_phonetic: "/ˈkɑː.liːɡ/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "assistance".to_string(),
                        meaning_vi: "Sự giúp đỡ, trợ giúp".to_string(),
                        kana_or_phonetic: "/əˈsɪs.təns/".to_string(),
                    },
                ],
                writing_challenge: "welcome".to_string(),
                grammar_hints: Some(vec![GrammarHint {
                    pattern: "Please feel free to + Verb".to_string(),
                    explanation_vi: "Lời mời cởi mở, khuyến khích đối phương thoải mái hành động".to_string(),
                    example: "Please feel free to ask if you need any help.".to_string(),
                }]),
                suggested_replies: Some(vec![
                    "Thank you for the warm welcome!".to_string(),
                    "Where can I find the team documentation?".to_string(),
                ]),
            },
            ("en", "general", "intermediate") => RoleplayResponse {
                reply: "I'm scheduling our weekly project sync. Please review the shared document and add any discussion topics before tomorrow.".to_string(),
                reply_translation_vi: "Tôi đang lên lịch họp đồng bộ dự án hàng tuần. Xin vui lòng xem tài liệu chia sẻ và bổ sung các chủ đề thảo luận trước ngày mai.".to_string(),
                breakdown: vec![
                    DialogueBreakdown {
                        word: "schedule".to_string(),
                        meaning_vi: "Lên lịch trình, kế hoạch".to_string(),
                        kana_or_phonetic: "/ˈskedʒ.uːl/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "collaboration".to_string(),
                        meaning_vi: "Sự cộng tác, làm việc nhóm".to_string(),
                        kana_or_phonetic: "/kəˌlæb.əˈreɪ.ʃən/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "deadline".to_string(),
                        meaning_vi: "Hạn chót hoàn thành".to_string(),
                        kana_or_phonetic: "/ˈded.laɪn/".to_string(),
                    },
                ],
                writing_challenge: "schedule".to_string(),
                grammar_hints: Some(vec![GrammarHint {
                    pattern: "Please review ... and add ... before ...".to_string(),
                    explanation_vi: "Lời yêu cầu phối hợp công việc chuyên nghiệp có thời hạn rõ ràng".to_string(),
                    example: "Please review the document before tomorrow.".to_string(),
                }]),
                suggested_replies: Some(vec![
                    "I added two agenda items regarding cross-team dependencies.".to_string(),
                    "I'll review the deck and share my feedback this afternoon.".to_string(),
                ]),
            },
            ("en", "general", "advanced") => RoleplayResponse {
                reply: "Effective organizational transformation requires proactive stakeholder engagement, transparent communication channels, and cultural alignment.".to_string(),
                reply_translation_vi: "Chuyển đổi tổ chức hiệu quả đòi hỏi sự gắn kết chủ động của các bên liên quan, các kênh truyền thông minh bạch và sự hòa hợp về văn hóa doanh nghiệp.".to_string(),
                breakdown: vec![
                    DialogueBreakdown {
                        word: "transformation".to_string(),
                        meaning_vi: "Sự chuyển đổi toàn diện tổ chức".to_string(),
                        kana_or_phonetic: "/ˌtræns.fɚˈmeɪ.ʃən/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "stakeholder".to_string(),
                        meaning_vi: "Các bên liên quan/đối tượng hữu quan".to_string(),
                        kana_or_phonetic: "/ˈsteɪkˌhoʊl.dɚ/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "alignment".to_string(),
                        meaning_vi: "Sự đồng lòng, thống nhất định hướng".to_string(),
                        kana_or_phonetic: "/əˈlaɪn.mənt/".to_string(),
                    },
                ],
                writing_challenge: "transformation".to_string(),
                grammar_hints: Some(vec![GrammarHint {
                    pattern: "... requires ..., ..., and ...".to_string(),
                    explanation_vi: "Liệt kê các yếu tố điều kiện tiên quyết cho một mục tiêu lớn".to_string(),
                    example: "Transformation requires stakeholder engagement and cultural alignment.".to_string(),
                }]),
                suggested_replies: Some(vec![
                    "I agree; let's foster an open-door policy for bottom-up initiatives.".to_string(),
                    "We should establish quarterly feedback retrospectives across all departments.".to_string(),
                ]),
            },

            // Fallback Catch-all
            _ => self.get_curated_roleplay_fallback(&RoleplayRequest {
                target_language: "ja".to_string(),
                profession: "it".to_string(),
                user_level: "beginner".to_string(),
                topic: req.topic.clone(),
                user_message: req.user_message.clone(),
            }),
        }
    }

    pub fn get_curated_dialogue_fallback(&self, req: &DialogueRequest) -> DialogueResponse {
        let lang = normalize_language(&req.target_language);
        let prof = normalize_profession(&req.profession);
        let level = normalize_level(&req.difficulty_level);

        match (lang, prof, level) {
            // ==================== JAPANESE IT ====================
            ("ja", "it", "beginner") => DialogueResponse {
                topic: "daily_standup".to_string(),
                profession: "it".to_string(),
                difficulty_level: "beginner".to_string(),
                title: "朝のデイリースタンドアップ".to_string(),
                title_vi: "Cuộc họp Standup kỹ thuật buổi sáng".to_string(),
                lines: vec![
                    DialogueLine {
                        speaker: "田中リーダー".to_string(),
                        text: "おはようございます。昨日のタスクは予定通り完了しましたか？".to_string(),
                        translation_vi: "Chào buổi sáng. Tác vụ hôm qua của bạn đã hoàn thành đúng kế hoạch chưa?".to_string(),
                        phonetic_or_romaji: "Ohayou gozaimasu. Kinou no tasuku wa yotei doori kanryou shimashita ka?".to_string(),
                    },
                    DialogueLine {
                        speaker: "鈴木エンジニア".to_string(),
                        text: "はい、ログイン機能の単体テストをすべて実装しました。".to_string(),
                        translation_vi: "Vâng, tôi đã hoàn thiện toàn bộ unit test cho chức năng đăng nhập.".to_string(),
                        phonetic_or_romaji: "Hai, rogukou kinou no tantai tesuto o subete jissou shimashita.".to_string(),
                    },
                    DialogueLine {
                        speaker: "田中リーダー".to_string(),
                        text: "素晴らしいですね。今日の予定を教えてください。".to_string(),
                        translation_vi: "Tuyệt vời quá. Hãy cho tôi biết kế hoạch hôm nay của bạn nhé.".to_string(),
                        phonetic_or_romaji: "Subarashii desu ne. Kyou no yotei o oshiete kudasai.".to_string(),
                    },
                    DialogueLine {
                        speaker: "鈴木エンジニア".to_string(),
                        text: "本日はAPIの結合テストとコードレビューを行う予定です。".to_string(),
                        translation_vi: "Hôm nay tôi dự định chạy test tích hợp API và tiến hành review code.".to_string(),
                        phonetic_or_romaji: "Honjitsu wa API no ketsugou tesuto to koudo rebyuu o okonau yotei desu.".to_string(),
                    },
                ],
                vocabulary: vec![
                    DialogueBreakdown {
                        word: "実装".to_string(),
                        meaning_vi: "Triển khai/lập trình tính năng".to_string(),
                        kana_or_phonetic: "じっそう (Jissou)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "予定通り".to_string(),
                        meaning_vi: "Đúng theo kế hoạch".to_string(),
                        kana_or_phonetic: "よていどおり (Yotei doori)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "単体テスト".to_string(),
                        meaning_vi: "Unit test / Kiểm thử đơn vị".to_string(),
                        kana_or_phonetic: "たんたいてすと (Tantai tesuto)".to_string(),
                    },
                ],
                grammar_hints: vec![GrammarHint {
                    pattern: "〜を行う予定です".to_string(),
                    explanation_vi: "Biểu thị dự định hoặc kế hoạch chắc chắn sẽ thực hiện".to_string(),
                    example: "テストを行う予定です。".to_string(),
                }],
                suggested_writing_targets: vec!["実装".to_string(), "予定".to_string()],
            },
            ("ja", "it", "intermediate") => DialogueResponse {
                topic: "code_review".to_string(),
                profession: "it".to_string(),
                difficulty_level: "intermediate".to_string(),
                title: "プルリクエストのレビュー会議".to_string(),
                title_vi: "Cuộc họp review Pull Request".to_string(),
                lines: vec![
                    DialogueLine {
                        speaker: "リードエンジニア".to_string(),
                        text: "このPRですが、データベースの接続プールが適切に解放されていません。".to_string(),
                        translation_vi: "Ở PR này, connection pool của database chưa được giải phóng đúng cách.".to_string(),
                        phonetic_or_romaji: "Kono PR desu ga, deetabeesu no setsuzoku puuru ga tekisetsu ni kaihou sarete imasen.".to_string(),
                    },
                    DialogueLine {
                        speaker: "開発担当".to_string(),
                        text: "申し訳ありません。コネクションリークを防ぐためスコープを見直します。".to_string(),
                        translation_vi: "Xin lỗi anh. Để tránh rò rỉ kết nối, tôi sẽ rà soát lại scope.".to_string(),
                        phonetic_or_romaji: "Moushiwake arimasen. Konekushon riiku o fusegu tame sukoopu o minaoshimasu.".to_string(),
                    },
                    DialogueLine {
                        speaker: "リードエンジニア".to_string(),
                        text: "それから、エラー発生時のリトライ間隔も指数バックオフに設定してください。".to_string(),
                        translation_vi: "Ngoài ra, hãy cài đặt khoảng thời gian retry khi có lỗi theo kiểu exponential backoff nhé.".to_string(),
                        phonetic_or_romaji: "Sorekara, eraa hasseiji no ritorai kankaku mo shisuu bakkuofu ni settei shite kudasai.".to_string(),
                    },
                    DialogueLine {
                        speaker: "開発担当".to_string(),
                        text: "承知いたしました。本日中に修正版をコミットします。".to_string(),
                        translation_vi: "Tôi đã hiểu rõ. Tôi sẽ commit bản sửa lỗi trong ngày hôm nay.".to_string(),
                        phonetic_or_romaji: "Shouchi itashimashita. Honjitsuchuu ni shuuseiban o komitto shimasu.".to_string(),
                    },
                ],
                vocabulary: vec![
                    DialogueBreakdown {
                        word: "接続".to_string(),
                        meaning_vi: "Kết nối (Connection)".to_string(),
                        kana_or_phonetic: "せつぞく (Setsuzoku)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "解放".to_string(),
                        meaning_vi: "Giải phóng tài nguyên (Release)".to_string(),
                        kana_or_phonetic: "かいほう (Kaihou)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "承知".to_string(),
                        meaning_vi: "Tiếp nhận và thấu hiểu mệnh lệnh".to_string(),
                        kana_or_phonetic: "しょうち (Shouchi)".to_string(),
                    },
                ],
                grammar_hints: vec![GrammarHint {
                    pattern: "〜を防ぐため".to_string(),
                    explanation_vi: "Để phòng ngừa, ngăn chặn một rủi ro kỹ thuật".to_string(),
                    example: "リークを防ぐため見直します。".to_string(),
                }],
                suggested_writing_targets: vec!["接続".to_string(), "解放".to_string()],
            },
            ("ja", "it", "advanced") => DialogueResponse {
                topic: "incident_management".to_string(),
                profession: "it".to_string(),
                difficulty_level: "advanced".to_string(),
                title: "本番障害の緊急対応".to_string(),
                title_vi: "Xử lý khẩn cấp sự cố Production".to_string(),
                lines: vec![
                    DialogueLine {
                        speaker: "SRE担当".to_string(),
                        text: "アラート検知：決済APIのレスポンスタイムがSLOを超過しています。".to_string(),
                        translation_vi: "Phát hiện cảnh báo: Thời gian phản hồi của API thanh toán vượt quá SLO.".to_string(),
                        phonetic_or_romaji: "Araato kenchi: kessai API no responsu taimu ga SLO o chouka shite imasu.".to_string(),
                    },
                    DialogueLine {
                        speaker: "アーキテクト".to_string(),
                        text: "直近のデプロイをロールバックして、トラフィックをスタンバイ系へ切り替えます。".to_string(),
                        translation_vi: "Hãy rollback lần deploy gần nhất và chuyển traffic sang cụm standby.".to_string(),
                        phonetic_or_romaji: "Chokkin no depuroi o roorubakku shite, torafikku o sutanbai-kei e kirikaemasu.".to_string(),
                    },
                    DialogueLine {
                        speaker: "SRE担当".to_string(),
                        text: "了解しました。フェイルオーバー完了後、根本原因の分析ログを保全します。".to_string(),
                        translation_vi: "Đã rõ. Sau khi failover xong, tôi sẽ lưu trữ log để phân tích nguyên nhân gốc rễ.".to_string(),
                        phonetic_or_romaji: "Ryoukai shimashita. Feiruoobaa kanryougo, konbon gen'in no bunseki rogu o hozen shimasu.".to_string(),
                    },
                    DialogueLine {
                        speaker: "アーキテクト".to_string(),
                        text: "顧客影響を最小限に抑えるため、ステータスページの更新も依頼してください。".to_string(),
                        translation_vi: "Để giảm thiểu ảnh hưởng đến khách hàng, hãy yêu cầu cập nhật trang status page nữa.".to_string(),
                        phonetic_or_romaji: "Kokyaku eikyou o saishougen ni osaeru tame, suteetasu peeji no koushin mo irai shite kudasai.".to_string(),
                    },
                ],
                vocabulary: vec![
                    DialogueBreakdown {
                        word: "検知".to_string(),
                        meaning_vi: "Phát hiện, nhận diện cảnh báo".to_string(),
                        kana_or_phonetic: "けんち (Kenchi)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "超過".to_string(),
                        meaning_vi: "Vượt quá ngưỡng quy định".to_string(),
                        kana_or_phonetic: "ちょうか (Chouka)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "保全".to_string(),
                        meaning_vi: "Bảo toàn, giữ nguyên hiện trạng".to_string(),
                        kana_or_phonetic: "ほぜん (Hozen)".to_string(),
                    },
                ],
                grammar_hints: vec![GrammarHint {
                    pattern: "〜を最小限に抑えるため".to_string(),
                    explanation_vi: "Để hạn chế/kìm hãm ở mức tối thiểu".to_string(),
                    example: "影響を最小限に抑えるため更新します。".to_string(),
                }],
                suggested_writing_targets: vec!["検知".to_string(), "保全".to_string()],
            },

            // ==================== JAPANESE HOSPITALITY ====================
            ("ja", "hospitality", "beginner") => DialogueResponse {
                topic: "hotel_checkin".to_string(),
                profession: "hospitality".to_string(),
                difficulty_level: "beginner".to_string(),
                title: "ホテルのフロントでのチェックイン".to_string(),
                title_vi: "Thủ tục check-in tại quầy lễ tân khách sạn".to_string(),
                lines: vec![
                    DialogueLine {
                        speaker: "フロントスタッフ".to_string(),
                        text: "いらっしゃいませ。リンガホテルへようこそ。チェックインでいらっしゃいますか？".to_string(),
                        translation_vi: "Kính chào quý khách. Chào mừng quý khách đến với khách sạn Lingua. Quý khách muốn làm thủ tục nhận phòng phải không ạ?".to_string(),
                        phonetic_or_romaji: "Irasshaimase. Ringa hoteru e youkoso. Chekkuin de irasshaimasu ka?".to_string(),
                    },
                    DialogueLine {
                        speaker: "お客様".to_string(),
                        text: "はい、予約した田中です。パスポートはこちらです。".to_string(),
                        translation_vi: "Vâng, tôi là Tanaka đã đặt phòng trước. Hộ chiếu của tôi đây ạ.".to_string(),
                        phonetic_or_romaji: "Hai, yoyaku shita Tanaka desu. Pasupooto wa kochira desu.".to_string(),
                    },
                    DialogueLine {
                        speaker: "フロントスタッフ".to_string(),
                        text: "田中様、ご予約を確認いたしました。禁煙のデラックスルームでございます。".to_string(),
                        translation_vi: "Thưa quý khách Tanaka, tôi đã xác nhận phòng đặt. Phòng của quý khách là phòng Deluxe không hút thuốc.".to_string(),
                        phonetic_or_romaji: "Tanaka-sama, goyoyaku o kakunin itashimashita. Kin'en no derakkusu ruumu de gozaimasu.".to_string(),
                    },
                    DialogueLine {
                        speaker: "お客様".to_string(),
                        text: "ありがとうございます。朝食は何時から利用できますか？".to_string(),
                        translation_vi: "Cảm ơn bạn. Bữa sáng bắt đầu từ mấy giờ vậy?".to_string(),
                        phonetic_or_romaji: "Arigatou gozaimasu. Choushoku wa nanji kara riyou dekimasu ka?".to_string(),
                    },
                    DialogueLine {
                        speaker: "フロントスタッフ".to_string(),
                        text: "朝6時30分から10時まで、1階のレストランにてご用意しております。".to_string(),
                        translation_vi: "Dạ từ 6h30 sáng đến 10h tại nhà hàng tầng 1 ạ.".to_string(),
                        phonetic_or_romaji: "Asa rokuji sanjuppun kara juuji made, ikkai no resutoran nite goyoui shite orimasu.".to_string(),
                    },
                ],
                vocabulary: vec![
                    DialogueBreakdown {
                        word: "禁煙".to_string(),
                        meaning_vi: "Cấm hút thuốc / phòng không hút thuốc".to_string(),
                        kana_or_phonetic: "きんえん (Kinen)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "確認".to_string(),
                        meaning_vi: "Kiểm tra, xác nhận".to_string(),
                        kana_or_phonetic: "かくにん (Kakunin)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "用意".to_string(),
                        meaning_vi: "Chuẩn bị sẵn sàng".to_string(),
                        kana_or_phonetic: "ようい (Youi)".to_string(),
                    },
                ],
                grammar_hints: vec![GrammarHint {
                    pattern: "〜でございます".to_string(),
                    explanation_vi: "Dạng lịch sự trang trọng của です trong giao tiếp dịch vụ".to_string(),
                    example: "デラックスルームでございます。".to_string(),
                }],
                suggested_writing_targets: vec!["禁煙".to_string(), "確認".to_string()],
            },
            ("ja", "hospitality", "intermediate") => DialogueResponse {
                topic: "concierge_request".to_string(),
                profession: "hospitality".to_string(),
                difficulty_level: "intermediate".to_string(),
                title: "コンシェルジュへの特別なご要望".to_string(),
                title_vi: "Yêu cầu dịch vụ đặc biệt với Concierge".to_string(),
                lines: vec![
                    DialogueLine {
                        speaker: "コンシェルジュ".to_string(),
                        text: "デスクでございます。何かお手伝いできることはございますでしょうか？".to_string(),
                        translation_vi: "Bàn dịch vụ khách hàng xin chào quý khách. Tôi có thể hỗ trợ gì cho quý khách ạ?".to_string(),
                        phonetic_or_romaji: "Desuku de gozaimasu. Nanika otetsudai dekiru koto wa gozaimasu deshou ka?".to_string(),
                    },
                    DialogueLine {
                        speaker: "宿泊客".to_string(),
                        text: "明日の夜、伝統的な懐石料理の予約をお願いしたいのですが。".to_string(),
                        translation_vi: "Tối mai, tôi muốn nhờ bạn đặt giúp một bàn ăn món Kaiseki truyền thống.".to_string(),
                        phonetic_or_romaji: "Ashita no yoru, dentouteki na kaiseki ryouri no yoyaku o onegai shitai no desu ga.".to_string(),
                    },
                    DialogueLine {
                        speaker: "コンシェルジュ".to_string(),
                        text: "承知いたしました。アレルギー食材やお好みの席はございますか？".to_string(),
                        translation_vi: "Tôi hiểu rồi ạ. Quý khách có món ăn nào bị dị ứng hoặc yêu cầu chỗ ngồi không ạ?".to_string(),
                        phonetic_or_romaji: "Shouchi itashimashita. Arerugii shokuzai ya okonomi no seki wa gozaimasu ka?".to_string(),
                    },
                    DialogueLine {
                        speaker: "宿泊客".to_string(),
                        text: "甲殻類のアレルギーがあります。静かな個室をお願いできますか。".to_string(),
                        translation_vi: "Tôi bị dị ứng hải sản vỏ cứng. Xin hãy cho tôi một phòng riêng yên tĩnh.".to_string(),
                        phonetic_or_romaji: "Koukakurui no arerugii ga arimasu. Shizuka na koshitsu o onegai dekimasu ka.".to_string(),
                    },
                ],
                vocabulary: vec![
                    DialogueBreakdown {
                        word: "懐石料理".to_string(),
                        meaning_vi: "Món ăn Kaiseki truyền thống Nhật Bản".to_string(),
                        kana_or_phonetic: "かいせきりょうり (Kaiseki ryouri)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "要望".to_string(),
                        meaning_vi: "Yêu cầu, nguyện vọng của khách".to_string(),
                        kana_or_phonetic: "ようぼう (Youbou)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "厳選".to_string(),
                        meaning_vi: "Chọn lọc kỹ càng, chuẩn mực".to_string(),
                        kana_or_phonetic: "げんせん (Gensen)".to_string(),
                    },
                ],
                grammar_hints: vec![GrammarHint {
                    pattern: "〜をお願いしたいのですが".to_string(),
                    explanation_vi: "Cách mở lời nhờ vả nhẹ nhàng, lịch thiệp khi đưa ra yêu cầu".to_string(),
                    example: "予約をお願いしたいのですが。".to_string(),
                }],
                suggested_writing_targets: vec!["要望".to_string(), "厳選".to_string()],
            },
            ("ja", "hospitality", "advanced") => DialogueResponse {
                topic: "vip_omotenashi".to_string(),
                profession: "hospitality".to_string(),
                difficulty_level: "advanced".to_string(),
                title: "VIP客への接客とおもてなし対応".to_string(),
                title_vi: "Phục vụ và ứng xử chu đáo với khách VIP".to_string(),
                lines: vec![
                    DialogueLine {
                        speaker: "総支配人".to_string(),
                        text: "当ホテルの不手際によりご不快な思いをおかけし、心よりお詫び申し上げます。".to_string(),
                        translation_vi: "Do sơ suất của khách sạn khiến quý khách không hài lòng, tôi xin chân thành tạ lỗi.".to_string(),
                        phonetic_or_romaji: "Touhoteru no futegiwa ni yori gofukai na omoi o okakeshi, kokoro yori owabi moushiagemasu.".to_string(),
                    },
                    DialogueLine {
                        speaker: "VIP客".to_string(),
                        text: "急な設備故障には驚きましたが、迅速な連絡と代替案の提示は良かったです。".to_string(),
                        translation_vi: "Sự cố thiết bị đột ngột làm tôi bất ngờ, nhưng các bạn thông báo nhanh và đưa ra phương án thay thế rất tốt.".to_string(),
                        phonetic_or_romaji: "Kyuu na setsubi koshou ni wa odorokimashita ga, jinsoku na renraku to daitaian no teiji wa yokatta desu.".to_string(),
                    },
                    DialogueLine {
                        speaker: "総支配人".to_string(),
                        text: "ご寛恕いただき恐縮です。エグゼクティブラウンジのご利用を終日ご案内申し上げます。".to_string(),
                        translation_vi: "Rất cảm kích trước sự bao dung của quý khách. Xin kính mời quý khách sử dụng Executive Lounge cả ngày.".to_string(),
                        phonetic_or_romaji: "Gokanjo itadaki kyoushuku desu. Eguzekutibu raunji no goriyou o shuujitsu goannai moushiagemasu.".to_string(),
                    },
                    DialogueLine {
                        speaker: "VIP客".to_string(),
                        text: "丁寧なおもてなしに安心しました。引き続き滞在を楽しみます。".to_string(),
                        translation_vi: "Sự tiếp đón chu đáo của các bạn làm tôi thấy an tâm. Tôi sẽ tiếp tục tận hưởng kỳ nghỉ.".to_string(),
                        phonetic_or_romaji: "Teinei na omotenashi ni anshin shimashita. Hikitsuzuki taizai o tanoshimimasu.".to_string(),
                    },
                ],
                vocabulary: vec![
                    DialogueBreakdown {
                        word: "不手際".to_string(),
                        meaning_vi: "Sai sót, bất cẩn trong phục vụ".to_string(),
                        kana_or_phonetic: "ふてぎわ (Futegiwa)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "お詫び".to_string(),
                        meaning_vi: "Lời xin lỗi chân thành".to_string(),
                        kana_or_phonetic: "おわび (Owabi)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "恐縮".to_string(),
                        meaning_vi: "Vô cùng áy náy và biết ơn".to_string(),
                        kana_or_phonetic: "きょうしゅく (Kyoushuku)".to_string(),
                    },
                ],
                grammar_hints: vec![GrammarHint {
                    pattern: "心より〜申し上げます".to_string(),
                    explanation_vi: "Bày tỏ tình cảm từ tận đáy lòng (khiêm nhường ngữ cao cấp)".to_string(),
                    example: "心よりお詫び申し上げます。".to_string(),
                }],
                suggested_writing_targets: vec!["不手際".to_string(), "恐縮".to_string()],
            },

            // ==================== JAPANESE BUSINESS ====================
            ("ja", "business", "beginner") => DialogueResponse {
                topic: "business_meeting".to_string(),
                profession: "business".to_string(),
                difficulty_level: "beginner".to_string(),
                title: "初回商談での名刺交換と挨拶".to_string(),
                title_vi: "Trao đổi danh thiếp và chào hỏi trong buổi gặp mặt đầu tiên".to_string(),
                lines: vec![
                    DialogueLine {
                        speaker: "佐藤営業".to_string(),
                        text: "初めまして。リンガソリューションズの佐藤と申します。".to_string(),
                        translation_vi: "Xin chào lần đầu gặp. Tôi là Sato thuộc Công ty Giải pháp Lingua.".to_string(),
                        phonetic_or_romaji: "Hajimemashite. Ringa soryuushonzu no Satou to moushimasu.".to_string(),
                    },
                    DialogueLine {
                        speaker: "鈴木部長".to_string(),
                        text: "グローバル商事の鈴木でございます。お会いできて光栄です。".to_string(),
                        translation_vi: "Tôi là Suzuki thuộc Global Trading. Rất vinh hạnh được gặp anh.".to_string(),
                        phonetic_or_romaji: "Guroobaru shouji no Suzuki de gozaimasu. Oaidekite kouei desu.".to_string(),
                    },
                    DialogueLine {
                        speaker: "佐藤営業".to_string(),
                        text: "頂戴いたします。本日は新製品のデモンストレーションをご案内いたします。".to_string(),
                        translation_vi: "Tôi xin phép nhận danh thiếp. Hôm nay tôi xin giới thiệu bản demo sản phẩm mới.".to_string(),
                        phonetic_or_romaji: "Choudai itashimasu. Honjitsu wa shinseihin no demonsutoreeshon o goannai itashimasu.".to_string(),
                    },
                    DialogueLine {
                        speaker: "鈴木部長".to_string(),
                        text: "期待しております。よろしくお願いいたします。".to_string(),
                        translation_vi: "Tôi rất kỳ vọng. Nhờ anh giúp đỡ nhé.".to_string(),
                        phonetic_or_romaji: "Kitai shite orimasu. Yoroshiku onegai itashimasu.".to_string(),
                    },
                ],
                vocabulary: vec![
                    DialogueBreakdown {
                        word: "商談".to_string(),
                        meaning_vi: "Đàm phán kinh doanh, trao đổi thương mại".to_string(),
                        kana_or_phonetic: "しょうだん (Shoudan)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "光栄".to_string(),
                        meaning_vi: "Vinh hạnh, hân hạnh".to_string(),
                        kana_or_phonetic: "こうえい (Kouei)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "頂戴".to_string(),
                        meaning_vi: "Xin phép nhận lấy (Khiêm nhường)".to_string(),
                        kana_or_phonetic: "ちょうだい (Choudai)".to_string(),
                    },
                ],
                grammar_hints: vec![GrammarHint {
                    pattern: "〜と申します".to_string(),
                    explanation_vi: "Xưng tên lịch sự trang trọng trong giao tiếp kinh doanh".to_string(),
                    example: "佐藤と申します。".to_string(),
                }],
                suggested_writing_targets: vec!["商談".to_string(), "名刺".to_string()],
            },
            ("ja", "business", "intermediate") => DialogueResponse {
                topic: "contract_negotiation".to_string(),
                profession: "business".to_string(),
                difficulty_level: "intermediate".to_string(),
                title: "契約条件と納期の調整交渉".to_string(),
                title_vi: "Đàm phán điều chỉnh điều khoản hợp đồng và thời hạn bàn giao".to_string(),
                lines: vec![
                    DialogueLine {
                        speaker: "購買担当".to_string(),
                        text: "今回の提案ですが、単価と保守サポートの範囲について合意が必要です。".to_string(),
                        translation_vi: "Đối với đề xuất lần này, chúng ta cần thống nhất về đơn giá và phạm vi hỗ trợ bảo trì.".to_string(),
                        phonetic_or_romaji: "Konkai no teian desu ga, tanka to hoshu sapooto no han'i ni tsuite goui ga hitsuyou desu.".to_string(),
                    },
                    DialogueLine {
                        speaker: "営業マネージャー".to_string(),
                        text: "年間契約を前提としていただければ、ボリュームディスカウントを適用可能です。".to_string(),
                        translation_vi: "Nếu quý công ty đồng ý ký hợp đồng năm, chúng tôi có thể áp dụng mức chiết khấu theo số lượng.".to_string(),
                        phonetic_or_romaji: "Nenkan keiyaku o zentei to shite itadakereba, boryuumu disukaunto o tekiyou kanou desu.".to_string(),
                    },
                    DialogueLine {
                        speaker: "購買担当".to_string(),
                        text: "承知しました。来週の役員会議で正式な決裁を取る段取りを進めます。".to_string(),
                        translation_vi: "Tôi hiểu rồi. Tôi sẽ xúc tiến các bước để xin phê duyệt chính thức trong cuộc họp ban giám đốc tuần tới.".to_string(),
                        phonetic_or_romaji: "Shouchi shimashita. Raishuu no yakuin kaigi de seishiki na kessai o toru dandori o susumemasu.".to_string(),
                    },
                    DialogueLine {
                        speaker: "営業マネージャー".to_string(),
                        text: "ありがとうございます。修正した提案書を本日中に送付いたします。".to_string(),
                        translation_vi: "Cảm ơn quý công ty. Tôi sẽ gửi bản đề xuất đã chỉnh sửa trong ngày hôm nay.".to_string(),
                        phonetic_or_romaji: "Arigatou gozaimasu. Shuusei shita teiansho o honjitsuchuu ni soufu itashimasu.".to_string(),
                    },
                ],
                vocabulary: vec![
                    DialogueBreakdown {
                        word: "提案".to_string(),
                        meaning_vi: "Đề xuất, kiến nghị".to_string(),
                        kana_or_phonetic: "ていあん (Teian)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "合意".to_string(),
                        meaning_vi: "Thống nhất, đồng thuận".to_string(),
                        kana_or_phonetic: "ごうい (Goui)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "決裁".to_string(),
                        meaning_vi: "Phê duyệt, chuẩn y của cấp trên".to_string(),
                        kana_or_phonetic: "けっさい (Kessai)".to_string(),
                    },
                ],
                grammar_hints: vec![GrammarHint {
                    pattern: "〜を前提として".to_string(),
                    explanation_vi: "Lấy cái gì làm điều kiện tiên quyết / tiền đề".to_string(),
                    example: "年間契約を前提として適用可能です。".to_string(),
                }],
                suggested_writing_targets: vec!["契約".to_string(), "提案".to_string()],
            },
            ("ja", "business", "advanced") => DialogueResponse {
                topic: "strategic_partnership".to_string(),
                profession: "business".to_string(),
                difficulty_level: "advanced".to_string(),
                title: "戦略的パートナーシップの締結".to_string(),
                title_vi: "Ký kết thỏa thuận hợp tác chiến lược".to_string(),
                lines: vec![
                    DialogueLine {
                        speaker: "代表取締役A".to_string(),
                        text: "両社の強みを融合させ、アジア太平洋地域での新規事業を展開いたしましょう。".to_string(),
                        translation_vi: "Hãy cùng kết hợp thế mạnh của cả hai bên để mở rộng mảng kinh doanh mới tại khu vực Châu Á - Thái Bình Dương.".to_string(),
                        phonetic_or_romaji: "Ryousha no tsuyomi o yuugou sase, Ajia Taiheiyou chiiki de no shinki jigyou o tenkai itashimashou.".to_string(),
                    },
                    DialogueLine {
                        speaker: "代表取締役B".to_string(),
                        text: "異存ございません。シナジー効果を最大化するため共同タスクフォースを立ち上げます。".to_string(),
                        translation_vi: "Tôi hoàn toàn nhất trí. Chúng tôi sẽ thành lập nhóm đặc nhiệm chung để tối đa hóa hiệu ứng cộng hưởng.".to_string(),
                        phonetic_or_romaji: "Izon gozaimasen. Shinajii kouka o saidaika suru tame kyoudou tasukufousu o tachiagemasu.".to_string(),
                    },
                    DialogueLine {
                        speaker: "代表取締役A".to_string(),
                        text: "コンプライアンス体制とガバナンスの透明性も同時に確保してまいりましょう。".to_string(),
                        translation_vi: "Chúng ta cũng hãy đồng thời đảm bảo hệ thống tuân thủ và tính minh bạch trong quản trị.".to_string(),
                        phonetic_or_romaji: "Konpuraiansu taisei to gabanansu no toumeisei mo douji ni kakuho shite mairimashou.".to_string(),
                    },
                    DialogueLine {
                        speaker: "代表取締役B".to_string(),
                        text: "確固たる信頼関係のもと、長期的な発展を目指して前進いたします。".to_string(),
                        translation_vi: "Dựa trên mối quan hệ tin cậy vững chắc, chúng ta sẽ cùng tiến bước hướng tới sự phát triển lâu dài.".to_string(),
                        phonetic_or_romaji: "Kakkotaru shinrai kankei no moto, choukiteki na hatten o mezashite zenshin itashimasu.".to_string(),
                    },
                ],
                vocabulary: vec![
                    DialogueBreakdown {
                        word: "融合".to_string(),
                        meaning_vi: "Hòa quyện, kết hợp sâu rộng".to_string(),
                        kana_or_phonetic: "ゆうごう (Yuugou)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "展開".to_string(),
                        meaning_vi: "Triển khai, mở rộng quy mô".to_string(),
                        kana_or_phonetic: "てんかい (Tenkai)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "透明性".to_string(),
                        meaning_vi: "Tính minh bạch".to_string(),
                        kana_or_phonetic: "とうめいせい (Toumeisei)".to_string(),
                    },
                ],
                grammar_hints: vec![GrammarHint {
                    pattern: "〜のもと".to_string(),
                    explanation_vi: "Dưới sự lãnh đạo, dựa trên nền tảng của cái gì".to_string(),
                    example: "信頼関係のもと前進いたします。".to_string(),
                }],
                suggested_writing_targets: vec!["提携".to_string(), "展開".to_string()],
            },

            // ==================== JAPANESE GENERAL ====================
            ("ja", "general", "beginner") => DialogueResponse {
                topic: "office_conversation".to_string(),
                profession: "general".to_string(),
                difficulty_level: "beginner".to_string(),
                title: "オフィスでの日常会話とランチの誘い".to_string(),
                title_vi: "Trò chuyện thường nhật và rủ ăn trưa tại văn phòng".to_string(),
                lines: vec![
                    DialogueLine {
                        speaker: "山田さん".to_string(),
                        text: "お疲れ様です。今日の午前中の仕事は順調ですか？".to_string(),
                        translation_vi: "Chào bạn. Công việc sáng nay có thuận lợi không?".to_string(),
                        phonetic_or_romaji: "Otsukaresama desu. Kyou no gozenchuu no shigoto wa junchou desu ka?".to_string(),
                    },
                    DialogueLine {
                        speaker: "佐々木さん".to_string(),
                        text: "ええ、資料作成がひと段落したところです。".to_string(),
                        translation_vi: "Ừ, mình vừa mới làm xong một đoạn báo cáo tài liệu rồi.".to_string(),
                        phonetic_or_romaji: "Ee, shiryou sakusei ga hitodanraku shita tokoro desu.".to_string(),
                    },
                    DialogueLine {
                        speaker: "山田さん".to_string(),
                        text: "よかったら、駅前に新しくできた定食屋へ行きませんか？".to_string(),
                        translation_vi: "Nếu được thì trưa nay cùng qua quán cơm mới mở trước nhà ga không?".to_string(),
                        phonetic_or_romaji: "Yokattara, ekimae ni atarashiku dekita teishokuya e ikimasen ka?".to_string(),
                    },
                    DialogueLine {
                        speaker: "佐々木さん".to_string(),
                        text: "いいですね！美味しそうなのでぜひ行きましょう。".to_string(),
                        translation_vi: "Được đó! Nghe hấp dẫn quá, chúng mình đi thôi.".to_string(),
                        phonetic_or_romaji: "Ii desu ne! Oishisou na node zehi ikimashou.".to_string(),
                    },
                ],
                vocabulary: vec![
                    DialogueBreakdown {
                        word: "資料".to_string(),
                        meaning_vi: "Tài liệu, hồ sơ".to_string(),
                        kana_or_phonetic: "しりょう (Shiryou)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "順調".to_string(),
                        meaning_vi: "Thuận lợi, trôi chảy".to_string(),
                        kana_or_phonetic: "じゅんちょう (Junchou)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "定食".to_string(),
                        meaning_vi: "Cơm phần/suất ăn truyền thống".to_string(),
                        kana_or_phonetic: "ていしょく (Teishoku)".to_string(),
                    },
                ],
                grammar_hints: vec![GrammarHint {
                    pattern: "〜したところです".to_string(),
                    explanation_vi: "Vừa mới làm xong một việc gì đó tức thì".to_string(),
                    example: "ひと段落したところです。".to_string(),
                }],
                suggested_writing_targets: vec!["資料".to_string(), "順調".to_string()],
            },
            ("ja", "general", "intermediate") => DialogueResponse {
                topic: "schedule_coordination".to_string(),
                profession: "general".to_string(),
                difficulty_level: "intermediate".to_string(),
                title: "チーム間のスケジュール調整".to_string(),
                title_vi: "Điều phối lịch trình giữa các nhóm làm việc".to_string(),
                lines: vec![
                    DialogueLine {
                        speaker: "企画リーダー".to_string(),
                        text: "来週のリリースに向けて、各部門のタスク進行状況を確認したいです。".to_string(),
                        translation_vi: "Hướng tới đợt release tuần sau, tôi muốn xác nhận tiến độ công việc của từng phòng ban.".to_string(),
                        phonetic_or_romaji: "Raishuu no ririisu ni mukete, kakubumon no tasuku shinkou joukyou o kakunin shitai desu.".to_string(),
                    },
                    DialogueLine {
                        speaker: "デザイン担当".to_string(),
                        text: "デザインチームの最終チェックは木曜日までに完了する見込みです。".to_string(),
                        translation_vi: "Dự kiến nhóm thiết kế sẽ hoàn tất khâu kiểm duyệt cuối cùng trước thứ Năm.".to_string(),
                        phonetic_or_romaji: "Dezain chiimu no saishuu chekku wa mokuyoubi made ni kanryou suru mikomi desu.".to_string(),
                    },
                    DialogueLine {
                        speaker: "企画リーダー".to_string(),
                        text: "助かります。金曜日の午前中に合同の最終リハーサルを設定しましょう。".to_string(),
                        translation_vi: "Cảm ơn bạn. Vậy sáng thứ Sáu chúng ta sẽ tổ chức buổi diễn tập tổng thể.".to_string(),
                        phonetic_or_romaji: "Tasukarimasu. Kinyoubi no gozenchuu ni goudou no saishuu rihaasaru o settei shimashou.".to_string(),
                    },
                    DialogueLine {
                        speaker: "デザイン担当".to_string(),
                        text: "了解しました。関係者全員にカレンダー招待状を送信します。".to_string(),
                        translation_vi: "Nhất trí. Tôi sẽ gửi lời mời lịch tới tất cả những người liên quan.".to_string(),
                        phonetic_or_romaji: "Ryoukai shimashita. Kankeisha zen'in ni karendaa shoutaijou o soushin shimasu.".to_string(),
                    },
                ],
                vocabulary: vec![
                    DialogueBreakdown {
                        word: "進行".to_string(),
                        meaning_vi: "Tiến hành, diễn tiến".to_string(),
                        kana_or_phonetic: "しんこう (Shinkou)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "見込み".to_string(),
                        meaning_vi: "Dự kiến, triển vọng".to_string(),
                        kana_or_phonetic: "みこみ (Mikomi)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "関係者".to_string(),
                        meaning_vi: "Những người có liên quan".to_string(),
                        kana_or_phonetic: "かんけいしゃ (Kankeisha)".to_string(),
                    },
                ],
                grammar_hints: vec![GrammarHint {
                    pattern: "〜に向けて".to_string(),
                    explanation_vi: "Nhằm hướng tới một mục tiêu hoặc thời điểm".to_string(),
                    example: "リリースに向けて確認したいです。".to_string(),
                }],
                suggested_writing_targets: vec!["進行".to_string(), "関係".to_string()],
            },
            ("ja", "general", "advanced") => DialogueResponse {
                topic: "leadership_culture".to_string(),
                profession: "general".to_string(),
                difficulty_level: "advanced".to_string(),
                title: "組織風土改革とリーダーシップの確立".to_string(),
                title_vi: "Đổi mới văn hóa doanh nghiệp và thiết lập năng lực lãnh đạo".to_string(),
                lines: vec![
                    DialogueLine {
                        speaker: "役員A".to_string(),
                        text: "多様なバックグラウンドを持つメンバーが主体的に挑戦できる環境作りが必要です。".to_string(),
                        translation_vi: "Chúng ta cần xây dựng môi trường để các thành viên đa dạng nền tảng có thể chủ động thử sức.".to_string(),
                        phonetic_or_romaji: "Tayou na bakkuguraundo o motsu menbaa ga shutaiteki ni chousen dekiru kankyouzukuri ga hitsuyou desu.".to_string(),
                    },
                    DialogueLine {
                        speaker: "役員B".to_string(),
                        text: "心理的安全性を担保することで、建設的なフィードバックが活発になりますね。".to_string(),
                        translation_vi: "Bằng cách đảm bảo sự an toàn tâm lý, những phản hồi mang tính xây dựng sẽ diễn ra sôi nổi.".to_string(),
                        phonetic_or_romaji: "Shinriteki anzensei o tanpo suru koto de, kensetsuteki na fiidobakku ga kappatsu ni narimasu ne.".to_string(),
                    },
                    DialogueLine {
                        speaker: "役員A".to_string(),
                        text: "個々の成果だけでなくチーム全体の協調性を正当に評価する制度を整えましょう。".to_string(),
                        translation_vi: "Hãy hoàn thiện cơ chế đánh giá công bằng không chỉ thành tích cá nhân mà cả sự gắn kết toàn đội.".to_string(),
                        phonetic_or_romaji: "Koko no seika dake de naku chiimu zentai no kyouchousei o seitou ni hyouka suru seido o totonoemashou.".to_string(),
                    },
                    DialogueLine {
                        speaker: "役員B".to_string(),
                        text: "賛成です。持続可能な成長を実現する盤石な基盤を築きましょう。".to_string(),
                        translation_vi: "Hoàn toàn tán thành. Chúng ta hãy cùng gây dựng nền tảng vững chắc để đạt tăng trưởng bền vững.".to_string(),
                        phonetic_or_romaji: "Sansei desu. Jizokukanou na seichou o jitsugen suru banjaku na kiban o kizukimashou.".to_string(),
                    },
                ],
                vocabulary: vec![
                    DialogueBreakdown {
                        word: "主体的".to_string(),
                        meaning_vi: "Tính chủ động, tự thân sáng tạo".to_string(),
                        kana_or_phonetic: "しゅたいてき (Shutaiteki)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "協調性".to_string(),
                        meaning_vi: "Tinh thần hợp tác, đồng lòng".to_string(),
                        kana_or_phonetic: "きょうちょうせい (Kyouchousei)".to_string(),
                    },
                    DialogueBreakdown {
                        word: "持続可能".to_string(),
                        meaning_vi: "Bền vững, lâu dài (Sustainable)".to_string(),
                        kana_or_phonetic: "じぞくかのう (Jizoku kanou)".to_string(),
                    },
                ],
                grammar_hints: vec![GrammarHint {
                    pattern: "〜ことで".to_string(),
                    explanation_vi: "Bằng phương thức, nhờ vào hành động gì đó mà đạt kết quả".to_string(),
                    example: "担保することで活発になります。".to_string(),
                }],
                suggested_writing_targets: vec!["協調".to_string(), "改革".to_string()],
            },

            // ==================== ENGLISH IT ====================
            ("en", "it", "beginner") => DialogueResponse {
                topic: "daily_standup".to_string(),
                profession: "it".to_string(),
                difficulty_level: "beginner".to_string(),
                title: "Morning Engineering Standup".to_string(),
                title_vi: "Họp Standup kỹ thuật buổi sáng".to_string(),
                lines: vec![
                    DialogueLine {
                        speaker: "Tech Lead".to_string(),
                        text: "Good morning team. What did you accomplish yesterday?".to_string(),
                        translation_vi: "Chào buổi sáng cả đội. Hôm qua bạn đã hoàn thành những gì?".to_string(),
                        phonetic_or_romaji: "/ɡʊd ˈmɔːr.nɪŋ tiːm.../".to_string(),
                    },
                    DialogueLine {
                        speaker: "Software Engineer".to_string(),
                        text: "Yesterday I completed the user authentication endpoints and wrote unit tests.".to_string(),
                        translation_vi: "Hôm qua tôi đã hoàn thiện các endpoint xác thực người dùng và viết unit tests.".to_string(),
                        phonetic_or_romaji: "/ˈjes.tɚ.deɪ aɪ kəmˈpliː.t̬ɪd.../".to_string(),
                    },
                    DialogueLine {
                        speaker: "Tech Lead".to_string(),
                        text: "Great progress. Any blockers preventing you from continuing today?".to_string(),
                        translation_vi: "Tiến độ rất tốt. Có trở ngại nào cản trở bạn hôm nay không?".to_string(),
                        phonetic_or_romaji: "/ɡreɪt ˈprɑː.ɡres.../".to_string(),
                    },
                    DialogueLine {
                        speaker: "Software Engineer".to_string(),
                        text: "No blockers today. I plan to wire the database migrations and create the pull request.".to_string(),
                        translation_vi: "Hôm nay không có trở ngại gì. Tôi dự định kết nối migration cơ sở dữ liệu và tạo pull request.".to_string(),
                        phonetic_or_romaji: "/noʊ ˈblɑː.kɚz təˈdeɪ.../".to_string(),
                    },
                ],
                vocabulary: vec![
                    DialogueBreakdown {
                        word: "blocker".to_string(),
                        meaning_vi: "Trở ngại/vấn đề gây tắc nghẽn công việc".to_string(),
                        kana_or_phonetic: "/ˈblɑː.kɚ/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "authentication".to_string(),
                        meaning_vi: "Xác thực danh tính người dùng".to_string(),
                        kana_or_phonetic: "/ɔːˌθen.tɪˈkeɪ.ʃən/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "migration".to_string(),
                        meaning_vi: "Chuyển đổi/cập nhật cấu trúc cơ sở dữ liệu".to_string(),
                        kana_or_phonetic: "/maɪˈɡreɪ.ʃən/".to_string(),
                    },
                ],
                grammar_hints: vec![GrammarHint {
                    pattern: "I plan to + Verb".to_string(),
                    explanation_vi: "Mẫu câu diễn tả kế hoạch hành động trong ngày làm việc".to_string(),
                    example: "I plan to wire the database migrations.".to_string(),
                }],
                suggested_writing_targets: vec!["commit".to_string(), "blocker".to_string()],
            },
            ("en", "it", "intermediate") => DialogueResponse {
                topic: "code_review".to_string(),
                profession: "it".to_string(),
                difficulty_level: "intermediate".to_string(),
                title: "Pull Request Architecture Discussion".to_string(),
                title_vi: "Thảo luận kiến trúc cho Pull Request".to_string(),
                lines: vec![
                    DialogueLine {
                        speaker: "Senior Reviewer".to_string(),
                        text: "Thanks for submitting the PR. The caching logic looks clean, but check the cache invalidation strategy.".to_string(),
                        translation_vi: "Cảm ơn bạn đã gửi PR. Logic caching trông rất gọn, nhưng hãy kiểm tra chiến lược hủy cache.".to_string(),
                        phonetic_or_romaji: "/θæŋks fɔːr səbˈmɪt̬.ɪŋ.../".to_string(),
                    },
                    DialogueLine {
                        speaker: "PR Author".to_string(),
                        text: "I configured a 5-minute TTL, but we could also listen to Redis pub/sub events for immediate invalidation.".to_string(),
                        translation_vi: "Tôi đã cấu hình TTL 5 phút, nhưng chúng ta cũng có thể lắng nghe sự kiện Redis pub/sub để xóa cache tức thì.".to_string(),
                        phonetic_or_romaji: "/aɪ kənˈfɪɡ.jɚd eɪ.../".to_string(),
                    },
                    DialogueLine {
                        speaker: "Senior Reviewer".to_string(),
                        text: "Event-driven invalidation will ensure strong consistency across our backend replicas.".to_string(),
                        translation_vi: "Hủy cache hướng sự kiện sẽ đảm bảo tính nhất quán mạnh mẽ trên các bản sao backend của chúng ta.".to_string(),
                        phonetic_or_romaji: "/ɪˈvent ˌdrɪv.ən.../".to_string(),
                    },
                    DialogueLine {
                        speaker: "PR Author".to_string(),
                        text: "Agreed. I'll add the event subscriber and push the updated commit shortly.".to_string(),
                        translation_vi: "Nhất trí. Tôi sẽ thêm event subscriber và đẩy commit đã cập nhật lên sớm.".to_string(),
                        phonetic_or_romaji: "/əˈɡriːd. aɪl æd.../".to_string(),
                    },
                ],
                vocabulary: vec![
                    DialogueBreakdown {
                        word: "invalidation".to_string(),
                        meaning_vi: "Hủy bỏ/làm mất hiệu lực bộ nhớ cache cũ".to_string(),
                        kana_or_phonetic: "/ɪnˌvæl.əˈdeɪ.ʃən/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "consistency".to_string(),
                        meaning_vi: "Tính nhất quán của dữ liệu phân tán".to_string(),
                        kana_or_phonetic: "/kənˈsɪs.tən.si/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "replica".to_string(),
                        meaning_vi: "Bản sao nút dịch vụ chạy song song".to_string(),
                        kana_or_phonetic: "/ˈrep.lɪ.kə/".to_string(),
                    },
                ],
                grammar_hints: vec![GrammarHint {
                    pattern: "will ensure + noun phrase".to_string(),
                    explanation_vi: "Khẳng định một giải pháp kỹ thuật sẽ đảm bảo điều gì".to_string(),
                    example: "Event-driven invalidation will ensure strong consistency.".to_string(),
                }],
                suggested_writing_targets: vec!["refactor".to_string(), "cache".to_string()],
            },
            ("en", "it", "advanced") => DialogueResponse {
                topic: "incident_triage".to_string(),
                profession: "it".to_string(),
                difficulty_level: "advanced".to_string(),
                title: "Production High-Severity Incident Triage".to_string(),
                title_vi: "Xử lý khẩn cấp sự cố nghiêm trọng Production".to_string(),
                lines: vec![
                    DialogueLine {
                        speaker: "Incident Commander".to_string(),
                        text: "Status update: 504 gateway timeouts spiked above our critical SLO threshold on payment ingestion.".to_string(),
                        translation_vi: "Cập nhật tình trạng: Lỗi 504 gateway timeout tăng đột biến vượt ngưỡng SLO nguy cấp ở luồng thanh toán.".to_string(),
                        phonetic_or_romaji: "/ˈsteɪ.t̬əs ˈʌp.deɪt.../".to_string(),
                    },
                    DialogueLine {
                        speaker: "Database Lead".to_string(),
                        text: "We identified connection exhaustion caused by unindexed foreign key table locks.".to_string(),
                        translation_vi: "Chúng tôi đã xác định tình trạng cạn kiệt connection do khóa bảng khóa ngoại chưa được đánh chỉ mục.".to_string(),
                        phonetic_or_romaji: "/wiː aɪˈden.t̬ə.faɪd.../".to_string(),
                    },
                    DialogueLine {
                        speaker: "Incident Commander".to_string(),
                        text: "Apply the index concurrently on read replicas first, then execute on primary.".to_string(),
                        translation_vi: "Hãy áp dụng đánh index concurrently trên read replica trước, sau đó thực thi trên node chính.".to_string(),
                        phonetic_or_romaji: "/əˈplaɪ ðiː ˈɪn.deks.../".to_string(),
                    },
                    DialogueLine {
                        speaker: "Database Lead".to_string(),
                        text: "Index applied successfully. Latency dropped back under 40 milliseconds across all nodes.".to_string(),
                        translation_vi: "Đã đánh index thành công. Độ trễ đã giảm xuống dưới 40ms trên tất cả các node.".to_string(),
                        phonetic_or_romaji: "/ˈɪn.deks əˈplaɪd.../".to_string(),
                    },
                ],
                vocabulary: vec![
                    DialogueBreakdown {
                        word: "exhaustion".to_string(),
                        meaning_vi: "Sự cạn kiệt tài nguyên (bộ nhớ, connection)".to_string(),
                        kana_or_phonetic: "/ɪɡˈzɑː.stʃən/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "concurrently".to_string(),
                        meaning_vi: "Đồng thời song song không khóa bảng".to_string(),
                        kana_or_phonetic: "/kənˈkɝː.ənt.li/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "latency".to_string(),
                        meaning_vi: "Độ trễ truyền tải tín hiệu mạng".to_string(),
                        kana_or_phonetic: "/ˈleɪ.tən.si/".to_string(),
                    },
                ],
                grammar_hints: vec![GrammarHint {
                    pattern: "identified a ... caused by ...".to_string(),
                    explanation_vi: "Mẫu câu báo cáo nguyên nhân cốt lõi của sự cố kỹ thuật".to_string(),
                    example: "We identified connection exhaustion caused by table locks.".to_string(),
                }],
                suggested_writing_targets: vec!["latency".to_string(), "failover".to_string()],
            },

            // ==================== ENGLISH HOSPITALITY ====================
            ("en", "hospitality", "beginner") => DialogueResponse {
                topic: "hotel_checkin".to_string(),
                profession: "hospitality".to_string(),
                difficulty_level: "beginner".to_string(),
                title: "Front Desk Guest Check-in".to_string(),
                title_vi: "Làm thủ tục nhận phòng tại quầy lễ tân".to_string(),
                lines: vec![
                    DialogueLine {
                        speaker: "Receptionist".to_string(),
                        text: "Good afternoon, welcome to Lingua Grand Hotel. How may I assist you today?".to_string(),
                        translation_vi: "Chào buổi chiều, chào mừng quý khách đến với khách sạn Lingua Grand. Tôi có thể hỗ trợ gì cho quý khách hôm nay ạ?".to_string(),
                        phonetic_or_romaji: "/ɡʊd ˌæf.tɚˈnuːn.../".to_string(),
                    },
                    DialogueLine {
                        speaker: "Guest".to_string(),
                        text: "Hello, I have a reservation for three nights under the name Alex Rivera.".to_string(),
                        translation_vi: "Xin chào, tôi có đặt phòng 3 đêm dưới tên Alex Rivera.".to_string(),
                        phonetic_or_romaji: "/həˈloʊ, aɪ hæv eɪ.../".to_string(),
                    },
                    DialogueLine {
                        speaker: "Receptionist".to_string(),
                        text: "Thank you, Mr. Rivera. I have your king-size room ready on the 12th floor with a harbor view.".to_string(),
                        translation_vi: "Cảm ơn quý khách Rivera. Tôi đã chuẩn bị sẵn phòng giường King ở tầng 12 hướng nhìn ra cảng biển.".to_string(),
                        phonetic_or_romaji: "/θæŋk juː, ˈmɪs.tɚ.../".to_string(),
                    },
                    DialogueLine {
                        speaker: "Guest".to_string(),
                        text: "That sounds lovely! What time is breakfast served in the morning?".to_string(),
                        translation_vi: "Nghe tuyệt quá! Bữa sáng phục vụ lúc mấy giờ vào buổi sáng vậy?".to_string(),
                        phonetic_or_romaji: "/ðæt saʊndz ˈlʌv.li.../".to_string(),
                    },
                    DialogueLine {
                        speaker: "Receptionist".to_string(),
                        text: "Complimentary breakfast is served from 6:30 AM to 10:30 AM in the Sky Dining Hall.".to_string(),
                        translation_vi: "Bữa sáng miễn phí được phục vụ từ 6h30 đến 10h30 tại Sky Dining Hall tầng thượng.".to_string(),
                        phonetic_or_romaji: "/ˌkɑːm.pləˈmen.t̬ɚ.i ˈbrek.fəst.../".to_string(),
                    },
                ],
                vocabulary: vec![
                    DialogueBreakdown {
                        word: "complimentary".to_string(),
                        meaning_vi: "Miễn phí (dịch vụ kèm theo)".to_string(),
                        kana_or_phonetic: "/ˌkɑːm.pləˈmen.t̬ɚ.i/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "harbor".to_string(),
                        meaning_vi: "Cảng biển / vịnh nước sâu".to_string(),
                        kana_or_phonetic: "/ˈhɑːr.bɚ/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "reservation".to_string(),
                        meaning_vi: "Sự đặt phòng trước".to_string(),
                        kana_or_phonetic: "/ˌrez.ɚˈveɪ.ʃən/".to_string(),
                    },
                ],
                grammar_hints: vec![GrammarHint {
                    pattern: "How may I assist you today?".to_string(),
                    explanation_vi: "Lời chào mở đầu lịch sự của lễ tân khách sạn".to_string(),
                    example: "How may I assist you today?".to_string(),
                }],
                suggested_writing_targets: vec!["reservation".to_string(), "welcome".to_string()],
            },
            ("en", "hospitality", "intermediate") => DialogueResponse {
                topic: "concierge_dining".to_string(),
                profession: "hospitality".to_string(),
                difficulty_level: "intermediate".to_string(),
                title: "Concierge VIP Dining & Excursion Arrangement".to_string(),
                title_vi: "Sắp xếp ẩm thực và du lịch cùng Concierge".to_string(),
                lines: vec![
                    DialogueLine {
                        speaker: "Head Concierge".to_string(),
                        text: "Good evening, Ms. Zhang. How was your sightseeing tour of the historical district today?".to_string(),
                        translation_vi: "Chào buổi tối cô Zhang. Chuyến tham quan khu phố lịch sử của cô hôm nay thế nào ạ?".to_string(),
                        phonetic_or_romaji: "/ɡʊd ˈiːv.nɪŋ, mɪz.../".to_string(),
                    },
                    DialogueLine {
                        speaker: "Guest".to_string(),
                        text: "It was wonderful, thank you! Could you recommend a fine dining seafood bistro for tonight?".to_string(),
                        translation_vi: "Tuyệt vời lắm, cảm ơn bạn! Bạn có thể gợi ý cho tôi một nhà hàng hải sản cao cấp tối nay không?".to_string(),
                        phonetic_or_romaji: "/ɪt wɑːz ˈwʌn.dɚ.fəl.../".to_string(),
                    },
                    DialogueLine {
                        speaker: "Head Concierge".to_string(),
                        text: "I would be delighted to secure a waterfront terrace table for you at The Marina Pearl.".to_string(),
                        translation_vi: "Tôi rất hân hạnh được đặt giúp cô một bàn ngoài ban công hướng biển tại The Marina Pearl.".to_string(),
                        phonetic_or_romaji: "/aɪ wʊd biː dɪˈlaɪ.t̬ɪd.../".to_string(),
                    },
                    DialogueLine {
                        speaker: "Guest".to_string(),
                        text: "That would be perfect. Please make the reservation for 8:00 PM for two guests.".to_string(),
                        translation_vi: "Thế thì hoàn hảo quá. Làm ơn đặt bàn lúc 8 giờ tối cho 2 người giúp tôi nhé.".to_string(),
                        phonetic_or_romaji: "/ðæt wʊd biː ˈpɝː.fekt.../".to_string(),
                    },
                    DialogueLine {
                        speaker: "Head Concierge".to_string(),
                        text: "Consider it done. I will also have our chauffeur ready at 7:30 PM to escort you.".to_string(),
                        translation_vi: "Cô cứ yên tâm nhé. Tôi cũng sẽ chuẩn bị tài xế riêng lúc 7h30 tối để đưa đón cô.".to_string(),
                        phonetic_or_romaji: "/kənˈsɪd.ɚ ɪt dʌn.../".to_string(),
                    },
                ],
                vocabulary: vec![
                    DialogueBreakdown {
                        word: "sightseeing".to_string(),
                        meaning_vi: "Tham quan ngắm cảnh".to_string(),
                        kana_or_phonetic: "/ˈsaɪtˌsiː.ɪŋ/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "chauffeur".to_string(),
                        meaning_vi: "Tài xế riêng lịch thiệp".to_string(),
                        kana_or_phonetic: "/ʃoʊˈfɝː/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "waterfront".to_string(),
                        meaning_vi: "Bờ sông, ven bờ vịnh".to_string(),
                        kana_or_phonetic: "/ˈwɑː.t̬ɚ.frʌnt/".to_string(),
                    },
                ],
                grammar_hints: vec![GrammarHint {
                    pattern: "I would be delighted to + Verb".to_string(),
                    explanation_vi: "Cách nói trang nhã thể hiện sự vinh hạnh khi được phục vụ khách quý".to_string(),
                    example: "I would be delighted to secure a table for you.".to_string(),
                }],
                suggested_writing_targets: vec!["concierge".to_string(), "itinerary".to_string()],
            },
            ("en", "hospitality", "advanced") => DialogueResponse {
                topic: "crisis_resolution".to_string(),
                profession: "hospitality".to_string(),
                difficulty_level: "advanced".to_string(),
                title: "Executive Suite De-escalation & Service Recovery".to_string(),
                title_vi: "Xử lý khủng hoảng và khôi phục dịch vụ phòng VIP".to_string(),
                lines: vec![
                    DialogueLine {
                        speaker: "General Manager".to_string(),
                        text: "Good evening, Ambassador. I came personally to address the unforeseen noise disruption.".to_string(),
                        translation_vi: "Chào buổi tối ngài Đại sứ. Tôi đích thân đến để giải quyết sự cố tiếng ồn bất ngờ này.".to_string(),
                        phonetic_or_romaji: "/ɡʊd ˈiːv.nɪŋ, æmˈbæs.ə.dɚ.../".to_string(),
                    },
                    DialogueLine {
                        speaker: "Ambassador".to_string(),
                        text: "The diplomatic conference call was interrupted, which caused notable complications.".to_string(),
                        translation_vi: "Cuộc họp ngoại giao trực tuyến đã bị gián đoạn, gây ra những phức tạp đáng kể.".to_string(),
                        phonetic_or_romaji: "/ðə ˌdɪp.ləˈmæt̬.ɪk.../".to_string(),
                    },
                    DialogueLine {
                        speaker: "General Manager".to_string(),
                        text: "We deeply regret this disruption. Our staff has prepared the private soundproof lounge on floor 35 for your exclusive use.".to_string(),
                        translation_vi: "Chúng tôi vô cùng lấy làm tiếc. Nhân viên đã chuẩn bị phòng chờ cách âm riêng tại tầng 35 dành riêng cho ngài.".to_string(),
                        phonetic_or_romaji: "/wiː ˈdiːp.li rɪˈɡret.../".to_string(),
                    },
                    DialogueLine {
                        speaker: "Ambassador".to_string(),
                        text: "Your immediate personal intervention and prompt solution are greatly appreciated.".to_string(),
                        translation_vi: "Sự can thiệp cá nhân tức thì và giải pháp nhanh chóng của ông rất đáng trân trọng.".to_string(),
                        phonetic_or_romaji: "/jʊr ɪˈmiː.di.ət.../".to_string(),
                    },
                    DialogueLine {
                        speaker: "General Manager".to_string(),
                        text: "It is our absolute honor to ensure your stay remains seamless and comfortable.".to_string(),
                        translation_vi: "Được đảm bảo kỳ nghỉ của ngài diễn ra suôn sẻ và tiện nghi là vinh dự tuyệt đối của chúng tôi.".to_string(),
                        phonetic_or_romaji: "/ɪt ɪz ˈaʊ.ɚ ˈæb.sə.luːt.../".to_string(),
                    },
                ],
                vocabulary: vec![
                    DialogueBreakdown {
                        word: "unforeseen".to_string(),
                        meaning_vi: "Bất ngờ, ngoài dự kiến".to_string(),
                        kana_or_phonetic: "/ˌʌn.fɚˈsiːn/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "soundproof".to_string(),
                        meaning_vi: "Cách âm tuyệt đối".to_string(),
                        kana_or_phonetic: "/ˈsaʊnd.pruːf/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "intervention".to_string(),
                        meaning_vi: "Sự can thiệp, hỗ trợ kịp thời".to_string(),
                        kana_or_phonetic: "/ˌɪn.t̬ɚˈven.ʃən/".to_string(),
                    },
                ],
                grammar_hints: vec![GrammarHint {
                    pattern: "It is our honor to ensure...".to_string(),
                    explanation_vi: "Mẫu câu tôn vinh khách hàng ở cấp quản lý khách sạn cao cấp".to_string(),
                    example: "It is our absolute honor to ensure your comfort.".to_string(),
                }],
                suggested_writing_targets: vec!["apologies".to_string(), "seamless".to_string()],
            },

            // ==================== ENGLISH BUSINESS ====================
            ("en", "business", "beginner") => DialogueResponse {
                topic: "kickoff_meeting".to_string(),
                profession: "business".to_string(),
                difficulty_level: "beginner".to_string(),
                title: "Project Kickoff and Alignment".to_string(),
                title_vi: "Khởi động dự án và thống nhất mục tiêu".to_string(),
                lines: vec![
                    DialogueLine {
                        speaker: "Project Manager".to_string(),
                        text: "Good morning everyone. Let's review the primary milestones for our Q4 product launch.".to_string(),
                        translation_vi: "Chào buổi sáng mọi người. Chúng ta hãy cùng rà soát các cột mốc chính cho đợt ra mắt sản phẩm quý 4.".to_string(),
                        phonetic_or_romaji: "/ɡʊd ˈmɔːr.nɪŋ ˈev.ri.wʌn.../".to_string(),
                    },
                    DialogueLine {
                        speaker: "Enterprise Client".to_string(),
                        text: "Our main priority is ensuring cross-platform stability before the Black Friday campaign.".to_string(),
                        translation_vi: "Ưu tiên hàng đầu của chúng tôi là đảm bảo sự ổn định đa nền tảng trước chiến dịch Black Friday.".to_string(),
                        phonetic_or_romaji: "/ˈaʊ.ɚ meɪn praɪˈɔːr.ə.t̬i.../".to_string(),
                    },
                    DialogueLine {
                        speaker: "Project Manager".to_string(),
                        text: "Understood. We allocated dedicated QA resources to conduct rigorous automated regression tests.".to_string(),
                        translation_vi: "Tôi hiểu rõ. Chúng tôi đã phân bổ nguồn lực QA chuyên biệt để chạy kiểm thử hồi quy tự động nghiêm ngặt.".to_string(),
                        phonetic_or_romaji: "/ˌʌn.dɚˈstʊd. wiː ˈæl.ə.keɪ.t̬ɪd.../".to_string(),
                    },
                    DialogueLine {
                        speaker: "Enterprise Client".to_string(),
                        text: "Excellent. Let's schedule a bi-weekly sync to review performance analytics.".to_string(),
                        translation_vi: "Tuyệt vời. Hãy lên lịch họp hai tuần một lần để xem xét các chỉ số phân tích hiệu năng.".to_string(),
                        phonetic_or_romaji: "/ˈek.səl.ənt. lets ˈskedʒ.uːl.../".to_string(),
                    },
                ],
                vocabulary: vec![
                    DialogueBreakdown {
                        word: "milestone".to_string(),
                        meaning_vi: "Cột mốc quan trọng trong dự án".to_string(),
                        kana_or_phonetic: "/ˈmaɪl.stoʊn/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "priority".to_string(),
                        meaning_vi: "Mức độ ưu tiên hàng đầu".to_string(),
                        kana_or_phonetic: "/praɪˈɔːr.ə.t̬i/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "rigorous".to_string(),
                        meaning_vi: "Nghiêm ngặt, chặt chẽ".to_string(),
                        kana_or_phonetic: "/ˈrɪɡ.ɚ.əs/".to_string(),
                    },
                ],
                grammar_hints: vec![GrammarHint {
                    pattern: "Our main priority is + Verb-ing".to_string(),
                    explanation_vi: "Nhấn mạnh trọng tâm công việc kinh doanh cần ưu tiên".to_string(),
                    example: "Our main priority is ensuring cross-platform stability.".to_string(),
                }],
                suggested_writing_targets: vec!["timeline".to_string(), "milestone".to_string()],
            },
            ("en", "business", "intermediate") => DialogueResponse {
                topic: "contract_negotiation".to_string(),
                profession: "business".to_string(),
                difficulty_level: "intermediate".to_string(),
                title: "Enterprise Pricing & Service Level Agreement Negotiation".to_string(),
                title_vi: "Đàm phán định giá doanh nghiệp và cam kết chất lượng dịch vụ SLA".to_string(),
                lines: vec![
                    DialogueLine {
                        speaker: "Procurement Director".to_string(),
                        text: "We appreciate your tailored presentation, but your enterprise tier exceeds our projected budget.".to_string(),
                        translation_vi: "Chúng tôi đánh giá cao bài thuyết trình của bạn, nhưng gói doanh nghiệp này đang vượt ngân sách dự toán.".to_string(),
                        phonetic_or_romaji: "/wiː əˈpriː.ʃi.eɪt jʊr.../".to_string(),
                    },
                    DialogueLine {
                        speaker: "Sales Director".to_string(),
                        text: "If you commit to a 24-month term, we can waive all onboarding and data migration fees.".to_string(),
                        translation_vi: "Nếu quý công ty cam kết kỳ hạn 24 tháng, chúng tôi có thể miễn toàn bộ phí onboarding và migration dữ liệu.".to_string(),
                        phonetic_or_romaji: "/ɪf juː kəˈmɪt tuː eɪ.../".to_string(),
                    },
                    DialogueLine {
                        speaker: "Procurement Director".to_string(),
                        text: "That adjustment brings the proposal within our target threshold. How about the SLA warranty?".to_string(),
                        translation_vi: "Sự điều chỉnh đó đưa đề xuất về ngưỡng mong đợi của chúng tôi. Còn về bảo đảm SLA thì sao?".to_string(),
                        phonetic_or_romaji: "/ðæt əˈdʒʌst.mənt brɪŋz.../".to_string(),
                    },
                    DialogueLine {
                        speaker: "Sales Director".to_string(),
                        text: "We guarantee 99.95% uptime with financial penalties in case of any service degradation.".to_string(),
                        translation_vi: "Chúng tôi cam kết uptime 99.95% kèm điều khoản phạt tài chính nếu dịch vụ bị suy giảm chất lượng.".to_string(),
                        phonetic_or_romaji: "/wiː ˌɡer.ənˈtiː.../".to_string(),
                    },
                ],
                vocabulary: vec![
                    DialogueBreakdown {
                        word: "procurement".to_string(),
                        meaning_vi: "Bộ phận thu mua/mua sắm doanh nghiệp".to_string(),
                        kana_or_phonetic: "/prəˈkjʊr.mənt/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "onboarding".to_string(),
                        meaning_vi: "Quá trình triển khai và hướng dẫn ban đầu".to_string(),
                        kana_or_phonetic: "/ˈɑːnˌbɔːr.dɪŋ/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "degradation".to_string(),
                        meaning_vi: "Sự suy giảm chất lượng dịch vụ".to_string(),
                        kana_or_phonetic: "/ˌdeɡ.rəˈdeɪ.ʃən/".to_string(),
                    },
                ],
                grammar_hints: vec![GrammarHint {
                    pattern: "If you commit to ..., we can waive ...".to_string(),
                    explanation_vi: "Cấu trúc trao đổi quyền lợi trong đàm phán hợp đồng kinh tế".to_string(),
                    example: "If you commit to a 24-month term, we can waive fees.".to_string(),
                }],
                suggested_writing_targets: vec!["agreement".to_string(), "proposal".to_string()],
            },
            ("en", "business", "advanced") => DialogueResponse {
                topic: "strategic_merger".to_string(),
                profession: "business".to_string(),
                difficulty_level: "advanced".to_string(),
                title: "Executive Boardroom Strategic Alignment".to_string(),
                title_vi: "Thống nhất chiến lược cấp Hội đồng Quản trị".to_string(),
                lines: vec![
                    DialogueLine {
                        speaker: "Chairman of the Board".to_string(),
                        text: "Colleagues, we are evaluating a pivotal acquisition that expands our distribution footprint across emerging markets.".to_string(),
                        translation_vi: "Các đồng nghiệp thân mến, chúng ta đang đánh giá một thương vụ thâu tóm then chốt giúp mở rộng mạng lưới phân phối tại các thị trường mới nổi.".to_string(),
                        phonetic_or_romaji: "/ˈkɑː.liːɡz, wiː ɑːr.../".to_string(),
                    },
                    DialogueLine {
                        speaker: "Chief Financial Officer".to_string(),
                        text: "The valuation multiples indicate favorable EBITDA synergies, provided we streamline redundant operational overhead.".to_string(),
                        translation_vi: "Các hệ số định giá cho thấy sức cộng hưởng EBITDA rất thuận lợi, với điều kiện chúng ta phải tinh gọn chi phí vận hành trùng lặp.".to_string(),
                        phonetic_or_romaji: "/ðə ˌvæl.juˈeɪ.ʃən.../".to_string(),
                    },
                    DialogueLine {
                        speaker: "Chairman of the Board".to_string(),
                        text: "Our fiduciary duty demands rigorous risk mitigation regarding intellectual property and cross-border currency exposure.".to_string(),
                        translation_vi: "Trách nhiệm ủy thác đòi hỏi chúng ta phải kiểm soát rủi ro nghiêm ngặt đối với sở hữu trí tuệ và rủi ro tỷ giá tiền tệ xuyên biên giới.".to_string(),
                        phonetic_or_romaji: "/ˈaʊ.ɚ fɪˈduː.ʃiˌer.i.../".to_string(),
                    },
                    DialogueLine {
                        speaker: "Chief Financial Officer".to_string(),
                        text: "Agreed. Our audit committee has structured hedging mechanisms to safeguard balance sheet resilience.".to_string(),
                        translation_vi: "Nhất trí. Ủy ban kiểm toán của chúng ta đã thiết lập các cơ chế phòng hộ hedging để bảo vệ sức chống chịu của bảng cân đối kế toán.".to_string(),
                        phonetic_or_romaji: "/əˈɡriːd. ˈaʊ.ɚ ˈɑː.dɪt.../".to_string(),
                    },
                ],
                vocabulary: vec![
                    DialogueBreakdown {
                        word: "acquisition".to_string(),
                        meaning_vi: "Thương vụ mua lại doanh nghiệp".to_string(),
                        kana_or_phonetic: "/ˌæk.wəˈzɪʃ.ən/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "fiduciary".to_string(),
                        meaning_vi: "Trách nhiệm ủy thác, tín thác pháp lý".to_string(),
                        kana_or_phonetic: "/fɪˈduː.ʃiˌer.i/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "resilience".to_string(),
                        meaning_vi: "Khả năng chống chịu và phục hồi nhanh".to_string(),
                        kana_or_phonetic: "/rɪˈzɪl.jəns/".to_string(),
                    },
                ],
                grammar_hints: vec![GrammarHint {
                    pattern: "demands rigorous ... regarding ...".to_string(),
                    explanation_vi: "Khẳng định yêu cầu kiểm soát rủi ro nghiêm ngặt trong quản trị".to_string(),
                    example: "Our duty demands rigorous risk mitigation regarding currency exposure.".to_string(),
                }],
                suggested_writing_targets: vec!["compliance".to_string(), "merger".to_string()],
            },

            // ==================== ENGLISH GENERAL ====================
            ("en", "general", "beginner") => DialogueResponse {
                topic: "office_welcome".to_string(),
                profession: "general".to_string(),
                difficulty_level: "beginner".to_string(),
                title: "Welcoming a New Teammate".to_string(),
                title_vi: "Chào đón đồng nghiệp mới vào công ty".to_string(),
                lines: vec![
                    DialogueLine {
                        speaker: "Teammate Mark".to_string(),
                        text: "Hi Sarah! Welcome aboard. I'm Mark from the design team.".to_string(),
                        translation_vi: "Chào Sarah! Chào mừng bạn gia nhập công ty. Mình là Mark từ nhóm thiết kế.".to_string(),
                        phonetic_or_romaji: "/haɪ ˈser.ə! ˈwel.kəm əˈbɔːrd.../".to_string(),
                    },
                    DialogueLine {
                        speaker: "New Member Sarah".to_string(),
                        text: "Hi Mark, very nice to meet you. Everyone has been so welcoming.".to_string(),
                        translation_vi: "Chào Mark, rất vui được gặp bạn. Mọi người đều rất nồng nhiệt đón chào mình.".to_string(),
                        phonetic_or_romaji: "/haɪ mɑːrk, ˈver.i naɪs.../".to_string(),
                    },
                    DialogueLine {
                        speaker: "Teammate Mark".to_string(),
                        text: "We're grabbing lunch together at 12:30. Would you like to join us?".to_string(),
                        translation_vi: "Bọn mình sẽ cùng nhau đi ăn trưa lúc 12h30. Bạn có muốn đi cùng bọn mình không?".to_string(),
                        phonetic_or_romaji: "/wɪr ˈɡræb.ɪŋ lʌntʃ.../".to_string(),
                    },
                    DialogueLine {
                        speaker: "New Member Sarah".to_string(),
                        text: "I'd love to! Thank you so much for inviting me.".to_string(),
                        translation_vi: "Mình rất muốn! Cảm ơn bạn rất nhiều vì đã rủ mình nhé.".to_string(),
                        phonetic_or_romaji: "/aɪd lʌv tuː! θæŋk juː.../".to_string(),
                    },
                ],
                vocabulary: vec![
                    DialogueBreakdown {
                        word: "aboard".to_string(),
                        meaning_vi: "Gia nhập tổ chức/lên tàu".to_string(),
                        kana_or_phonetic: "/əˈbɔːrd/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "welcoming".to_string(),
                        meaning_vi: "Hiếu khách, nhiệt tình chào đón".to_string(),
                        kana_or_phonetic: "/ˈwel.kəm.ɪŋ/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "invitation".to_string(),
                        meaning_vi: "Lời mời tham gia".to_string(),
                        kana_or_phonetic: "/ˌɪn.vəˈteɪ.ʃən/".to_string(),
                    },
                ],
                grammar_hints: vec![GrammarHint {
                    pattern: "Would you like to + Verb?".to_string(),
                    explanation_vi: "Mẫu câu rủ rê, mời mọc lịch sự thân mật".to_string(),
                    example: "Would you like to join us for lunch?".to_string(),
                }],
                suggested_writing_targets: vec!["welcome".to_string(), "colleague".to_string()],
            },
            ("en", "general", "intermediate") => DialogueResponse {
                topic: "collaboration_sync".to_string(),
                profession: "general".to_string(),
                difficulty_level: "intermediate".to_string(),
                title: "Cross-Functional Collaboration Sync".to_string(),
                title_vi: "Đồng bộ phối hợp liên phòng ban".to_string(),
                lines: vec![
                    DialogueLine {
                        speaker: "Project Coordinator".to_string(),
                        text: "Let's quickly align on who owns the presentation slides for Thursday's workshop.".to_string(),
                        translation_vi: "Chúng ta hãy nhanh chóng thống nhất ai sẽ phụ trách slide thuyết trình cho buổi workshop thứ Năm nhé.".to_string(),
                        phonetic_or_romaji: "/lets ˈkwɪk.li əˈlaɪn.../".to_string(),
                    },
                    DialogueLine {
                        speaker: "Operations Lead".to_string(),
                        text: "I can draft the operational workflows if the analytics team provides the customer metrics.".to_string(),
                        translation_vi: "Tôi có thể soạn thảo các luồng vận hành nếu team phân tích dữ liệu cung cấp các chỉ số khách hàng.".to_string(),
                        phonetic_or_romaji: "/aɪ kæn dræft ðiː.../".to_string(),
                    },
                    DialogueLine {
                        speaker: "Project Coordinator".to_string(),
                        text: "Perfect division of responsibility. Let's aim to have the final draft ready by Wednesday noon.".to_string(),
                        translation_vi: "Phân chia trách nhiệm quá chuẩn. Hãy cùng đặt mục tiêu bản thảo cuối cùng sẵn sàng trước trưa thứ Tư.".to_string(),
                        phonetic_or_romaji: "/ˈpɝː.fekt dɪˈvɪʒ.ən.../".to_string(),
                    },
                    DialogueLine {
                        speaker: "Operations Lead".to_string(),
                        text: "Sounds like a solid plan. I'll ping you on Slack once my sections are completed.".to_string(),
                        translation_vi: "Kế hoạch rất chắc chắn. Tôi sẽ nhắn bạn trên Slack ngay khi phần của tôi hoàn tất.".to_string(),
                        phonetic_or_romaji: "/saʊndz laɪk eɪ ˈsɑː.lɪd.../".to_string(),
                    },
                ],
                vocabulary: vec![
                    DialogueBreakdown {
                        word: "workflow".to_string(),
                        meaning_vi: "Quy trình luồng công việc".to_string(),
                        kana_or_phonetic: "/ˈwɝːk.floʊ/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "responsibility".to_string(),
                        meaning_vi: "Trách nhiệm, phận sự được giao".to_string(),
                        kana_or_phonetic: "/rɪˌspɑːn.səˈbɪl.ə.t̬i/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "metrics".to_string(),
                        meaning_vi: "Các chỉ số đo lường định lượng".to_string(),
                        kana_or_phonetic: "/ˈmet.rɪks/".to_string(),
                    },
                ],
                grammar_hints: vec![GrammarHint {
                    pattern: "Let's aim to have ... ready by ...".to_string(),
                    explanation_vi: "Đặt mục tiêu thời hạn hoàn thành công việc chung".to_string(),
                    example: "Let's aim to have the final draft ready by Wednesday.".to_string(),
                }],
                suggested_writing_targets: vec!["schedule".to_string(), "workflow".to_string()],
            },
            ("en", "general", "advanced") => DialogueResponse {
                topic: "organizational_leadership".to_string(),
                profession: "general".to_string(),
                difficulty_level: "advanced".to_string(),
                title: "Fostering Culture of Continuous Innovation".to_string(),
                title_vi: "Xây dựng văn hóa đổi mới sáng tạo không ngừng".to_string(),
                lines: vec![
                    DialogueLine {
                        speaker: "Executive Vice President".to_string(),
                        text: "Sustaining long-term competitive advantage demands psychological safety where calculated risk-taking is embraced.".to_string(),
                        translation_vi: "Duy trì lợi thế cạnh tranh lâu dài đòi hỏi sự an toàn tâm lý nơi việc chấp nhận rủi ro có tính toán được đón nhận.".to_string(),
                        phonetic_or_romaji: "/səˈsteɪ.nɪŋ lɑːŋ.tɝːm.../".to_string(),
                    },
                    DialogueLine {
                        speaker: "Managing Director".to_string(),
                        text: "Our retrospective feedback indicates teams want autonomy in exploring new problem-solving methodologies.".to_string(),
                        translation_vi: "Phản hồi hồi cố cho thấy các đội ngũ muốn có quyền tự chủ trong việc thử nghiệm các phương pháp giải quyết vấn đề mới.".to_string(),
                        phonetic_or_romaji: "/ˈaʊ.ɚ ˌret.roʊˈspek.tɪv.../".to_string(),
                    },
                    DialogueLine {
                        speaker: "Executive Vice President".to_string(),
                        text: "Let's empower department leads to allocate ten percent of sprint capacity toward experimental initiatives.".to_string(),
                        translation_vi: "Hãy trao quyền cho các trưởng bộ phận phân bổ 10% năng lực sprint cho các sáng kiến thử nghiệm.".to_string(),
                        phonetic_or_romaji: "/lets ɪmˈpaʊ.ɚ.../".to_string(),
                    },
                    DialogueLine {
                        speaker: "Managing Director".to_string(),
                        text: "That will significantly boost morale and unlock high-impact cross-functional innovation.".to_string(),
                        translation_vi: "Điều đó sẽ thúc đẩy tinh thần làm việc đáng kể và khơi thông các đột phá sáng tạo liên phòng ban.".to_string(),
                        phonetic_or_romaji: "/ðæt wɪl sɪɡˈnɪf.ə.kənt.li.../".to_string(),
                    },
                ],
                vocabulary: vec![
                    DialogueBreakdown {
                        word: "autonomy".to_string(),
                        meaning_vi: "Quyền tự chủ, độc lập ra quyết định".to_string(),
                        kana_or_phonetic: "/ɑːˈtɑː.nə.mi/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "empower".to_string(),
                        meaning_vi: "Trao quyền, tiếp thêm năng lực".to_string(),
                        kana_or_phonetic: "/ɪmˈpaʊ.ɚ/".to_string(),
                    },
                    DialogueBreakdown {
                        word: "innovation".to_string(),
                        meaning_vi: "Sự đổi mới, sáng tạo bứt phá".to_string(),
                        kana_or_phonetic: "/ˌɪn.əˈveɪ.ʃən/".to_string(),
                    },
                ],
                grammar_hints: vec![GrammarHint {
                    pattern: "demands ... where ... is embraced".to_string(),
                    explanation_vi: "Mẫu câu lập luận lãnh đạo khẳng định điều kiện phát triển".to_string(),
                    example: "It demands psychological safety where risk-taking is embraced.".to_string(),
                }],
                suggested_writing_targets: vec!["transformation".to_string(), "innovation".to_string()],
            },

            // Fallback Catch-all
            _ => self.get_curated_dialogue_fallback(&DialogueRequest {
                target_language: "ja".to_string(),
                profession: "it".to_string(),
                difficulty_level: "beginner".to_string(),
                topic: req.topic.clone(),
                turn_count: req.turn_count,
            }),
        }
    }
}

pub fn clean_json_str(raw: &str) -> &str {
    let trimmed = raw.trim();

    // Try finding code fence first
    if let Some(start_fence) = trimmed.find("```") {
        let remainder = &trimmed[start_fence + 3..];
        let fence_body = if let Some(first_brace) = remainder.find('{') {
            &remainder[first_brace..]
        } else {
            remainder
        };
        if let Some(end_fence) = fence_body.rfind("```") {
            let inside = fence_body[..end_fence].trim();
            if let (Some(first_brace), Some(last_brace)) = (inside.find('{'), inside.rfind('}')) {
                if first_brace <= last_brace {
                    return &inside[first_brace..=last_brace];
                }
            }
            return inside;
        }
    }

    // Fall back to finding the outermost JSON object braces
    if let (Some(first_brace), Some(last_brace)) = (trimmed.find('{'), trimmed.rfind('}')) {
        if first_brace <= last_brace {
            return &trimmed[first_brace..=last_brace];
        }
    }

    trimmed
}

fn normalize_language(lang: &str) -> &'static str {
    let lower = lang.trim().to_lowercase();
    if lower.starts_with("ja") {
        "ja"
    } else {
        "en"
    }
}

fn normalize_profession(prof: &str) -> &'static str {
    let lower = prof.trim().to_lowercase();
    if lower.contains("hosp") || lower.contains("hotel") || lower.contains("rest") {
        "hospitality"
    } else if lower.contains("biz")
        || lower.contains("bus")
        || lower.contains("sale")
        || lower.contains("mark")
    {
        "business"
    } else if lower.contains("gen") || lower.contains("daily") {
        "general"
    } else {
        "it"
    }
}

fn normalize_level(level: &str) -> &'static str {
    let lower = level.trim().to_lowercase();
    if lower.contains("adv") || lower.contains("c1") || lower.contains("n1") {
        "advanced"
    } else if lower.contains("inter")
        || lower.contains("b1")
        || lower.contains("b2")
        || lower.contains("n2")
        || lower.contains("n3")
    {
        "intermediate"
    } else {
        "beginner"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ai_config_defaults() {
        let config = AIConfig::default();
        assert_eq!(config.endpoint, "http://127.0.0.1:11434/api/generate");
        assert_eq!(config.provider, AIProvider::OllamaNative);
        assert_eq!(config.model, "qwen2.5:3b");
        assert_eq!(config.timeout_secs, 8);
        assert_eq!(config.connect_timeout_secs, 2);
        assert!(config.fallback_enabled);
    }

    #[test]
    fn test_clean_json_str_variations() {
        // Plain JSON
        let plain = r#"{"reply": "Hello World"}"#;
        assert_eq!(clean_json_str(plain), plain);

        // Markdown code fence with language tag
        let with_fence = "```json\n{\"reply\": \"Hello\"}\n```";
        assert_eq!(clean_json_str(with_fence), "{\"reply\": \"Hello\"}");

        // Markdown code fence without language tag
        let no_tag = "```\n{\"reply\": \"Hello\"}\n```";
        assert_eq!(clean_json_str(no_tag), "{\"reply\": \"Hello\"}");

        // Text before and after
        let surrounded =
            "Here is the response:\n```json\n{\"reply\": \"Hello\"}\n```\nHope this helps!";
        assert_eq!(clean_json_str(surrounded), "{\"reply\": \"Hello\"}");

        // Raw braces embedded in chat commentary
        let raw_commentary = "Sure! Here is your JSON: {\"reply\": \"Embedded\"} Thanks!";
        assert_eq!(clean_json_str(raw_commentary), "{\"reply\": \"Embedded\"}");
    }

    #[test]
    fn test_roleplay_fallback_matrix_coverage() {
        let service = AIService::new();
        let languages = ["ja", "en"];
        let professions = ["it", "hospitality", "business", "general"];
        let levels = ["beginner", "intermediate", "advanced"];

        for lang in &languages {
            for prof in &professions {
                for level in &levels {
                    let req = RoleplayRequest {
                        target_language: lang.to_string(),
                        profession: prof.to_string(),
                        user_level: level.to_string(),
                        topic: "test_topic".to_string(),
                        user_message: "test message".to_string(),
                    };

                    let res = service.get_curated_roleplay_fallback(&req);
                    assert!(
                        !res.reply.is_empty(),
                        "Empty reply for {}, {}, {}",
                        lang,
                        prof,
                        level
                    );
                    assert!(
                        !res.reply_translation_vi.is_empty(),
                        "Empty translation for {}, {}, {}",
                        lang,
                        prof,
                        level
                    );
                    assert!(
                        res.breakdown.len() >= 2,
                        "Breakdown too short for {}, {}, {}",
                        lang,
                        prof,
                        level
                    );
                    assert!(
                        !res.writing_challenge.is_empty(),
                        "Empty writing challenge for {}, {}, {}",
                        lang,
                        prof,
                        level
                    );
                    assert!(
                        res.grammar_hints.as_ref().map_or(0, |h| h.len()) >= 1,
                        "Missing grammar hints for {}, {}, {}",
                        lang,
                        prof,
                        level
                    );
                    assert!(
                        res.suggested_replies.as_ref().map_or(0, |r| r.len()) >= 2,
                        "Missing suggested replies for {}, {}, {}",
                        lang,
                        prof,
                        level
                    );
                }
            }
        }
    }

    #[test]
    fn test_dialogue_fallback_matrix_coverage() {
        let service = AIService::new();
        let languages = ["ja", "en"];
        let professions = ["it", "hospitality", "business", "general"];
        let levels = ["beginner", "intermediate", "advanced"];

        for lang in &languages {
            for prof in &professions {
                for level in &levels {
                    let req = DialogueRequest {
                        target_language: lang.to_string(),
                        profession: prof.to_string(),
                        difficulty_level: level.to_string(),
                        topic: Some("test_topic".to_string()),
                        turn_count: Some(4),
                    };

                    let res = service.get_curated_dialogue_fallback(&req);
                    assert_eq!(res.profession, *prof);
                    assert_eq!(res.difficulty_level, *level);
                    assert!(!res.title.is_empty());
                    assert!(!res.title_vi.is_empty());
                    assert!(
                        res.lines.len() >= 4,
                        "Expected at least 4 dialogue lines for {}, {}, {}",
                        lang,
                        prof,
                        level
                    );
                    for line in &res.lines {
                        assert!(!line.speaker.is_empty());
                        assert!(!line.text.is_empty());
                        assert!(!line.translation_vi.is_empty());
                        assert!(!line.phonetic_or_romaji.is_empty());
                    }
                    assert!(res.vocabulary.len() >= 2);
                    assert!(!res.grammar_hints.is_empty());
                    assert!(!res.suggested_writing_targets.is_empty());
                }
            }
        }
    }

    #[tokio::test]
    async fn test_unreachable_endpoint_graceful_fallback() {
        // Point to unreachable localhost port with 1s timeout
        let config = AIConfig {
            endpoint: "http://127.0.0.1:54321/v1/chat/completions".to_string(),
            provider: AIProvider::OpenAICompatible,
            model: "test_model".to_string(),
            timeout_secs: 1,
            connect_timeout_secs: 1,
            fallback_enabled: true,
        };
        let service = AIService::with_config(config);

        let roleplay_req = RoleplayRequest {
            target_language: "ja".to_string(),
            profession: "hospitality".to_string(),
            user_level: "beginner".to_string(),
            topic: "hotel_checkin".to_string(),
            user_message: "チェックインをお願いします。".to_string(),
        };

        let roleplay_res = service.generate_roleplay(&roleplay_req).await.unwrap();
        assert!(!roleplay_res.reply.is_empty());
        assert_eq!(roleplay_res.writing_challenge, "予約");

        let dialogue_req = DialogueRequest {
            target_language: "en".to_string(),
            profession: "business".to_string(),
            difficulty_level: "intermediate".to_string(),
            topic: Some("negotiation".to_string()),
            turn_count: Some(4),
        };

        let dialogue_res = service.generate_dialogue(&dialogue_req).await.unwrap();
        assert_eq!(dialogue_res.profession, "business");
        assert_eq!(dialogue_res.difficulty_level, "intermediate");
        assert!(dialogue_res.lines.len() >= 4);
    }

    #[tokio::test]
    async fn test_unreachable_endpoint_with_fallback_disabled_returns_error() {
        let config = AIConfig {
            endpoint: "http://127.0.0.1:54321/v1/chat/completions".to_string(),
            provider: AIProvider::OpenAICompatible,
            model: "test_model".to_string(),
            timeout_secs: 1,
            connect_timeout_secs: 1,
            fallback_enabled: false,
        };
        let service = AIService::with_config(config);

        let roleplay_req = RoleplayRequest {
            target_language: "ja".to_string(),
            profession: "hospitality".to_string(),
            user_level: "beginner".to_string(),
            topic: "hotel_checkin".to_string(),
            user_message: "".to_string(),
        };

        let result = service.generate_roleplay(&roleplay_req).await;
        assert!(result.is_err());
        let err_msg = result.unwrap_err().to_string();
        assert!(err_msg.contains("fallback is disabled"));

        let dialogue_req = DialogueRequest {
            target_language: "ja".to_string(),
            profession: "it".to_string(),
            difficulty_level: "beginner".to_string(),
            topic: Some("hotel_checkin".to_string()),
            turn_count: Some(4),
        };

        let diag_result = service.generate_dialogue(&dialogue_req).await;
        assert!(diag_result.is_err());
        assert!(diag_result
            .unwrap_err()
            .to_string()
            .contains("fallback is disabled"));
    }

    #[test]
    fn test_ai_config_env_parsing() {
        std::env::set_var("OLLAMA_BASE_URL", "http://localhost:11434");
        std::env::set_var("AI_TIMEOUT_SECS", "15");
        std::env::set_var("AI_MODEL", "llama-3.2-3b");

        let config = AIConfig::from_env();
        assert_eq!(
            config.endpoint,
            "http://localhost:11434/v1/chat/completions"
        );
        assert_eq!(config.provider, AIProvider::OpenAICompatible);
        assert_eq!(config.model, "llama-3.2-3b");
        assert_eq!(config.timeout_secs, 15);

        std::env::remove_var("OLLAMA_BASE_URL");
        std::env::remove_var("AI_TIMEOUT_SECS");
        std::env::remove_var("AI_MODEL");
    }
}
