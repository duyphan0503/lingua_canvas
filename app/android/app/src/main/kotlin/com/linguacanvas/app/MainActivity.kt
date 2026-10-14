package com.linguacanvas.app

import android.content.Intent
import android.media.AudioAttributes
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.os.Bundle
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.google.mlkit.common.model.DownloadConditions
import com.google.mlkit.common.model.RemoteModelManager
import com.google.mlkit.vision.digitalink.recognition.DigitalInkRecognition
import com.google.mlkit.vision.digitalink.recognition.DigitalInkRecognitionModel
import com.google.mlkit.vision.digitalink.recognition.DigitalInkRecognitionModelIdentifier
import com.google.mlkit.vision.digitalink.recognition.DigitalInkRecognizerOptions
import com.google.mlkit.vision.digitalink.recognition.Ink
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

class MainActivity : FlutterActivity() {
    private val DIGITAL_INK_CHANNEL = "com.linguacanvas.app/digital_ink_native"
    private val TTS_CHANNEL = "com.linguacanvas.app/tts_native"

    private val recognizers = ConcurrentHashMap<String, com.google.mlkit.vision.digitalink.recognition.DigitalInkRecognizer>()

    private var tts: TextToSpeech? = null
    private var ttsInitStatus: Int? = null
    private var ttsInitGeneration = 0
    private var selectedTtsEngine: String? = null
    private var activeUtteranceId: String? = null
    private val ttsHandler = Handler(Looper.getMainLooper())
    private val pendingTtsCalls = mutableListOf<Pair<MethodChannel.Result, (TextToSpeech) -> Unit>>()
    private val ttsInitTimeout = Runnable { finishTtsInitialization(TextToSpeech.ERROR) }
    private var ttsMethodChannel: MethodChannel? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Initialize Android TextToSpeech engine
        initTextToSpeech()

