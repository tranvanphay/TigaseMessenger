//
// JingleManager
//
// Siskin IM
// Copyright (C) 2019 "Tigase, Inc." <office@tigase.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. Look for COPYING file in the top folder.
// If not, see https://www.gnu.org/licenses/.
//

import Foundation
import TigaseSwift
import WebRTC

#if targetEnvironment(simulator)
#else
class JingleManager: JingleSessionManager, XmppServiceEventHandler {
    
    static let instance = JingleManager();
    
    let connectionFactory = { () -> RTCPeerConnectionFactory in
        RTCPeerConnectionFactory.initialize();
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory());
    }();
    let events: [Event] = [JingleModule.JingleEvent.TYPE, PresenceModule.ContactPresenceChanged.TYPE];
    
    fileprivate var connections: [Session] = [];
    
    let dispatcher = QueueDispatcher(label: "jingleEventHandler");
    
    func activeSessionSid(for account: BareJID, with jid: JID) -> String? {
        return session(for: account, with: jid, sid: nil)?.sid;
    }
    
    func session(for account: BareJID, with jid: JID, sid: String?) -> Session? {
        return dispatcher.sync {
            return connections.first(where: {(sess) -> Bool in
                return (sid == nil || sess.sid == sid) && sess.account == account && sess.jid == jid;
            });
        }
    }
    
    fileprivate func session(peerConnection: RTCPeerConnection) -> Session? {
        return dispatcher.sync {
            return connections.first(where: {(sess) -> Bool in
                return sess.peerConnection == peerConnection;
            })
        }
    }
    
    func open(for account: BareJID, with jid: JID, sid: String?, role: Jingle.Content.Creator) -> Session {
        return dispatcher.sync {
            let session = Session(account: account, jid: jid, sid: sid, role: role);
            self.connections.append(session);
            return session;
        }
    }
    
    func close(for account: BareJID, with jid: JID, sid: String) -> Session? {
        return dispatcher.sync {
            guard let idx = self.connections.firstIndex(where: { sess -> Bool in
                return sess.sid == sid && sess.account == account && sess.jid == jid;
            }) else {
                return nil;
            }
            let session =  self.connections.remove(at: idx);
            _ = session.terminate();
            return session;
        }
    }
    
    func close(session: Session) {
        dispatcher.async {
            guard let idx = self.connections.firstIndex(of: session) else {
                return;
            }
            let session = self.connections.remove(at: idx);
            _ = session.terminate();
        }
    }
    
    func handle(event: Event) {
        dispatcher.async {
            switch event {
            case let e as JingleModule.JingleEvent:
                switch e.action! {
                case .sessionInitiate:
                    self.sessionInitiated(event: e);
                case .sessionAccept:
                    self.sessionAccepted(event: e);
                case .transportInfo:
                    self.transportInfo(event: e);
                case .sessionTerminate:
                    self.sessionTerminated(event: e);
                default:
                    break;
                }
                break;
            case let e as PresenceModule.ContactPresenceChanged:
                if e.availabilityChanged && (e.presence.type ?? .available) == .unavailable, let account = e.sessionObject.userBareJid, let from = e.presence.from {
                    let toClose = self.connections.filter({ (session) in
                        return session.jid == from && session.account == account;
                    });
                    toClose.forEach({ (session) in
                        self.close(session: session);
                    })
                }
            default:
                break;
            }
        }
    }
    
    enum ContentType {
        case audio
        case video
        case filetransfer
    }
    
    func support(for jid: JID, on account: BareJID) -> Set<ContentType> {
        guard let client = XmppService.instance.getClient(forJid: account), let presenceModule: PresenceModule = client.modulesManager.getModule(PresenceModule.ID) else {
            return [];
        }
        
        var features: [String] = [];
        
        if jid.resource == nil {
            presenceModule.presenceStore.getPresences(for: jid.bareJid)?.values.filter({ (p) -> Bool in
                return (p.type ?? .available) == .available;
            }).forEach({ (p) in
                guard let node = p.capsNode, let f = XmppService.instance.dbCapsCache.getFeatures(for: node) else {
                    return;
                }
                features.append(contentsOf: f);
            })
        } else {
            guard let p = presenceModule.presenceStore.getPresence(for: jid), (p.type ?? .available) == .available, let node = p.capsNode, let f = XmppService.instance.dbCapsCache.getFeatures(for: node) else {
                return [];
            }
            features.append(contentsOf: f);
        }
        
        var support: [ContentType] = [];
        
        // check jingle and supported transports...
        guard features.contains("urn:xmpp:jingle:1") && features.contains("urn:xmpp:jingle:transports:ice-udp:1") && features.contains("urn:xmpp:jingle:apps:dtls:0") && features.contains("urn:xmpp:jingle:apps:rtp:1") else {
            return Set(support);
        }
        
        if features.contains("urn:xmpp:jingle:apps:rtp:audio") {
            support.append(.audio);
        }
        
        if features.contains("urn:xmpp:jingle:apps:rtp:video") {
            support.append(.video);
        }
        
        if features.contains("urn:xmpp:jingle:apps:file-transfer:3") {
            support.append(.filetransfer);
        }
        
        return Set(support);
    }
    
    fileprivate func sessionInitiated(event e: JingleModule.JingleEvent) {
        
        guard let content = e.contents.first, let _ = content.description as? Jingle.RTP.Description else {
            return;
        }
        
        let session = open(for: e.sessionObject.userBareJid!, with: e.jid, sid: e.sid, role: .responder);
        
        // TODO: FIX ME SOON
        if !VideoCallController.accept(session: session, sdpOffer: SDP(sid: e.sid!, contents: e.contents, bundle: e.bundle)) {
            _ = session.terminate();
        }
    }
    
    fileprivate func sessionAccepted(event e: JingleModule.JingleEvent) {
        guard let session = session(for: e.sessionObject.userBareJid!, with: e.jid, sid: e.sid) else {
            return;
        }
        
        session.accepted(sdpAnswer: SDP(sid: e.sid!, contents: e.contents, bundle: e.bundle));
    }
    
    fileprivate func sessionTerminated(event e: JingleModule.JingleEvent) {
        guard let session = session(for: e.sessionObject.userBareJid!, with: e.jid, sid: e.sid) else {
            return;
        }
        _ = session.terminate();
    }
    
    fileprivate func transportInfo(event e: JingleModule.JingleEvent) {
        print("processing transport info");
        guard let session = self.session(for: e.sessionObject.userBareJid!, with: e.jid, sid: e.sid) else {
            return;
        }
        
        e.contents.forEach { (content) in
            content.transports.forEach({ (trans) in
                if let transport = trans as? Jingle.Transport.ICEUDPTransport {
                    transport.candidates.forEach({ (candidate) in
                        session.addCandidate(candidate, for: content.name);
                    })
                }
            })
        }
    }
    
}

extension String {
    static func randomString(length: Int) -> String {
        let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
        return String((0...length-1).map{ _ in letters.randomElement()! });
    }
}
#endif
