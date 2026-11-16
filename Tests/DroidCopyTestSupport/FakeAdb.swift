import Foundation
import DroidCopyCore

/// A stand-in `adb` that runs "device" shell commands on this Mac, so `Adb` and `TransferQueue`
/// can be tested without a phone. `push`/`pull` become `cp -R`; toybox's `stat -c` is emulated
/// with BSD `stat -f`. Each instance lives in its own temp folder, so tests can run in parallel.
public struct FakeAdb {
    public enum CopyMode: String, Sendable {
        case normal
        /// Exits with an adb-style error after leaving a partial file behind.
        case fail
        /// Writes only part of the source and reports success.
        case truncate
        /// Writes a partial file, then blocks until killed.
        case hang
        /// Copies everything, then changes the first byte of the (first) file: same size, wrong content.
        case corrupt
    }

    public let root: URL
    public let adb: Adb

    /// - freeKB: when set, `df -k` on the "device" reports this many kilobytes available.
    public init(push: CopyMode = .normal, pull: CopyMode = .normal, freeKB: Int64? = nil,
         devicesOutput: String = "List of devices attached\nFAKE123  device product:x model:Fake_Phone\n") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("fakeadb-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

        try Self.write(bin.appendingPathComponent("stat"), """
            #!/bin/sh
            L=""; fmt=""
            while [ $# -gt 0 ]; do
              case "$1" in -L) L=-L; shift ;; -c) fmt="$2"; shift 2 ;; *) break ;; esac
            done
            for f in "$@"; do
              type=$(/usr/bin/stat $L -f %HT "$f" | tr 'A-Z' 'a-z') || exit 1
              bsd=$(printf '%s' "$fmt" | sed -e 's/%s/%z/g' -e 's/%Y/%m/g' -e 's/%n/%N/g' -e "s/%F/$type/g")
              /usr/bin/stat $L -f "$bsd" "$f"
            done
            """)
        try Self.write(bin.appendingPathComponent("ip"), """
            #!/bin/sh
            echo "10: wlan0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500"
            echo "    inet 192.168.1.50/24 brd 192.168.1.255 scope global wlan0"
            """)
        if let freeKB {
            try Self.write(bin.appendingPathComponent("df"), """
                #!/bin/sh
                echo "Filesystem 1K-blocks Used Available Use% Mounted on"
                echo "/dev/fake 1000000 0 \(freeKB) 0% /fake"
                """)
        }

        let copy: (CopyMode) -> String = { mode in
            switch mode {
            case .normal: return #"cp -RL "$1" "$2""#
            case .fail: return #"head -c 3 "$1" > "$2"; echo "adb: error: failed to copy: Broken pipe" >&2; exit 1"#
            case .truncate: return #"head -c 3 "$1" > "$2""#
            case .hang: return #"head -c 3 "$1" > "$2"; exec sleep 60"#
            case .corrupt: return #"cp -RL "$1" "$2"; f="$2"; [ -d "$f" ] && f=$(find "$f" -type f | sort | head -1); printf X | dd of="$f" bs=1 count=1 conv=notrunc 2>/dev/null"#
            }
        }
        let devicesFile = root.appendingPathComponent("devices.txt")
        try devicesOutput.write(to: devicesFile, atomically: true, encoding: .utf8)
        try Self.write(root.appendingPathComponent("adb"), """
            #!/bin/sh
            [ "$1" = "-s" ] && shift 2
            cmd="$1"; shift
            do_push() { \(copy(push)); }
            do_pull() { \(copy(pull)); }
            case "$cmd" in
              devices) cat '\(devicesFile.path)' ;;
              shell) PATH='\(bin.path)':"$PATH" exec /bin/sh -c "$1" ;;
              push) do_push "$1" "$2" ;;
              pull) do_pull "$1" "$2" ;;
              connect)
                # Port 5555 (adb tcpip) connects; any other port only after pairing with its host,
                # like Wireless debugging.
                case "$1" in
                  *:5555) ;;
                  *) [ -e '\(root.path)'/paired-"${1%:*}" ] || { echo "failed to connect to '$1': Connection refused"; exit 0; } ;;
                esac
                grep -q "^$1 " '\(devicesFile.path)' && { echo "already connected to $1"; exit 0; }
                echo "$1  device product:x model:Fake_Phone" >> '\(devicesFile.path)'; echo "connected to $1" ;;
              disconnect) grep -v "^$1 " '\(devicesFile.path)' > '\(devicesFile.path).new'; mv '\(devicesFile.path).new' '\(devicesFile.path)'; echo "disconnected $1" ;;
              pair)
                # The pairing screen listens on port 37099.
                case "$1" in *:37099) ;; *) echo "Failed: Unable to start pairing client."; exit 1 ;; esac
                [ "$2" = "123456" ] && touch '\(root.path)'/paired-"${1%:*}" && echo "Successfully paired to $1 [guid=adb-FAKE]" || { echo "Failed: Wrong password or connection was dropped."; exit 1; } ;;
              tcpip) echo "restarting in TCP mode port: $1"; touch '\(root.path)'/tcpip-"$1" ;;
              install)
                [ "$1" = "-r" ] && shift
                case "$1" in
                  *bad*) echo "Performing Streamed Install"; echo "adb: failed to install $1: Failure [INSTALL_FAILED_INVALID_APK: not an apk]" >&2; exit 1 ;;
                  *slow*) exec sleep 60 ;;
                esac
                mkdir -p '\(root.path)/installed' && cp "$1" '\(root.path)/installed/' && echo "Performing Streamed Install" && echo Success ;;
              *) echo "fake adb: unknown command $cmd" >&2; exit 1 ;;
            esac
            """)
        adb = Adb(path: root.appendingPathComponent("adb").path)
    }

    /// A scratch folder that plays the "device" side.
    public func deviceDir(_ name: String = "device") throws -> String {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    /// A scratch folder that plays the Mac side.
    public func macDir(_ name: String = "mac") throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Where the fake `adb install` puts the .apk files it "installed".
    public var installedDir: URL { root.appendingPathComponent("installed") }

    public func cleanUp() { try? FileManager.default.removeItem(at: root) }

    private static func write(_ url: URL, _ script: String) throws {
        try (script + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

public func writeFile(_ path: String, _ contents: String) throws {
    try contents.write(toFile: path, atomically: true, encoding: .utf8)
}

public func readFile(_ path: String) -> String? {
    try? String(contentsOfFile: path, encoding: .utf8)
}

/// Waits until the queue has nothing waiting or running.
@MainActor
public func waitIdle(_ q: TransferQueue, seconds: Double = 20) async {
    let deadline = Date().addingTimeInterval(seconds)
    while q.hasActive && Date() < deadline {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

/// Waits until `condition` holds or the timeout passes.
@MainActor
public func waitUntil(seconds: Double = 10, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() && Date() < deadline {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}
