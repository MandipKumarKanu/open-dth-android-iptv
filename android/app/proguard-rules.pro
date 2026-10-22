# Prevent R8 / Proguard from stripping VideoPlayer and ExoPlayer
-keep class io.flutter.plugins.videoplayer.** { *; }
-keepclassmembers class io.flutter.plugins.videoplayer.** { *; }
-keep class androidx.media3.** { *; }
-keepclassmembers class androidx.media3.** { *; }
-keep class com.example.live_tv.** { *; }
-keep class com.nk.live_tv.** { *; }
