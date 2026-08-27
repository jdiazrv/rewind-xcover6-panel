allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Redirected to an absolute path fully outside the Dropbox-synced project
// tree (not the usual "../../build" relative to the project root): this
// project's build/ kept getting fought over by Dropbox's sync engine
// (constantly re-materializing deleted files, renaming our directory into
// "Copia en conflicto..." files) — moving Gradle's actual output out of the
// synced tree entirely sidesteps that regardless of what any other synced
// device does.
val newBuildDir: Directory =
    rootProject.layout.projectDirectory.dir("/Users/juandiaz/FlutterBuilds/rewind_xcover6_panel")
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
