package com.example.media_player

import android.app.PictureInPictureParams
import android.content.res.Configuration
import android.os.Build
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "app/native"
        ).also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "isPipSupported" ->
                        result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                    "enterPip" -> {
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                            result.success(false)
                        } else {
                            val width = call.argument<Int>("width") ?: 16
                            val height = call.argument<Int>("height") ?: 9
                            result.success(enterPipMode(width, height))
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    private fun enterPipMode(width: Int, height: Int): Boolean {
        return try {
            val params = PictureInPictureParams.Builder()
                .setAspectRatio(clampAspect(width, height))
                .build()
            enterPictureInPictureMode(params)
        } catch (e: Exception) {
            false
        }
    }

    /** 系统要求画中画宽高比在 0.41841 ~ 2.39 之间，超出则夹取 */
    private fun clampAspect(width: Int, height: Int): Rational {
        val w = if (width > 0) width else 16
        val h = if (height > 0) height else 9
        val ratio = w.toDouble() / h.toDouble()
        return when {
            ratio > 2.39 -> Rational(239, 100)
            ratio < 0.41841 -> Rational(42, 100)
            else -> Rational(w, h)
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        channel?.invokeMethod("pipChanged", isInPictureInPictureMode)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        channel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
