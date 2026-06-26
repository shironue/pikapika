param(
    [Parameter(Mandatory = $true)]
    [string]$ApkPath,

    [string]$OutputAar = "",

    [string]$WorkDir = "",

    [string]$AndroidSdk = "",

    [switch]$KeepWorkDir,

    [switch]$VerifyBuild
)

$ErrorActionPreference = "Stop"

function Resolve-FullPath([string]$Path) {
    $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Get-RepoRoot {
    $scriptDir = Split-Path -Parent $PSCommandPath
    Resolve-Path (Join-Path $scriptDir "..")
}

function Read-LocalProperty([string]$File, [string]$Name) {
    if (!(Test-Path $File)) {
        return $null
    }
    foreach ($line in Get-Content $File) {
        if ($line -match "^\s*$([regex]::Escape($Name))\s*=\s*(.+?)\s*$") {
            return $Matches[1]
        }
    }
    return $null
}

function Find-AndroidSdk([string]$RepoRoot, [string]$ExplicitSdk) {
    if ($ExplicitSdk) {
        return Resolve-FullPath $ExplicitSdk
    }

    $fromLocalProperties = Read-LocalProperty (Join-Path $RepoRoot "android/local.properties") "sdk.dir"
    if ($fromLocalProperties) {
        return $fromLocalProperties
    }

    if ($env:ANDROID_HOME) {
        return $env:ANDROID_HOME
    }

    if ($env:ANDROID_SDK_ROOT) {
        return $env:ANDROID_SDK_ROOT
    }

    throw "Android SDK not found. Pass -AndroidSdk or set sdk.dir in android/local.properties."
}

function Find-AndroidJar([string]$AndroidSdkPath) {
    $platforms = Join-Path $AndroidSdkPath "platforms"
    if (!(Test-Path $platforms)) {
        throw "Android SDK platforms directory not found: $platforms"
    }

    $androidJars = Get-ChildItem -Path $platforms -Filter "android.jar" -Recurse |
        Sort-Object {
            if ($_.Directory.Name -match "android-(\d+)") {
                [int]$Matches[1]
            } else {
                0
            }
        } -Descending

    if (!$androidJars) {
        throw "No android.jar found under: $platforms"
    }

    return $androidJars[0].FullName
}

function Find-Tool([string]$Name) {
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (!$cmd) {
        throw "$Name not found in PATH. Install/configure a JDK and make sure $Name is available."
    }
    return $cmd.Source
}

function Find-Dexdump([string]$AndroidSdkPath) {
    $buildTools = Join-Path $AndroidSdkPath "build-tools"
    if (!(Test-Path $buildTools)) {
        return $null
    }
    $tools = Get-ChildItem -Path $buildTools -Filter "dexdump.exe" -Recurse -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending
    if ($tools) {
        return $tools[0].FullName
    }
    return $null
}

function Write-TextFile([string]$Path, [string]$Content) {
    $dir = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force $dir | Out-Null
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Invoke-Checked([string]$Exe, [string[]]$Arguments) {
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed ($LASTEXITCODE): $Exe $($Arguments -join ' ')"
    }
}

function Write-MobileStubSources([string]$SrcDir) {
    Write-TextFile (Join-Path $SrcDir "go/Seq.java") @'
package go;

import android.content.Context;
import java.lang.ref.PhantomReference;
import java.lang.ref.ReferenceQueue;
import java.util.HashMap;
import java.util.IdentityHashMap;
import java.util.Map;
import java.util.logging.Logger;

public final class Seq {
    private static final int NULL_REFNUM = 41;
    private static final GoRefQueue goRefQueue;
    private static Logger log;
    public static final Ref nullRef;
    static final RefTracker tracker;

    static {
        log = Logger.getLogger("GoSeq");
        nullRef = new Ref(NULL_REFNUM, null);
        goRefQueue = new GoRefQueue();
        System.loadLibrary("gojni");
        init();
        Universe.touch();
        tracker = new RefTracker();
    }

    private Seq() {
    }

    static Logger access$000() {
        return log;
    }

    static void decRef(int refnum) {
        tracker.dec(refnum);
    }

    static native void destroyRef(int refnum);

    public static Ref getRef(int refnum) {
        return tracker.get(refnum);
    }

    public static int incGoObjectRef(GoObject obj) {
        return obj.incRefnum();
    }

    public static native void incGoRef(int refnum, GoObject obj);

    public static int incRef(Object obj) {
        return tracker.inc(obj);
    }

    public static void incRefnum(int refnum) {
        tracker.incRefnum(refnum);
    }

    private static native void init();

    public static void setContext(Context context) {
        setContext((Object) context);
    }

    static native void setContext(Object context);

    public static void touch() {
    }

    public static void trackGoRef(int refnum, GoObject obj) {
        if (refnum <= 0) {
            throw new RuntimeException("trackGoRef called with Java refnum " + refnum);
        }
        goRefQueue.track(refnum, obj);
    }

    public interface GoObject {
        int incRefnum();
    }

    public interface Proxy extends GoObject {
    }

    static final class GoRef extends PhantomReference<GoObject> {
        final int refnum;

        GoRef(int refnum, GoObject obj, GoRefQueue queue) {
            super(obj, queue);
            if (refnum <= 0) {
                throw new RuntimeException("GoRef instantiated with a Java refnum " + refnum);
            }
            this.refnum = refnum;
        }
    }

    static final class GoRefQueue extends ReferenceQueue<GoObject> {
        GoRefQueue() {
            Thread thread = new Thread(new GoRefRunnable(this), "GoRefQueue");
            thread.setDaemon(true);
            thread.start();
        }

        void track(int refnum, GoObject obj) {
            new GoRef(refnum, obj, this);
        }
    }

    static final class GoRefRunnable implements Runnable {
        private final GoRefQueue queue;

        GoRefRunnable(GoRefQueue queue) {
            this.queue = queue;
        }

        @Override
        public void run() {
            while (true) {
                try {
                    GoRef ref = (GoRef) queue.remove();
                    destroyRef(ref.refnum);
                } catch (InterruptedException ignored) {
                    return;
                } catch (Throwable throwable) {
                    access$000().warning(String.valueOf(throwable));
                }
            }
        }
    }

    public static final class Ref {
        public final Object obj;
        private int refcnt;
        public final int refnum;

        public Ref(int refnum, Object obj) {
            if (refnum < 0) {
                throw new RuntimeException("Ref instantiated with a Go refnum " + refnum);
            }
            this.refnum = refnum;
            this.refcnt = 0;
            this.obj = obj;
        }

        static int access$100(Ref ref) {
            return ref.refcnt;
        }

        static int access$110(Ref ref) {
            int old = ref.refcnt;
            ref.refcnt = old - 1;
            return old;
        }

        void inc() {
            if (refcnt == Integer.MAX_VALUE) {
                throw new RuntimeException("refnum " + refnum + " overflow");
            }
            refcnt++;
        }
    }

    static final class RefMap {
        private final Map<Integer, Ref> refs = new HashMap<Integer, Ref>();

        Ref get(int key) {
            return refs.get(Integer.valueOf(key));
        }

        void put(int key, Ref ref) {
            refs.put(Integer.valueOf(key), ref);
        }

        void remove(int key) {
            refs.remove(Integer.valueOf(key));
        }
    }

    static final class RefTracker {
        private static final int REF_OFFSET = 42;
        private final RefMap javaObjs = new RefMap();
        private final IdentityHashMap<Object, Integer> javaRefs = new IdentityHashMap<Object, Integer>();
        private int next = REF_OFFSET;

        synchronized void dec(int refnum) {
            if (refnum > 0) {
                access$000().severe("dec request for Go object " + refnum);
                return;
            }
            if (refnum == nullRef.refnum) {
                return;
            }
            Ref ref = javaObjs.get(refnum);
            if (ref == null) {
                throw new RuntimeException("referenced Java object is not found: refnum=" + refnum);
            }
            Ref.access$110(ref);
            if (Ref.access$100(ref) <= 0) {
                javaObjs.remove(refnum);
                javaRefs.remove(ref.obj);
            }
        }

        synchronized Ref get(int refnum) {
            if (refnum == NULL_REFNUM) {
                return nullRef;
            }
            if (refnum >= 0) {
                throw new RuntimeException("ref called with Go refnum " + refnum);
            }
            Ref ref = javaObjs.get(refnum);
            if (ref == null) {
                throw new RuntimeException("unknown java Ref: " + refnum);
            }
            return ref;
        }

        synchronized int inc(Object obj) {
            if (obj == null) {
                return NULL_REFNUM;
            }
            if (obj instanceof Proxy) {
                return ((Proxy) obj).incRefnum();
            }
            Integer existing = javaRefs.get(obj);
            int refnum;
            if (existing == null) {
                if (next == Integer.MAX_VALUE) {
                    throw new RuntimeException("createRef overflow for " + obj);
                }
                refnum = next++;
                javaRefs.put(obj, Integer.valueOf(refnum));
                javaObjs.put(refnum, new Ref(refnum, obj));
            } else {
                refnum = existing.intValue();
            }
            Ref ref = javaObjs.get(refnum);
            if (ref != null) {
                ref.inc();
            }
            return refnum;
        }

        synchronized void incRefnum(int refnum) {
            Ref ref = javaObjs.get(refnum);
            if (ref != null) {
                ref.inc();
            }
        }
    }
}
'@

    Write-TextFile (Join-Path $SrcDir "go/Universe.java") @'
package go;

public abstract class Universe {
    static {
        Seq.touch();
        _init();
    }

    private Universe() {
    }

    private static native void _init();

    public static void touch() {
    }

    static final class proxyerror extends Exception implements Seq.Proxy, error {
        private final int refnum;

        proxyerror(int refnum) {
            this.refnum = refnum;
            Seq.trackGoRef(refnum, this);
        }

        @Override
        public native String error();

        @Override
        public String getMessage() {
            return error();
        }

        @Override
        public final int incRefnum() {
            Seq.incGoRef(refnum, this);
            return refnum;
        }
    }
}
'@

    Write-TextFile (Join-Path $SrcDir "go/error.java") @'
package go;

public interface error {
    String error();
}
'@

    Write-TextFile (Join-Path $SrcDir "mobile/EventNotifyHandler.java") @'
package mobile;

public interface EventNotifyHandler {
    void onNotify(String message);
}
'@

    Write-TextFile (Join-Path $SrcDir "mobile/Mobile.java") @'
package mobile;

import go.Seq;

public abstract class Mobile {
    static {
        Seq.touch();
        _init();
    }

    private Mobile() {
    }

    private static native void _init();

    public static native void eventNotify(EventNotifyHandler handler);

    public static native String flatInvoke(String method, String params);

    public static native void initApplication(String dataPath);

    public static native void migration(String from, String to);

    public static void touch() {
    }

    static final class proxyEventNotifyHandler implements Seq.Proxy, EventNotifyHandler {
        private final int refnum;

        proxyEventNotifyHandler(int refnum) {
            this.refnum = refnum;
            Seq.trackGoRef(refnum, this);
        }

        @Override
        public final int incRefnum() {
            Seq.incGoRef(refnum, this);
            return refnum;
        }

        @Override
        public native void onNotify(String message);
    }
}
'@
}

function Validate-DexBindings([string]$Dexdump, [string]$ClassesDex, [string]$ValidationFile) {
    if (!$Dexdump) {
        Write-Warning "dexdump not found; skipping APK binding validation."
        return
    }

    & $Dexdump -d $ClassesDex > $ValidationFile
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "dexdump failed; skipping APK binding validation."
        return
    }

    $dump = Get-Content $ValidationFile -Raw
    $required = @(
        "Class descriptor  : 'Lmobile/Mobile;'",
        "name          : 'flatInvoke'",
        "type          : '(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;'",
        "name          : 'initApplication'",
        "name          : 'eventNotify'",
        "Class descriptor  : 'Lmobile/EventNotifyHandler;'",
        "name          : 'onNotify'",
        "Class descriptor  : 'Lgo/Seq;'"
    )

    foreach ($item in $required) {
        if (!$dump.Contains($item)) {
            throw "APK dex does not contain expected gomobile binding: $item"
        }
    }
}

