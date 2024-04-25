/**
 
Multiplayer functionality backed by Apple's GroupActivities Framework.
 
 */
//  Created by Kevin Watters on 4/23/24.

import Foundation
import GroupActivities
import CoreTransferable
import Combine
import SwiftUI

public class LogCoordinator: NSObject, ObservableObject {
    static var _instance: LogCoordinator = LogCoordinator()
    public static var instance: LogCoordinator { _instance }
    
    @Published public var lines: [(Int, String)] = []
}

public struct LogView: View {
    @EnvironmentObject private var logCoordinator: LogCoordinator
    public init() {
        
    }
    public var body: some View {
        ForEach(logCoordinator.lines, id: \.0) { line in
            Text(line.1).monospaced()
        }
    }
}

fileprivate var messageCount = 0

public func log(_ message: String) {
    print(message)
    
    DispatchQueue.main.async {
        messageCount += 1
        let id = messageCount
        var oldLines = LogCoordinator.instance.lines
        oldLines.insert((id, message), at: 0)
        if oldLines.count > 50 {
            oldLines = Array(oldLines.prefix(50))
        }
        LogCoordinator.instance.lines = oldLines
    }
}

public class ShareModel: ObservableObject {
    public typealias ActivityType = GodotVisionGroupActivity
    
    public var groupSession: GroupSession<ActivityType>? = nil
    public var activityIdentifier: String? = nil // set from outside
    public var automaticallyShareInput = false

    static var instance: ShareModel? = nil

    @Published public var isEligibleForGroupSession = false
    var session: GroupSession<ActivityType>? = nil
    
    let activity = ActivityType()
    private let groupStateObserver = GroupStateObserver()
    var unreliableMessenger: GroupSessionMessenger?
    var reliableMessenger: GroupSessionMessenger?
    private var subs: Set<AnyCancellable> = []
    private var sessionSubs: Set<AnyCancellable> = []
    private var tasks = Set<Task<Void, Never>>()
    private var awaitSessionsTask: Task<Void, Never>? = nil
    private var preparingSession = false
    public var onMessageCallback: ((Data) -> Void)? = nil

    #if os(visionOS)
    var systemCoordinatorConfig: SystemCoordinator.Configuration?
    var spatialTemplatePreference: SpatialTemplatePreference = .none
    #endif
    
    var didSetup = false
    
    var godotData: GodotData = .init()
    
    public init() {
        if Self.instance == nil {
            Self.instance = self
        } else {
            logError("more than one ShareModel")
            log("more than one ShareModel")
        }
        
        groupStateObserver.$isEligibleForGroupSession.sink { [weak self] value in
            self?.isEligibleForGroupSession = value
        }.store(in: &subs)
    }
    
    public func prepareSession() async {
        log("prepareSession")
        // Await the result of the preparation call.
        let result = await activity.prepareForActivation()
        switch result {
        case .activationDisabled:
            log("Activation is disabled")
        case .activationPreferred:
            do {
                log("Activation is preferred")
                _ = try await activity.activate()
            } catch {
                log("Unable to activate the activity: \(error)")
            }
        case .cancelled:
            log("Activation Cancelled")
        default:
            logError("unknown activation \(result)")
            log("unknown activation \(result)")
        }
    }
    
    public func startSessionHandlerTask() {
        awaitSessionsTask?.cancel()
        
        log("starting session handler task")
        awaitSessionsTask = Task {
            for await session in ActivityType.sessions() {
                log("SESSION \(session)")
                log("  FOR ACTIVITY \(session.activity)")
#if os(visionOS)
                guard let systemCoordinator = await session.systemCoordinator else {
                    logError("no system coordinator")
                    continue
                }
                
                let isSpatial = systemCoordinator.localParticipantState.isSpatial
                print("  isSpatial", isSpatial)
                
                if isSpatial {
                    var configuration = SystemCoordinator.Configuration()
                    configuration.spatialTemplatePreference = spatialTemplatePreference
                    configuration.supportsGroupImmersiveSpace = true
                    systemCoordinator.configuration = configuration
                    systemCoordinatorConfig = configuration
                }
#endif
                let reliableMessenger = GroupSessionMessenger(session: session, deliveryMode: .reliable)
                self.reliableMessenger = reliableMessenger
                
                let unreliableMessenger = GroupSessionMessenger(session: session, deliveryMode: .unreliable)
                self.unreliableMessenger = unreliableMessenger
                
                session.$state.sink { [weak self] sessionState in
                    guard let self else { return }
                    log("sesssion state \(sessionState)")
                    switch sessionState {
                    case .invalidated(let reason):
                        if self.session === session {
                            log("calling endSession because \(reason)")
                            self.endSession()
                        }
                    case .joined:
                        ()
                    case .waiting:
                        ()
                    @unknown default:
                        fatalError("unhandled sessionState \(sessionState)")
                    }
                }.store(in: &sessionSubs)
                
                for messenger in [reliableMessenger, unreliableMessenger] {
                    tasks.insert(Task.detached {
                        for await (data, messageContext) in messenger.messages(of: Data.self) {
                            log("msg data from \(messageContext.source.id) -> \(data)")
                            self.onMessageCallback?(data)
                        }
                    })
                }

                self.session = session
                
                session.join()
                log("calling join")
            }
        }
    }
    
