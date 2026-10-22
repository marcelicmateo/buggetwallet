# Text recognition: only the Latin model is used (Bills > Scan bill). The plugin also mentions the Chinese, Devanagari, Japanese and
# Korean option classes, which are not packaged; R8 must not fail on them.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
