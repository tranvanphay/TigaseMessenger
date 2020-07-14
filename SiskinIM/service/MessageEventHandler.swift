//
// MessageEventHandler.swift
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
import TigaseSwiftOMEMO

class MessageEventHandler: XmppServiceEventHandler {
    
    public static let OMEMO_AVAILABILITY_CHANGED = Notification.Name(rawValue: "OMEMOAvailabilityChanged");
    public static let MESSAGE_SYNCHRONIZATION_FINISHED = Notification.Name(rawValue: "MessageSynchronizationFinished");
    
    static func prepareBody(message: Message, forAccount account: BareJID) -> (String?, MessageEncryption, String?) {
        var encryption: MessageEncryption = .none;
        var fingerprint: String? = nil;
        
        guard (message.type ?? .chat) != .error else {
            guard let body = message.body else {
                return (message.to?.resource == nil ? nil : "", encryption, nil);
            }
            return (body, encryption, nil);
        }
        
        var encryptionErrorBody: String?;
        if let omemoModule: OMEMOModule = XmppService.instance.getClient(for: account)?.modulesManager.getModule(OMEMOModule.ID) {
            switch omemoModule.decode(message: message) {
            case .successMessage(let decodedMessage, let keyFingerprint):
                encryption = .decrypted;
                fingerprint = keyFingerprint
                break;
            case .successTransportKey(let key, let iv):
                print("got transport key with key and iv!");
            case .failure(let error):
                switch error {
                case .invalidMessage:
                    encryptionErrorBody = "Message was not encrypted for this device.";
                    encryption = .notForThisDevice;
                case .duplicateMessage:
                    if let from = message.from?.bareJid, DBChatHistoryStore.instance.checkItemAlreadyAdded(for: account, with: from, authorNickname: nil, type: .message, timestamp: message.delay?.stamp ?? Date(), direction: account == from ? .outgoing : .incoming, stanzaId: message.getAttribute("id"), data: nil) {
                        return (nil, .none, nil);
                    }
                case .notEncrypted:
                    encryption = .none;
                default:
                    encryptionErrorBody = "Message decryption failed!";
                    encryption = .decryptionFailed;
                }
                break;
            }
        }
        
        guard let body = message.body ?? message.oob ?? encryptionErrorBody else {
            return (nil, encryption, nil);
        }
        return (body, encryption, fingerprint);
    }
    
    let events: [Event] = [MessageModule.MessageReceivedEvent.TYPE, MessageDeliveryReceiptsModule.ReceiptEvent.TYPE, MessageCarbonsModule.CarbonReceivedEvent.TYPE, DiscoveryModule.ServerFeaturesReceivedEvent.TYPE, MessageArchiveManagementModule.ArchivedMessageReceivedEvent.TYPE, SessionEstablishmentModule.SessionEstablishmentSuccessEvent.TYPE, StreamManagementModule.ResumedEvent.TYPE, OMEMOModule.AvailabilityChangedEvent.TYPE];
    
    init() {
    }
 
