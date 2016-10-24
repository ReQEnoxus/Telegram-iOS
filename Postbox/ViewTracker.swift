import Foundation
#if os(macOS)
    import SwiftSignalKitMac
#else
    import SwiftSignalKit
#endif

public enum ViewUpdateType {
    case InitialUnread(MessageIndex)
    case Generic
    case FillHole(insertions: [MessageIndex: HoleFillDirection], deletions: [MessageIndex: HoleFillDirection])
    case UpdateVisible
}

final class ViewTracker {
    private let queue: Queue
    private let fetchEarlierHistoryEntries: (PeerId, MessageIndex?, Int, MessageTags?) -> [MutableMessageHistoryEntry]
    private let fetchLaterHistoryEntries: (PeerId, MessageIndex?, Int, MessageTags?) -> [MutableMessageHistoryEntry]
    private let fetchEarlierChatEntries: (MessageIndex?, Int) -> [MutableChatListEntry]
    private let fetchLaterChatEntries: (MessageIndex?, Int) -> [MutableChatListEntry]
    private let fetchAnchorIndex: (MessageId) -> MessageHistoryAnchorIndex?
    private let renderMessage: (IntermediateMessage) -> Message
    private let getPeer: (PeerId) -> Peer?
    private let getPeerNotificationSettings: (PeerId) -> PeerNotificationSettings?
    private let getCachedPeerData: (PeerId) -> CachedPeerData?
    private let getPeerPresence: (PeerId) -> PeerPresence?
    
    private var chatListViews = Bag<(MutableChatListView, ValuePipe<(ChatListView, ViewUpdateType)>)>()
    private var messageHistoryViews: [PeerId: Bag<(MutableMessageHistoryView, ValuePipe<(MessageHistoryView, ViewUpdateType)>)>] = [:]
    private var contactPeerIdsViews = Bag<(MutableContactPeerIdsView, ValuePipe<ContactPeerIdsView>)>()
    private var contactPeersViews = Bag<(MutableContactPeersView, ValuePipe<ContactPeersView>)>()
    
    private let messageHistoryHolesView = MutableMessageHistoryHolesView()
    private let messageHistoryHolesViewSubscribers = Bag<ValuePipe<MessageHistoryHolesView>>()
    
    private let chatListHolesView = MutableChatListHolesView()
    private let chatListHolesViewSubscribers = Bag<ValuePipe<ChatListHolesView>>()
    
    private var unsentMessageView: UnsentMessageHistoryView
    private let unsendMessageIndicesViewSubscribers = Bag<ValuePipe<UnsentMessageIndicesView>>()
    
    private var synchronizeReadStatesView: MutableSynchronizePeerReadStatesView
    private let synchronizePeerReadStatesViewSubscribers = Bag<ValuePipe<SynchronizePeerReadStatesView>>()
    
    private var peerViews = Bag<(MutablePeerView, ValuePipe<PeerView>)>()
    
    init(queue: Queue, fetchEarlierHistoryEntries: @escaping (PeerId, MessageIndex?, Int, MessageTags?) -> [MutableMessageHistoryEntry], fetchLaterHistoryEntries: @escaping (PeerId, MessageIndex?, Int, MessageTags?) -> [MutableMessageHistoryEntry], fetchEarlierChatEntries: @escaping (MessageIndex?, Int) -> [MutableChatListEntry], fetchLaterChatEntries: @escaping (MessageIndex?, Int) -> [MutableChatListEntry], fetchAnchorIndex: @escaping (MessageId) -> MessageHistoryAnchorIndex?, renderMessage: @escaping (IntermediateMessage) -> Message, getPeer: @escaping (PeerId) -> Peer?, getPeerNotificationSettings: @escaping (PeerId) -> PeerNotificationSettings?, getCachedPeerData: @escaping (PeerId) -> CachedPeerData?, getPeerPresence: @escaping (PeerId) -> PeerPresence?, unsentMessageIndices: [MessageIndex], synchronizePeerReadStateOperations: [PeerId: PeerReadStateSynchronizationOperation]) {
        self.queue = queue
        self.fetchEarlierHistoryEntries = fetchEarlierHistoryEntries
        self.fetchLaterHistoryEntries = fetchLaterHistoryEntries
        self.fetchEarlierChatEntries = fetchEarlierChatEntries
        self.fetchLaterChatEntries = fetchLaterChatEntries
        self.fetchAnchorIndex = fetchAnchorIndex
        self.renderMessage = renderMessage
        self.getPeer = getPeer
        self.getPeerNotificationSettings = getPeerNotificationSettings
        self.getCachedPeerData = getCachedPeerData
        self.getPeerPresence = getPeerPresence
        
        self.unsentMessageView = UnsentMessageHistoryView(indices: unsentMessageIndices)
        self.synchronizeReadStatesView = MutableSynchronizePeerReadStatesView(operations: synchronizePeerReadStateOperations)
    }
    
