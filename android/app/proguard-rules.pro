# JNI entry points are looked up by name.
-keep class com.rbrian.biblio.core.Core { native <methods>; }
# The JNI shim builds the core's models and Core.Failure by class name and constructor
# signature (android/native/src/jni.zig).
-keep class com.rbrian.biblio.core.** { <init>(...); }
-keepclassmembers @kotlinx.serialization.Serializable class com.rbrian.biblio.** { *; }
