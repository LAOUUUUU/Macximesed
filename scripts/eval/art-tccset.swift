// Grants Screen Recording to Terminal through TCC.framework's private TCCAccessSetForBundleId, the way tools like
// tccplus do, so tccd itself makes the change and eslogger's tcc_modify should see it. For scripts/eval/art.sh on a
// throwaway runner only.
import Foundation

typealias SetForBundleId = @convention(c) (CFString, CFString, Bool) -> Bool
guard let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_NOW) else {
    print("TCC.framework not loaded")
    exit(0)
}
guard let sym = dlsym(tcc, "TCCAccessSetForBundleId") else {
    print("TCCAccessSetForBundleId not found")
    exit(0)
}
let set = unsafeBitCast(sym, to: SetForBundleId.self)
let ok = set("kTCCServiceScreenCapture" as CFString, "com.apple.Terminal" as CFString, true)
print("TCCAccessSetForBundleId(ScreenCapture, com.apple.Terminal, true) as uid \(getuid()): \(ok)")
