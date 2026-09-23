package com.example.pothole_app

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.example.pothole_app/road_tools",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getRoadPhotoDirectory" -> {
                    val photoDirectory = File(filesDir, "road_report_photos")
                    if (photoDirectory.exists() || photoDirectory.mkdirs()) {
                        result.success(photoDirectory.absolutePath)
                    } else {
                        result.error("PHOTO_STORAGE", "Could not create photo storage.", null)
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
}