    func addMessageHistoryView(_ peerId: PeerId, view: MutableMessageHistoryView) -> (Bag<(MutableMessageHistoryView, ValuePipe<(MessageHistoryView, ViewUpdateType)>)>.Index, Signal<(MessageHistoryView, ViewUpdateType), NoError>) {
        let record = (view, ValuePipe<(MessageHistoryView, ViewUpdateType)>())
        
        let index: Bag<(MutableMessageHistoryView, ValuePipe<(MessageHistoryView, ViewUpdateType)>)>.Index
        if let bag = self.messageHistoryViews[peerId] {
            index = bag.add(record)
        } else {
            let bag = Bag<(MutableMessageHistoryView, ValuePipe<(MessageHistoryView, ViewUpdateType)>)>()
            index = bag.add(record)
            self.messageHistoryViews[peerId] = bag
        }
        
        self.updateTrackedHoles(peerId)
        
        return (index, record.1.signal())
    }
    
    func removeMessageHistoryView(_ peerId: PeerId, index: Bag<(MutableMessageHistoryView, ValuePipe<(MessageHistoryView, ViewUpdateType)>)>.Index) {
        if let bag = self.messageHistoryViews[peerId] {
            bag.remove(index)
            
            self.updateTrackedHoles(peerId)
        }
    }
    
    func addChatListView(_ view: MutableChatListView) -> (Bag<(MutableChatListView, ValuePipe<(ChatListView, ViewUpdateType)>)>.Index, Signal<(ChatListView, ViewUpdateType), NoError>) {
        let record = (view, ValuePipe<(ChatListView, ViewUpdateType)>())
        let index = self.chatListViews.add(record)
        
        self.updateTrackedChatListHoles()
        
        return (index, record.1.signal())
    }
    
    func removeChatListView(_ index: Bag<(MutableChatListView, ValuePipe<ChatListView>)>.Index) {
        self.chatListViews.remove(index)
        self.updateTrackedChatListHoles()
    }
    
    func addContactPeerIdsView(_ view: MutableContactPeerIdsView) -> (Bag<(MutableContactPeerIdsView, ValuePipe<ContactPeerIdsView>)>.Index, Signal<ContactPeerIdsView, NoError>) {
        let record = (view, ValuePipe<ContactPeerIdsView>())
        let index = self.contactPeerIdsViews.add(record)
        
        return (index, record.1.signal())
    }
    
    func removeContactPeerIdsView(_ index: Bag<(MutableContactPeerIdsView, ValuePipe<ContactPeerIdsView>)>.Index) {
        self.contactPeerIdsViews.remove(index)
    }
    
    func addContactPeersView(_ view: MutableContactPeersView) -> (Bag<(MutableContactPeersView, ValuePipe<ContactPeersView>)>.Index, Signal<ContactPeersView, NoError>) {
        let record = (view, ValuePipe<ContactPeersView>())
        let index = self.contactPeersViews.add(record)
        
        return (index, record.1.signal())
    }
    
    func removeContactPeersView(_ index: Bag<(MutableContactPeersView, ValuePipe<ContactPeersView>)>.Index) {
        self.contactPeersViews.remove(index)
    }
    
    func updateMessageHistoryViewVisibleRange(_ id: MessageHistoryViewId, earliestVisibleIndex: MessageIndex, latestVisibleIndex: MessageIndex) {
        if let bag = self.messageHistoryViews[id.peerId] {
            for (mutableView, pipe) in bag.copyItems() {
                if mutableView.id == id {
                    let context = MutableMessageHistoryViewReplayContext()
                    var updated = false
                    
                    let updateType: ViewUpdateType = .UpdateVisible
                    
                    if mutableView.updateVisibleRange(earliestVisibleIndex: earliestVisibleIndex, latestVisibleIndex: latestVisibleIndex, context: context) {
                        mutableView.complete(context: context, fetchEarlier: { index, count in
                            return self.fetchEarlierHistoryEntries(id.peerId, index, count, mutableView.tagMask)
                        }, fetchLater: { index, count in
                            return self.fetchLaterHistoryEntries(id.peerId, index, count, mutableView.tagMask)
                        })
                        mutableView.incrementVersion()
                        updated = true
                    }
                    
                    if updated {
                        mutableView.render(self.renderMessage)
                        pipe.putNext((MessageHistoryView(mutableView), updateType))
                        
                        self.updateTrackedHoles(id.peerId)
                    }
                    
                    break
                }
            }
        }
    }
    
