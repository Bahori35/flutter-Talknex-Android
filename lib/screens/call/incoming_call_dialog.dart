import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../constants/app_colors.dart';
import '../../models/call_model.dart';
import '../../models/user_model.dart';
import '../../services/signaling_service.dart';
import 'call_screen.dart';
import '../../widgets/app_avatar.dart';

class IncomingCallDialog extends StatelessWidget {
  final CallModel call;
  final UserModel currentUser;

  const IncomingCallDialog({
    super.key,
    required this.call,
    required this.currentUser,
  });

  @override
  Widget build(BuildContext context) {
    final SignalingService signaling = SignalingService();

    final callerUser = UserModel(
      uid: call.callerId,
      username: call.callerName,
      email: '',
      displayName: call.callerName,
      photoUrl: call.callerPic,
    );

    return Scaffold(
      backgroundColor: Colors.black.withOpacity(0.9),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 40.0, horizontal: 24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Caller Information
              Column(
                children: [
                  const SizedBox(height: 30),
                  AppAvatar(
                    radius: 60,
                    imageUrl: call.callerPic,
                    name: call.callerName,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    call.callerName,
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    call.callType == CallType.video
                        ? 'Gelen Görüntülü Arama...'
                        : 'Gelen Sesli Arama...',
                    style: const TextStyle(
                      fontSize: 16,
                      color: AppColors.primaryLight,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),

              // Accept / Reject Buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Reject Button
                  Column(
                    children: [
                      CircleAvatar(
                        radius: 34,
                        backgroundColor: AppColors.callRed,
                        child: IconButton(
                          icon: const Icon(Icons.call_end, color: Colors.white, size: 32),
                          onPressed: () async {
                            await signaling.endCall(call.callId);
                          },
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text('Reddet', style: TextStyle(color: Colors.white70)),
                    ],
                  ),

                  // Accept Button
                  Column(
                    children: [
                      CircleAvatar(
                        radius: 34,
                        backgroundColor: AppColors.callGreen,
                        child: IconButton(
                          icon: Icon(
                            call.callType == CallType.video ? Icons.videocam : Icons.call,
                            color: Colors.white,
                            size: 32,
                          ),
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => CallScreen(
                                  currentUser: currentUser,
                                  peerUser: callerUser,
                                  callType: call.callType,
                                  isCaller: false,
                                  callId: call.callId,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text('Cevapla', style: TextStyle(color: Colors.white70)),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