$repoRoot = Get-RepoRoot
$apkFullPath = Resolve-FullPath $ApkPath
if (!(Test-Path $apkFullPath)) {
    throw "APK not found: $apkFullPath"
}

if (!$OutputAar) {
    $OutputAar = Join-Path $repoRoot "go/mobile/lib/Mobile.aar"
}
$outputAarFullPath = Resolve-FullPath $OutputAar

if (!$WorkDir) {
    $WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("pikapika-mobile-aar-" + [System.Guid]::NewGuid().ToString("N"))
}
$workFullPath = Resolve-FullPath $WorkDir

$androidSdkPath = Find-AndroidSdk $repoRoot $AndroidSdk
$androidJar = Find-AndroidJar $androidSdkPath
$javac = Find-Tool "javac"
$jar = Find-Tool "jar"
$dexdump = Find-Dexdump $androidSdkPath

Write-Host "APK: $apkFullPath"
Write-Host "Android SDK: $androidSdkPath"
Write-Host "android.jar: $androidJar"
Write-Host "Work dir: $workFullPath"
Write-Host "Output AAR: $outputAarFullPath"

Remove-Item -Recurse -Force $workFullPath -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $workFullPath | Out-Null

$extractDir = Join-Path $workFullPath "apk"
$srcDir = Join-Path $workFullPath "src"
$classesDir = Join-Path $workFullPath "classes"
$aarDir = Join-Path $workFullPath "aar"

