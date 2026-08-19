allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

subprojects {
    // camera_android_camerax needs concurrent-futures on its compile classpath.
    // Inject it into every subproject so plugin compilation succeeds.
    afterEvaluate {
        if (plugins.hasPlugin("com.android.library") || plugins.hasPlugin("com.android.application")) {
            dependencies {
                "implementation"("androidx.concurrent:concurrent-futures:1.1.0")
                "compileOnly"("org.jspecify:jspecify:1.0.0")
            }
        }
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
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
