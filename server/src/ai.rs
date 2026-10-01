use crate::models::{DialogueBreakdown, RoleplayRequest, RoleplayResponse};
use serde::{Deserialize, Serialize};
use std::time::Duration;

#[derive(Debug, Serialize)]
struct OllamaChatRequest<'a> {
    model: &'a str,
    prompt: &'a str,
    stream: bool,
}

#[derive(Debug, Deserialize)]
struct OllamaChatResponse {
    response: String,
}

pub struct AIService {
    client: reqwest::Client,
    ollama_url: String,
    model_name: String,
}

impl Default for AIService {
    fn default() -> Self {
        Self::new()
    }
}

impl AIService {
    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(5))
            .build()
            .unwrap_or_default();

        let ollama_url = std::env::var("AI_ENDPOINT")
            .unwrap_or_else(|_| "http://127.0.0.1:11434/api/generate".to_string());
        let model_name = std::env::var("AI_MODEL").unwrap_or_else(|_| "qwen2.5:3b".to_string());

        Self {
            client,
            ollama_url,
            model_name,
        }
    }

    pub async fn generate_roleplay(&self, req: &RoleplayRequest) -> RoleplayResponse {
        // Attempt to call local LLM if available
        if let Ok(resp) = self.try_call_local_llm(req).await {
            return resp;
        }

        // Contextual fallback simulation based on workplace topic and language
        self.contextual_mock_engine(req)
    }

    async fn try_call_local_llm(
        &self,
        req: &RoleplayRequest,
    ) -> Result<RoleplayResponse, Box<dyn std::error::Error + Send + Sync>> {
        let prompt = format!(
            "You are a helpful IT workplace colleague speaking in {}. User says: '{}'. Give a concise workplace response, vietnamese translation, 2 keywords, and 1 short sentence for handwriting practice.",
            req.target_language, req.user_message
        );

        let body = OllamaChatRequest {
            model: &self.model_name,
            prompt: &prompt,
            stream: false,
        };

        let res = self
            .client
            .post(&self.ollama_url)
            .json(&body)
            .send()
            .await?
            .json::<OllamaChatResponse>()
            .await?;

        Ok(RoleplayResponse {
            reply: res.response.clone(),
            reply_translation_vi: "Đã phản hồi từ mô hình AI Local.".to_string(),
            breakdown: vec![DialogueBreakdown {
                word: "AI Generated".to_string(),
                meaning_vi: "Tạo tự động từ Local AI".to_string(),
                kana_or_phonetic: "".to_string(),
            }],
            writing_challenge: "Review code".to_string(),
        })
    }

    fn contextual_mock_engine(&self, req: &RoleplayRequest) -> RoleplayResponse {
        match req.target_language.as_str() {
            "ja" => {
                RoleplayResponse {
                    reply: "お疲れ様です！進捗はどうですか？何かバグや問題があればいつでも相談してください。".to_string(),
                    reply_translation_vi: "Chào bạn, vất vả rồi! Tiến độ thế nào rồi? Nếu có bug hay vấn đề gì hãy cứ trao đổi bất cứ lúc nào nhé.".to_string(),
                    breakdown: vec![
                        DialogueBreakdown {
                            word: "お疲れ様です".to_string(),
                            meaning_vi: "Chào anh/chị, vất vả rồi (lời chào quen thuộc chốn công sở)".to_string(),
                            kana_or_phonetic: "おつかれさまです (Otsukaresama desu)".to_string(),
                        },
                        DialogueBreakdown {
                            word: "進捗".to_string(),
                            meaning_vi: "Tiến độ công việc".to_string(),
                            kana_or_phonetic: "しんちょく (Shinchoku)".to_string(),
                        },
                        DialogueBreakdown {
                            word: "相談".to_string(),
                            meaning_vi: "Trao đổi, thảo luận để xin ý kiến".to_string(),
                            kana_or_phonetic: "そうだん (Soudan)".to_string(),
                        },
                    ],
                    writing_challenge: "進捗".to_string(),
                }
            }
            _ => {
                RoleplayResponse {
                    reply: "Good morning! Did you push the latest commit to Git? We should test the build before our daily standup.".to_string(),
                    reply_translation_vi: "Chào buổi sáng! Bạn đã đẩy commit mới nhất lên Git chưa? Chúng ta nên kiểm tra bản build trước buổi họp daily standup.".to_string(),
                    breakdown: vec![
                        DialogueBreakdown {
                            word: "commit".to_string(),
                            meaning_vi: "lưu lại thay đổi mã nguồn trong Git".to_string(),
                            kana_or_phonetic: "/kəˈmɪt/".to_string(),
                        },
                        DialogueBreakdown {
                            word: "standup".to_string(),
                            meaning_vi: "cuộc họp nhanh đầu ngày của team Agile/Scrum".to_string(),
                            kana_or_phonetic: "/ˈstænd.ʌp/".to_string(),
                        },
                    ],
                    writing_challenge: "commit".to_string(),
                }
            }
        }
    }
}