[System.Reflection.Assembly]::LoadWithPartialName("System.IO.Compression.FileSystem") | Out-Null
New-Item -ItemType Directory -Force $extractDir | Out-Null

$zip = [System.IO.Compression.ZipFile]::OpenRead($apkFullPath)
try {
    $classesEntry = $zip.Entries | Where-Object { $_.FullName -eq "classes.dex" } | Select-Object -First 1
    if (!$classesEntry) {
        throw "classes.dex not found in APK."
    }
    $classesDex = Join-Path $extractDir "classes.dex"
    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($classesEntry, $classesDex, $true)

    $gojniEntries = $zip.Entries | Where-Object { $_.FullName -match "^lib/[^/]+/libgojni\.so$" }
    if (!$gojniEntries) {
        throw "libgojni.so not found in APK."
    }

    foreach ($entry in $gojniEntries) {
        $target = Join-Path $extractDir $entry.FullName.Replace("/", [System.IO.Path]::DirectorySeparatorChar)
        New-Item -ItemType Directory -Force (Split-Path -Parent $target) | Out-Null
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
    }
} finally {
    $zip.Dispose()
}

$gojniLibs = Get-ChildItem -Path (Join-Path $extractDir "lib") -Filter "libgojni.so" -Recurse -ErrorAction SilentlyContinue

