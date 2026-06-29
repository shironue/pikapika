-keep class go.** { *; }
-keep class mobile.** { *; }
-keepnames class go.**
-keepnames class mobile.**

-keepclasseswithmembernames class * {
    native <methods>;
}
