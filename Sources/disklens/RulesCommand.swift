import CryptoKit
import DiskLensCore
import Foundation

/// `disklens rules …`: makes the signing key and signs rule libraries for publishing.
enum RulesCommand {
    static let usage = """
        usage: disklens rules keygen <key-file>
               disklens rules sign <key-file> <cleanup-rules.json> <output-folder>

          keygen  makes a new signing key, saves it to <key-file> (readable only by you)
                  and prints the public key to build into the app
          sign    checks the rules, then writes them with their signature to <output-folder>
        """

    static func run(_ args: [String]) -> Int32 {
        switch args.first {
        case "keygen" where args.count == 2: return keygen(at: args[1])
        case "sign" where args.count == 4: return sign(keyFile: args[1], rules: args[2], output: args[3])
        default:
            print(usage)
            return 2
        }
    }

    private static func keygen(at path: String) -> Int32 {
        guard !FileManager.default.fileExists(atPath: path) else {
            fail("\(path) already exists; not replacing a signing key")
            return 1
        }
        let key = Curve25519.Signing.PrivateKey()
        let created = FileManager.default.createFile(atPath: path, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                                     attributes: [.posixPermissions: 0o600])
        guard created else {
            fail("could not write \(path)")
            return 1
        }
        print("Saved the private key to \(path). Keep a backup; without it no new rules can be published.")
        print("Public key (SignedRules.publicKeyBase64):")
        print(key.publicKey.rawRepresentation.base64EncodedString())
        return 0
    }

    /// `disklens sign <key-file> <file>`: writes `<file>.sig`, as release archives carry for the updater.
    static func signFile(_ args: [String]) -> Int32 {
        guard args.count == 2 else {
            print("usage: disklens sign <key-file> <file>   (writes <file>.sig)")
            return 2
        }
        do {
            guard let key = try loadKey(args[0]) else { return 1 }
            let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
            let signature = try SignedRules.sign(data, privateKey: key)
            try Data((signature + "\n").utf8).write(to: URL(fileURLWithPath: args[1] + ".sig"), options: .atomic)
            if key.publicKey.rawRepresentation.base64EncodedString() != SignedRules.publicKeyBase64 {
                fail("warning: the app's built-in public key does not match this signing key")
                return 1
            }
            print("Wrote \(args[1]).sig")
            return 0
        } catch {
            fail(String(describing: error))
            return 1
        }
    }

    private static func loadKey(_ keyFile: String) throws -> Curve25519.Signing.PrivateKey? {
        let keyText = try String(contentsOfFile: keyFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = Data(base64Encoded: keyText) else {
            fail("\(keyFile) is not a key made by `disklens rules keygen`")
            return nil
        }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    }

    private static func sign(keyFile: String, rules: String, output: String) -> Int32 {
        do {
            guard let key = try loadKey(keyFile) else { return 1 }
            let data = try Data(contentsOf: URL(fileURLWithPath: rules))
            let set = try CleanupRuleSet(data: data)
            let problems = RuleValidator.problems(in: set)
            guard problems.isEmpty else {
                fail("the rules do not pass the checks:\n  " + problems.joined(separator: "\n  "))
                return 1
            }
            let signature = Data(try SignedRules.sign(data, privateKey: key).utf8)
            let folder = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent("cleanup-rules.json"), options: .atomic)
            try signature.write(to: folder.appendingPathComponent("cleanup-rules.json.sig"), options: .atomic)
            print("Signed version \(set.version) (\(set.rules.count) rules) into \(output)")
            if (try? SignedRules.open(data, signature: signature)) == nil {
                fail("warning: the app's built-in public key does not match this signing key")
                return 1
            }
            return 0
        } catch {
            fail(String(describing: error))
            return 1
        }
    }

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
