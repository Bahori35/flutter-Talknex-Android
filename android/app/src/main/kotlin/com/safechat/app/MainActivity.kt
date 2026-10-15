package com.safechat.app

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.ChannelMixingAudioProcessor
import androidx.media3.common.audio.ChannelMixingMatrix
import androidx.media3.common.audio.SonicAudioProcessor
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
                    val videoVolume = call.argument<Number>("videoVolume")?.toDouble() ?: (if (isMuted) 0.0 else 1.0)
                    val audioTrackPath = call.argument<String>("audioTrackPath")
                    val audioTrackVolume = call.argument<Number>("audioTrackVolume")?.toDouble() ?: 1.0
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
                                videoVolume = videoVolume,
                                audioTrackPath = audioTrackPath,
                                audioTrackVolume = audioTrackVolume,
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
        videoVolume: Double,
        audioTrackPath: String?,
        audioTrackVolume: Double,
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
        val isMuted = videoVolume <= 0.01

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
                videoVolume = videoVolume,
                resampleAudio = true
            )

            val sequence = if (isMuted) {
                EditedMediaItemSequence.withVideoFrom(listOf(item))
            } else {
                EditedMediaItemSequence.withAudioAndVideoFrom(listOf(item))
            }

            val comp = buildComposition(sequence, audioTrackPath, audioTrackVolume)
            runTransformerExport(context, comp, outputFile)
            return@withContext outputFile.absolutePath
        }

        // --- MULTIPLE VIDEOS MERGE ---
        val finalOutputFile = File(context.cacheDir, "merged_${System.currentTimeMillis()}.mp4").apply {
            parentFile?.mkdirs()
            if (exists()) delete()
        }

        // Attempt 1: Direct sequence with Sonic audio resampling, volume scaling, background music & safe 720p
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
                    videoVolume = videoVolume,
                    resampleAudio = true
                )
            }

            val sequence = if (isMuted) {
                EditedMediaItemSequence.withVideoFrom(editedItems)
            } else {
                EditedMediaItemSequence.withAudioAndVideoFrom(editedItems)
            }

            val comp = buildComposition(sequence, audioTrackPath, audioTrackVolume)
            runTransformerExport(context, comp, finalOutputFile)
            return@withContext finalOutputFile.absolutePath
        } catch (attempt1Err: Throwable) {
            android.util.Log.w("MainActivity", "Direct sequence merge failed, running multi-pass fallback: ${attempt1Err.message}", attempt1Err)
            if (finalOutputFile.exists()) finalOutputFile.delete()
        }

        // Attempt 2: Multi-pass (transcode each clip individually to normalized MP4, then concatenate & mix audio)
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
                    videoVolume = videoVolume,
                    resampleAudio = true
                )

                val sequence = if (isMuted) {
                    EditedMediaItemSequence.withVideoFrom(listOf(item))
                } else {
                    EditedMediaItemSequence.withAudioAndVideoFrom(listOf(item))
                }
                val comp = Composition.Builder(listOf(sequence)).build()
                runTransformerExport(context, comp, partFile)
            }

            // Now concatenate normalized parts (they share identical dimensions, codec, sample rate)
            val partItems = tempFiles.map { file ->
                val mediaItem = MediaItem.Builder().setUri(Uri.fromFile(file)).build()
                EditedMediaItem.Builder(mediaItem).build()
            }

            val seq = if (isMuted) {
                EditedMediaItemSequence.withVideoFrom(partItems)
            } else {
                EditedMediaItemSequence.withAudioAndVideoFrom(partItems)
            }

            val finalComp = buildComposition(seq, audioTrackPath, audioTrackVolume)
            runTransformerExport(context, finalComp, finalOutputFile)
            return@withContext finalOutputFile.absolutePath
        } finally {
            for (f in tempFiles) {
                try { if (f.exists()) f.delete() } catch (_: Throwable) {}
            }
        }
    }

    private fun buildComposition(
        videoSequence: EditedMediaItemSequence,
        audioTrackPath: String?,
        audioTrackVolume: Double
    ): Composition {
        val sequences = mutableListOf<EditedMediaItemSequence>()
        sequences.add(videoSequence)

        if (!audioTrackPath.isNullOrBlank()) {
            val bgSeq = buildBackgroundAudioSequence(audioTrackPath, audioTrackVolume)
            if (bgSeq != null) {
                sequences.add(bgSeq)
            }
        }

        return Composition.Builder(sequences)
            .setTransmuxVideo(false)
            .setTransmuxAudio(false)
            .build()
    }

    private fun buildBackgroundAudioSequence(
        audioPath: String,
        audioVolume: Double
    ): EditedMediaItemSequence? {
        val file = File(audioPath)
        if (!file.exists()) return null
        return try {
            val mediaItem = MediaItem.Builder().setUri(Uri.fromFile(file)).build()
            val processors = mutableListOf<AudioProcessor>()
            processors.add(SonicAudioProcessor().apply { setOutputSampleRateHz(48000) })
            if (audioVolume in 0.02..0.98) {
                createVolumeProcessor(audioVolume.toFloat())?.let { processors.add(it) }
            }
            val editedItem = EditedMediaItem.Builder(mediaItem)
                .setEffects(Effects(processors, emptyList()))
                .build()

            EditedMediaItemSequence.Builder(setOf(C.TRACK_TYPE_AUDIO))
                .addItem(editedItem)
                .setIsLooping(true)
                .build()
        } catch (t: Throwable) {
            android.util.Log.w("MainActivity", "Failed to build background audio sequence", t)
            null
        }
    }

    private fun buildSingleEditedItem(
        path: String,
        startMs: Long,
        endMs: Long,
        totalMs: Long,
        targetWidth: Int,
        targetHeight: Int,
        videoVolume: Double,
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
        val isMuted = videoVolume <= 0.01

        if (resampleAudio && !isMuted) {
            try {
                audioProcessors.add(SonicAudioProcessor().apply {
                    setOutputSampleRateHz(48000)
                })
            } catch (t: Throwable) {
                android.util.Log.w("MainActivity", "SonicAudioProcessor setup warning", t)
            }

            if (videoVolume in 0.02..0.98) {
                createVolumeProcessor(videoVolume.toFloat())?.let { audioProcessors.add(it) }
            }
        }

        val editedBuilder = EditedMediaItem.Builder(mediaItemBuilder.build())
            .setEffects(Effects(audioProcessors, listOf(presentation)))

        if (isMuted) {
            editedBuilder.setRemoveAudio(true)
        }

        return editedBuilder.build()
    }

    private fun createVolumeProcessor(volume: Float): AudioProcessor? {
        return try {
            val processor = ChannelMixingAudioProcessor()
            for (ch in 1..2) {
                val matrix = ChannelMixingMatrix.createForConstantGain(ch, ch).scaleBy(volume)
                processor.putChannelMixingMatrix(matrix)
            }
            processor
        } catch (t: Throwable) {
            android.util.Log.w("MainActivity", "createVolumeProcessor failed", t)
            null
        }
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
