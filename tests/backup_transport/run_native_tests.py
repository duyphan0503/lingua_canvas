#!/usr/bin/env python3
"""Compile the production bounded reader with the cached Android Kotlin compiler."""

import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
CACHE = Path.home() / ".gradle/caches/modules-2/files-2.1"


def dependency(group: str, name: str, version: str | None = None) -> Path:
    matches = sorted((CACHE / group / name).glob(f"{version or '*'}/**/{name}-*.jar"))
    if not matches:
        raise SystemExit(f"Missing cached {name}; first run the pinned Android build")
    return matches[-1]


compiler = dependency("org.jetbrains.kotlin", "kotlin-compiler-embeddable", "2.2.20")
stdlib = dependency("org.jetbrains.kotlin", "kotlin-stdlib", "2.2.20")
annotations = dependency("org.jetbrains", "annotations")
compiler_jars = [
    compiler,
    stdlib,
    annotations,
    dependency("org.jetbrains.kotlin", "kotlin-script-runtime", "2.2.20"),
    dependency("org.jetbrains.kotlin", "kotlin-reflect"),
    dependency("org.jetbrains.kotlin", "kotlin-daemon-embeddable", "2.2.20"),
    dependency("org.jetbrains.kotlinx", "kotlinx-coroutines-core-jvm"),
]
java = Path(os.environ.get("JAVA_HOME", "/usr/lib/jvm/java-21-openjdk-amd64")) / "bin/java"

with tempfile.TemporaryDirectory(prefix="lingua-backup-native-") as directory:
    jar = Path(directory) / "test.jar"
    subprocess.run(
        [
            str(java),
            "-cp", os.pathsep.join(map(str, compiler_jars)),
            "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler",
            "-no-stdlib", "-no-reflect", "-jvm-target", "17",
            "-classpath", os.pathsep.join(map(str, [stdlib, annotations])),
            "-d", str(jar),
            str(ROOT / "app/android/app/src/main/kotlin/com/linguacanvas/app/BackupDocumentIo.kt"),
            str(ROOT / "tests/backup_transport/BackupDocumentIoTest.kt"),
        ],
        check=True,
    )
    subprocess.run(
        [str(java), "-cp", os.pathsep.join(map(str, [jar, stdlib])),
         "com.linguacanvas.app.BackupDocumentIoTestKt"],
        check=True,
    )