    func addPeerView(_ view: MutablePeerView) -> (Bag<(MutablePeerView, ValuePipe<PeerView>)>.Index, Signal<PeerView, NoError>) {
        let record = (view, ValuePipe<PeerView>())
        let index = self.peerViews.add(record)
        
        return (index, record.1.signal())
    }
    
    func removePeerView(_ index: Bag<(MutablePeerView, ValuePipe<Peer?>)>.Index) {
        self.peerViews.remove(index)
    }
    
    func refreshViewsDueToExternalTransaction(fetchAroundChatEntries: (_ index: MessageIndex, _ count: Int) -> (entries: [MutableChatListEntry], earlier: MutableChatListEntry?, later: MutableChatListEntry?), fetchAroundHistoryEntries: (_ index: MessageIndex, _ count: Int, _ tagMask: MessageTags?) -> (entries: [MutableMessageHistoryEntry], lower: MutableMessageHistoryEntry?, upper: MutableMessageHistoryEntry?), fetchUnsendMessageIndices: () -> [MessageIndex], fetchSynchronizePeerReadStateOperations: () -> [PeerId: PeerReadStateSynchronizationOperation]) {
        var updateTrackedHolesPeerIds: [PeerId] = []
        
        for (peerId, bag) in self.messageHistoryViews {
            for (mutableView, pipe) in bag.copyItems() {
                if mutableView.refreshDueToExternalTransaction(fetchAroundHistoryEntries: fetchAroundHistoryEntries) {
                    mutableView.incrementVersion()
                    
                    mutableView.render(self.renderMessage)
                    pipe.putNext((MessageHistoryView(mutableView), .Generic))
                    
                    updateTrackedHolesPeerIds.append(peerId)
                }
            }
        }
        
        for (mutableView, pipe) in self.chatListViews.copyItems() {
            if mutableView.refreshDueToExternalTransaction(fetchAroundChatEntries: fetchAroundChatEntries) {
                mutableView.render(self.renderMessage, getPeerNotificationSettings: self.getPeerNotificationSettings)
                pipe.putNext((ChatListView(mutableView), .Generic))
            }
        }
        
        for peerId in updateTrackedHolesPeerIds {
            self.updateTrackedHoles(peerId)
        }
        
        if self.unsentMessageView.refreshDueToExternalTransaction(fetchUnsendMessageIndices: fetchUnsendMessageIndices) {
            self.unsentViewUpdated()
        }
        
        if self.synchronizeReadStatesView.refreshDueToExternalTransaction(fetchSynchronizePeerReadStateOperations: fetchSynchronizePeerReadStateOperations) {
            self.synchronizeReadStateViewUpdated()
        }
        
        for (mutableView, pipe) in self.peerViews.copyItems() {
            var updatedPeers: [PeerId: Peer] = [:]
            if let peer = self.getPeer(mutableView.peerId) {
                updatedPeers[mutableView.peerId] = peer
            }
            var updatedPeerPresences: [PeerId: PeerPresence] = [:]
            if let presence = self.getPeerPresence(mutableView.peerId) {
                updatedPeerPresences[mutableView.peerId] = presence
            }
            
            var updatedNotificationSettings: [PeerId: PeerNotificationSettings] = [:]
            if let notificationSettings = self.getPeerNotificationSettings(mutableView.peerId) {
                updatedNotificationSettings[mutableView.peerId] = notificationSettings
            }
            
            var updatedCachedPeerData: [PeerId: CachedPeerData] = [:]
            if let cachedPeerData = self.getCachedPeerData(mutableView.peerId) {
                updatedCachedPeerData[mutableView.peerId] = cachedPeerData
                for peerId in cachedPeerData.peerIds {
                    if let peer = self.getPeer(peerId) {
                        updatedPeers[peerId] = peer
                    }
                    if let presence = self.getPeerPresence(peerId) {
                        updatedPeerPresences[peerId] = presence
                    }
                }
            }
            
            if mutableView.replay(updatedPeers: updatedPeers, updatedNotificationSettings: updatedNotificationSettings, updatedCachedPeerData: updatedCachedPeerData, updatedPeerPresences: updatedPeerPresences, replaceContactPeerIds: nil, getPeer: self.getPeer, getPeerPresence: self.getPeerPresence) {
                pipe.putNext(PeerView(mutableView))
            }
        }
    }
    