    func endSession() {
        sessionSubs.forEach { $0.cancel() }
        sessionSubs.removeAll()

        unreliableMessenger = nil
        reliableMessenger = nil
        
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        
        session = nil
    }
    
    deinit {
        awaitSessionsTask?.cancel()
        awaitSessionsTask = nil
        

        subs.forEach { $0.cancel() }
        subs.removeAll()
        godotData.cleanup()
    }

    public func maybeJoin() {
        if preparingSession {
            log("already preparing session...")
            return
        }
        
        if !isReadyToJoinGroupActivity {
            log("maybeJoin failed, not ready to join group activity")
            return
        }
        
        if session != nil {
            log("maybeJoin failed already have a session")
            return
        }
        
        print("maybeJoin, current session is", String(describing: session))
        print("activity", activityIdentifier ?? "<nil>")
        if !preparingSession {
            preparingSession = true
            Task {
                await prepareSession()
                preparingSession = false
            }
        }
    }
    
    // nocommit: change to closure?
    public func sendInput<T>(_ inputMessage: T, reliable: Bool) where T: Codable {
        let messengerOptional = reliable ? reliableMessenger : unreliableMessenger
        guard let messenger = messengerOptional else {
            return
        }
        
        tasks.insert(Task {
            do {
              let data = try JSONEncoder().encode(inputMessage)
              try await messenger.send(data)
            } catch {
                logError(error)
            }
        })
    }
    
    private var isReadyToJoinGroupActivity: Bool {
        if activityIdentifier == nil {
            return false
        }
        if activityIdentifier!.isEmpty {
            return false
        }
        if !automaticallyShareInput {
            return false
        }
        if !groupStateObserver.isEligibleForGroupSession {
            return false
        }
        return true
    }
}


public struct GodotVisionGroupActivity: GroupActivity {
    public static var activityIdentifier: String {
        ShareModel.instance?.activityIdentifier ?? Bundle.main.bundleIdentifier!.appending(".GodotVistionActivity")
    }
    
    public var metadata: GroupActivityMetadata {
        var metaData = GroupActivityMetadata()
        metaData.type = .generic
        metaData.title = "Play Together"
        //metaData.sceneAssociationBehavior = .content(Self.activityIdentifier)
        metaData.sceneAssociationBehavior = .default
        return metaData
    }
}

struct GodotVisionTransferable: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        GroupActivityTransferRepresentation { _ in
            GodotVisionGroupActivity()
        }
    }
}

//
// GODOT specific stuff below
//

import SwiftGodot

struct GodotData {
    var node: Node? = nil
    var signal_cb: Callable? = nil
    
    mutating func cleanup() {
        if let node {
            if let signal_cb {
                node.disconnect(signal: join_activity, callable: signal_cb)
                self.signal_cb = nil
            }
            self.node = nil
        }
    }
}

fileprivate let config_changed = StringName("config_changed") /// Signal name for SharePlay config change
fileprivate let peer_connected = StringName("peer_connected")
fileprivate let join_activity = StringName("join_activity")

extension ShareModel {
      
    func setup(sceneTree: SceneTree, onMessageData: @escaping (Data) -> Void) {
        self.onMessageCallback = onMessageData
        guard let _sharePlayNode = findSharePlayNode(sceneTree: sceneTree) else {
            logError("no share play node")
            return
        }
        
        let id = Int64(_sharePlayNode.getInstanceId())
        
        guard let node = GD.instanceFromId(instanceId: id) as? Node else {
            logError("could not get Node instance from ID \(id)")
            return
        }
        
        godotData.node = node
        
        let callable = Callable(onGodotRequestJoin)
        let godotError = node.connect(signal: join_activity, callable: callable)
        if godotError != .ok {
            logError("Could not connect to \(join_activity) signal on SharePlay node: \(godotError)")
        } else {
            godotData.signal_cb = callable
        }
    }
        
    private func onGodotRequestJoin(args: [Variant]) -> Variant? {
        guard let node = godotData.node else { return nil }
        automaticallyShareInput = Bool(node.get(property: "automatically_share_input")) ?? false
        maybeJoin()
        return nil
    }
    
}

fileprivate func findSharePlayNode(sceneTree: SceneTree) -> Node? {
    guard let root = sceneTree.root else {
        logError("sceneTree had no root")
        return nil
    }
    
    // TODO: find a better way to find the GodotVision plugin singleton?
    for GV in root.getChildren() where GV.name == "GodotVision" {
        for sharePlay in GV.getChildren() where sharePlay.name == "SharePlay" && sharePlay.hasSignal(peer_connected) {
            return sharePlay
        }
    }
    
    return nil
}


