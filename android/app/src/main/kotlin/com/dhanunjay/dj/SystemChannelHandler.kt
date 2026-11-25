package com.dhanunjay.dj

import android.app.Activity
import android.app.ActivityManager
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Environment
import android.os.SystemClock
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Channel: com.dhanunjay.dj/system
 *
 * Android implementation of the SystemOps methods the Dart Core services call.
 * Every method returns a Map with {ok, message} (plus data) and never throws
 * across the channel — failures come back as {ok: false, message: ...}.
 *
 * Methods:
 * - openFile(path)          ACTION_VIEW with a FileProvider content:// URI.
 * - openFolder(path)        Tries the system file manager; falls back to a
 *                           plain message when no app handles the folder.
 * - openApp(name)           Launch by package name, else by installed app label.
 *                           Dart sends the name under 'exe' (plus 'args',
 *                           which Android launch intents ignore).
 * - deleteToTrash(path)     Android has no Recycle Bin: the file is MOVED to a
 *                           ".trash" folder inside DJ's own storage and the
 *                           original path is recorded, so it can be restored.
 *                           NEVER permanently deletes without that move first.
 * - restoreFromTrash(trashPath)  Moves a trashed file back to its original path.
 * - getSystemStats()        CPU % (two /proc/stat samples), cores, RAM, uptime.
 * - setStartAtLogin(bool)   NOT applicable on Android — always {ok: false}.
 * - getHomeDir()            DJ's home = app external files dir.
 * - getDownloadsDir()       Public Downloads folder path.
 * - pickFolder()            Storage Access Framework (ACTION_OPEN_DOCUMENT_TREE);
 *                           returns the tree URI + display name. SAF URIs are
 *                           not filesystem paths — the Dart side must store the
 *                           URI string, not treat it as a File path.
 */
