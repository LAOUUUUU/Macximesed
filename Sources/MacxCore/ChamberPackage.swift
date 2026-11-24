import Foundation

/// Detonation chamber, phase 2: the scripts inside an installer package, run in the chamber the way Installer
/// runs them (research/detonation-chamber/PHASE2.md). The package is only expanded on the Mac, never installed.
public struct PackageScript: Sendable, Equatable {
    public enum Phase: String, Sendable, Equatable { case preinstall, postinstall }
    public var phase: Phase
    /// Which component package it belongs to ("" for a flat package's own Scripts).
    public var component: String
    public var url: URL

    /// Installer's arguments: the package, the destination and the target volume.
    public static func arguments(packageName: String) -> [String] { ["/tmp/\(packageName)", "/Applications", "/"] }
}

public enum ChamberPackage {
    /// Scripts in a folder made by `pkgutil --expand`: `Scripts/` of a flat component package, or
    /// `<component>.pkg/Scripts/` of each component in a product archive.
    public static func scripts(inExpanded root: URL) -> [PackageScript] {
        let fm = FileManager.default
        var out: [PackageScript] = []
        func collect(_ scripts: URL, component: String) {
            for phase in [PackageScript.Phase.preinstall, .postinstall] {
                let u = scripts.appendingPathComponent(phase.rawValue)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue {
                    out.append(PackageScript(phase: phase, component: component, url: u))
                }
            }
        }
        collect(root.appendingPathComponent("Scripts"), component: "")
        let children = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
        for name in children where name.hasSuffix(".pkg") {
            collect(root.appendingPathComponent(name).appendingPathComponent("Scripts"), component: name)
        }
        return out
    }

    /// `pkgutil --expand` into a new folder. Reads the archive only; nothing in it runs.
    public static func expand(_ pkg: URL, into dir: URL, runner: CommandRunner = ProcessRunner(timeout: 60)) throws {
        _ = try runner.run("/usr/sbin/pkgutil", ["--expand", pkg.path, dir.path])
    }
}
