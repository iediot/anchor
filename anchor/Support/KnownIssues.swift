// limitations the user has already met, stated in the interface rather than only in a report
enum KnownIssues {
    static let pycharm = "pycharm has crashed after being reopened by anchor on this mac. the cause is not established and anchor does not claim one. you can leave pycharm out of this operation and open it yourself"

    static func affectsPyCharm(bundleID: String?) -> Bool {
        bundleID == IntegrationKind.pycharm.bundleID
    }
}
