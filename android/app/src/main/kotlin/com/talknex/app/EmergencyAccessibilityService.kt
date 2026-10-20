package com.talknex.app

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.content.Context
import android.content.Intent
import android.location.Location
import android.location.LocationManager
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.view.KeyEvent
import android.view.accessibility.AccessibilityEvent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL

/**
 * System Accessibility Service that runs continuously in the background,
 * even when the Talknex application is closed, killed, or the screen is locked.
 * Intercepts the assigned hardware button (Volume Up / Down) held for 3 seconds
 * to broadcast the emergency message, GPS location, and start live streaming.
 */
class EmergencyAccessibilityService : AccessibilityService() {

    private var volumeHoldJob: Job? = null
    private var isEmergencyTriggered = false
    private var lastTriggerTime = 0L

    override fun onServiceConnected() {
        super.onServiceConnected()
        try {
            val info = serviceInfo ?: AccessibilityServiceInfo()
            info.eventTypes = AccessibilityEvent.TYPES_ALL_MASK
            info.feedbackType = AccessibilityServiceInfo.FEEDBACK_GENERIC
            info.flags = info.flags or AccessibilityServiceInfo.FLAG_REQUEST_FILTER_KEY_EVENTS
            info.notificationTimeout = 100
            serviceInfo = info
            android.util.Log.i("EmergencyService", "✅ Talknex EmergencyAccessibilityService connected successfully!")
        } catch (e: Exception) {
            android.util.Log.e("EmergencyService", "Failed to configure AccessibilityService", e)
        }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // Required abstract method - no-op for button filtering
    }

    override fun onInterrupt() {
        volumeHoldJob?.cancel()
        volumeHoldJob = null
    }

    override fun onKeyEvent(event: KeyEvent): Boolean {
        try {
            val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val isEnabled = prefs.getBoolean("flutter.emergency_enabled", true)
            if (!isEnabled) {
                return super.onKeyEvent(event)
            }

            val triggerKey = prefs.getString("flutter.emergency_trigger_key", "volume_up") ?: "volume_up"
            val isTargetKey = when (triggerKey) {
                "volume_down" -> event.keyCode == KeyEvent.KEYCODE_VOLUME_DOWN
                else -> event.keyCode == KeyEvent.KEYCODE_VOLUME_UP
            }

            if (isTargetKey) {
                if (event.action == KeyEvent.ACTION_DOWN) {
                    if (event.repeatCount == 0) {
                        volumeHoldJob?.cancel()
                        isEmergencyTriggered = false

                        volumeHoldJob = CoroutineScope(Dispatchers.Main).launch {
                            delay(3000L) // 3 seconds continuous hold
                            val now = System.currentTimeMillis()
                            if (now - lastTriggerTime > 10000L) { // Debounce 10s
                                lastTriggerTime = now
                                isEmergencyTriggered = true
                                android.util.Log.i("EmergencyService", "🚨 3s HOLD DETECTED VIA ACCESSIBILITY SERVICE! TRIGGERING SOS!")
                                vibrateDiscreetly()
                                triggerBackgroundSos(applicationContext)
                            }
                        }
                    }
                    if (isEmergencyTriggered) {
                        return true
                    }
                } else if (event.action == KeyEvent.ACTION_UP) {
                    volumeHoldJob?.cancel()
                    volumeHoldJob = null
                    if (isEmergencyTriggered) {
                        isEmergencyTriggered = false
                        return true
                    }
                }
            }
        } catch (e: Exception) {
            android.util.Log.e("EmergencyService", "Error filtering key event", e)
        }
        return super.onKeyEvent(event)
    }

