package com.safechat.app

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.Presentation
import androidx.media3.exoplayer.audio.SonicAudioProcessor
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

        // Determine orientation from first clip (Standard 720p aligned to 16-pixel macroblocks)
        val (firstW, firstH) = getVideoDimensions(validPaths[0])
        val isPortrait = firstH >= firstW
        val targetWidth = if (isPortrait) 720 else 1280
        val targetHeight = if (isPortrait) 1280 else 720

        // If only 1 video was selected, simply transcode/trim that single video
        if (validPaths.size == 1) {
            val outputFile = File(context.cacheDir, "processed_${System.currentTimeMillis()}.mp4").apply {
                parentFile?.mkdirs()
                if (exists()) delete()
            }
            val path = validPaths[0]
            val startMs = trimStarts[path]?.toLong() ?: 0L
            val endMs = trimEnds[path]?.toLong() ?: 0L
            val totalMs = totalDurations[path]?.toLong() ?: 0L

            val item = buildSingleEditedItem(
                path = path,
                startMs = startMs,
                endMs = endMs,
                totalMs = totalMs,
                targetWidth = targetWidth,
                targetHeight = targetHeight,
                isMuted = isMuted,
                resampleAudio = false
            )

            val comp = Composition.Builder(EditedMediaItemSequence(item)).build()
            runTransformerExport(context, comp, outputFile)
            return@withContext outputFile.absolutePath
        }

        // --- MULTIPLE VIDEOS MERGE ---
        val finalOutputFile = File(context.cacheDir, "merged_${System.currentTimeMillis()}.mp4").apply {
            parentFile?.mkdirs()
            if (exists()) delete()
        }

        // Attempt 1: Direct sequence with Sonic audio resampling & safe 720p presentation
        try {
            val editedItems = validPaths.map { path ->
                val startMs = trimStarts[path]?.toLong() ?: 0L
                val endMs = trimEnds[path]?.toLong() ?: 0L
                val totalMs = totalDurations[path]?.toLong() ?: 0L
                buildSingleEditedItem(
                    path = path,
                    startMs = startMs,
                    endMs = endMs,
                    totalMs = totalMs,
                    targetWidth = targetWidth,
                    targetHeight = targetHeight,
                    isMuted = isMuted,
                    resampleAudio = true
                )
            }

            val sequence = EditedMediaItemSequence(editedItems)

            val comp = Composition.Builder(listOf(sequence))
                .setTransmuxVideo(false)
                .setTransmuxAudio(false)
                .build()

            runTransformerExport(context, comp, finalOutputFile)
            return@withContext finalOutputFile.absolutePath
        } catch (attempt1Err: Throwable) {
            android.util.Log.w("MainActivity", "Direct sequence merge failed, running multi-pass fallback: ${attempt1Err.message}", attempt1Err)
            if (finalOutputFile.exists()) finalOutputFile.delete()
        }

        // Attempt 2: Multi-pass (transcode each clip individually to normalized MP4, then concatenate)
        val tempFiles = mutableListOf<File>()
        try {
            for (i in validPaths.indices) {
                val path = validPaths[i]
                val startMs = trimStarts[path]?.toLong() ?: 0L
                val endMs = trimEnds[path]?.toLong() ?: 0L
                val totalMs = totalDurations[path]?.toLong() ?: 0L

                val partFile = File(context.cacheDir, "part_${i}_${System.currentTimeMillis()}.mp4").apply {
                    parentFile?.mkdirs()
                    if (exists()) delete()
                }
                tempFiles.add(partFile)

                val item = buildSingleEditedItem(
                    path = path,
                    startMs = startMs,
                    endMs = endMs,
                    totalMs = totalMs,
                    targetWidth = targetWidth,
                    targetHeight = targetHeight,
                    isMuted = isMuted,
                    resampleAudio = true
                )

                val comp = Composition.Builder(EditedMediaItemSequence(item)).build()
                runTransformerExport(context, comp, partFile)
            }

            // Now concatenate normalized parts (they share identical dimensions, codec, sample rate)
            val partItems = tempFiles.map { file ->
                val mediaItem = MediaItem.Builder().setUri(Uri.fromFile(file)).build()
                EditedMediaItem.Builder(mediaItem).build()
            }

            val seq = EditedMediaItemSequence(partItems)

            val finalComp = Composition.Builder(listOf(seq))
                .setTransmuxVideo(false)
                .setTransmuxAudio(false)
                .build()

            runTransformerExport(context, finalComp, finalOutputFile)
            return@withContext finalOutputFile.absolutePath
        } finally {
            for (f in tempFiles) {
                try { if (f.exists()) f.delete() } catch (_: Throwable) {}
            }
        }
    }

    private fun buildSingleEditedItem(
        path: String,
        startMs: Long,
        endMs: Long,
        totalMs: Long,
        targetWidth: Int,
        targetHeight: Int,
        isMuted: Boolean,
        resampleAudio: Boolean
    ): EditedMediaItem {
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
            targetWidth,
            targetHeight,
            Presentation.LAYOUT_SCALE_TO_FIT
        )

        val audioProcessors = mutableListOf<AudioProcessor>()
        if (resampleAudio && !isMuted) {
            try {
                val sonic = SonicAudioProcessor().apply {
                    setOutputSampleRateHz(48000)
                }
                audioProcessors.add(sonic)
            } catch (t: Throwable) {
                android.util.Log.w("MainActivity", "SonicAudioProcessor setup warning", t)
            }
        }

        val editedBuilder = EditedMediaItem.Builder(mediaItemBuilder.build())
            .setEffects(Effects(audioProcessors, listOf(presentation)))

        if (isMuted) {
            editedBuilder.setRemoveAudio(true)
        }

        return editedBuilder.build()
    }

    private suspend fun runTransformerExport(
        context: Context,
        composition: Composition,
        outputFile: File
    ) = kotlinx.coroutines.suspendCancellableCoroutine { continuation ->
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
                            continuation.resumeWith(Result.success(Unit))
                        }
                    }

                    override fun onError(
                        comp: Composition,
                        exportResult: ExportResult,
                        exportException: ExportException
                    ) {
                        android.util.Log.e("MainActivity", "Transformer export error: ${exportException.message}", exportException)
                        if (outputFile.exists()) outputFile.delete()
                        if (continuation.isActive) {
                            continuation.resumeWith(Result.failure(exportException))
                        }
                    }
                })
                .build()

            continuation.invokeOnCancellation {
                try { transformer.cancel() } catch (_: Throwable) {}
                try { if (outputFile.exists()) outputFile.delete() } catch (_: Throwable) {}
            }

            transformer.start(composition, outputFile.absolutePath)
        } catch (e: Throwable) {
            android.util.Log.e("MainActivity", "Transformer startup exception", e)
            if (outputFile.exists()) outputFile.delete()
            if (continuation.isActive) {
                continuation.resumeWith(Result.failure(e))
            }
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
