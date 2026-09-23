package com.lantransfer.lan_transfer_client

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.SocketTimeoutException
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/**
 * 原生 UDP 发现，对齐 PC LANT_DISCOVER_v8。
 * 华为等机型上 Dart RawDatagramSocket 经常收不到包。
 */
class NativeDiscovery(
    private val context: Context,
    private val methodChannel: MethodChannel,
    private val eventChannel: EventChannel,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        private val MAGIC = "LANT_DISCOVER_v8".toByteArray(StandardCharsets.US_ASCII)
        private const val PORT = 5100
        private const val KIND_QUERY = 0
        private const val KIND_HERE = 1
        private const val BEACON_MS = 3000L
    }

    private val main = Handler(Looper.getMainLooper())
    private val running = AtomicBoolean(false)
    private var tcpPort: Int = 5000
    private var sock: DatagramSocket? = null
    private var worker: Thread? = null
    private var events: EventChannel.EventSink? = null
    private val localIps = HashSet<String>()
    private val bcasts = ArrayList<InetAddress>()

    fun attach() {
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        this.events = events
    }

    override fun onCancel(arguments: Any?) {
        this.events = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                val port = call.argument<Int>("tcpPort") ?: 5000
                try {
                    start(port)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("start_failed", e.message, null)
                }
            }
            "stop" -> {
                stop()
                result.success(null)
            }
            "setTcpPort" -> {
                tcpPort = call.argument<Int>("tcpPort") ?: tcpPort
                result.success(null)
            }
            "probe" -> {
                probe()
                result.success(null)
            }
            "isListening" -> result.success(running.get() && sock != null)
            else -> result.notImplemented()
        }
    }

    @Synchronized
    fun start(port: Int = tcpPort) {
        tcpPort = port
        if (running.get() && sock != null && !sock!!.isClosed) {
            try {
                probe()
            } catch (_: Exception) {
            }
            return
        }
        stopLocked()
        refreshNets()
        try {
            val s = try {
                DatagramSocket(null).apply {
                    reuseAddress = true
                    broadcast = true
                    soTimeout = 500
                    bind(InetSocketAddress(InetAddress.getByName("0.0.0.0"), PORT))
                }
            } catch (e1: Exception) {
                log("bind reuse fail ${e1.javaClass.simpleName}:${e1.message}")
                DatagramSocket(PORT).apply {
                    broadcast = true
                    soTimeout = 500
                }
            }
            sock = s
            running.set(true)
            worker = thread(name = "lant-discover", isDaemon = true) { loop(s) }
            try {
                probe()
            } catch (e: Exception) {
                log("probe fail ${e.javaClass.simpleName}:${e.message}")
            }
            log("bound :$PORT tcp=$tcpPort local=${s.localSocketAddress}")
        } catch (e: Exception) {
            running.set(false)
            sock = null
            log("start fail ${e.javaClass.simpleName}:${e.message}")
            throw e
        }
    }

    @Synchronized
    fun stop() {
        stopLocked()
    }

    private fun stopLocked() {
        running.set(false)
        try {
            sock?.close()
        } catch (_: Exception) {
        }
        sock = null
        worker = null
    }

    private fun log(msg: String) {
        try {
            File(context.filesDir, "discover.log").appendText("${System.currentTimeMillis()} $msg\n")
        } catch (_: Exception) {
        }
    }

    private fun probe() {
        sendAll(pack(KIND_HERE, tcpPort, hostname()))
        sendAll(pack(KIND_QUERY, tcpPort, hostname()))
    }

    private fun loop(s: DatagramSocket) {
        var nextBeacon = 0L
        val buf = ByteArray(2048)
        while (running.get()) {
            val now = System.currentTimeMillis()
            if (now >= nextBeacon) {
                refreshNets()
                sendAll(pack(KIND_HERE, tcpPort, hostname()))
                sendAll(pack(KIND_QUERY, tcpPort, hostname()))
                nextBeacon = now + BEACON_MS
            }
            try {
                val pkt = DatagramPacket(buf, buf.size)
                s.receive(pkt)
                val data = buf.copyOf(pkt.length)
                val from = pkt.address?.hostAddress ?: continue
                onPacket(data, from, pkt.port, s)
            } catch (_: SocketTimeoutException) {
            } catch (_: Exception) {
                if (!running.get()) break
            }
        }
    }

    private fun onPacket(data: ByteArray, fromIp: String, fromPort: Int, s: DatagramSocket) {
        val parsed = unpack(data) ?: return
        val mine = synchronized(this) { HashSet(localIps) }
        if (mine.contains(fromIp)) return
        val (kind, peerPort, name) = parsed
        val host = if (name.isEmpty()) fromIp else name
        if (kind == KIND_HERE || kind == KIND_QUERY) {
            emit(fromIp, host, if (peerPort in 1..65535) peerPort else 5000)
            log("rx $kind from $fromIp:$fromPort peerTcp=$peerPort $host")
        }
        if (kind == KIND_QUERY) {
            try {
                val payload = pack(KIND_HERE, tcpPort, hostname())
                val replyPort = if (fromPort in 1..65535) fromPort else PORT
                s.send(
                    DatagramPacket(
                        payload,
                        payload.size,
                        InetAddress.getByName(fromIp),
                        replyPort,
                    ),
                )
            } catch (e: Exception) {
                log("reply fail ${e.message}")
            }
        }
    }

    private fun emit(ip: String, name: String, port: Int) {
        main.post {
            events?.success(
                mapOf(
                    "ip" to ip,
                    "name" to name,
                    "tcpPort" to port,
                ),
            )
        }
    }

    private fun sendAll(payload: ByteArray) {
        val s = sock ?: return
        val dests = synchronized(this) { ArrayList(bcasts) }
        for (dest in dests) {
            try {
                s.send(DatagramPacket(payload, payload.size, dest, PORT))
            } catch (_: Exception) {
            }
        }
    }

    private fun refreshNets() {
        val nextLocal = HashSet<String>()
        nextLocal.add("127.0.0.1")
        val nextBcast = ArrayList<InetAddress>()
        try {
            nextBcast.add(InetAddress.getByName("255.255.255.255"))
        } catch (_: Exception) {
        }
        try {
            val en = NetworkInterface.getNetworkInterfaces() ?: return
            while (en.hasMoreElements()) {
                val nif = en.nextElement()
                if (!nif.isUp || nif.isLoopback) continue
                val addrs = nif.inetAddresses
                while (addrs.hasMoreElements()) {
                    val a = addrs.nextElement()
                    if (a.hostAddress?.contains(':') == true) continue
                    val ip = a.hostAddress ?: continue
                    nextLocal.add(ip)
                    val parts = ip.split('.')
                    if (parts.size == 4) {
                        try {
                            nextBcast.add(InetAddress.getByName("${parts[0]}.${parts[1]}.${parts[2]}.255"))
                        } catch (_: Exception) {
                        }
                    }
                }
            }
        } catch (_: Exception) {
        }
        synchronized(this) {
            localIps.clear()
            localIps.addAll(nextLocal)
            bcasts.clear()
            bcasts.addAll(nextBcast)
        }
    }

    private fun hostname(): String =
        try {
            InetAddress.getLocalHost().hostName?.takeIf { it.isNotBlank() } ?: "android"
        } catch (_: Exception) {
            "android"
        }

    private fun pack(kind: Int, tcpPort: Int, name: String): ByteArray {
        val nameB = name.toByteArray(StandardCharsets.UTF_8).let {
            if (it.size > 200) it.copyOf(200) else it
        }
        return ByteBuffer.allocate(MAGIC.size + 1 + 2 + nameB.size).apply {
            put(MAGIC)
            put((kind and 0xff).toByte())
            putShort((tcpPort and 0xffff).toShort())
            put(nameB)
        }.array()
    }

    private fun unpack(data: ByteArray): Triple<Int, Int, String>? {
        if (data.size < MAGIC.size + 3) return null
        for (i in MAGIC.indices) {
            if (data[i] != MAGIC[i]) return null
        }
        val o = MAGIC.size
        val kind = data[o].toInt() and 0xff
        val port = ((data[o + 1].toInt() and 0xff) shl 8) or (data[o + 2].toInt() and 0xff)
        val name = String(data, o + 3, data.size - o - 3, StandardCharsets.UTF_8).trim()
        return Triple(kind, port, name)
    }
}
