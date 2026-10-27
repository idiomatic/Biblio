# JNI entry points are looked up by name.
-keep class com.rbrian.biblio.core.Core { native <methods>; }
-keepclassmembers @kotlinx.serialization.Serializable class com.rbrian.biblio.** { *; }
