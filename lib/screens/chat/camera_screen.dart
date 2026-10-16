import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:video_player/video_player.dart';
import '../../constants/app_colors.dart';

enum CameraMode { photo, video }

class CameraCaptureResult {
  final File file;
  final bool isVideo;
  final String caption;

  CameraCaptureResult({
    required this.file,
    required this.isVideo,
    required this.caption,
  });
}

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  List<CameraDescription> _cameras = [];
  CameraController? _controller;
  int _selectedCameraIndex = 0;
  bool _isInitialized = false;
  bool _hasPermissionError = false;

  // Modes & states
  CameraMode _currentMode = CameraMode.photo;
  bool _isRecording = false;
  int _recordSeconds = 0;
  Timer? _recordTimer;

  // Flash
  FlashMode _flashMode = FlashMode.auto;

  // Captured media preview state
  File? _capturedFile;
  bool _capturedIsVideo = false;
  VideoPlayerController? _videoPreviewController;
  final TextEditingController _captionController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCameraSystem();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _recordTimer?.cancel();
    _controller?.dispose();
    _videoPreviewController?.dispose();
    _captionController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final CameraController? cameraController = _controller;
    if (cameraController == null || !cameraController.value.isInitialized) {
      return;
    }

    if (state == AppLifecycleState.inactive) {
      cameraController.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initCameraController(cameraController.description);
    }
  }

  Future<void> _initCameraSystem() async {
    // 1. Request permissions
    await Permission.camera.request();
    await Permission.microphone.request();

    final isCameraGranted = await Permission.camera.isGranted;
    if (!isCameraGranted) {
      if (mounted) {
        setState(() {
          _hasPermissionError = true;
        });
      }
      return;
    }

    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        if (mounted) setState(() => _hasPermissionError = true);
        return;
      }

      // Default to rear camera if available
      int initialIndex = _cameras.indexWhere((c) => c.lensDirection == CameraLensDirection.back);
      if (initialIndex == -1) initialIndex = 0;
      _selectedCameraIndex = initialIndex;

      await _initCameraController(_cameras[_selectedCameraIndex]);
    } catch (e) {
      debugPrint('[CAMERA INIT ERR] $e');
      if (mounted) setState(() => _hasPermissionError = true);
    }
  }

  Future<void> _initCameraController(CameraDescription description) async {
    final prevController = _controller;
    await prevController?.dispose();

    final controller = CameraController(
      description,
      ResolutionPreset.high,
      enableAudio: true,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    try {
      await controller.initialize();
      await controller.setFlashMode(_flashMode);
      if (mounted) {
        setState(() {
          _controller = controller;
          _isInitialized = true;
        });
      }
    } catch (e) {
      debugPrint('[CONTROLLER INIT ERR] $e');
      if (mounted) setState(() => _hasPermissionError = true);
    }
  }

  Future<void> _toggleCamera() async {
    if (_cameras.length < 2 || _isRecording) return;
    HapticFeedback.lightImpact();

    _selectedCameraIndex = (_selectedCameraIndex + 1) % _cameras.length;
    setState(() => _isInitialized = false);
    await _initCameraController(_cameras[_selectedCameraIndex]);
  }

  Future<void> _toggleFlash() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    HapticFeedback.selectionClick();

    FlashMode nextMode;
    switch (_flashMode) {
      case FlashMode.auto:
        nextMode = FlashMode.always;
        break;
      case FlashMode.always:
        nextMode = FlashMode.off;
        break;
      default:
        nextMode = FlashMode.auto;
    }

    try {
      await _controller!.setFlashMode(nextMode);
      setState(() => _flashMode = nextMode);
    } catch (e) {
      debugPrint('[FLASH ERR] $e');
    }
  }

  // --- CAPTURE PHOTO ---
  Future<void> _takePhoto() async {
    if (_controller == null || !_controller!.value.isInitialized || _isRecording) return;
    HapticFeedback.mediumImpact();

    try {
      final XFile photo = await _controller!.takePicture();
      if (!mounted) return;

      setState(() {
        _capturedFile = File(photo.path);
        _capturedIsVideo = false;
        _captionController.clear();
      });
    } catch (e) {
      debugPrint('[TAKE PHOTO ERR] $e');
    }
  }

  // --- RECORD VIDEO ---
  Future<void> _startVideoRecording() async {
    if (_controller == null || !_controller!.value.isInitialized || _isRecording) return;
    HapticFeedback.heavyImpact();

    try {
      await _controller!.startVideoRecording();
      _recordSeconds = 0;
      _recordTimer?.cancel();
      _recordTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (mounted) {
          setState(() {
            _recordSeconds++;
          });
        }
      });

      setState(() {
        _isRecording = true;
      });
    } catch (e) {
      debugPrint('[START VIDEO ERR] $e');
    }
  }

  Future<void> _stopVideoRecording() async {
    if (_controller == null || !_controller!.value.isRecordingVideo) return;
    HapticFeedback.mediumImpact();
    _recordTimer?.cancel();

    try {
      final XFile videoFile = await _controller!.stopVideoRecording();
      if (!mounted) return;

      final file = File(videoFile.path);

      // Initialize video preview player
      final vp = VideoPlayerController.file(file);
      await vp.initialize();
      await vp.setLooping(true);
      await vp.play();

      setState(() {
        _isRecording = false;
        _capturedFile = file;
        _capturedIsVideo = true;
        _videoPreviewController = vp;
        _captionController.clear();
      });
    } catch (e) {
      debugPrint('[STOP VIDEO ERR] $e');
      setState(() => _isRecording = false);
    }
  }

  void _retakeMedia() {
    _videoPreviewController?.pause();
    _videoPreviewController?.dispose();
    _videoPreviewController = null;
    _captionController.clear();
    setState(() {
      _capturedFile = null;
      _capturedIsVideo = false;
      _isRecording = false;
    });
  }

  void _sendCapturedMedia() {
    if (_capturedFile == null) return;
    HapticFeedback.mediumImpact();

    _videoPreviewController?.pause();
    _videoPreviewController?.dispose();

    Navigator.pop(
      context,
      CameraCaptureResult(
        file: _capturedFile!,
        isVideo: _capturedIsVideo,
        caption: _captionController.text.trim(),
      ),
    );
  }

  String _formatTimer(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    if (_hasPermissionError) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.no_photography_rounded, size: 64, color: Colors.white54),
                  const SizedBox(height: 16),
                  const Text(
                    'Kamera İzni Gerekli',
                    style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Fotoğraf ve video çekebilmek için lütfen kamera ve mikrofon izinlerini onaylayın.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton(
                    onPressed: openAppSettings,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Ayarları Aç', style: TextStyle(color: Colors.white)),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Kapat', style: TextStyle(color: Colors.white70)),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    // 1. Show Preview Screen if captured
    if (_capturedFile != null) {
      return _buildPreviewScreen();
    }

    // 2. Show Live Camera Viewfinder
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        top: false,
        child: Stack(
          children: [
            // Camera Live Viewport
            Positioned.fill(
              child: _isInitialized && _controller != null
                  ? FittedBox(
                      fit: BoxFit.cover,
                      child: SizedBox(
                        width: _controller!.value.previewSize?.height ?? 1,
                        height: _controller!.value.previewSize?.width ?? 1,
                        child: CameraPreview(_controller!),
                      ),
                    )
                  : const Center(
                      child: CircularProgressIndicator(color: AppColors.accent),
                    ),
            ),

            // Top Control Bar (Close, Flash, Recording Timer)
            Positioned(
              top: MediaQuery.of(context).padding.top + 10,
              left: 14,
              right: 14,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    icon: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black45,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white24),
                      ),
                      child: const Icon(Icons.close_rounded, color: Colors.white, size: 22),
                    ),
                    onPressed: () => Navigator.pop(context),
                  ),

                  // Recording Duration Pill
                  if (_isRecording)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: AppColors.callRed, width: 1.5),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: const BoxDecoration(
                              color: AppColors.callRed,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _formatTimer(_recordSeconds),
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),

                  // Flash Button
                  IconButton(
                    icon: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black45,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white24),
                      ),
                      child: Icon(
                        _flashMode == FlashMode.always
                            ? Icons.flash_on_rounded
                            : (_flashMode == FlashMode.auto
                                ? Icons.flash_auto_rounded
                                : Icons.flash_off_rounded),
                        color: _flashMode != FlashMode.off ? AppColors.accent : Colors.white,
                        size: 22,
                      ),
                    ),
                    onPressed: _toggleFlash,
                  ),
                ],
              ),
            ),

            // Bottom Control Area (Mode Switcher + Shutter + Flip)
            Positioned(
              bottom: 24,
              left: 0,
              right: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // MODE SWITCHER: FOTOĞRAF / VİDEO
                  if (!_isRecording)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildModeTab('FOTOĞRAF', CameraMode.photo),
                          const SizedBox(width: 8),
                          _buildModeTab('VİDEO', CameraMode.video),
                        ],
                      ),
                    ),

                  const SizedBox(height: 20),

                  // Shutter Button Row
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 36),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // Left: Mode info or spacer
                        const SizedBox(width: 44),

                        // Center: Main Shutter Button
                        _buildShutterButton(),

                        // Right: Flip Camera Button
                        IconButton(
                          icon: Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Colors.black45,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white24),
                            ),
                            child: const Icon(
                              Icons.flip_camera_ios_rounded,
                              color: Colors.white,
                              size: 24,
                            ),
                          ),
                          onPressed: _toggleCamera,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModeTab(String label, CameraMode mode) {
    final isSelected = _currentMode == mode;
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() => _currentMode = mode);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.accent.withValues(alpha: 0.25) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: isSelected ? Border.all(color: AppColors.accent, width: 1.2) : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? AppColors.accent : Colors.white70,
            fontSize: 12.5,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
            letterSpacing: 0.8,
          ),
        ),
      ),
    );
  }

  Widget _buildShutterButton() {
    final isVideoMode = _currentMode == CameraMode.video;

    return GestureDetector(
      onTap: () {
        if (isVideoMode) {
          if (_isRecording) {
            _stopVideoRecording();
          } else {
            _startVideoRecording();
          }
        } else {
          _takePhoto();
        }
      },
      onLongPress: () {
        // WhatsApp style: Long press in photo mode starts video recording!
        if (!isVideoMode && !_isRecording) {
          _startVideoRecording();
        }
      },
      onLongPressEnd: (_) {
        if (!isVideoMode && _isRecording) {
          _stopVideoRecording();
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 78,
        height: 78,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: isVideoMode || _isRecording ? AppColors.callRed : Colors.white,
            width: 4,
          ),
        ),
        padding: const EdgeInsets.all(5),
        child: Container(
          decoration: BoxDecoration(
            color: isVideoMode || _isRecording ? AppColors.callRed : Colors.white,
            shape: _isRecording ? BoxShape.rectangle : BoxShape.circle,
            borderRadius: _isRecording ? BorderRadius.circular(8) : null,
          ),
        ),
      ),
    );
  }

  // --- CAPTURED MEDIA PREVIEW SCREEN ---
  Widget _buildPreviewScreen() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // Preview Image or Looping Video
            Positioned.fill(
              child: Center(
                child: _capturedIsVideo
                    ? (_videoPreviewController != null && _videoPreviewController!.value.isInitialized
                        ? AspectRatio(
                            aspectRatio: _videoPreviewController!.value.aspectRatio,
                            child: VideoPlayer(_videoPreviewController!),
                          )
                        : const CircularProgressIndicator(color: AppColors.accent))
                    : Image.file(_capturedFile!, fit: BoxFit.contain),
              ),
            ),

            // Top Bar (Retake Button + Badge)
            Positioned(
              top: 10,
              left: 14,
              right: 14,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    icon: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: const BoxDecoration(
                        color: Colors.black54,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.close_rounded, color: Colors.white, size: 24),
                    ),
                    onPressed: _retakeMedia,
                    tooltip: 'Yeniden Çek',
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppColors.accent.withValues(alpha: 0.6)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _capturedIsVideo ? Icons.videocam_rounded : Icons.photo_camera_rounded,
                          color: AppColors.accent,
                          size: 15,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _capturedIsVideo ? 'Video Önizleme' : 'Fotoğraf Önizleme',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Bottom Bar (Caption input + Send button)
            Positioned(
              bottom: 12,
              left: 14,
              right: 14,
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1F2C34),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.edit_note_rounded, color: AppColors.accent, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _captionController,
                              style: const TextStyle(color: Colors.white, fontSize: 14),
                              decoration: const InputDecoration(
                                hintText: 'Bir başlık ekleyin...',
                                hintStyle: TextStyle(color: Colors.white54, fontSize: 14),
                                border: InputBorder.none,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  GestureDetector(
                    onTap: _sendCapturedMedia,
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: const BoxDecoration(
                        gradient: AppColors.primaryGradient,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.accent,
                            blurRadius: 8,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                      child: const Icon(Icons.send_rounded, color: Colors.white, size: 22),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
