package com.talknex.app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.media.MediaRecorder
import android.os.Build
import android.net.Uri
import android.provider.MediaStore
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.ChannelMixingAudioProcessor
import androidx.media3.common.audio.ChannelMixingMatrix
import androidx.media3.common.audio.SonicAudioProcessor
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BitmapOverlay
import androidx.media3.effect.OverlayEffect
import androidx.media3.effect.Presentation
import androidx.media3.effect.RgbMatrix
import androidx.media3.effect.TextureOverlay
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import com.google.common.collect.ImmutableList
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream
import kotlin.math.roundToInt

@OptIn(UnstableApi::class)
class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.safechat.app/video"
    private val VOICE_CHANNEL = "com.safechat.app/voice"

    private var mediaRecorder: MediaRecorder? = null
    private var currentVoiceFile: File? = null
    private var voiceStartTime = 0L
    private var isRecordingVoice = false

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
                    val audioTrackStartMs = call.argument<Number>("audioTrackStartMs")?.toLong() ?: 0L
                    val audioTrackEndMs = call.argument<Number>("audioTrackEndMs")?.toLong() ?: 0L
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
                                audioTrackStartMs = audioTrackStartMs,
                                audioTrackEndMs = audioTrackEndMs,
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
                } else if (call.method == "applyOverlayToVideo") {
                    val videoPath = call.argument<String>("videoPath")
                    val overlayPath = call.argument<String>("overlayPath")
                    val colorMatrix = call.argument<List<Double>>("colorMatrix")

                    if (videoPath == null) {
                        result.error("INVALID_ARGS", "videoPath cannot be null", null)
                        return@setMethodCallHandler
                    }

                    CoroutineScope(Dispatchers.Main + Job()).launch {
                        try {
                            val outputPath = applyOverlayToVideoNative(
                                context = applicationContext,
                                videoPath = videoPath,
                                overlayPath = overlayPath,
                                colorMatrix = colorMatrix
                            )
                            result.success(outputPath)
                        } catch (t: Throwable) {
                            android.util.Log.e("MainActivity", "Video overlay failed", t)
                            result.error("OVERLAY_ERROR", t.message ?: "Video overlay failed", null)
                        }
                    }
                } else {
                    result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VOICE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startRecording" -> {
                        try {
                            if (isRecordingVoice) {
                                try {
                                    mediaRecorder?.stop()
                                    mediaRecorder?.release()
                                } catch (_: Exception) {}
                                mediaRecorder = null
                                isRecordingVoice = false
                            }

                            val cacheDir = applicationContext.cacheDir
                            val voiceDir = File(cacheDir, "voice_notes").apply { mkdirs() }
                            val outputFile = File(voiceDir, "voice_${System.currentTimeMillis()}.m4a")
                            currentVoiceFile = outputFile

                            val recorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                                MediaRecorder(applicationContext)
                            } else {
                                @Suppress("DEPRECATION")
                                MediaRecorder()
                            }

                            recorder.setAudioSource(MediaRecorder.AudioSource.MIC)
                            recorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                            recorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                            recorder.setAudioEncodingBitRate(128000)
                            recorder.setAudioSamplingRate(44100)
                            recorder.setOutputFile(outputFile.absolutePath)
                            recorder.prepare()
                            recorder.start()

                            mediaRecorder = recorder
                            voiceStartTime = System.currentTimeMillis()
                            isRecordingVoice = true

                            result.success(outputFile.absolutePath)
                        } catch (e: Exception) {
                            android.util.Log.e("MainActivity", "startRecording error", e)
                            mediaRecorder = null
                            isRecordingVoice = false
                            result.error("RECORD_START_ERROR", e.message ?: "Kayıt başlatılamadı", null)
                        }
                    }
                    "stopRecording" -> {
                        try {
                            if (!isRecordingVoice || mediaRecorder == null || currentVoiceFile == null) {
                                result.success(null)
                                return@setMethodCallHandler
                            }

                            val durationMs = System.currentTimeMillis() - voiceStartTime
                            try {
                                mediaRecorder?.stop()
                            } catch (stopErr: Exception) {
                                android.util.Log.w("MainActivity", "MediaRecorder stop failed (short audio)", stopErr)
                            } finally {
                                mediaRecorder?.release()
                                mediaRecorder = null
                                isRecordingVoice = false
                            }

                            val file = currentVoiceFile
                            if (file != null && file.exists() && file.length() > 0) {
                                val resMap = mapOf(
                                    "filePath" to file.absolutePath,
                                    "durationMs" to durationMs
                                )
                                result.success(resMap)
                            } else {
                                result.success(null)
                            }
                        } catch (e: Exception) {
                            android.util.Log.e("MainActivity", "stopRecording error", e)
                            mediaRecorder?.release()
                            mediaRecorder = null
                            isRecordingVoice = false
                            result.error("RECORD_STOP_ERROR", e.message ?: "Kayıt durdurulamadı", null)
                        }
                    }
                    "cancelRecording" -> {
                        try {
                            if (isRecordingVoice && mediaRecorder != null) {
                                try {
                                    mediaRecorder?.stop()
                                } catch (_: Exception) {}
                                mediaRecorder?.release()
                                mediaRecorder = null
                                isRecordingVoice = false
                            }
                            currentVoiceFile?.let {
                                if (it.exists()) it.delete()
                            }
                            currentVoiceFile = null
                            result.success(true)
                        } catch (e: Exception) {
                            mediaRecorder = null
                            isRecordingVoice = false
                            result.success(false)
                        }
                    }
                    "getAmplitude" -> {
                        try {
                            val amp = if (isRecordingVoice && mediaRecorder != null) {
                                mediaRecorder?.maxAmplitude ?: 0
                            } else {
                                0
                            }
                            result.success(amp)
                        } catch (e: Exception) {
                            result.success(0)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.safechat.app/gallery")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getGalleryMedia" -> {
                        CoroutineScope(Dispatchers.IO).launch {
                            try {
                                val limit = call.argument<Int>("limit") ?: 400
                                val mediaList = mutableListOf<Map<String, Any?>>()

                                val projection = arrayOf(
                                    MediaStore.Files.FileColumns._ID,
                                    MediaStore.Files.FileColumns.DATA,
                                    MediaStore.Files.FileColumns.MEDIA_TYPE,
                                    MediaStore.Files.FileColumns.DATE_ADDED,
                                    MediaStore.Video.VideoColumns.DURATION
                                )

                                val selection = "${MediaStore.Files.FileColumns.MEDIA_TYPE} = ? OR ${MediaStore.Files.FileColumns.MEDIA_TYPE} = ?"
                                val selectionArgs = arrayOf(
                                    MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE.toString(),
                                    MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO.toString()
                                )
                                val sortOrder = "${MediaStore.Files.FileColumns.DATE_ADDED} DESC"

                                val queryUri = MediaStore.Files.getContentUri("external")
                                val cursor = applicationContext.contentResolver.query(
                                    queryUri,
                                    projection,
                                    selection,
                                    selectionArgs,
                                    sortOrder
                                )

                                val thumbDir = File(applicationContext.cacheDir, "video_thumbs").apply {
                                    if (!exists()) mkdirs()
                                }

                                cursor?.use { c ->
                                    val dataCol = c.getColumnIndex(MediaStore.Files.FileColumns.DATA)
                                    val typeCol = c.getColumnIndex(MediaStore.Files.FileColumns.MEDIA_TYPE)
                                    val durCol = c.getColumnIndex(MediaStore.Video.VideoColumns.DURATION)

                                    var count = 0
                                    var videoThumbCount = 0
                                    while (c.moveToNext() && count < limit) {
                                        val path = if (dataCol != -1) c.getString(dataCol) else null
                                        if (path != null) {
                                            val f = File(path)
                                            if (f.exists() && f.length() > 0) {
                                                val mediaType = if (typeCol != -1) c.getInt(typeCol) else 1
                                                val isVideo = mediaType == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO
                                                val durationMs = if (isVideo && durCol != -1) c.getLong(durCol) else 0L
                                                val parentFolder = f.parentFile?.name ?: "Diğer"

                                                var thumbnailPath: String? = null
                                                if (isVideo) {
                                                    val safeName = "thumb_" + (path.hashCode().toLong() and 0xFFFFFFFFL).toString(16) + ".jpg"
                                                    val thumbFile = File(thumbDir, safeName)
                                                    if (thumbFile.exists() && thumbFile.length() > 0) {
                                                        thumbnailPath = thumbFile.absolutePath
                                                    } else if (videoThumbCount < 25) {
                                                        thumbnailPath = getVideoThumbnail(path, applicationContext)
                                                        if (thumbnailPath != null) {
                                                            videoThumbCount++
                                                        }
                                                    }
                                                }

                                                mediaList.add(mapOf(
                                                    "path" to path,
                                                    "isVideo" to isVideo,
                                                    "durationMs" to durationMs,
                                                    "bucketName" to parentFolder,
                                                    "thumbnailPath" to thumbnailPath
                                                ))
                                                count++
                                            }
                                        }
                                    }
                                }

                                withContext(Dispatchers.Main) {
                                    result.success(mediaList)
                                }
                            } catch (e: Exception) {
                                android.util.Log.e("MainActivity", "getGalleryMedia error", e)
                                withContext(Dispatchers.Main) {
                                    result.success(emptyList<Map<String, Any?>>())
                                }
                            }
                        }
                    }
                    "getVideoThumbnail" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.success(null)
                            return@setMethodCallHandler
                        }
                        CoroutineScope(Dispatchers.IO).launch {
                            val thumb = getVideoThumbnail(path, applicationContext)
                            withContext(Dispatchers.Main) {
                                result.success(thumb)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun getVideoThumbnail(videoPath: String, context: Context): String? {
        return try {
            val thumbDir = File(context.cacheDir, "video_thumbs")
            if (!thumbDir.exists()) thumbDir.mkdirs()
            val safeName = "thumb_" + (videoPath.hashCode().toLong() and 0xFFFFFFFFL).toString(16) + ".jpg"
            val thumbFile = File(thumbDir, safeName)
            if (thumbFile.exists() && thumbFile.length() > 0) {
                return thumbFile.absolutePath
            }

            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(videoPath)
                val rawBitmap = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                    retriever.getScaledFrameAtTime(
                        1000000L,
                        MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                        360,
                        360
                    ) ?: retriever.frameAtTime
                } else {
                    retriever.frameAtTime
                }

                if (rawBitmap != null) {
                    val finalBitmap = if (rawBitmap.width > 360 || rawBitmap.height > 360) {
                        val maxDim = Math.max(rawBitmap.width, rawBitmap.height)
                        val scale = 360f / maxDim
                        val targetW = Math.max(1, (rawBitmap.width * scale).toInt())
                        val targetH = Math.max(1, (rawBitmap.height * scale).toInt())
                        val scaled = Bitmap.createScaledBitmap(rawBitmap, targetW, targetH, true)
                        if (scaled != rawBitmap) rawBitmap.recycle()
                        scaled
                    } else {
                        rawBitmap
                    }

                    FileOutputStream(thumbFile).use { out ->
                        finalBitmap.compress(Bitmap.CompressFormat.JPEG, 80, out)
                    }
                    finalBitmap.recycle()
                    return thumbFile.absolutePath
                }
            } finally {
                try {
                    retriever.release()
                } catch (_: Exception) {}
            }
            null
        } catch (e: Exception) {
            android.util.Log.w("MainActivity", "getVideoThumbnail error for $videoPath", e)
            null
        }
    }

    private suspend fun applyOverlayToVideoNative(
        context: Context,
        videoPath: String,
        overlayPath: String?,
        colorMatrix: List<Double>?
    ): String = withContext(Dispatchers.Main) {
        val videoFile = File(videoPath)
        if (!videoFile.exists()) {
            throw IllegalArgumentException("Video dosyası bulunamadı.")
        }

        val (origW, origH) = getVideoDimensions(videoPath)
        val isPortrait = origH >= origW
        val targetWidth = if (isPortrait) 720 else 1280
        val targetHeight = if (isPortrait) 1280 else 720

        val outputFile = File(context.cacheDir, "edited_video_${System.currentTimeMillis()}.mp4").apply {
            parentFile?.mkdirs()
            if (exists()) delete()
        }

        val mediaItem = MediaItem.Builder().setUri(Uri.fromFile(videoFile)).build()
        val presentation = Presentation.createForWidthAndHeight(
            targetWidth,
            targetHeight,
            Presentation.LAYOUT_SCALE_TO_FIT
        )

        val videoEffects = mutableListOf<androidx.media3.common.Effect>(presentation)

        if (colorMatrix != null && colorMatrix.size == 16) {
            val matrixFloats = FloatArray(16) { i -> colorMatrix[i].toFloat() }
            val rgbMatrixEffect = RgbMatrix { _, _ -> matrixFloats }
            videoEffects.add(rgbMatrixEffect)
        }

        if (overlayPath != null) {
            val overlayFile = File(overlayPath)
            if (overlayFile.exists()) {
                val bitmap = BitmapFactory.decodeFile(overlayFile.absolutePath)
                if (bitmap != null) {
                    val bitmapOverlay: TextureOverlay = BitmapOverlay.createStaticBitmapOverlay(bitmap)
                    val overlayEffect = OverlayEffect(ImmutableList.of<TextureOverlay>(bitmapOverlay))
                    videoEffects.add(overlayEffect)
                }
            }
        }

        val retriever = MediaMetadataRetriever()
        val hasAudio = try {
            retriever.setDataSource(videoPath)
            val audioPresent = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO)
            audioPresent != null && audioPresent.equals("yes", ignoreCase = true)
        } catch (_: Throwable) {
            true
        } finally {
            try { retriever.release() } catch (_: Throwable) {}
        }

        val audioProcessors = if (hasAudio) {
            listOf(SonicAudioProcessor().apply { setOutputSampleRateHz(48000) })
        } else {
            emptyList()
        }

        val editedItem = EditedMediaItem.Builder(mediaItem)
            .setEffects(Effects(audioProcessors, videoEffects))
            .apply {
                if (!hasAudio) {
                    setRemoveAudio(true)
                }
            }
            .build()

        val sequence = if (hasAudio) {
            EditedMediaItemSequence.withAudioAndVideoFrom(listOf(editedItem))
        } else {
            EditedMediaItemSequence.withVideoFrom(listOf(editedItem))
        }

        val composition = Composition.Builder(listOf(sequence))
            .setTransmuxVideo(false)
            .setTransmuxAudio(false)
            .build()

        runTransformerExport(context, composition, outputFile)
        return@withContext outputFile.absolutePath
    }

    private suspend fun processVideosNative(
        context: Context,
        videoPaths: List<String>,
        videoVolume: Double,
        audioTrackPath: String?,
        audioTrackVolume: Double,
        audioTrackStartMs: Long,
        audioTrackEndMs: Long,
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

            val comp = buildComposition(sequence, audioTrackPath, audioTrackVolume, audioTrackStartMs, audioTrackEndMs)
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

            val comp = buildComposition(sequence, audioTrackPath, audioTrackVolume, audioTrackStartMs, audioTrackEndMs)
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

            val finalComp = buildComposition(seq, audioTrackPath, audioTrackVolume, audioTrackStartMs, audioTrackEndMs)
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
        audioTrackVolume: Double,
        audioTrackStartMs: Long,
        audioTrackEndMs: Long
    ): Composition {
        val sequences = mutableListOf<EditedMediaItemSequence>()
        sequences.add(videoSequence)

        if (!audioTrackPath.isNullOrBlank()) {
            val bgSeq = buildBackgroundAudioSequence(audioTrackPath, audioTrackVolume, audioTrackStartMs, audioTrackEndMs)
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
        audioVolume: Double,
        audioStartMs: Long,
        audioEndMs: Long
    ): EditedMediaItemSequence? {
        val file = File(audioPath)
        if (!file.exists()) return null
        return try {
            val mediaItemBuilder = MediaItem.Builder().setUri(Uri.fromFile(file))
            val clipBuilder = MediaItem.ClippingConfiguration.Builder()
            var hasClipping = false
            if (audioStartMs > 50L) {
                clipBuilder.setStartPositionMs(audioStartMs)
                hasClipping = true
            }
            if (audioEndMs > audioStartMs && audioEndMs > 100L) {
                clipBuilder.setEndPositionMs(audioEndMs)
                hasClipping = true
            }
            if (hasClipping) {
                mediaItemBuilder.setClippingConfiguration(clipBuilder.build())
            }
            val mediaItem = mediaItemBuilder.build()
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
            val safeVol = volume.coerceIn(0f, 1f)
            for (ch in 1..8) {
                try {
                    val matrix = ChannelMixingMatrix.createForConstantGain(ch, ch).scaleBy(safeVol)
                    processor.putChannelMixingMatrix(matrix)
                } catch (_: Throwable) {}
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

    override fun onDestroy() {
        try {
            if (isRecordingVoice) {
                mediaRecorder?.stop()
                mediaRecorder?.release()
                mediaRecorder = null
            }
        } catch (_: Exception) {}
        super.onDestroy()
    }
}
