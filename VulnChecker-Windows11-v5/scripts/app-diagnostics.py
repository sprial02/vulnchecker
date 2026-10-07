"""Inspect installed splits/native libraries and collect crash evidence."""
import json
import pathlib
import re
import subprocess
import sys
import tempfile
import zipfile

identifier, package = sys.argv[1:3]
if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+", package):
    raise ValueError("Invalid Android package")
adb = ["/usr/bin/adb", "-s", identifier]
def run(*args):
    result = subprocess.run(adb + list(args), text=True, capture_output=True, timeout=60, check=True)
    return result.stdout.strip()
paths = [line[8:] for line in run("shell", "pm", "path", package).splitlines() if line.startswith("package:")]
if not paths:
    raise RuntimeError("App is not installed on the managed emulator")
libs = []
with tempfile.TemporaryDirectory(prefix="vulnchecker-apk-") as folder:
    for index, remote in enumerate(paths):
        local = pathlib.Path(folder) / (str(index) + ".apk")
        run("pull", remote, str(local))
        with zipfile.ZipFile(local) as apk:
            libs.extend(name for name in apk.namelist() if name.startswith("lib/") and name.endswith(".so"))
crash = run("logcat", "-d", "-b", "crash")
blocks = re.split(r'(?=^.*AndroidRuntime.*Process: )', crash, flags=re.MULTILINE)
matching = [block for block in blocks if re.search(r'Process:\s*' + re.escape(package) + r',\s*PID:', block)]
evidence = '\n'.join(matching)
missing = "MissingLibraryException" in evidence and "librealm-jni.so" in evidence
print(json.dumps({"package": package, "apk_paths": paths, "native_library_count": len(libs),
                  "abis": sorted({name.split('/')[1] for name in libs}),
                  "realm_libraries": [name for name in libs if name.endswith('/librealm-jni.so')],
                  "missing_realm_crash_seen": missing,
                  "crash_excerpt": evidence[-24000:],
                  "guidance": "Provide the complete split APK set or a universal APK containing the required native library" if missing else "Review the package-specific crash log before assuming root detection"}, ensure_ascii=False))
