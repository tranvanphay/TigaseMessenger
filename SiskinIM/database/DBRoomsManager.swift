//
// DBRoomsManager.swift
//
// Siskin IM
// Copyright (C) 2016 "Tigase, Inc." <office@tigase.com>
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

open class DBRoomsManager: DefaultRoomsManager {
    
    fileprivate let store: DBChatStore;
    
    public convenience init() {
        self.init(store: DBChatStore.instance);
    }
    
    public init(store: DBChatStore) {
        self.store = store;
        super.init(dispatcher: store.dispatcher);
    }
    
    open override func createRoomInstance(roomJid: BareJID, nickname: String, password: String?) -> Room {
        let room = super.createRoomInstance(roomJid: roomJid, nickname: nickname, password: password);
        return store.open(for: context.sessionObject.userBareJid!, chat: room)!;
    }
    
    open override func contains(roomJid: BareJID) -> Bool {
        return getRoom(for: roomJid) != nil;
    }
    
    open override func getRoom(for roomJid: BareJID) -> Room? {
        return store.getChat(for: context.sessionObject.userBareJid!, with: roomJid) as? Room;
    }
    
    open override func getRoomOrCreate(for roomJid: BareJID, nickname: String, password: String?, onCreate: @escaping (Room) -> Void) -> Room {
        let room = super.createRoomInstance(roomJid: roomJid, nickname: nickname, password: password);
        let account: BareJID = context.sessionObject.userBareJid!;
        let dbRoom: DBRoom = store.open(for: account, chat: room)!;
        if dbRoom.state == .not_joined {
            onCreate(dbRoom);
        }
        return dbRoom;
    }
    
    open override func getRooms() -> [Room] {
        return store.getChats(for: context.sessionObject.userBareJid!).filter({ (item) -> Bool in
            return item is Room;
        }).map({ item -> Room in item as! Room });
    }
    
    open override func register(room: Room) {
        // nothing to do....
    }
    
    open override func remove(room: Room) {
        _ = store.close(for: context!.sessionObject.userBareJid!, chat: room);
    }

    open override func initialize() {
        super.initialize();
        store.loadChats(for: context!.sessionObject.userBareJid!, context: context);
    }
    
    public func deinitialize() {
        store.unloadChats(for: context!.sessionObject.userBareJid!);
    }
    
}

public struct RoomOptions: Codable, ChatOptionsProtocol {
    
    public var notifications: ConversationNotification;
    
    init() {
        notifications = .mention;
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self);
        if let val = try container.decodeIfPresent(String.self, forKey: .notifications) {
            notifications = ConversationNotification(rawValue: val) ?? .mention;
        } else {
            notifications = .mention;
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self);
        if notifications != .mention {
            try container.encode(notifications.rawValue, forKey: .notifications);
        }
    }
    
    enum CodingKeys: String, CodingKey {
        case notifications = "notifications"
    }
}