    func updateViews(transaction: PostboxTransaction) {
        var updateTrackedHolesPeerIds: [PeerId] = []
        
        for (peerId, bag) in self.messageHistoryViews {
            var updateHoles = false
            let operations = transaction.currentOperationsByPeerId[peerId]
            if operations != nil || !transaction.updatedMedia.isEmpty {
                updateHoles = true
                for (mutableView, pipe) in bag.copyItems() {
                    let context = MutableMessageHistoryViewReplayContext()
                    var updated = false
                    
                    let updateType: ViewUpdateType
                    if let filledIndices = transaction.peerIdsWithFilledHoles[peerId] {
                        updateType = .FillHole(insertions: filledIndices, deletions: transaction.removedHolesByPeerId[peerId] ?? [:])
                    } else {
                        updateType = .Generic
                    }
                    
                    if mutableView.replay(operations ?? [], holeFillDirections: transaction.peerIdsWithFilledHoles[peerId] ?? [:], updatedMedia: transaction.updatedMedia, context: context) {
                        mutableView.complete(context: context, fetchEarlier: { index, count in
                            return self.fetchEarlierHistoryEntries(peerId, index, count, mutableView.tagMask)
                        }, fetchLater: { index, count in
                            return self.fetchLaterHistoryEntries(peerId, index, count, mutableView.tagMask)
                        })
                        mutableView.incrementVersion()
                        updated = true
                    }
                    
                    if mutableView.updateAnchorIndex(self.fetchAnchorIndex) {
                        updated = true
                    }
                    
                    if mutableView.updatePeers(transaction.currentUpdatedPeers) {
                        updated = true
                    }
                    
                    if updated {
                        mutableView.render(self.renderMessage)
                        
                        pipe.putNext((MessageHistoryView(mutableView), updateType))
                    }
                }
            }
            
            if updateHoles {
                updateTrackedHolesPeerIds.append(peerId)
            }
        }
        
        if !transaction.chatListOperations.isEmpty || !transaction.currentUpdatedPeerNotificationSettings.isEmpty {
            for (mutableView, pipe) in self.chatListViews.copyItems() {
                let context = MutableChatListViewReplayContext()
                if mutableView.replay(transaction.chatListOperations, updatedPeerNotificationSettings: transaction.currentUpdatedPeerNotificationSettings, context: context) {
                    mutableView.complete(context: context, fetchEarlier: self.fetchEarlierChatEntries, fetchLater: self.fetchLaterChatEntries)
                    mutableView.render(self.renderMessage, getPeerNotificationSettings: self.getPeerNotificationSettings)
                    var updateType: ViewUpdateType = .Generic
                    for operation in transaction.chatListOperations {
                        if case .RemoveHoles = operation {
                            updateType = .UpdateVisible
                            break
                        }
                    }
                    pipe.putNext((ChatListView(mutableView), .Generic))
                }
            }
            
            self.updateTrackedChatListHoles()
        }
        
        for peerId in updateTrackedHolesPeerIds {
            self.updateTrackedHoles(peerId)
        }
        
        if self.unsentMessageView.replay(transaction.unsentMessageOperations) {
            self.unsentViewUpdated()
        }
        
        if self.synchronizeReadStatesView.replay(transaction.updatedSynchronizePeerReadStateOperations) {
            self.synchronizeReadStateViewUpdated()
        }
        
        if let replaceContactPeerIds = transaction.replaceContactPeerIds {
            for (mutableView, pipe) in self.contactPeerIdsViews.copyItems() {
                if mutableView.replay(replace: replaceContactPeerIds) {
                    pipe.putNext(ContactPeerIdsView(mutableView))
                }
            }
        }
        
        for (mutableView, pipe) in self.contactPeersViews.copyItems() {
            if mutableView.replay(replacePeerIds: transaction.replaceContactPeerIds, updatedPeerPresences: transaction.currentUpdatedPeerPresences, getPeer: self.getPeer, getPeerPresence: self.getPeerPresence) {
                pipe.putNext(ContactPeersView(mutableView))
            }
        }
        
        for (mutableView, pipe) in self.peerViews.copyItems() {
            if mutableView.replay(updatedPeers: transaction.currentUpdatedPeers, updatedNotificationSettings: transaction.currentUpdatedPeerNotificationSettings, updatedCachedPeerData: transaction.currentUpdatedCachedPeerData, updatedPeerPresences: transaction.currentUpdatedPeerPresences, replaceContactPeerIds: transaction.replaceContactPeerIds, getPeer: self.getPeer, getPeerPresence: self.getPeerPresence) {
                pipe.putNext(PeerView(mutableView))
            }
        }
    }
    