Validate-DexBindings $dexdump $classesDex (Join-Path $workFullPath "dexdump.txt")
Write-MobileStubSources $srcDir

New-Item -ItemType Directory -Force $classesDir | Out-Null
$javaFiles = Get-ChildItem -Path $srcDir -Filter "*.java" -Recurse | ForEach-Object { $_.FullName }
Invoke-Checked $javac (@("-g:none", "-source", "8", "-target", "8", "-cp", $androidJar, "-d", $classesDir) + $javaFiles)

New-Item -ItemType Directory -Force $aarDir | Out-Null
Write-TextFile (Join-Path $aarDir "AndroidManifest.xml") '<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="go.mobile.gojni" />'
Invoke-Checked $jar @("cf", (Join-Path $aarDir "classes.jar"), "-C", $classesDir, ".")

foreach ($lib in $gojniLibs) {
    $abi = Split-Path -Leaf $lib.DirectoryName
    $targetDir = Join-Path $aarDir "jni/$abi"
    New-Item -ItemType Directory -Force $targetDir | Out-Null
    Copy-Item -Force $lib.FullName (Join-Path $targetDir "libgojni.so")
    Write-Host "Added native library for ABI: $abi"
}

New-Item -ItemType Directory -Force (Split-Path -Parent $outputAarFullPath) | Out-Null
$tempAar = Join-Path $workFullPath "Mobile.aar"
Push-Location $aarDir
try {
    Invoke-Checked $jar @("cf", $tempAar, "AndroidManifest.xml", "classes.jar", "jni")
} finally {
    Pop-Location
}
Copy-Item -Force $tempAar $outputAarFullPath

Write-Host "Generated: $outputAarFullPath"

if ($VerifyBuild) {
    $flutterSdk = Read-LocalProperty (Join-Path $repoRoot "android/local.properties") "flutter.sdk"
    $flutterExe = if ($flutterSdk) { Join-Path $flutterSdk "bin/flutter.bat" } else { "flutter" }
    $env:ANDROID_HOME = $androidSdkPath
    $env:ANDROID_SDK_ROOT = $androidSdkPath
    Push-Location $repoRoot
    try {
        Invoke-Checked $flutterExe @("build", "apk", "--debug", "--target-platform", "android-arm64")
    } finally {
        Pop-Location
    }
}

if (!$KeepWorkDir) {
    Remove-Item -Recurse -Force $workFullPath -ErrorAction SilentlyContinue
} else {
    Write-Host "Kept work dir: $workFullPath"
}
