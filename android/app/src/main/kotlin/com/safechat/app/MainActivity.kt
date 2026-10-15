package com.safechat.app

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.Presentation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import kotlin.math.roundToInt

@OptIn(UnstableApi::class)
class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.safechat.app/video"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "mergeAndProcessVideos") {
                    val videoPaths = call.argument<List<String>>("videoPaths") ?: emptyList()
                    val isMuted = call.argument<Boolean>("isMuted") ?: false
                    val trimStarts = call.argument<Map<String, Number>>("trimStarts") ?: emptyMap()
                    val trimEnds = call.argument<Map<String, Number>>("trimEnds") ?: emptyMap()
                    val totalDurations = call.argument<Map<String, Number>>("totalDurations") ?: emptyMap()

                    if (videoPaths.isEmpty()) {
                        result.error("INVALID_ARGS", "Video paths cannot be empty", null)
                        return@setMethodCallHandler
                    }

                    CoroutineScope(Dispatchers.Main + Job()).launch {
                        try {
                            val outputPath = processVideosNative(
                                context = applicationContext,
                                videoPaths = videoPaths,
                                isMuted = isMuted,
                                trimStarts = trimStarts,
                                trimEnds = trimEnds,
                                totalDurations = totalDurations
                            )
                            result.success(outputPath)
                        } catch (t: Throwable) {
                            android.util.Log.e("MainActivity", "Video processing failed", t)
                            result.error("VIDEO_PROCESS_ERROR", t.message ?: "Video birleştirilemedi", null)
                        }
                    }
                } else {
                    result.notImplemented()
                }
            }
    }

    private suspend fun processVideosNative(
        context: Context,
        videoPaths: List<String>,
        isMuted: Boolean,
        trimStarts: Map<String, Number>,
        trimEnds: Map<String, Number>,
        totalDurations: Map<String, Number>
    ): String = withContext(Dispatchers.Main) {
        val validPaths = videoPaths.filter { File(it).exists() }
        if (validPaths.isEmpty()) {
            throw IllegalArgumentException("Belirtilen video dosyaları bulunamadı.")
        }

        // Calculate safe dimensions (Max 1280 to prevent any OOM or encoder failure on Android)
        var maxW = 0
        var maxH = 0
        for (path in validPaths) {
            val (w, h) = getVideoDimensions(path)
            if (w > maxW) maxW = w
            if (h > maxH) maxH = h
        }

        if (maxW <= 0) maxW = 720
        if (maxH <= 0) maxH = 1280

        val maxAllowed = 1280
        if (maxW > maxAllowed || maxH > maxAllowed) {
            val scale = maxAllowed.toFloat() / maxOf(maxW, maxH).toFloat()
            maxW = (maxW * scale).roundToInt()
            maxH = (maxH * scale).roundToInt()
        }
        if (maxW % 2 != 0) maxW += 1
        if (maxH % 2 != 0) maxH += 1

        val allHaveAudio = validPaths.all { checkHasAudio(it) }
        val shouldRemoveAudio = isMuted || !allHaveAudio

        val outputFile = File(
            context.cacheDir,
            "merged_${System.currentTimeMillis()}.mp4"
        ).apply {
            parentFile?.mkdirs()
            if (exists()) delete()
        }

        val editedItems = validPaths.map { path ->
            val startMs = trimStarts[path]?.toLong() ?: 0L
            val endMs = trimEnds[path]?.toLong() ?: 0L
            val totalMs = totalDurations[path]?.toLong() ?: 0L

            val mediaItemBuilder = MediaItem.Builder().setUri(Uri.fromFile(File(path)))

            val isStartTrimmed = startMs > 250L
            val isEndTrimmed = endMs > 0L && totalMs > 0L && (totalMs - endMs) > 300L

            if (isStartTrimmed || isEndTrimmed) {
                val clipBuilder = MediaItem.ClippingConfiguration.Builder()
                if (isStartTrimmed) {
                    clipBuilder.setStartPositionMs(startMs)
                }
                if (isEndTrimmed) {
                    clipBuilder.setEndPositionMs(endMs)
                }
                mediaItemBuilder.setClippingConfiguration(clipBuilder.build())
            }

            val presentation = Presentation.createForWidthAndHeight(
                maxW,
                maxH,
                Presentation.LAYOUT_SCALE_TO_FIT
            )

            val editedBuilder = EditedMediaItem.Builder(mediaItemBuilder.build())
                .setEffects(Effects(emptyList(), listOf(presentation)))

            if (shouldRemoveAudio) {
                editedBuilder.setRemoveAudio(true)
            }
            editedBuilder.build()
        }

        val sequence = EditedMediaItemSequence(editedItems)
        val composition = Composition.Builder(listOf(sequence))
            .setTransmuxVideo(false)
            .setTransmuxAudio(false)
            .build()

        kotlinx.coroutines.suspendCancellableCoroutine { continuation ->
            try {
                val encoderFactory = DefaultEncoderFactory.Builder(context)
                    .setEnableFallback(true)
                    .build()

                val transformer = Transformer.Builder(context)
                    .setEncoderFactory(encoderFactory)
                    .setVideoMimeType(MimeTypes.VIDEO_H264)
                    .setAudioMimeType(MimeTypes.AUDIO_AAC)
                    .addListener(object : Transformer.Listener {
                        override fun onCompleted(comp: Composition, exportResult: ExportResult) {
                            if (continuation.isActive) {
                                continuation.resumeWith(Result.success(outputFile.absolutePath))
                            }
                        }

                        override fun onError(
                            comp: Composition,
                            exportResult: ExportResult,
                            exportException: ExportException
                        ) {
                            android.util.Log.e("MainActivity", "Transformer error: ${exportException.message}", exportException)
                            outputFile.delete()
                            if (continuation.isActive) {
                                continuation.resumeWith(Result.failure(exportException))
                            }
                        }
                    })
                    .build()

                continuation.invokeOnCancellation {
                    try { transformer.cancel() } catch (_: Throwable) {}
                    try { outputFile.delete() } catch (_: Throwable) {}
                }

                transformer.start(composition, outputFile.absolutePath)
            } catch (e: Throwable) {
                android.util.Log.e("MainActivity", "Transformer startup exception", e)
                if (continuation.isActive) {
                    continuation.resumeWith(Result.failure(e))
                }
            }
        }
    }

    private fun checkHasAudio(videoPath: String): Boolean {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(videoPath)
            val hasAudio = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO)
            hasAudio == "yes"
        } catch (_: Throwable) {
            true
        } finally {
            try { retriever.release() } catch (_: Throwable) {}
        }
    }

    private fun getVideoDimensions(videoPath: String): Pair<Int, Int> {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(videoPath)
            val w = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 720
            val h = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 1280
            val rot = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
            if (rot == 90 || rot == 270) Pair(h, w) else Pair(w, h)
        } catch (_: Throwable) {
            Pair(720, 1280)
        } finally {
            try { retriever.release() } catch (_: Throwable) {}
        }
    }
}
