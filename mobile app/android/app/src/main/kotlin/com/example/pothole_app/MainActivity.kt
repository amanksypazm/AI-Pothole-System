package com.example.pothole_app

import android.content.ActivityNotFoundException
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.MediaStore
import android.speech.tts.TextToSpeech
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.Locale
import kotlin.math.min

class MainActivity : FlutterActivity(), TextToSpeech.OnInitListener {
    private var pendingProfilePhotoResult: MethodChannel.Result? = null
    private val profilePhotoRequestCode = 7314
    private val profileCameraRequestCode = 7315
    private var textToSpeech: TextToSpeech? = null
    private var ttsReady = false

    override fun onInit(status: Int) {
        if (status == TextToSpeech.SUCCESS) {
            textToSpeech?.language = Locale.getDefault()
            ttsReady = true
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        if (textToSpeech == null) {
            textToSpeech = TextToSpeech(applicationContext, this)
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.example.pothole_app/road_tools",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "speakVoiceAlert" -> {
                    val message = call.argument<String>("message") ?: "Warning: Pothole ahead!"
                    if (textToSpeech != null && ttsReady) {
                        textToSpeech?.speak(message, TextToSpeech.QUEUE_FLUSH, null, "pothole_voice_alert")
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                "stopVoiceAlert" -> {
                    textToSpeech?.stop()
                    result.success(true)
                }
                "pickProfilePhoto" -> {
                    if (pendingProfilePhotoResult != null) {
                        result.error("PICKER_BUSY", "Photo picker is already open.", null)
                        return@setMethodCallHandler
                    }
                    pendingProfilePhotoResult = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "image/*"
                    }
                    try {
                        startActivityForResult(intent, profilePhotoRequestCode)
                    } catch (error: Exception) {
                        pendingProfilePhotoResult = null
                        result.error("PICKER_UNAVAILABLE", error.message, null)
                    }
                }
                "captureProfilePhoto" -> {
                    if (pendingProfilePhotoResult != null) {
                        result.error("PICKER_BUSY", "Photo picker is already open.", null)
                        return@setMethodCallHandler
                    }
                    pendingProfilePhotoResult = result
                    try {
                        startActivityForResult(
                            Intent(MediaStore.ACTION_IMAGE_CAPTURE),
                            profileCameraRequestCode,
                        )
                    } catch (error: Exception) {
                        pendingProfilePhotoResult = null
                        result.error("CAMERA_UNAVAILABLE", error.message, null)
                    }
                }
                "getRoadPhotoDirectory" -> {
                    val photoDirectory = File(filesDir, "road_report_photos")
                    if (photoDirectory.exists() || photoDirectory.mkdirs()) {
                        result.success(photoDirectory.absolutePath)
                    } else {
                        result.error("PHOTO_STORAGE", "Could not create photo storage.", null)
                    }
                }
                "getRoadVideoDirectory" -> {
                    val videoDirectory = File(filesDir, "road_scan_videos")
                    if (videoDirectory.exists() || videoDirectory.mkdirs()) {
                        result.success(videoDirectory.absolutePath)
                    } else {
                        result.error("VIDEO_STORAGE", "Could not create video storage.", null)
                    }
                }

                "loadRoadReports" -> {
                    val reportsJson = getSharedPreferences(
                        "road_reports",
                        MODE_PRIVATE,
                    ).getString("reports_json", "[]")
                    result.success(reportsJson)
                }

                "saveRoadReports" -> {
                    val reportsJson = call.argument<String>("reportsJson")
                    if (reportsJson == null) {
                        result.error("INVALID_REPORTS", "Report data is missing.", null)
                    } else {
                        getSharedPreferences("road_reports", MODE_PRIVATE)
                            .edit()
                            .putString("reports_json", reportsJson)
                            .apply()
                        result.success(null)
                    }
                }

                "openGoogleMapsPin" -> {
                    val latitude = call.argument<Double>("latitude")
                    val longitude = call.argument<Double>("longitude")
                    if (latitude == null || longitude == null) {
                        result.error("INVALID_LOCATION", "Coordinates are missing.", null)
                        return@setMethodCallHandler
                    }

                    val coordinates = "$latitude,$longitude"
                    val mapIntent = Intent(
                        Intent.ACTION_VIEW,
                        Uri.parse("geo:$coordinates?q=$coordinates(Pothole)"),
                    ).setPackage("com.google.android.apps.maps")

                    try {
                        startActivity(mapIntent)
                        result.success(null)
                    } catch (_: ActivityNotFoundException) {
                        try {
                            val browserIntent = Intent(
                                Intent.ACTION_VIEW,
                                Uri.parse(
                                    "https://www.google.com/maps/search/?api=1&query=" +
                                        "$latitude%2C$longitude",
                                ),
                            )
                            startActivity(browserIntent)
                            result.success(null)
                        } catch (error: Exception) {
                            result.error("MAPS_UNAVAILABLE", error.message, null)
                        }
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    @Deprecated("Deprecated in Android, retained for Flutter's activity result flow")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == profileCameraRequestCode) {
            val result = pendingProfilePhotoResult
            pendingProfilePhotoResult = null
            if (result == null) return
            if (resultCode != RESULT_OK) {
                result.success(null)
                return
            }
            try {
                val bitmap = data?.extras?.get("data") as? Bitmap
                    ?: throw IllegalStateException("The camera did not return a photo.")
                val path = saveProfilePhoto(bitmap).absolutePath
                if (!bitmap.isRecycled) bitmap.recycle()
                result.success(path)
            } catch (error: Exception) {
                result.error("PHOTO_CAPTURE_FAILED", error.message, null)
            }
            return
        }
        if (requestCode == profilePhotoRequestCode) {
            val result = pendingProfilePhotoResult
            pendingProfilePhotoResult = null
            if (result == null) return
            if (resultCode != RESULT_OK || data?.data == null) {
                result.success(null)
                return
            }
            try {
                val uri: Uri = data.data!!
                val photo = copyProfilePhoto(uri)
                result.success(photo.absolutePath)
            } catch (error: Exception) {
                result.error("PHOTO_READ_FAILED", error.message, null)
            }
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun copyProfilePhoto(uri: Uri): File {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
            ?: throw IllegalStateException("Could not read selected image.")
        var sample = 1
        while (min(bounds.outWidth / sample, bounds.outHeight / sample) > 1024) sample *= 2
        val options = BitmapFactory.Options().apply { inSampleSize = sample }
        val source = contentResolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, options)
        } ?: throw IllegalStateException("Could not decode selected image.")
        val photo = saveProfilePhoto(source)
        source.recycle()
        return photo
    }

    private fun saveProfilePhoto(source: Bitmap): File {
        val squareSize = min(source.width, source.height)
        val cropped = Bitmap.createBitmap(
            source,
            (source.width - squareSize) / 2,
            (source.height - squareSize) / 2,
            squareSize,
            squareSize,
        )
        val avatar = Bitmap.createScaledBitmap(cropped, 512, 512, true)
        val destination = File(filesDir, "profile_avatar.jpg")
        FileOutputStream(destination).use { output ->
            avatar.compress(Bitmap.CompressFormat.JPEG, 82, output)
        }
        if (avatar !== cropped) avatar.recycle()
        if (cropped !== source) cropped.recycle()
        return destination
    }

    override fun onDestroy() {
        textToSpeech?.stop()
        textToSpeech?.shutdown()
        textToSpeech = null
        super.onDestroy()
    }
}