    private func updateTrackedChatListHoles() {
        var firstHoles = Set<ChatListHole>()
        
        for (view, _) in self.chatListViews.copyItems() {
            if let hole = view.firstHole() {
                firstHoles.insert(hole)
            }
        }
    
        if self.chatListHolesView.update(holes: firstHoles) {
            for pipe in self.chatListHolesViewSubscribers.copyItems() {
                pipe.putNext(ChatListHolesView(self.chatListHolesView))
            }
        }
    }
    
    private func updateTrackedHoles(_ peerId: PeerId) {
        var firstHolesAndTags = Set<MessageHistoryHolesViewEntry>()
        if let bag = self.messageHistoryViews[peerId]  {
            for (view, _) in bag.copyItems() {
                if let (hole, direction) = view.firstHole() {
                    firstHolesAndTags.insert(MessageHistoryHolesViewEntry(hole: hole, direction: direction, tags: view.tagMask))
                }
            }
        }
        
        if self.messageHistoryHolesView.update(peerId: peerId, holes: firstHolesAndTags) {
            for subscriber in self.messageHistoryHolesViewSubscribers.copyItems() {
                subscriber.putNext(MessageHistoryHolesView(self.messageHistoryHolesView))
            }
        }
    }
    
    private func unsentViewUpdated() {
        for subscriber in self.unsendMessageIndicesViewSubscribers.copyItems() {
            subscriber.putNext(UnsentMessageIndicesView(self.unsentMessageView.indices))
        }
    }
    
    private func synchronizeReadStateViewUpdated() {
        for subscriber in self.synchronizePeerReadStatesViewSubscribers.copyItems() {
            subscriber.putNext(SynchronizePeerReadStatesView(self.synchronizeReadStatesView))
        }
    }
    
    func messageHistoryHolesViewSignal() -> Signal<MessageHistoryHolesView, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.queue.async {
                subscriber.putNext(MessageHistoryHolesView(self.messageHistoryHolesView))
                
                let pipe = ValuePipe<MessageHistoryHolesView>()
                let index = self.messageHistoryHolesViewSubscribers.add(pipe)
                
                let pipeDisposable = pipe.signal().start(next: { view in
                    subscriber.putNext(view)
                })
                
                disposable.set(ActionDisposable {
                    pipeDisposable.dispose()
                    self.messageHistoryHolesViewSubscribers.remove(index)
                })
            }
            return disposable
        }
    }
    
    func chatListHolesViewSignal() -> Signal<ChatListHolesView, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.queue.async {
                subscriber.putNext(ChatListHolesView(self.chatListHolesView))
                
                let pipe = ValuePipe<ChatListHolesView>()
                let index = self.chatListHolesViewSubscribers.add(pipe)
                
                let pipeDisposable = pipe.signal().start(next: { view in
                    subscriber.putNext(view)
                })
                
                disposable.set(ActionDisposable {
                    pipeDisposable.dispose()
                    self.chatListHolesViewSubscribers.remove(index)
                })
            }
            return disposable
        }
    }
    
    func unsentMessageIndicesViewSignal() -> Signal<UnsentMessageIndicesView, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.queue.async {
                subscriber.putNext(UnsentMessageIndicesView(self.unsentMessageView.indices))
                
                let pipe = ValuePipe<UnsentMessageIndicesView>()
                let index = self.unsendMessageIndicesViewSubscribers.add(pipe)
                
                let pipeDisposable = pipe.signal().start(next: { view in
                    subscriber.putNext(view)
                })
                
                disposable.set(ActionDisposable {
                    pipeDisposable.dispose()
                    self.unsendMessageIndicesViewSubscribers.remove(index)
                })
            }
            return disposable
        }
    }
    
    func synchronizePeerReadStatesViewSignal() -> Signal<SynchronizePeerReadStatesView, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.queue.async {
                subscriber.putNext(SynchronizePeerReadStatesView(self.synchronizeReadStatesView))
                
                let pipe = ValuePipe<SynchronizePeerReadStatesView>()
                let index = self.synchronizePeerReadStatesViewSubscribers.add(pipe)
                
                let pipeDisposable = pipe.signal().start(next: { view in
                    subscriber.putNext(view)
                })
                
                disposable.set(ActionDisposable {
                    pipeDisposable.dispose()
                    self.synchronizePeerReadStatesViewSubscribers.remove(index)
                })
            }
            return disposable
        }
    }
}