        // 1. Native Digital Ink Channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DIGITAL_INK_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isModelDownloaded" -> {
                    val tag = call.argument<String>("model") ?: "ja"
                    val modelIdentifier = try {
                        DigitalInkRecognitionModelIdentifier.fromLanguageTag(tag)
                    } catch (e: Exception) {
                        null
                    }
                    if (modelIdentifier == null) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    val model = DigitalInkRecognitionModel.builder(modelIdentifier).build()
                    RemoteModelManager.getInstance().isModelDownloaded(model)
                        .addOnSuccessListener { isDownloaded ->
                            result.success(isDownloaded)
                        }
                        .addOnFailureListener { e ->
                            result.error("CHECK_FAILED", e.localizedMessage, null)
                        }
                }
                "downloadModel" -> {
                    val tag = call.argument<String>("model") ?: "ja"
                    val modelIdentifier = try {
                        DigitalInkRecognitionModelIdentifier.fromLanguageTag(tag)
                    } catch (e: Exception) {
                        null
                    }
                    if (modelIdentifier == null) {
                        result.error("INVALID_TAG", "Unknown language tag: $tag", null)
                        return@setMethodCallHandler
                    }
                    val model = DigitalInkRecognitionModel.builder(modelIdentifier).build()
                    val conditions = DownloadConditions.Builder().build()
                    RemoteModelManager.getInstance().download(model, conditions)
                        .addOnSuccessListener {
                            result.success(true)
                        }
                        .addOnFailureListener { e ->
                            result.error("DOWNLOAD_FAILED", e.localizedMessage, null)
                        }
                }
                "deleteModel" -> {
                    val tag = call.argument<String>("model") ?: "ja"
                    val modelIdentifier = try {
                        DigitalInkRecognitionModelIdentifier.fromLanguageTag(tag)
                    } catch (e: Exception) {
                        null
                    }
                    if (modelIdentifier == null) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    val model = DigitalInkRecognitionModel.builder(modelIdentifier).build()
                    RemoteModelManager.getInstance().deleteDownloadedModel(model)
                        .addOnSuccessListener {
                            result.success(true)
                        }
                        .addOnFailureListener { e ->
                            result.error("DELETE_FAILED", e.localizedMessage, null)
                        }
                }
                "recognizeInk" -> {
                    val tag = call.argument<String>("model") ?: "ja"
                    val strokesList = call.argument<List<Map<String, Any>>>("strokes") ?: emptyList()
                    val modelIdentifier = try {
                        DigitalInkRecognitionModelIdentifier.fromLanguageTag(tag)
                    } catch (e: Exception) {
                        null
                    }
                    if (modelIdentifier == null) {
                        result.error("INVALID_TAG", "Unknown language tag: $tag", null)
                        return@setMethodCallHandler
                    }
                    val model = DigitalInkRecognitionModel.builder(modelIdentifier).build()
                    val recognizer = recognizers.getOrPut(tag) {
                        DigitalInkRecognition.getClient(DigitalInkRecognizerOptions.builder(model).build())
                    }

                    val inkBuilder = Ink.builder()
                    for (strokeMap in strokesList) {
                        val strokeBuilder = Ink.Stroke.builder()
                        val pointsList = (strokeMap["points"] as? List<*>) ?: emptyList<Any>()
                        for (pointObj in pointsList) {
                            val point = pointObj as? Map<*, *> ?: continue
                            val x = ((point["x"] as? Number)?.toDouble() ?: 0.0).toFloat()
                            val y = ((point["y"] as? Number)?.toDouble() ?: 0.0).toFloat()
                            val t = ((point["t"] as? Number)?.toLong() ?: 0L)
                            strokeBuilder.addPoint(Ink.Point.create(x, y, t))
                        }
                        inkBuilder.addStroke(strokeBuilder.build())
                    }
                    val ink = inkBuilder.build()

                    recognizer.recognize(ink)
                        .addOnSuccessListener { recognitionResult ->
                            val candidateList = recognitionResult.candidates.map { candidate ->
                                mapOf(
                                    "text" to candidate.text,
                                    "score" to (candidate.score?.toDouble() ?: 0.0)
                                )
                            }
                            result.success(candidateList)
                        }
                        .addOnFailureListener { e ->
                            result.error("RECOGNIZE_FAILED", e.localizedMessage, null)
                        }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        // 2. Native TTS Channel
        ttsMethodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, TTS_CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "isLanguageAvailable" -> {
                        val locale = getLocaleFromTag(call.argument<String>("language") ?: "ja-JP")
                        withTtsReady(result) { engine ->
                            result.success(engine.isLanguageAvailable(locale) >= TextToSpeech.LANG_AVAILABLE)
                        }
                    }
                    "speak" -> {
                        val text = call.argument<String>("text")?.trim().orEmpty()
                        val lang = call.argument<String>("language") ?: "ja-JP"
                        val rate = (call.argument<Number>("rate")?.toDouble() ?: 0.9).toFloat()
                        val pitch = (call.argument<Number>("pitch")?.toDouble() ?: 1.0).toFloat()
                        val volume = (call.argument<Number>("volume")?.toDouble() ?: 1.0).toFloat()
                        if (text.isEmpty()) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        withTtsReady(result) { engine ->
                            val languageStatus = engine.setLanguage(getLocaleFromTag(lang))
                            Log.i("LinguaTTS", "engine=$selectedTtsEngine language=$lang status=$languageStatus")
                            if (languageStatus < TextToSpeech.LANG_AVAILABLE) {
                                result.error("TTS_LANGUAGE_UNAVAILABLE", "Install a TTS voice for $lang", null)
                            } else {
                                engine.setSpeechRate(rate)
                                engine.setPitch(pitch)
                                val utteranceId = UUID.randomUUID().toString()
                                activeUtteranceId = utteranceId
                                val params = Bundle()
                                params.putFloat(TextToSpeech.Engine.KEY_PARAM_VOLUME, volume.coerceIn(0f, 1f))
                                val speakResult = engine.speak(text, TextToSpeech.QUEUE_FLUSH, params, utteranceId)
                                result.success(speakResult == TextToSpeech.SUCCESS)
                            }
                        }
                    }
                    "stop" -> {
                        activeUtteranceId = null
                        tts?.stop()
                        pendingTtsCalls.forEach { (pendingResult, _) -> pendingResult.success(false) }
                        pendingTtsCalls.clear()
                        result.success(true)
                    }
                    "openSettings" -> {
                        try {
                            startActivity(Intent("com.android.settings.TTS_SETTINGS"))
                            result.success(true)
                        } catch (_: Exception) {
                            result.success(false)
                        }
                    }
                    else -> {
                        result.notImplemented()
                    }
                }
            }
        }
    }

    private fun withTtsReady(result: MethodChannel.Result, action: (TextToSpeech) -> Unit) {
        val engine = tts
        if (ttsInitStatus == TextToSpeech.SUCCESS && engine != null) {
            action(engine)
            return
        }
        pendingTtsCalls.add(result to action)
        if (ttsInitStatus != null || engine == null) initTextToSpeech()
    }

    private fun finishTtsInitialization(status: Int) {
        if (ttsInitStatus != null) return
        ttsHandler.removeCallbacks(ttsInitTimeout)
        ttsInitStatus = status
        val engine = tts
        val calls = pendingTtsCalls.toList()
        pendingTtsCalls.clear()
        if (status == TextToSpeech.SUCCESS && engine != null) {
            engine.setAudioAttributes(AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
            engine.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                private fun emit(method: String, utteranceId: String?) {
                    runOnUiThread {
                        if (utteranceId == activeUtteranceId) {
                            if (method != "onSpeakStart") activeUtteranceId = null
                            Log.i("LinguaTTS", "$method utterance=$utteranceId")
                            ttsMethodChannel?.invokeMethod(method, utteranceId)
                        }
                    }
                }
                override fun onStart(utteranceId: String?) = emit("onSpeakStart", utteranceId)
                override fun onDone(utteranceId: String?) = emit("onSpeakDone", utteranceId)
                override fun onError(utteranceId: String?) = emit("onSpeakError", utteranceId)
                override fun onStop(utteranceId: String?, interrupted: Boolean) = emit("onSpeakDone", utteranceId)
            })
            calls.forEach { (_, action) -> action(engine) }
        } else {
            Log.e("LinguaTTS", "TTS initialization failed: engine=$selectedTtsEngine status=$status")
            engine?.shutdown()
            tts = null
            calls.forEach { (result, _) ->
                result.error("TTS_NOT_READY", "Choose an installed TTS engine in Android settings", null)
            }
        }
    }

    private fun initTextToSpeech() {
        tts?.shutdown()
        ttsInitStatus = null
        val generation = ++ttsInitGeneration
        // Android's automatic fallback can ignore non-system engines when no
        // default is configured (e.g. Xiaomi ROMs). Explicitly choose an installed engine.
        val engines = packageManager.queryIntentServices(Intent(TextToSpeech.Engine.INTENT_ACTION_TTS_SERVICE), 0)
            .sortedByDescending { it.priority }.map { it.serviceInfo.packageName }.distinct()
        val configured = Settings.Secure.getString(contentResolver, Settings.Secure.TTS_DEFAULT_SYNTH)
        selectedTtsEngine = when {
            configured in engines -> configured
            "com.google.android.tts" in engines -> "com.google.android.tts"
            else -> engines.firstOrNull()
        }
        ttsHandler.removeCallbacks(ttsInitTimeout)
        ttsHandler.postDelayed(ttsInitTimeout, 8000)
        tts = TextToSpeech(applicationContext, { status ->
            // Post so the constructor's assignment to tts has completed first.
            ttsHandler.post { if (generation == ttsInitGeneration) finishTtsInitialization(status) }
        }, selectedTtsEngine)
    }

    private fun getLocaleFromTag(tag: String): Locale {
        val lower = tag.trim().lowercase().replace('_', '-')
        return when {
            lower.startsWith("ja") -> Locale.JAPANESE
            lower.startsWith("en") -> Locale.US
            lower.startsWith("vi") -> Locale("vi", "VN")
            else -> Locale.forLanguageTag(tag)
        }
    }

    override fun onResume() {
        super.onResume()
        // Reload the selected engine and voices after returning from Android
        // settings or installing a speech engine. Keep the first initialization.
        if (ttsInitStatus != null) initTextToSpeech()
    }

    override fun onDestroy() {
        for (recognizer in recognizers.values) {
            recognizer.close()
        }
        recognizers.clear()
        ++ttsInitGeneration
        ttsHandler.removeCallbacks(ttsInitTimeout)
        pendingTtsCalls.forEach { (result, _) -> result.error("TTS_CLOSED", "Activity closed", null) }
        pendingTtsCalls.clear()
        ttsMethodChannel?.setMethodCallHandler(null)
        activeUtteranceId = null
        tts?.stop()
        tts?.shutdown()
        tts = null
        super.onDestroy()
    }
}
