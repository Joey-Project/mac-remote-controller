import SwiftUI
import UIKit
import AppleCore
import Foundation
import Network

extension RemoteModel {
    func startBluetoothConnection(to mac: PairedMac, attempt: UUID) {
        connectionSummary = "Connecting over Bluetooth LE…"
        let name = DeviceName.bounded(UIDevice.current.name)
        do {
            let peer = try IOSBLEPeer(mac: mac, deviceName: name)
            self.peer = peer
            peer.onStatus = { [weak self] in self?.connectionSummary = $0 }
            peer.onReady = { [weak self] in
                guard let self, self.attemptID == attempt else { return }
                self.connectionSummary = "Authenticating paired Mac…"
            }
            peer.onMessage = { [weak self] in self?.receive($0) }
            peer.onClose = { [weak self] in self?.handleClose($0) }
            monitorConnection()
            peer.start()
        } catch {
            handleClose("Could not start Bluetooth: \(error.localizedDescription)")
        }
    }

    func startBenchmark() {
        guard isConnected, supportsRoundTripProbe, let target = candidate else { return }
        guard benchmarkRequestTracker.canBegin else {
            errorMessage = "Reconnect before running another benchmark to clear retired probes."
            return
        }
        benchmarkTargetID = target.serviceName
        benchmark = RTTBenchmarkAccumulator(transport: selectedTransport.rawValue)
        benchmarkRunning = true
        benchmarkProgress = 0
        benchmarkResultText = nil
        sendNextBenchmarkProbe()
    }

    func cancelBenchmark() {
        guard benchmarkRunning else { return }
        benchmarkTimeout?.invalidate()
        benchmarkTimeout = nil
        guard benchmarkRequestTracker.retireActive() else {
            peer?.close()
            return
        }
        benchmarkRequest = nil
        benchmark?.cancel()
        finishBenchmark()
    }

    func advanceBenchmark() {
        guard benchmarkRunning else { return }
        if benchmark?.isComplete == true {
            finishBenchmark()
        } else if !benchmarkRequestTracker.canBegin {
            benchmark?.cancel()
            errorMessage = "Reconnect before running another benchmark to clear retired probes."
            finishBenchmark()
        } else {
            sendNextBenchmarkProbe()
        }
    }

    func updateBenchmarkGroupProgress() {
        guard let benchmark else { benchmarkGroupProgress = ""; return }
        benchmarkGroupProgress =
            "Group \(benchmark.currentGroup) · sample \(benchmark.currentSampleInGroup)"
    }