    func handle(event: Event) {
        switch event {
        case let e as MessageModule.MessageReceivedEvent:
            guard let from = e.message.from, let account = e.sessionObject.userBareJid else {
                return;
            }
            
            let (body, encryption, fingerprint) = MessageEventHandler.prepareBody(message: e.message, forAccount: account)
            guard body != nil else {
                return;
            }
            
            let timestamp = e.message.delay?.stamp ?? Date();
            let state: MessageState = ((e.message.type ?? .chat) == .error) ? .incoming_error_unread : .incoming_unread;
            
            var type: ItemType = .message;
            if let oob = e.message.oob {
                if oob == body! {
                    type = .attachment;
                }
            }

            var authorNickname: String? = nil;
            var recipientNickname: String? = nil;
            if let room = DBChatStore.instance.getChat(for: account, with: from.bareJid) as? DBRoom {
                if state.direction == .incoming {
                    authorNickname = from.resource;
                    recipientNickname = room.nickname;
                } else {
                    authorNickname = room.nickname;
                    recipientNickname = e.message.to?.resource;
                }
            }

            DBChatHistoryStore.instance.appendItem(for: account, with: from.bareJid, state: state, authorNickname: authorNickname, recipientNickname: recipientNickname, type: type, timestamp: timestamp, stanzaId: e.message.id, data: body!, chatState: e.message.chatState, errorCondition: e.message.errorCondition, errorMessage: e.message.errorText, encryption: encryption, encryptionFingerprint: fingerprint, completionHandler: nil);
            
            if type == .message && !state.isError, #available(iOS 13.0, *) {
                let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue | NSTextCheckingResult.CheckingType.address.rawValue);
                let matches = detector.matches(in: body!, range: NSMakeRange(0, body!.utf16.count));
                matches.forEach { match in
                    if let url = match.url, let scheme = url.scheme, ["https", "http"].contains(scheme) {
                        DBChatHistoryStore.instance.appendItem(for: account, with: from.bareJid, state: state, authorNickname: authorNickname, recipientNickname: recipientNickname, type: .linkPreview, timestamp: timestamp, stanzaId: nil, data: url.absoluteString, chatState: e.message.chatState, errorCondition: e.message.errorCondition, errorMessage: e.message.errorText, encryption: encryption, encryptionFingerprint: fingerprint, completionHandler: nil);
                    }
                    if let address = match.components {
                        let query = address.values.joined(separator: ",").addingPercentEncoding(withAllowedCharacters: .urlHostAllowed);
                        let mapUrl = URL(string: "http://maps.apple.com/?q=\(query!)")!;
                        DBChatHistoryStore.instance.appendItem(for: account, with: from.bareJid, state: state, authorNickname: authorNickname, recipientNickname: recipientNickname, type: .linkPreview, timestamp: timestamp, stanzaId: nil, data: mapUrl.absoluteString, chatState: e.message.chatState, errorCondition: e.message.errorCondition, errorMessage: e.message.errorText, encryption: encryption, encryptionFingerprint: fingerprint, completionHandler: nil);
                    }
                }
            }
        case let e as MessageDeliveryReceiptsModule.ReceiptEvent:
            guard let from = e.message.from?.bareJid, let account = e.sessionObject.userBareJid else {
                return;
            }
            DBChatHistoryStore.instance.updateItemState(for: account, with: from, stanzaId: e.messageId, from: .outgoing, to: .outgoing_delivered);
        case let e as SessionEstablishmentModule.SessionEstablishmentSuccessEvent:
            let account = e.sessionObject.userBareJid!;
            MessageEventHandler.syncMessages(for: account);
            sendUnsentMessages(for: account);
        case let e as StreamManagementModule.ResumedEvent:
            let account = e.sessionObject.userBareJid!;
            sendUnsentMessages(for: account);
        case let e as DiscoveryModule.ServerFeaturesReceivedEvent:
            guard Settings.enableMessageCarbons.bool() else {
                return;
            }
            guard e.features.contains(MessageCarbonsModule.MC_XMLNS) else {
                return;
            }
            guard let mcModule: MessageCarbonsModule = XmppService.instance.getClient(for: e.sessionObject.userBareJid!)?.modulesManager.getModule(MessageCarbonsModule.ID) else {
                return;
            }
            guard !XmppService.instance.isFetch else {
                return;
            }
            mcModule.enable();
        case let e as MessageCarbonsModule.CarbonReceivedEvent:
            guard let account = e.sessionObject.userBareJid, let from = e.message.from, let to = e.message.to else {
                    return;
                }
                let (body, encryption,fingerprint) = MessageEventHandler.prepareBody(message: e.message, forAccount: account);
            guard body != nil else {
//                if Settings.markMessageDeliveredToOtherResourceAsRead.bool(), let delivery = e.message.messageDelivery, e.action == .sent {
//                        switch delivery {
//                    case .received(let msgId):
//                        DBChatHistoryStore.instance.markAsRead(for: from.bareJid, with: to.bareJid, messageId: msgId);
//                            break;
//                    default:
//                        break;
//                    }
//                }
                return;
            }
            let jid = account == from.bareJid ? to.bareJid : from.bareJid;
            let timestamp = e.message.delay?.stamp ?? Date();
            let state: MessageState = calculateState(direction: account == from.bareJid ? .outgoing : .incoming, error: ((e.message.type ?? .chat) == .error), unread: /*!Settings.markMessageCarbonsAsRead.bool()*/ true);
            
