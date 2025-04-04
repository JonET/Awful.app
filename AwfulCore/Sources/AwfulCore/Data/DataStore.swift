//  DataStore.swift
//
//  Copyright 2014 Awful Contributors. CC BY-NC-SA 3.0 US https://github.com/Awful/Awful.app

import CoreData
import os

#if canImport(UIKit)
import UIKit
#endif

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "DataStore")

public final class DataStore: NSObject {
    /// A directory in which the store is saved. Since stores can span multiple files, a directory is required.
    let storeDirectoryURL: URL
    
    /// A main-queue-concurrency-type context that is automatically saved when the application enters the background.
    public let mainManagedObjectContext: NSManagedObjectContext
    
    private let storeCoordinator: NSPersistentStoreCoordinator
    private let lastModifiedObserver: LastModifiedContextObserver

    // Creating multiple model instances with the same classes (e.g. SwiftUI Previews) breaks things. Ensure we only load it once.
    public static let model: NSManagedObjectModel = .init(contentsOf: Bundle.module.url(forResource: "Awful", withExtension: "momd")!)!
    
    /**
    :param: storeDirectoryURL A directory to save the store. Created if it doesn't already exist. The directory will be excluded from backups to iCloud or iTunes.
    */
    public init(storeDirectoryURL: URL) {
        self.storeDirectoryURL = storeDirectoryURL
        mainManagedObjectContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        storeCoordinator = NSPersistentStoreCoordinator(managedObjectModel: Self.model)
        mainManagedObjectContext.persistentStoreCoordinator = storeCoordinator
        lastModifiedObserver = LastModifiedContextObserver(managedObjectContext: mainManagedObjectContext)
        super.init()
        
        loadPersistentStore()

        #if canImport(UIKit)
        let noteCenter = NotificationCenter.default
        noteCenter.addObserver(self, selector: #selector(applicationDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        noteCenter.addObserver(self, selector: #selector(applicationDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        #endif
    }
    
    @objc private func applicationDidEnterBackground(notification: Notification) {
        invalidatePruneTimer()
        
        do {
            try mainManagedObjectContext.save()
        }
        catch {
            fatalError("error saving main managed object context: \(error)")
        }
    }
    
    @objc private func applicationDidBecomeActive(notification: Notification) {
        invalidatePruneTimer()
        // Since pruning could potentially take a noticeable amount of time, and there's no real rush, let's schedule it for a little bit after becoming active.
        pruneTimer = Timer.scheduledTimer(timeInterval: 30, target: self, selector: #selector(DataStore.pruneTimerDidFire(timer:)), userInfo: nil, repeats: false)
    }
    
    private var pruneTimer: Timer?
    
    private func invalidatePruneTimer() {
        pruneTimer?.invalidate()
        pruneTimer = nil
    }
    
    @objc private func pruneTimerDidFire(timer: Timer) {
        pruneTimer = nil
        prune()
    }
    
    private var persistentStore: NSPersistentStore?
    
    private func loadPersistentStore() {
        assert(persistentStore == nil, "persistent store already loaded")
        
        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(at:storeDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        }
        catch {
            fatalError("could not create directory at \(storeDirectoryURL): \(error)")
        }
        
        do {
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutableStoreDirectoryURL = storeDirectoryURL
            try mutableStoreDirectoryURL.setResourceValues(resourceValues)
        }
        catch {
            logger.error("failed to exclude \(self.storeDirectoryURL) from backup. Error: \(error)")
        }
        
        let storeURL = storeDirectoryURL.appendingPathComponent("AwfulCache.sqlite")
        let options = [
            NSMigratePersistentStoresAutomaticallyOption: true,
            NSInferMappingModelAutomaticallyOption: true
        ]
        
        do {
            persistentStore = try storeCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: storeURL, options: options)
        }
        catch let error as NSError {
            if error.domain == NSCocoaErrorDomain {
                switch error.code {
                case NSMigrationMissingSourceModelError, NSMigrationMissingMappingModelError:
                    fatalError("automatic migration failed at \(storeURL): \(error)")
                default:
                    break
                }
            }
            fatalError("could not load persistent store at \(storeURL): \(error)")
        }

        fixParentForumSetToSelf()
    }

    private enum MetadataKey {
        static let didFixParentForumSetToSelf = "com.awfulapp.awful did fix parent forum set to self"
    }

    /**
     In August 2020, a change to Forums markup meant we scraped the current forum twice from the `forumdisplay.php` breadcrumbs. This results in our setting its parent forum to itself. Unsurprisingly, this ends poorly anytime we try to follow parent forum edges up the tree, such as when deciding how far to indent cells in the Forums tab.

     Having fixed the scraping (for now), this does a one-time fix for any afflicted forums and severs the connection.
     */
    private func fixParentForumSetToSelf() {
        guard let store = persistentStore else { fatalError("missing persistent store") }
        mainManagedObjectContext.performAndWait {
            var metadata = storeCoordinator.metadata(for: store)
            if let didFix = metadata[MetadataKey.didFixParentForumSetToSelf] as? Bool, didFix {
                return
            }

            let forums = Forum.fetch(in: mainManagedObjectContext) {
                $0.predicate = NSPredicate(format: "%K == SELF", #keyPath(Forum.parentForum))
            }
            for forum in forums {
                forum.parentForum = nil
            }
            try! mainManagedObjectContext.save()

            metadata[MetadataKey.didFixParentForumSetToSelf] = true
            storeCoordinator.setMetadata(metadata, for: store)
        }
    }
    
    private var operationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
        }()
    
    func prune() {
        operationQueue.addOperation(CachePruner(managedObjectContext: mainManagedObjectContext))
    }
    
    public func deleteStoreAndReset() {
        invalidatePruneTimer()
        operationQueue.cancelAllOperations()
        
        NotificationCenter.default.post(name: NSNotification.Name(rawValue: DataStoreWillResetNotification), object: self)
        
        mainManagedObjectContext.reset()
        if let persistentStore = persistentStore {
            do {
                try storeCoordinator.remove(persistentStore)
            }
            catch {
                logger.error("error removing store at \(self.persistentStore?.url?.absoluteString ?? "(null)"): \(error)")
            }
            self.persistentStore = nil
        }
        assert(storeCoordinator.persistentStores.isEmpty, "unexpected persistent stores remain after reset")
        
        do {
            try FileManager.default.removeItem(at: storeDirectoryURL as URL)
        }
        catch {
            logger.error("error deleting store directory \(self.storeDirectoryURL): \(error)")
        }
        
        loadPersistentStore()
        
        NotificationCenter.default.post(name: NSNotification.Name(rawValue: DataStoreDidResetNotification), object: self)
    }
}

/// A LastModifiedContextObserver updates the lastModifiedDate attribute (for any objects that have one) whenever its context is saved.
public final class LastModifiedContextObserver: NSObject {
    let managedObjectContext: NSManagedObjectContext
    let relevantEntities: [NSEntityDescription]
    