    private fun vibrateDiscreetly() {
        try {
            val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val vibratorManager = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager
                vibratorManager?.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
            }

            if (vibrator != null && vibrator.hasVibrator()) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    val timings = longArrayOf(0, 120, 80, 120, 80, 180)
                    val amplitudes = intArrayOf(0, 255, 0, 255, 0, 255)
                    vibrator.vibrate(VibrationEffect.createWaveform(timings, amplitudes, -1))
                } else {
                    @Suppress("DEPRECATION")
                    vibrator.vibrate(longArrayOf(0, 120, 80, 120, 80, 180), -1)
                }
            }
        } catch (e: Exception) {
            android.util.Log.w("EmergencyService", "Vibration failed", e)
        }
    }

    private fun triggerBackgroundSos(context: Context) {
        CoroutineScope(Dispatchers.IO).launch {
            try {
                val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)

                val customMessage = prefs.getString("flutter.emergency_custom_message", null)
                    ?: "🚨 ACİL DURUM! Başım dertte ve acil yardıma ihtiyacım var! Bu otomatik bir acil durum mesajıdır. Lütfen hemen yardım gönderin!"

                var senderId = prefs.getString("flutter.emergency_user_id", "0") ?: "0"
                if (senderId == "0") {
                    val savedUser = prefs.getString("flutter.saved_user", null)
                    if (savedUser != null) {
                        try {
                            val userObj = JSONObject(savedUser)
                            senderId = userObj.optString("uid", "0")
                        } catch (_: Exception) {}
                    }
                }

                // Parse emergency contacts
                val contactsList = mutableListOf<String>()
                val rawContactsJson = prefs.getString("flutter.emergency_contacts_raw_json", null)
                if (rawContactsJson != null) {
                    try {
                        val arr = JSONArray(rawContactsJson)
                        for (i in 0 until arr.length()) {
                            val obj = arr.getJSONObject(i)
                            val uid = obj.optString("uid", "")
                            if (uid.isNotBlank()) contactsList.add(uid)
                        }
                    } catch (_: Exception) {}
                }

                // Fallback to legacy contacts format if empty
                if (contactsList.isEmpty()) {
                    val legacyList = prefs.getStringSet("flutter.emergency_contacts_json", null)
                    legacyList?.forEach { str ->
                        try {
                            val obj = JSONObject(str)
                            val uid = obj.optString("uid", "")
                            if (uid.isNotBlank()) contactsList.add(uid)
                        } catch (_: Exception) {}
                    }
                }

                if (contactsList.isEmpty()) {
                    android.util.Log.w("EmergencyService", "No emergency contacts found in background storage!")
                    return@launch
                }

                // Acquire current GPS coordinates
                val (lat, lon) = getBestLocation(context)
                val mapsUrl = "https://maps.google.com/?q=$lat,$lon"
                val finalMessage = "$customMessage\n📍 Acil Durum Konumu: $mapsUrl\n🔴 Canlı Konum Başlatıldı"

                // 1. Post direct HTTP message for EACH contact to guarantee DB storage & FCM notification
                for (contactUid in contactsList) {
                    try {
                        val payload = JSONObject().apply {
                            put("senderId", senderId.toIntOrNull() ?: 0)
                            put("receiverId", contactUid.toIntOrNull() ?: 0)
                            put("content", finalMessage)
                            put("type", "location")
                            put("mediaUrl", mapsUrl)
                        }
                        sendHttpPost("http://46.197.188.20:3000/api/messages", payload.toString())
                    } catch (e: Exception) {
                        android.util.Log.e("EmergencyService", "Failed to send message to $contactUid", e)
                    }
                }

                // 2. Start Live Location on backend
                try {
                    val locPayload = JSONObject().apply {
                        put("senderId", senderId)
                        put("receiverIds", JSONArray(contactsList))
                        put("latitude", lat)
                        put("longitude", lon)
                    }
                    sendHttpPost("http://46.197.188.20:3000/api/live-location/start", locPayload.toString())
                } catch (e: Exception) {
                    android.util.Log.w("EmergencyService", "Failed to start backend live location", e)
                }

                // 3. Launch MainActivity with FLAG_ACTIVITY_NEW_TASK to wake up Flutter engine & live location stream
                launchAppForLiveStreaming(context)

            } catch (e: Exception) {
                android.util.Log.e("EmergencyService", "Critical error in triggerBackgroundSos", e)
            }
        }
    }

    private fun getBestLocation(context: Context): Pair<Double, Double> {
        return try {
            val locationManager = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
            var bestLoc: Location? = null

            try {
                val gpsLoc = locationManager?.getLastKnownLocation(LocationManager.GPS_PROVIDER)
                val netLoc = locationManager?.getLastKnownLocation(LocationManager.NETWORK_PROVIDER)

                bestLoc = when {
                    gpsLoc != null && netLoc != null -> if (gpsLoc.time > netLoc.time) gpsLoc else netLoc
                    gpsLoc != null -> gpsLoc
                    else -> netLoc
                }
            } catch (_: SecurityException) {}

            val lat = bestLoc?.latitude ?: 39.925533
            val lon = bestLoc?.longitude ?: 32.866287
            Pair(lat, lon)
        } catch (_: Exception) {
            Pair(39.925533, 32.866287)
        }
    }

    private fun sendHttpPost(urlStr: String, jsonBody: String) {
        var conn: HttpURLConnection? = null
        try {
            val url = URL(urlStr)
            conn = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 4000
                readTimeout = 4000
                doOutput = true
                setRequestProperty("Content-Type", "application/json; charset=UTF-8")
                setRequestProperty("Accept", "application/json")
            }

            OutputStreamWriter(conn.outputStream, "UTF-8").use { writer ->
                writer.write(jsonBody)
                writer.flush()
            }

            val respCode = conn.responseCode
            android.util.Log.i("EmergencyService", "POST $urlStr -> Response: $respCode")
        } catch (e: Exception) {
            android.util.Log.w("EmergencyService", "HTTP POST failed for $urlStr: ${e.message}")
        } finally {
            conn?.disconnect()
        }
    }

    private fun launchAppForLiveStreaming(context: Context) {
        try {
            val intent = Intent(context, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
                addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                putExtra("trigger_emergency", true)
            }
            context.startActivity(intent)
        } catch (e: Exception) {
            android.util.Log.e("EmergencyService", "Failed to launch MainActivity", e)
        }
    }
}
