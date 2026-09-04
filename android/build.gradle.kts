allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Keep Flutter's standard build directory by default so `flutter build apk`
// can locate and report its artifact. Developers affected by Dropbox build
// churn can still opt into an external directory for direct Gradle builds:
// REWIND_BUILD_DIR=/absolute/path ./gradlew assembleRelease
val externalBuildDir = providers.environmentVariable("REWIND_BUILD_DIR").orNull
val newBuildDir: Directory = if (externalBuildDir.isNullOrBlank()) {
    rootProject.layout.projectDirectory.dir("../build")
} else {
    rootProject.layout.projectDirectory.dir(externalBuildDir)
}
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
