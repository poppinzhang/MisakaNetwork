package com.misakanetwork.last_order

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.system.Os
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/** Credentials and protocol payloads never enter intent extras or logcat. */
class EmbeddedBridge(private val context: Context) {
    private val main = Handler(Looper.getMainLooper())
    // Deployments may wait on independent SSH uploads. Resource extraction stays
    // serial below, and the Go PKI initializer holds an OS file lock.
    private val helper = Executors.newCachedThreadPool()
    private val runtime = Executors.newSingleThreadExecutor()
    private val resources = Executors.newSingleThreadExecutor()
    @Volatile private var closed = false

    private external fun nativeHandle(request: ByteArray, appRoot: ByteArray): ByteArray?

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "runtime" -> execute(runtime, result) {
                val request = request(call.arguments, 4 * 1024 * 1024)
                synchronized(Python::class.java) {
                    if (!Python.isStarted()) Python.start(AndroidPlatform(context))
                }
                Python.getInstance().getModule("android_bridge")
                    .callAttr("invoke", request, context.cacheDir.absolutePath).toString()
            }
            "helper" -> execute(helper, result) {
                val request = request(call.arguments, 1024 * 1024)
                System.loadLibrary("misaka_mobile")
                val response = nativeHandle(request.toByteArray(Charsets.UTF_8), context.dataDir.canonicalPath.toByteArray(Charsets.UTF_8))
                    ?: throw IllegalStateException()
                response.toString(Charsets.UTF_8)
            }
            "resources" -> execute(resources, result) { extractBundles().absolutePath }
            "protectFile" -> execute(resources, result) {
                val path = call.argument<String>("path") ?: throw IllegalArgumentException()
                val mode = when (call.argument<String>("mode")) {
                    "600" -> 384
                    "700" -> 448
                    else -> throw IllegalArgumentException()
                }
                val file = File(path)
                val root = context.dataDir.canonicalPath + File.separator
                require(file.isAbsolute && file.canonicalPath.startsWith(root))
                require(file.exists() && !java.nio.file.Files.isSymbolicLink(file.toPath()))
                Os.chmod(file.canonicalPath, mode)
                true
            }
            else -> result.notImplemented()
        }
    }

    private fun request(value: Any?, max: Int): String {
        require(value is String && value.isNotEmpty() && value.toByteArray(Charsets.UTF_8).size <= max)
        return value
    }

    private fun execute(executor: ExecutorService, result: MethodChannel.Result, work: () -> Any) {
        if (closed) {
            result.error("unavailable", "本地服务已关闭", null)
            return
        }
        executor.execute {
            try {
                val value = work()
                main.post { if (!closed) result.success(value) }
            } catch (_: Exception) {
                main.post { if (!closed) result.error("embedded_error", "本地操作失败，请检查网络、文件权限和安装包完整性", null) }
            } catch (_: LinkageError) {
                main.post { if (!closed) result.error("runtime_unavailable", "内置运行时不完整，请重新安装此版本", null) }
            }
        }
    }

    private fun extractBundles(): File {
        val root = File(context.filesDir, "misaka-${BuildConfig.VERSION_NAME}")
        val destination = File(root, "bundles")
        val required = listOf("linux-amd64", "linux-arm64", "macos-amd64", "macos-arm64", "windows-amd64").map { "$it.tar.gz" }
        if (File(root, ".complete").isFile && required.all { File(destination, it).isFile }) return root
        val temporary = File(context.filesDir, "misaka-${BuildConfig.VERSION_NAME}.pending")
        if (temporary.exists()) check(temporary.deleteRecursively())
        check(File(temporary, "bundles").mkdirs())
        Os.chmod(temporary.absolutePath, 448)
        try {
            for (name in required) {
                val target = File(temporary, "bundles/$name")
                context.assets.open("bundles/${name.removeSuffix(".tar.gz")}.bundle").use { input -> target.outputStream().use { input.copyTo(it) } }
                check(target.length() > 0)
                Os.chmod(target.absolutePath, 384)
            }
            File(temporary, ".complete").writeText(BuildConfig.VERSION_NAME)
            if (root.exists()) check(root.deleteRecursively())
            check(temporary.renameTo(root))
        } finally {
            if (temporary.exists()) temporary.deleteRecursively()
        }
        return root
    }

    fun close() {
        closed = true
        // Let in-flight calls finish cleanup; interruption cannot safely abort
        // the embedded Python interpreter. Results are detached from the UI.
        helper.shutdown()
        runtime.shutdown()
        resources.shutdown()
    }
}
