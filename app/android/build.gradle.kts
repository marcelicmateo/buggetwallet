allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// receive_sharing_intent 1.9.0 asks for compileSdk 37, which the build image does not carry (it has 35 and 36, like the app). A plugin
// compiles fine against 36, so plugins that ask for more are lowered to the app's own compile SDK.
subprojects {
    if (project.name != "app") {
        afterEvaluate {
            if (plugins.hasPlugin("com.android.library")) {
                extensions.configure<com.android.build.gradle.LibraryExtension> {
                    val app = rootProject.findProject(":app")?.extensions?.findByType(com.android.build.gradle.internal.dsl.BaseAppModuleExtension::class.java)
                    val limit = app?.compileSdk ?: 36
                    if ((compileSdk ?: 0) > limit) compileSdk = limit
                }
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
