import AppKit

// MARK: - Pairing Confirm Result (Layer 2a)

enum PairingConfirmResult {
    case trust
    case decline
}

// MARK: - AppDelegate extension

extension AppDelegate {

    // Manual trigger path (Settings button): always runs regardless of config state.
    func startSSHKeySetup() {
        let config = ConfigStore.shared.config
        guard config.role == "main" else { return }
        guard !config.destinationIP.isEmpty, !config.username.isEmpty else {
            NSLog("[Sync] SSH setup aborted — IP or username empty"); return
        }
        runKeySetup()
    }

    private func runKeySetup() {
        let keyPath = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/id_ed25519")
        if !FileManager.default.fileExists(atPath: keyPath) {
            generateKey { [weak self] ok in
                guard ok else { NSLog("[Sync] key generation failed"); return }
                self?.promptAndConnect()
            }
        } else {
            promptAndConnect()
        }
    }

    private func generateKey(completion: @escaping (Bool) -> Void) {
        let keyPath = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/id_ed25519")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        proc.arguments = ["-t", "ed25519", "-f", keyPath, "-N", "", "-q"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError  = FileHandle.nullDevice
        proc.terminationHandler = { p in
            DispatchQueue.main.async { completion(p.terminationStatus == 0) }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try proc.run()
            } catch {
                NSLog("[Sync] ssh-keygen launch failed: %@", error.localizedDescription)
                DispatchQueue.main.async { [weak self] in
                    self?.showWizardLaunchFailureAlert()
                    completion(false)
                }
            }
        }
    }

    private func showWizardLaunchFailureAlert() {
        let alert = NSAlert()
        alert.messageText     = "Could Not Start Setup"
        alert.informativeText = "A required system tool failed to launch. Please try again."
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }

    private func promptAndConnect() {
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)

        let config = ConfigStore.shared.config

        let alert = NSAlert()
        alert.messageText     = "Authorise Backup Mac"
        alert.informativeText = "Enter the password for \(config.username)@\(config.destinationIP) once to set up the secure connection. Your password will not be stored."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let password = input.stringValue
        guard !password.isEmpty else { return }

        copyKey(password: password) { [weak self] ok in
            guard ok else { self?.showFailureAndMaybeRetry(); return }
            self?.verifyConnection { [weak self] verified in
                if verified {
                    var c = ConfigStore.shared.config
                    c.sshKeysConfigured           = true
                    c.sshKeyConfiguredForIP       = c.destinationIP
                    c.sshKeyConfiguredForUsername = c.username
                    ConfigStore.shared.config     = c
                    self?.showSuccessAlert()
                } else {
                    self?.showFailureAndMaybeRetry()
                }
            }
        }
    }

    private func copyKey(password: String, completion: @escaping (Bool) -> Void) {
        let pubKeyPath = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/id_ed25519.pub")

        guard let pubKey = try? String(contentsOfFile: pubKeyPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !pubKey.isEmpty else {
            DispatchQueue.main.async { completion(false) }
            return
        }

        // Write a temp askpass script — SSH calls this instead of prompting a TTY.
        // Single-quote the password; escape any literal single quotes inside it.
        let escapedPassword = password.replacingOccurrences(of: "'", with: "'\\''")
        let tmpScript = NSTemporaryDirectory() + "sync_askpass_\(UUID().uuidString).sh"
        do {
            try "#!/bin/sh\necho '\(escapedPassword)'\n"
                .write(toFile: tmpScript, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmpScript)
        } catch {
            try? FileManager.default.removeItem(atPath: tmpScript)
            DispatchQueue.main.async { completion(false) }
            return
        }

        let config = ConfigStore.shared.config
        // Single-quote the pubkey in the remote command; ed25519 keys never contain single quotes.
        let remoteCmd = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '\(pubKey)' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"

        var env = ProcessInfo.processInfo.environment
        env["SSH_ASKPASS"]         = tmpScript
        env["SSH_ASKPASS_REQUIRE"] = "force"   // OpenSSH 8.4+ — bypasses TTY check
        env["DISPLAY"]             = ":0"      // fallback for older OpenSSH builds

        let proc = Process()
        proc.environment   = env
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = [
            "-o", "StrictHostKeyChecking=no",
            "-o", "PasswordAuthentication=yes",
            "-o", "PreferredAuthentications=password",
            "\(config.username)@\(config.destinationIP)",
            remoteCmd
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError  = FileHandle.nullDevice
        proc.terminationHandler = { p in
            try? FileManager.default.removeItem(atPath: tmpScript)
            DispatchQueue.main.async { completion(p.terminationStatus == 0) }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try proc.run()
            } catch {
                NSLog("[Sync] ssh copyKey launch failed: %@", error.localizedDescription)
                // FIX 7: terminationHandler never fires on launch failure, so the askpass
                // script — which holds the password in plaintext — must be removed here.
                try? FileManager.default.removeItem(atPath: tmpScript)
                DispatchQueue.main.async { [weak self] in
                    self?.showWizardLaunchFailureAlert()
                    completion(false)
                }
            }
        }
    }

    private func verifyConnection(completion: @escaping (Bool) -> Void) {
        let config = ConfigStore.shared.config
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-o", "StrictHostKeyChecking=no",
            "\(config.username)@\(config.destinationIP)",
            "exit"
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError  = FileHandle.nullDevice
        proc.terminationHandler = { p in
            DispatchQueue.main.async { completion(p.terminationStatus == 0) }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try proc.run()
            } catch {
                NSLog("[Sync] ssh verifyConnection launch failed: %@", error.localizedDescription)
                DispatchQueue.main.async { [weak self] in
                    self?.showWizardLaunchFailureAlert()
                    completion(false)
                }
            }
        }
    }

    private func showSuccessAlert() {
        let alert = NSAlert()
        alert.messageText     = "Secure Connection Established"
        alert.informativeText = "You will never need to enter a password again."
        alert.addButton(withTitle: "Done")
        _ = alert.runModal()
    }

    private func showFailureAndMaybeRetry() {
        let alert = NSAlert()
        alert.messageText     = "Could Not Connect"
        alert.informativeText = "Check the IP address and password and try again."
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            promptAndConnect()
        }
    }

    // MARK: - Pairing Confirm Dialog (Layer 2a)

    /// Shows the "Trust this Mac" confirmation dialog for incoming pairing requests.
    /// Called on BACKUP when a Main requests pairing via Bonjour.
    /// - Parameters:
    ///   - peerName: The name of the Main Mac requesting pairing
    ///   - peerFingerprint: The SHA256 fingerprint of the Main's public key
    ///   - completion: Called with the user's choice (.trust or .decline)
    func showPairingConfirmDialog(peerName: String, peerFingerprint: String,
                                   completion: @escaping (PairingConfirmResult) -> Void) {
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Pairing Request"
        alert.informativeText = """
            "\(peerName)" wants to sync files to this Mac.

            Fingerprint:
            \(peerFingerprint)

            Verify this fingerprint matches the Main Mac's Settings to ensure a secure connection.
            """
        alert.addButton(withTitle: "Trust")
        alert.addButton(withTitle: "Decline")

        let response = alert.runModal()
        completion(response == .alertFirstButtonReturn ? .trust : .decline)
    }
}