class SystemChannelHandler(private val activity: MainActivity) :
    MethodChannel.MethodCallHandler {

    companion object {
        const val REQUEST_PICK_FOLDER = 1002
        private const val TRASH_DIR_NAME = ".trash"
        private const val TRASH_META_NAME = ".trash-meta.json"
    }

    private var pendingPickResult: MethodChannel.Result? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "openFile" -> openFile(call, result)
                "openFolder" -> openFolder(call, result)
                "openApp" -> openApp(call, result)
                "deleteToTrash" -> deleteToTrash(call, result)
                "restoreFromTrash" -> restoreFromTrash(call, result)
                "getSystemStats" -> getSystemStats(result)
                "setStartAtLogin" -> result.success(
                    mapOf(
                        "ok" to false,
                        "message" to "not available on Android"
                    )
                )
                "getHomeDir" -> getHomeDir(result)
                "getDownloadsDir" -> getDownloadsDir(result)
                "pickFolder" -> pickFolder(result)
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.success(mapOf("ok" to false, "message" to (e.message ?: "unknown error")))
        }
    }

    // ------------------------------------------------------------------ files

    private fun openFile(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
            ?: return result.success(mapOf("ok" to false, "message" to "no path given"))
        val file = File(path)
        if (!file.isFile) {
            return result.success(mapOf("ok" to false, "message" to "file not found: $path"))
        }
        val uri = FileProvider.getUriForFile(
            activity, "${activity.packageName}.fileprovider", file
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mimeTypeFor(file))
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        try {
            activity.startActivity(intent)
            result.success(mapOf("ok" to true, "message" to "Opened ${file.name}."))
        } catch (e: ActivityNotFoundException) {
            result.success(
                mapOf("ok" to false, "message" to "no app can open ${file.name}")
            )
        }
    }

    private fun openFolder(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
            ?: return result.success(mapOf("ok" to false, "message" to "no path given"))
        val dir = File(path)
        if (!dir.isDirectory) {
            return result.success(mapOf("ok" to false, "message" to "not a folder: $path"))
        }
        // 1. Try ACTION_VIEW on the folder via FileProvider (some OEM file
        //    managers handle a directory content:// URI).
        try {
            val uri = FileProvider.getUriForFile(
                activity, "${activity.packageName}.fileprovider", dir
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "resource/folder")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            if (intent.resolveActivity(activity.packageManager) != null) {
                activity.startActivity(intent)
                return result.success(mapOf("ok" to true, "message" to "Opened folder ${dir.name}."))
            }
        } catch (_: Exception) {
            // Fall through to the Files app.
        }
        // 2. Fall back to opening the system Files app (home view, not the
        //    exact folder — Android has no intent that opens an arbitrary
        //    filesystem path in a file manager).
        for (pkg in listOf("com.google.android.documentsui", "com.android.documentsui")) {
            val launch = activity.packageManager.getLaunchIntentForPackage(pkg)
            if (launch != null) {
                activity.startActivity(launch)
                return result.success(
                    mapOf(
                        "ok" to true,
                        "message" to "Opened the Files app — navigate to ${dir.name}."
                    )
                )
            }
        }
        result.success(
            mapOf(
                "ok" to false,
                "message" to "no file manager app found to open this folder"
            )
        )
    }

    private fun openApp(call: MethodCall, result: MethodChannel.Result) {
        val name = (call.argument<String>("exe")
            ?: call.argument<String>("packageName")
            ?: call.argument<String>("name")
            ?: call.argument<String>("appName")
            ?: "").trim()
        if (name.isEmpty()) {
            return result.success(mapOf("ok" to false, "message" to "no app name given"))
        }
        val pm = activity.packageManager
        // 1. Direct package name, e.g. com.google.android.apps.maps.
        pm.getLaunchIntentForPackage(name)?.let { intent ->
            activity.startActivity(intent)
            return result.success(mapOf("ok" to true, "message" to "Opened $name."))
        }
        // 2. Installed app label, e.g. "Chrome" / "chrome" / "maps".
        //    queryIntentActivities with MAIN/LAUNCHER is visible without
        //    QUERY_ALL_PACKAGES (see the <queries> block in the manifest).
        val launcherIntent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val apps = pm.queryIntentActivities(launcherIntent, 0)
        val match = apps.firstOrNull {
            it.loadLabel(pm).toString().equals(name, ignoreCase = true)
        } ?: apps.firstOrNull {
            it.loadLabel(pm).toString().contains(name, ignoreCase = true)
        }
        if (match != null) {
            val label = match.loadLabel(pm).toString()
            val intent = pm.getLaunchIntentForPackage(match.activityInfo.packageName)
            if (intent != null) {
                activity.startActivity(intent)
                return result.success(mapOf("ok" to true, "message" to "Opened $label."))
            }
        }
        result.success(
            mapOf(
                "ok" to false,
                "message" to "I could not find an app called '$name' on this phone."
            )
        )
    }

    // ------------------------------------------------------------------ trash
    // Android has no Recycle Bin. deleteToTrash MOVES the file into DJ's own
    // ".trash" folder and records the original path in .trash-meta.json, so
    // restoreFromTrash can put it back. Nothing is permanently deleted here.

    private fun trashDir(): File =
        File(activity.getExternalFilesDir(null), TRASH_DIR_NAME).apply { mkdirs() }

    private fun trashMetaFile(): File = File(trashDir(), TRASH_META_NAME)

    private fun readTrashMeta(): JSONObject {
        val f = trashMetaFile()
        return if (f.isFile) {
            try {
                JSONObject(f.readText())
            } catch (_: Exception) {
                JSONObject()
            }
        } else {
            JSONObject()
        }
    }

    private fun writeTrashMeta(meta: JSONObject) {
        trashMetaFile().writeText(meta.toString())
    }

    /** Free destination name in [dir]: name, then stem-1.ext, stem-2.ext, ... */
    private fun freeFile(dir: File, name: String): File {
        var candidate = File(dir, name)
        if (!candidate.exists()) return candidate
        val dot = name.lastIndexOf('.')
        val stem = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        var i = 1
        while (true) {
            candidate = File(dir, "$stem-$i$ext")
            if (!candidate.exists()) return candidate
            i++
        }
    }

    /** Move across volumes if needed: rename, else copy + delete original. */
    private fun moveFile(source: File, dest: File): Boolean {
        if (source.renameTo(dest)) return true
        return try {
            source.copyTo(dest, overwrite = false)
            if (source.delete()) true else {
                dest.delete()
                false
            }
        } catch (_: Exception) {
            if (dest.exists()) dest.delete()
            false
        }
    }

    private fun deleteToTrash(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
            ?: return result.success(mapOf("ok" to false, "message" to "no path given"))
        val file = File(path)
        if (!file.isFile) {
            return result.success(
                mapOf("ok" to false, "message" to "${file.name}: already gone.")
            )
        }
        val dest = freeFile(trashDir(), file.name)
        if (!moveFile(file, dest)) {
            return result.success(
                mapOf("ok" to false, "message" to "could not move ${file.name} to trash")
            )
        }
        val meta = readTrashMeta()
        meta.put(dest.name, file.absolutePath)
        writeTrashMeta(meta)
        result.success(
            mapOf(
                "ok" to true,
                "message" to "Moved ${file.name} to trash.",
                "trashPath" to dest.absolutePath
            )
        )
    }

    private fun restoreFromTrash(call: MethodCall, result: MethodChannel.Result) {
        val trashPath = call.argument<String>("trashPath")
            ?: call.argument<String>("path")
            ?: return result.success(mapOf("ok" to false, "message" to "no trash path given"))
        val trashed = File(trashPath)
        if (!trashed.isFile) {
            return result.success(
                mapOf("ok" to false, "message" to "nothing in trash at $trashPath")
            )
        }
        val meta = readTrashMeta()
        val originalPath = if (meta.has(trashed.name)) meta.getString(trashed.name) else null
        val original = originalPath?.let { File(it) }
        val dest = if (original != null) {
            original.parentFile?.mkdirs()
            freeFile(original.parentFile ?: trashDir(), original.name)
        } else {
            freeFile(trashDir(), trashed.name)
        }
        if (!moveFile(trashed, dest)) {
            return result.success(
                mapOf("ok" to false, "message" to "could not restore ${trashed.name}")
            )
        }
        if (meta.has(trashed.name)) {
            meta.remove(trashed.name)
            writeTrashMeta(meta)
        }
        result.success(
            mapOf(
                "ok" to true,
                "message" to "Restored ${dest.name}.",
                "path" to dest.absolutePath
            )
        )
    }

    // ------------------------------------------------------------------ stats

    /** CPU % needs two /proc/stat samples; run off the UI thread. */
    private fun getSystemStats(result: MethodChannel.Result) {
        Thread {
            val cpuPercent: Double? = readCpuPercent()
            val am = activity.getSystemService(Activity.ACTIVITY_SERVICE) as ActivityManager
            val memInfo = ActivityManager.MemoryInfo()
            am.getMemoryInfo(memInfo)
            val totalMb = (memInfo.totalMem / (1024 * 1024)).toDouble()
            val availMb = (memInfo.availMem / (1024 * 1024)).toDouble()
            val uptimeMs = SystemClock.elapsedRealtime()
            val stats = mutableMapOf<String, Any?>(
                "ok" to true,
                "cpuPercent" to cpuPercent,
                "cpuCores" to Runtime.getRuntime().availableProcessors(),
                // Byte keys match the Dart SystemStats model (totalMemBytes,
                // freeMemBytes, uptimeSeconds); the Mb keys are extra.
                "totalMemBytes" to memInfo.totalMem,
                "freeMemBytes" to memInfo.availMem,
                "ramUsedMb" to (totalMb - availMb),
                "ramTotalMb" to totalMb,
                "ramPercent" to if (totalMb > 0) (totalMb - availMb) / totalMb * 100.0 else null,
                "uptimeMs" to uptimeMs,
                "uptimeSeconds" to (uptimeMs / 1000),
                "uptime" to formatUptime(uptimeMs),
                "platform" to "Android ${android.os.Build.VERSION.RELEASE} (SDK ${android.os.Build.VERSION.SDK_INT})"
            )
            activity.runOnUiThread { result.success(stats) }
        }.start()
    }

    private fun readCpuTimes(): LongArray? {
        return try {
            RandomAccessFile("/proc/stat", "r").use { raf ->
                val line = raf.readLine() ?: return null
                if (!line.startsWith("cpu ")) return null
                val parts = line.trim().split("\\s+".toRegex()).drop(1)
                    .mapNotNull { it.toLongOrNull() }
                if (parts.size < 4) return null
                // user, nice, system, idle, iowait, irq, softirq, steal...
                val idle = parts[3] + if (parts.size > 4) parts[4] else 0L
                val total = parts.sum()
                longArrayOf(idle, total)
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun readCpuPercent(): Double? {
        val first = readCpuTimes() ?: return null
        try {
            Thread.sleep(300)
        } catch (_: InterruptedException) {
            return null
        }
        val second = readCpuTimes() ?: return null
        val idleDelta = (second[0] - first[0]).toDouble()
        val totalDelta = (second[1] - first[1]).toDouble()
        if (totalDelta <= 0) return null
        return ((1.0 - idleDelta / totalDelta) * 100.0)
    }

    private fun formatUptime(ms: Long): String {
        val totalSeconds = ms / 1000
        val days = totalSeconds / 86400
        val hours = (totalSeconds % 86400) / 3600
        val minutes = (totalSeconds % 3600) / 60
        val seconds = totalSeconds % 60
        return when {
            days > 0 -> "${days}d ${hours}h ${minutes}m"
            hours > 0 -> "${hours}h ${minutes}m"
            minutes > 0 -> "${minutes}m"
            else -> "${seconds}s"
        }
    }

    // ------------------------------------------------------------------ home

    private fun getHomeDir(result: MethodChannel.Result) {
        // DJ's home on Android: the app's external files dir (no permission
        // needed, survives reinstalls of the app data, visible in Files).
        val home = activity.getExternalFilesDir(null)?.absolutePath
            ?: activity.filesDir.absolutePath
        result.success(
            mapOf(
                "ok" to true,
                "homeDir" to home,
                "externalStorage" to Environment.getExternalStorageDirectory().absolutePath,
                "message" to "DJ home folder: $home"
            )
        )
    }

    private fun getDownloadsDir(result: MethodChannel.Result) {
        val downloads = Environment.getExternalStoragePublicDirectory(
            Environment.DIRECTORY_DOWNLOADS
        )?.absolutePath
            ?: File(
                Environment.getExternalStorageDirectory(),
                Environment.DIRECTORY_DOWNLOADS
            ).absolutePath
        result.success(
            mapOf(
                "ok" to true,
                "path" to downloads,
                "message" to "Downloads folder: $downloads"
            )
        )
    }

    // ------------------------------------------------------------------ SAF

    private fun pickFolder(result: MethodChannel.Result) {
        if (pendingPickResult != null) {
            return result.success(
                mapOf("ok" to false, "message" to "a folder picker is already open")
            )
        }
        pendingPickResult = result
        activity.registerActivityResultHandler(REQUEST_PICK_FOLDER) { resultCode, data ->
            val pending = pendingPickResult
            pendingPickResult = null
            if (pending == null) return@registerActivityResultHandler
            if (resultCode != Activity.RESULT_OK || data?.data == null) {
                pending.success(mapOf("ok" to false, "message" to "no folder picked"))
                return@registerActivityResultHandler
            }
            val uri: Uri = data.data!!
            try {
                activity.contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                )
            } catch (_: Exception) {
                // Permission persistence is best-effort; the URI still works
                // for this session.
            }
            val name = displayNameFor(uri) ?: uri.toString()
            pending.success(
                mapOf(
                    "ok" to true,
                    "uri" to uri.toString(),
                    // SAF tree URIs are not filesystem paths. The Dart side
                    // must store and reuse the URI string.
                    "path" to uri.toString(),
                    "name" to name,
                    "message" to "Picked folder: $name"
                )
            )
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
        activity.startActivityForResult(intent, REQUEST_PICK_FOLDER)
    }

    private fun displayNameFor(uri: Uri): String? {
        return try {
            activity.contentResolver.query(
                uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    cursor.getString(0)
                } else {
                    null
                }
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun mimeTypeFor(file: File): String {
        val ext = file.extension.lowercase(Locale.ROOT)
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "*/*"
    }

    @Suppress("UNUSED")
    private fun todayStamp(): String =
        SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date())
}
