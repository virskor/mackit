import Foundation
import Testing

@testable import Mackit

/// The services JSON parser.
///
/// The payload shape comes from brew's own `FormulaWrapper#to_hash` (read in
/// the brew 7.x source): an array of hashes with `name`, `service_name`,
/// `running`, `status`, `pid`, `user`, `file`, `registered` and friends. A
/// machine with no services prints `[]` and cannot produce a sample, so the
/// fixtures here mirror the source's field-for-field shape.
struct HomebrewServicesTests {
    @Test func parsesRunningAndStoppedServices() throws {
        let json = """
        [
          {"name":"mysql","service_name":"homebrew.mxcl.mysql","running":true,"loaded":true,"schedulable":false,"pid":1234,"exit_code":0,"user":"weizhang","status":"started","file":"/Users/weizhang/Library/LaunchAgents/homebrew.mxcl.mysql.plist","registered":true,"loaded_file":"/Users/weizhang/Library/LaunchAgents/homebrew.mxcl.mysql.plist"},
          {"name":"postgresql@16","service_name":"homebrew.mxcl.postgresql@16","running":false,"loaded":true,"schedulable":false,"pid":null,"exit_code":0,"user":"weizhang","status":"stopped","file":"/Users/weizhang/Library/LaunchAgents/homebrew.mxcl.postgresql@16.plist","registered":true}
        ]
        """
        let services = HomebrewServices.parse(json)
        #expect(services.count == 2)

        let mysql = try #require(services.first)
        #expect(mysql.name == "mysql")
        #expect(mysql.serviceName == "homebrew.mxcl.mysql")
        #expect(mysql.isRunning)
        #expect(mysql.status == "started")
        #expect(mysql.pid == 1234)
        #expect(mysql.user == "weizhang")
        #expect(mysql.registered)

        let postgres = try #require(services.last)
        #expect(postgres.name == "postgresql@16")
        #expect(!postgres.isRunning)
        #expect(postgres.status == "stopped")
        #expect(postgres.pid == nil)
    }

    @Test func emptyArrayIsAnAnswerNotAFailure() {
        // brew prints `[]` when nothing is installed — the page shows its
        // empty state, not an error.
        #expect(HomebrewServices.parse("[]").isEmpty)
    }

    @Test func undecodablePayloadYieldsNoServices() {
        #expect(HomebrewServices.parse("Error: something").isEmpty)
        #expect(HomebrewServices.parse("").isEmpty)
    }

    @Test func entriesWithoutANameAreSkipped() {
        // A future field change must drop one entry, not blank the list.
        let json = """
        [{"service_name":"homebrew.mxcl.ghost","running":true,"status":"started"}]
        """
        #expect(HomebrewServices.parse(json).isEmpty)
    }

    @Test func missingOptionalFieldsDecodeToDefaults() throws {
        let json = """
        [{"name":"redis"}]
        """
        let service = try #require(HomebrewServices.parse(json).first)
        #expect(service.serviceName == nil)
        #expect(service.status == "none")
        #expect(!service.isRunning)
        #expect(!service.registered)
    }
}
