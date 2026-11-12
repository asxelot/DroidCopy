import Foundation
import Testing
@testable import DroidCopyCore

@Suite struct ParseTests {
    @Test func devicesSkipsHeaderAndDaemonLines() {
        let out = """
        * daemon not running; starting now at tcp:5037
        * daemon started successfully
        List of devices attached
        8b100894               device usb:18874368X product:kona model:Retroid_Pocket_5 device:kona transport_id:1
        emulator-5554          unauthorized usb:1-1 transport_id:2

        """
        let devices = Parse.devices(out)
        #expect(devices.count == 2)
        #expect(devices[0] == DeviceInfo(serial: "8b100894", state: "device", model: "Retroid_Pocket_5"))
        #expect(devices[0].isReady)
        #expect(devices[0].displayName == "Retroid Pocket 5")
        #expect(devices[1].state == "unauthorized")
        #expect(!devices[1].isReady)
        #expect(devices[1].displayName == "emulator-5554")
    }

    @Test func listingParsesTypesSizesAndPathsWithSpecialCharacters() {
        let out = """
        directory/4096/1700000000//storage/7EF7-7423/ROMs
        regular file/14674251327/1558826160//storage/7EF7-7423/DOOM (2016) [0100416004C00000][USA].nsp
        regular file/10/1700000000//storage/7EF7-7423/.hidden
        regular file/5/1700000000//storage/7EF7-7423/it's a/b.txt
        garbage line
        """
        let items = Parse.listing(out)
        #expect(items.map(\.name) == ["ROMs", "b.txt", "DOOM (2016) [0100416004C00000][USA].nsp"])
        #expect(items[0].isDirectory)
        #expect(items[2].size == 14_674_251_327)
        #expect(items[2].path == "/storage/7EF7-7423/DOOM (2016) [0100416004C00000][USA].nsp")
        #expect(items[2].modified == Date(timeIntervalSince1970: 1_558_826_160))

        let withHidden = Parse.listing(out, showHidden: true)
        #expect(withHidden.contains { $0.name == ".hidden" })
    }

    @Test func dfAvailable() {
        let out = """
        Filesystem     1K-blocks      Used Available Use% Mounted on
        /dev/fuse      249862016 234529152  15332864  94% /storage/7EF7-7423
        """
        #expect(Parse.dfAvailableBytes(out) == Int64(15_332_864) * 1024)
        #expect(Parse.dfAvailableBytes("") == nil)
    }

    @Test func sizeOutput() {
        #expect(Parse.size("F 14674251327\n") == 14_674_251_327)
        #expect(Parse.size("D 2048\n") == Int64(2048) * 1024)
        #expect(Parse.size("") == nil)
        #expect(Parse.size("F \n") == nil)
    }

    @Test func storagesPutsInternalFirstAndNamesCards() {
        let roots = Parse.storages("7EF7-7423\nemulated\nself\n")
        #expect(roots == [
            StorageRoot(name: "Internal", path: "/storage/emulated/0"),
            StorageRoot(name: "SD card", path: "/storage/7EF7-7423"),
        ])
        let two = Parse.storages("AAAA-1111\nBBBB-2222\nemulated\nself\n")
        #expect(two.map(\.name) == ["Internal", "SD card 1", "SD card 2"])
    }

    @Test func shellQuoteSurvivesSingleQuotes() {
        #expect(Parse.shellQuote("it's [x] $y") == "'it'\\''s [x] $y'")
    }

    @Test func joinPaths() {
        #expect(Parse.join("/storage/x", "a") == "/storage/x/a")
        #expect(Parse.join("/", "a") == "/a")
    }
}
