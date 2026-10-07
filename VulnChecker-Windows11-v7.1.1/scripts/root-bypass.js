// Limited Java root checks for an authorized test app. No crash suppression.
// Frida 17 clients must provide the Java bridge (the launcher does this).
Java.perform(function () {
    // Verified against the original Energy Plus 8.9 / versionCode 234 split set.
    // Hook the five boolean probes, preserving the coroutine and app callbacks.
    // APK signature checks, TLS checks and Play Integrity are left intact.
    const ActivityThread = Java.use('android.app.ActivityThread');
    if (ActivityThread.currentPackageName().toString() === 'com.gscaltex.energyplus') {
        // At spawn time currentApplication() is still null; the system context
        // is already available before Application.attach/onCreate.
        const context = ActivityThread.currentActivityThread().getSystemContext();
        const info = context.getPackageManager().getPackageInfo('com.gscaltex.energyplus', 0);
        if (info.versionName.value.toString() === '8.9' && info.versionCode.value === 234) {
            try {
                Java.use('com.gscaltex.android.rootingchecker.RootingChecker');
                const probes = ['a', 'b', 'c', 'd', 'e'].map(function (name) {
                    const klass = Java.use('y6.' + name);
                    const method = name === 'c' ? klass.check.overload('android.content.Context') : klass.check.overload();
                    if (method.returnType.className !== 'boolean') throw new Error('Unexpected root probe signature');
                    return { name: 'y6.' + name, method: method };
                });
                probes.forEach(function (probe) {
                    let reported = false;
                    probe.method.implementation = function () {
                        if (!reported) { send({ profile: 'energyplus-8.9', root_probe: probe.name, result: false }); reported = true; }
                        return false;
                    };
                });
                send({ profile: 'energyplus-8.9', status: 'installed', probes: probes.length });
            } catch (error) {
                send({ profile: 'energyplus-8.9', status: 'failed', error: String(error) });
                throw error;
            }
        } else {
            send({ profile: 'energyplus-8.9', status: 'unsupported-version', version: info.versionName.value.toString() });
        }
    }
    const Build = Java.use('android.os.Build');
    Build.TAGS.value = 'release-keys';
    const File = Java.use('java.io.File');
    const exists = File.exists.overload();
    const rootPaths = new Set([
        '/system/bin/su', '/system/xbin/su', '/sbin/su',
        '/system/app/Superuser.apk', '/system/app/SuperSU.apk',
        '/data/local/bin/su', '/data/local/xbin/su', '/data/local/su'
    ]);
    exists.implementation = function () {
        if (rootPaths.has(this.getAbsolutePath().toString())) return false;
        return exists.call(this);
    };
    try {
        const RootBeer = Java.use('com.scottyab.rootbeer.RootBeer');
        ['isRooted', 'isRootedWithoutBusyBoxCheck', 'checkForSuBinary',
         'checkForMagiskBinary', 'detectTestKeys', 'checkForDangerousProps',
         'checkForRWPaths', 'checkForRootNative'].forEach(function (name) {
            if (RootBeer[name]) RootBeer[name].overloads.forEach(function (method) {
                if (method.returnType.className === 'boolean') {
                    method.implementation = function () { return false; };
                }
            });
        });
    } catch (_) { /* This app may not use RootBeer. */ }
    send('VulnChecker Java root hooks loaded');
});
