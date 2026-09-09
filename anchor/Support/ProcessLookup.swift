import Darwin
import Foundation

struct TTYProcess {
    let pid: pid_t
    let name: String
    let parent: pid_t
    let group: pid_t
    let foregroundGroup: pid_t
    let workingDirectory: String?
    let workingDirectoryError: Int32
}

// read-only process inspection used to turn a terminal tty into a directory
// nothing here reads history, environments, or file contents
enum ProcessLookup {
    nonisolated static func deviceID(ofTTY path: String) -> dev_t? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return info.st_rdev
    }

    nonisolated static func processes(onTTY path: String) -> [TTYProcess] {
        guard let device = deviceID(ofTTY: path) else { return [] }
        let wanted = UInt32(bitPattern: Int32(truncatingIfNeeded: device))
        let uid = getuid()
        var found: [TTYProcess] = []
        for pid in allPIDs() {
            guard let info = bsdInfo(pid), info.pbi_uid == uid, info.e_tdev == wanted else { continue }
            let (dir, error) = workingDirectory(pid)
            found.append(TTYProcess(pid: pid,
                                    name: processName(info),
                                    parent: pid_t(bitPattern: info.pbi_ppid),
                                    group: pid_t(bitPattern: info.pbi_pgid),
                                    foregroundGroup: pid_t(info.e_tpgid),
                                    workingDirectory: dir,
                                    workingDirectoryError: error))
        }
        return found.sorted { $0.pid > $1.pid }
    }

    // the foreground process group leader is what the tab is actually showing
    // at an idle prompt that is the shell itself, otherwise it is the running job
    nonisolated static func foregroundDirectory(onTTY path: String) -> (directory: String?, pid: pid_t?, method: String) {
        let procs = processes(onTTY: path)
        guard !procs.isEmpty else { return (nil, nil, "no process found on tty") }
        if let leader = procs.first(where: { $0.pid == $0.foregroundGroup }), let dir = leader.workingDirectory {
            return (dir, leader.pid, "foreground process group leader")
        }
        // fall back to the tty root process whose parent is off the tty
        let onTTY = Set(procs.map(\.pid))
        if let root = procs.filter({ !onTTY.contains($0.parent) }).min(by: { $0.pid < $1.pid }),
           let dir = root.workingDirectory {
            return (dir, root.pid, "tty session root process")
        }
        return (nil, nil, "no readable working directory on tty")
    }

    nonisolated static func allPIDs() -> [pid_t] {
        let probe = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard probe > 0 else { return [] }
        let capacity = Int(probe) / MemoryLayout<pid_t>.size + 64
        var buffer = [pid_t](repeating: 0, count: capacity)
        let used = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &buffer, Int32(capacity * MemoryLayout<pid_t>.size))
        guard used > 0 else { return [] }
        return Array(buffer.prefix(Int(used) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
    }

    nonisolated static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    nonisolated static func workingDirectory(_ pid: pid_t) -> (String?, Int32) {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        errno = 0
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return (nil, errno) }
        var path = info.pvi_cdir.vip_path
        let text = withUnsafeBytes(of: &path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return (text.isEmpty ? nil : text, 0)
    }

    nonisolated private static func processName(_ info: proc_bsdinfo) -> String {
        var comm = info.pbi_comm
        return withUnsafeBytes(of: &comm) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }
}