    public init(managedObjectContext context: NSManagedObjectContext) {
        managedObjectContext = context
        let allEntities = context.persistentStoreCoordinator!.managedObjectModel.entities as [NSEntityDescription]
        relevantEntities = allEntities.filter { $0.attributesByName["lastModifiedDate"] != nil }
        super.init()
        
        NotificationCenter.default.addObserver(self, selector: #selector(LastModifiedContextObserver.contextWillSave(notification:)), name: NSNotification.Name.NSManagedObjectContextWillSave, object: context)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func contextWillSave(notification: NSNotification) {
        let context = notification.object as! NSManagedObjectContext
        let lastModifiedDate = Date()
        let insertedOrUpdated = context.insertedObjects.union(context.updatedObjects)
        context.performAndWait {
            let relevantObjects = insertedOrUpdated.filter { relevantEntities.contains($0.entity) }
            for item in relevantObjects {
                item.setValue(lastModifiedDate, forKey: "lastModifiedDate")
            }
        }
    }
}

/// Posted when a data store (the notification's object) is about to delete its persistent data. Please relinquish any references you may have to managed objects originating from the data store, as they are now invalid.
let DataStoreWillResetNotification = "Data store will be deleted"

/// Posted once a data store (the notification's object) has deleted its persistent data. Managed objects can once again be inserted into, fetched from, and updated in the data store.
let DataStoreDidResetNotification = "Data store did reset"