            var type: ItemType = .message;
            if let oob = e.message.oob {
                if oob == body! {
                    type = .attachment;
                }
            }
            
            var authorNickname: String? = nil;
            var recipientNickname: String? = nil;
            if let room = DBChatStore.instance.getChat(for: account, with: jid) as? DBRoom {
                // carbons should not copy PM messages
                return;
            }
            
            DBChatHistoryStore.instance.appendItem(for: account, with: jid, state: state, authorNickname: authorNickname, recipientNickname: recipientNickname, type: type, timestamp: timestamp, stanzaId: e.message.id, data: body!, errorCondition: e.message.errorCondition, errorMessage: e.message.errorText, encryption: encryption, encryptionFingerprint: fingerprint, completionHandler: { (msgId) in
                if state.direction == .outgoing {
                    DBChatHistoryStore.instance.markAsRead(for: account, with: jid, before: timestamp);
                }
            });
            
            if type == .message && !state.isError, #available(iOS 13.0, *) {
                let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue | NSTextCheckingResult.CheckingType.address.rawValue);
                let matches = detector.matches(in: body!, range: NSMakeRange(0, body!.utf16.count));
                matches.forEach { match in
                    if let url = match.url, let scheme = url.scheme, ["https", "http"].contains(scheme) {
                        DBChatHistoryStore.instance.appendItem(for: account, with: jid, state: state, authorNickname: authorNickname, recipientNickname: recipientNickname, type: .linkPreview, timestamp: timestamp, stanzaId: nil, data: url.absoluteString, chatState: e.message.chatState, errorCondition: e.message.errorCondition, errorMessage: e.message.errorText, encryption: encryption, encryptionFingerprint: fingerprint, completionHandler: nil);
                    }
                    if let address = match.components {
                        let query = address.values.joined(separator: ",").addingPercentEncoding(withAllowedCharacters: .urlHostAllowed);
                        let mapUrl = URL(string: "http://maps.apple.com/?q=\(query!)")!;
                        DBChatHistoryStore.instance.appendItem(for: account, with: jid, state: state, authorNickname: authorNickname, recipientNickname: recipientNickname, type: .linkPreview, timestamp: timestamp, stanzaId: nil, data: mapUrl.absoluteString, errorCondition: e.message.errorCondition, errorMessage: e.message.errorText, encryption: encryption, encryptionFingerprint: fingerprint, completionHandler: nil);
                    }
                }
            }
        case let e as MessageArchiveManagementModule.ArchivedMessageReceivedEvent:
            guard let account = e.sessionObject.userBareJid, let from = e.message.from, let to = e.message.to else {
                    return;
                }
            let (body, encryption, fingerprint) = MessageEventHandler.prepareBody(message: e.message, forAccount: account)
            guard body != nil else {
                return;
            }
            
            var type: ItemType = .message;
            if let oob = e.message.oob {
                if oob == body {
                    type = .attachment;
                }
            }

            let jid = account == from.bareJid ? to.bareJid : from.bareJid;
            let timestamp = e.timestamp!;
            var state: MessageState = calculateState(direction: account == from.bareJid ? .outgoing : .incoming, error: ((e.message.type ?? .chat) == .error), unread: false);
            
            var authorNickname: String? = nil;
            var recipientNickname: String? = nil;
            if let room = DBChatStore.instance.getChat(for: account, with: jid) as? DBRoom {
                if room.nickname == from.resource {
                    if state.isError {
                        state = .incoming_error;
                    } else {
                        state = .incoming;
                    }
                } else {
                    if state.isError {
                        state = .outgoing_error;
                    } else {
                        state = .outgoing;
                    }
                }
                if state.direction == .incoming {
                    authorNickname = from.resource;
                    recipientNickname = room.nickname;
                } else {
                    authorNickname = room.nickname;
                    recipientNickname = e.message.to?.resource;
                }
            }
            
            DBChatHistoryStore.instance.appendItem(for: account, with: jid, state: state, authorNickname: authorNickname, recipientNickname: recipientNickname, type: type, timestamp: timestamp, stanzaId: e.message.id, data: body!, errorCondition: e.message.errorCondition, errorMessage: e.message.errorText, encryption: encryption, encryptionFingerprint: fingerprint, completionHandler: nil);
            
            if type == .message && !state.isError, #available(iOS 13.0, *) {
                let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue | NSTextCheckingResult.CheckingType.address.rawValue);
                let matches = detector.matches(in: body!, range: NSMakeRange(0, body!.utf16.count));
                matches.forEach { match in
                    if let url = match.url, let scheme = url.scheme, ["https", "http"].contains(scheme) {
                        DBChatHistoryStore.instance.appendItem(for: account, with: from.bareJid, state: state, authorNickname: authorNickname, recipientNickname: recipientNickname, type: .linkPreview, timestamp: timestamp, stanzaId: nil, data: url.absoluteString, errorCondition: e.message.errorCondition, errorMessage: e.message.errorText, encryption: encryption, encryptionFingerprint: fingerprint, completionHandler: nil);
                    }
                    if let address = match.components {
                        let query = address.values.joined(separator: ",").addingPercentEncoding(withAllowedCharacters: .urlHostAllowed);
                        let mapUrl = URL(string: "http://maps.apple.com/?q=\(query!)")!;
                        DBChatHistoryStore.instance.appendItem(for: account, with: from.bareJid, state: state, authorNickname: authorNickname, recipientNickname: recipientNickname, type: .linkPreview, timestamp: timestamp, stanzaId: nil, data: mapUrl.absoluteString, errorCondition: e.message.errorCondition, errorMessage: e.message.errorText, encryption: encryption, encryptionFingerprint: fingerprint, completionHandler: nil);
                    }
                }
            }
        case let e as OMEMOModule.AvailabilityChangedEvent:
            NotificationCenter.default.post(name: MessageEventHandler.OMEMO_AVAILABILITY_CHANGED, object: e);
        default:
            break;
        }
    }
    
    static func sendAttachment(chat: DBChat, originalUrl: URL?, uploadedUrl: String, appendix: ChatAttachmentAppendix, completionHandler: (()->Void)?) {
        
        self.sendMessage(chat: chat, body: nil, url: uploadedUrl, chatAttachmentAppendix: appendix, messageStored: { (msgId) in
            DispatchQueue.main.async {
                if originalUrl != nil {
                    _ = DownloadStore.instance.store(originalUrl!, filename: originalUrl!.lastPathComponent, with: "\(msgId)");
                }
                completionHandler?();
            }
        })
    }

    static func sendMessage(chat: DBChat, body: String?, url: String?, encrypted: ChatEncryption? = nil, stanzaId: String? = nil, chatAttachmentAppendix: ChatAttachmentAppendix? = nil, messageStored: ((Int)->Void)? = nil) {
        guard let msg = body ?? url else {
            return;
        }

        let encryption = encrypted ?? chat.options.encryption ?? ChatEncryption(rawValue: Settings.messageEncryption.string()!)!;

        let message = chat.createMessage(msg);
        message.id = stanzaId ?? UUID().uuidString;
        message.messageDelivery = .request;

        let account = chat.account;
        let jid = chat.jid.bareJid;

        switch encryption {
        case .omemo:
            if stanzaId == nil {
                let fingerprint = DBOMEMOStore.instance.identityFingerprint(forAccount: account, andAddress: SignalAddress(name: account.stringValue, deviceId: Int32(bitPattern: DBOMEMOStore.instance.localRegistrationId(forAccount: account)!)));
                DBChatHistoryStore.instance.appendItem(for: account, with: jid, state: .outgoing_unsent, type: url == nil ? .message : .attachment, timestamp: Date(), stanzaId: message.id, data: msg, encryption: .decrypted, encryptionFingerprint: fingerprint, chatAttachmentAppendix: chatAttachmentAppendix, completionHandler: messageStored);
            }
            XmppService.instance.tasksQueue.schedule(for: jid, task: { (completionHandler) in
                sendEncryptedMessage(message, from: account, completionHandler: { result in
                    switch result {
                    case .success(_):
                        DBChatHistoryStore.instance.updateItemState(for: account, with: jid, stanzaId: message.id!, from: .outgoing_unsent, to: .outgoing, withTimestamp: Date());
                    case .failure(let err):
                        let condition = (err is ErrorCondition) ? (err as? ErrorCondition) : nil;
                        guard condition == nil || condition! != .gone else {
                            completionHandler();
                            return;
                        }

                        var errorMessage: String? = nil;
                        if let encryptionError = err as? SignalError {
                            switch encryptionError {
                            case .noSession:
                                errorMessage = "There is no trusted device to send message to";
                            default:
                                errorMessage = "It was not possible to send encrypted message due to encryption error";
                            }
                        }
                        
                        DBChatHistoryStore.instance.markOutgoingAsError(for: account, with: jid, stanzaId: message.id!, errorCondition: .undefined_condition, errorMessage: errorMessage);
                    }
                    completionHandler();
                });
            });
        case .none:
            message.oob = url;
            let type: ItemType = url == nil ? .message : .attachment;
            if stanzaId == nil {
                DBChatHistoryStore.instance.appendItem(for: account, with: jid, state: .outgoing_unsent, type: type, timestamp: Date(), stanzaId: message.id, data: msg, encryption: .none, encryptionFingerprint: nil, chatAttachmentAppendix: chatAttachmentAppendix, completionHandler: messageStored);
            }
            XmppService.instance.tasksQueue.schedule(for: jid, task: { (completionHandler) in
                sendUnencryptedMessage(message, from: account, completionHandler: { result in
                    switch result {
                    case .success(_):
                        let timestamp = Date();
                        DBChatHistoryStore.instance.updateItemState(for: account, with: jid, stanzaId: message.id!, from: .outgoing_unsent, to: .outgoing, withTimestamp: timestamp);
                            
                        if type == .message, #available(iOS 13.0, *) {
                            let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue | NSTextCheckingResult.CheckingType.address.rawValue);
                            let matches = detector.matches(in: body!, range: NSMakeRange(0, body!.utf16.count));
                            matches.forEach { match in
                                if let url = match.url, let scheme = url.scheme, ["https", "http"].contains(scheme) {
                                    DBChatHistoryStore.instance.appendItem(for: account, with: jid, state: .outgoing, type: .linkPreview, timestamp: timestamp, stanzaId: nil, data: url.absoluteString, encryption: .none, encryptionFingerprint: nil, completionHandler: nil);
                                }
                                if let address = match.components {
                                    let query = address.values.joined(separator: ",").addingPercentEncoding(withAllowedCharacters: .urlHostAllowed);
                                    let mapUrl = URL(string: "http://maps.apple.com/?q=\(query!)")!;
                                    DBChatHistoryStore.instance.appendItem(for: account, with: jid, state: .outgoing, type: .linkPreview, timestamp: timestamp, stanzaId: nil, data: mapUrl.absoluteString, encryption: .none, encryptionFingerprint: nil, completionHandler: nil);
                                }
                            }
                        }
                    case .failure(let err):
                        guard let condition = err as? ErrorCondition, condition != .gone else {
                            completionHandler();
                            return;
                        }
                        DBChatHistoryStore.instance.markOutgoingAsError(for: account, with: jid, stanzaId: message.id!, errorCondition: err as? ErrorCondition ?? .undefined_condition, errorMessage: "Could not send message");
                    }
                    completionHandler();
                });
            });
        }
    }
    

        fileprivate static func sendUnencryptedMessage(_ message: Message, from account: BareJID, completionHandler: @escaping (Result<Void,Error>)->Void) {
            guard let client = XmppService.instance.getClient(for: account), client.state == .connected else {
                completionHandler(.failure(ErrorCondition.gone));
                return;
            }

            client.context.writer?.write(message);

            completionHandler(.success(Void()));
        }


        fileprivate static func sendEncryptedMessage(_ message: Message, from account: BareJID, completionHandler resultHandler: @escaping (Result<Void,Error>)->Void) {

            let msg = message.body!;

            guard let omemoModule: OMEMOModule = XmppService.instance.getClient(for: account)?.modulesManager.getModule(OMEMOModule.ID) else {
                DBChatHistoryStore.instance.updateItemState(for: account, with: message.to!.bareJid, stanzaId: message.id!, from: .outgoing_unsent, to: .outgoing_error);
                resultHandler(.failure(ErrorCondition.unexpected_request));
                return;
            }

            guard let client = XmppService.instance.getClient(for: account), client.state == .connected else {
                resultHandler(.failure(ErrorCondition.gone));
                return;
            }

            let jid = message.to!.bareJid;
            let stanzaId = message.id!;

            let completionHandler: ((EncryptionResult<Message, SignalError>)->Void)? = { (result) in
                switch result {
                case .failure(let error):
                    // FIXME: add support for error handling!!
                    resultHandler(.failure(error));
                case .successMessage(let encryptedMessage, let fingerprint):
                    guard let client = XmppService.instance.getClient(for: account) else {
                        resultHandler(.failure(ErrorCondition.gone));
                        return;
                    }
                    client.context.writer?.write(encryptedMessage);
                    resultHandler(.success(Void()));
                }
            };

            omemoModule.encode(message: message, completionHandler: completionHandler!);
        }

    fileprivate func sendUnsentMessages(for account: BareJID) {
        DBChatHistoryStore.instance.loadUnsentMessage(for: account, completionHandler: { (account, jid, data, stanzaId, encryption) in
                
            var chat = DBChatStore.instance.getChat(for: account, with: jid);
            if chat == nil {
                chat = DBChatStore.instance.open(for: account, chat: Chat(jid: JID(jid), thread: nil));
            }
                
            if let dbChat = chat as? DBChat {
                let url = data.starts(with: "http:") || data.starts(with: "https:") ? data : nil
                MessageEventHandler.sendMessage(chat: dbChat, body: data, url: data, stanzaId: stanzaId);
            }
        });
    }
    
    fileprivate func calculateState(direction: MessageDirection, error: Bool, unread: Bool) -> MessageState {
        if direction == .incoming {
            if error {
                return unread ? .incoming_error_unread : .incoming_error;
            }
            return unread ? .incoming_unread : .incoming;
        } else {
            if error {
                return unread ? .outgoing_error_unread : .outgoing_error;
            }
            return .outgoing;
        }
    }
    
    static func syncMessages(for account: BareJID) {
        if AccountSettings.messageSyncAuto(account).bool() {
            var syncPeriod = AccountSettings.messageSyncPeriod(account).double();
            if syncPeriod == 0 {
                syncPeriod = 72;
            }
            let syncMessagesSince = max(DBChatStore.instance.lastMessageTimestamp(for: account), Date(timeIntervalSinceNow: -1 * syncPeriod * 3600));
                
            MessageEventHandler.syncMessages(for: account, since: syncMessagesSince);
        }
    }
    
    static func syncMessages(for account: BareJID, since: Date, rsmQuery: RSM.Query? = nil) {
        guard let client = XmppService.instance.getClient(for: account), client.state == .connected, let mamModule: MessageArchiveManagementModule = client.modulesManager.getModule(MessageArchiveManagementModule.ID) else {
            NotificationCenter.default.post(name: MessageEventHandler.MESSAGE_SYNCHRONIZATION_FINISHED, object: self, userInfo: ["account": account]);
            return;
        }
        
        let queryId = UUID().uuidString;
        mamModule.queryItems(start: since, queryId: queryId, rsm: rsmQuery ?? RSM.Query(max: 150), onSuccess: { (queryid,complete,rsmResponse) in
            if rsmResponse != nil && !complete {
                MessageEventHandler.syncMessages(for: account, since: since, rsmQuery: rsmResponse?.next(150));
            } else {
                NotificationCenter.default.post(name: MessageEventHandler.MESSAGE_SYNCHRONIZATION_FINISHED, object: self, userInfo: ["account": account]);
            }
        }) { (error, stanza) in
            print("could not synchronize message archive for:", account, "got", error as Any, stanza as Any);
            NotificationCenter.default.post(name: MessageEventHandler.MESSAGE_SYNCHRONIZATION_FINISHED, object: self, userInfo: ["account": account]);
        }
    }
}
