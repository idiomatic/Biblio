# JNI entry points are looked up by name, and the shim calls Core.send as the core's transport.
-keep class com.rbrian.biblio.core.Core { native <methods>; public static *** send(...); }
# The JNI shim builds the core's models and Core.Failure by class name and constructor
# signature, and reads HttpResponse's getters (android/native/src/jni.zig).
-keep class com.rbrian.biblio.core.** { <init>(...); }
-keep class com.rbrian.biblio.core.HttpResponse { *; }
-keepclassmembers @kotlinx.serialization.Serializable class com.rbrian.biblio.** { *; }