    private func sendNextBenchmarkProbe() {
        guard benchmarkRunning, let connectionID, let peer else { return }
        sequence &+= 1
        let id = UUID().uuidString
        let sent = DispatchTime.now().uptimeNanoseconds
        guard benchmarkRequestTracker.begin(id: id, sequence: sequence) else {
            peer.close()
            return
        }
        benchmarkRequest = BenchmarkPendingProbe(id: id, sequence: sequence, sentNanoseconds: sent)
        peer.send(
            WireMessage(
                type: .ping, connectionID: connectionID, requestID: id, sequence: sequence))
        benchmarkTimeout?.invalidate()
        benchmarkTimeout = Timer.scheduledTimer(
            withTimeInterval: 2, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.benchmarkRequest?.id == id else { return }
                guard self.benchmarkRequestTracker.retireActive() else {
                    self.peer?.close()
                    return
                }
                self.benchmarkRequest = nil
                self.benchmark?.record(roundTripNanoseconds: nil)
                self.benchmarkProgress = self.benchmark?.progress ?? 0
                self.updateBenchmarkGroupProgress()
                self.advanceBenchmark()
            }
        }
        updateBenchmarkGroupProgress()
    }

    private func finishBenchmark() {
        guard let report = benchmark?.report(), let target = benchmarkTargetID else { return }
        benchmarkRunning = false
        benchmarkTimeout?.invalidate()
        benchmarkTimeout = nil
        let old = benchmarkReports[target, default: []].filter { $0.transport != report.transport }
        benchmarkReports[target] = Array((old + [report]).suffix(2))
        benchmarkResultText = report.summary
    }

    func receive(_ message: WireMessage) {
        switch message.type {
        case .welcome: acceptWelcome(message)
        case .state: acceptState(message)
        case .result: acceptResult(message)
        case .pong: acceptPong(message)
        case .ping, .authenticate, .disconnect:
            if message.type == .disconnect {
                peer?.close()
                handleClose("The Mac disconnected.")
            } else {
                peer?.close()
            }
        default: peer?.close()
        }
    }

    private func acceptWelcome(_ message: WireMessage) {
        guard !isConnected, let id = message.connectionID, let state = message.state,
            let candidate
        else { peer?.close(); return }
        do {
            let saved = PairedMac(
                serviceName: candidate.serviceName, name: state.deviceName,
                certificateSHA256: candidate.certificateSHA256,
                token: message.authToken ?? candidate.token)
            var updated = pairedMacs.filter { $0.serviceName != saved.serviceName }
            updated.append(saved)
            try SecureStore.save(updated, account: "paired-macs")
            pairedMacs = updated
            connectionID = id
            sequence = 0
            remoteState = state
            reconcilePlayerVolumeDisplayStates(with: state)
            isConnected = true
            connectionSummary = "Connected to \(state.deviceName)"
            discoveredMacs = discoveredMacs.map {
                $0.id == saved.serviceName
                    ? DiscoveredMac(id: $0.id, name: saved.name, isPaired: true) : $0
            }
        } catch { peer?.close(); errorMessage = error.localizedDescription }
    }

    private func acceptState(_ message: WireMessage) {
        guard isConnected, message.connectionID == connectionID else { peer?.close(); return }
        remoteState = message.state
        if let state = message.state { reconcilePlayerVolumeDisplayStates(with: state) }
    }

    private func acceptResult(_ message: WireMessage) {
        guard let id = message.requestID, let request = pending[id],
            request.metadata.matchesResult(message)
        else { peer?.close(); return }
        let mustReleaseSession = requiresSafePointerTeardown(
            metadata: request.metadata, message: message)
        let otherPendingControlsMayHaveTakenEffect = pending.count > 1
        pending.removeValue(forKey: id)
        #if DEBUG
            if isLiveMediaTesting {
                if message.error == nil {
                    liveSuccessfulResults += 1
                } else {
                    liveFailedResults += 1
                }
            }
        #endif
        recordPlayerVolumeResult(requestID: id, succeeded: message.error == nil)
        if let error = message.error { errorMessage = error.message }
        if mustReleaseSession {
            disconnect()
            errorMessage =
                otherPendingControlsMayHaveTakenEffect
                ? "Disconnected to release the pointer. Other pending controls may have taken effect; "
                    + "they were not retried."
                : "The Mac could not release the pointer. Reconnect to continue."
            return
        }
        flushQueuedCommands()
    }

    private func acceptPong(_ message: WireMessage) {
        guard supportsRoundTripProbe, message.connectionID == connectionID,
            let id = message.requestID, let sequence = message.sequence
        else { peer?.close(); return }
        let disposition = benchmarkRequestTracker.consumePong(id: id, sequence: sequence)
        guard disposition == .active else {
            if disposition == .retired { return }
            peer?.close()
            return
        }
        guard let request = benchmarkRequest, request.id == id, request.sequence == sequence else {
            peer?.close()
            return
        }
        benchmarkTimeout?.invalidate()
        benchmarkTimeout = nil
        benchmarkRequest = nil
        benchmark?.record(
            roundTripNanoseconds: DispatchTime.now().uptimeNanoseconds &- request.sentNanoseconds)
        benchmarkProgress = benchmark?.progress ?? 0
        updateBenchmarkGroupProgress()
        advanceBenchmark()
    }
}

struct ConnectionStatusCard: View {
    @Bindable var model: RemoteModel

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: model.isConnected ? "checkmark.circle.fill" : "desktopcomputer")
                .font(.title2)
                .foregroundStyle(model.isConnected ? .green : .secondary)
                .frame(width: 44, height: 44)
                .background(.quaternary, in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(
                    model.isConnected
                        ? (model.remoteState?.deviceName ?? "Mac connected")
                        : "Connect to your Mac"
                )
                .font(.headline)
                Text(model.connectionSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !model.isConnected {
                Button {
                    model.startDiscovery()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Refresh nearby Macs")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18))
    }
}
