//  ThreadsTableViewController.swift
//
//  Copyright 2015 Awful Contributors. CC BY-NC-SA 3.0 US https://github.com/Awful/Awful.app

import AwfulCore
import AwfulModelTypes
import AwfulSettings
import AwfulTheming
import Combine
import CoreData
import os
import ScrollViewDelegateMultiplexer
import UIKit

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "ThreadsTableViewController")

final class ThreadsTableViewController: TableViewController, ComposeTextViewControllerDelegate, ThreadTagPickerViewControllerDelegate, UIViewControllerRestoration {
    
    private var cancellables: Set<AnyCancellable> = []
    private var dataSource: ThreadListDataSource?
    @FoilDefaultStorage(Settings.enableHaptics) private var enableHaptics
    private var filterThreadTag: ThreadTag?
    let forum: Forum
    @FoilDefaultStorage(Settings.handoffEnabled) private var handoffEnabled
    private var latestPage = 0
    private var loadMoreFooter: LoadMoreFooter?
    private let managedObjectContext: NSManagedObjectContext
    @FoilDefaultStorage(Settings.showThreadTags) private var showThreadTags
    @FoilDefaultStorage(Settings.forumThreadsSortedUnread) private var sortUnreadThreadsToTop

    private lazy var multiplexer: ScrollViewDelegateMultiplexer = {
        return ScrollViewDelegateMultiplexer(scrollView: tableView)
    }()
    
    init(forum: Forum) {
        guard let managedObjectContext = forum.managedObjectContext else {
            fatalError("where's the context?")
        }
        self.managedObjectContext = managedObjectContext

        self.forum = forum
        
        super.init(style: .plain)

        title = forum.name
        
        navigationItem.rightBarButtonItem = composeBarButtonItem
        updateComposeBarButtonItem()
    }
    
    deinit {
        if isViewLoaded {
            multiplexer.removeDelegate(self)
        }
    }
    
    override var theme: Theme {
        return Theme.currentTheme(for: ForumID(forum.forumID))
    }

    private func makeDataSource() -> ThreadListDataSource {
        var filter: Set<ThreadTag> = []
        if let tag = filterThreadTag {
            filter.insert(tag)
        }
        let dataSource = try! ThreadListDataSource(
            forum: forum,
            sortedByUnread: sortUnreadThreadsToTop,
            showsTagAndRating: showThreadTags,
            threadTagFilter: filter,
            managedObjectContext: managedObjectContext,
            tableView: tableView)
        dataSource.delegate = self
        return dataSource
    }
    
    private func loadPage(_ page: Int) {
        Task {
            do {
                _ = try await ForumsClient.shared.listThreads(in: forum, tagged: filterThreadTag, page: page)

                latestPage = page

                enableLoadMore()

                tableView.tableHeaderView = filterButton

                if filterThreadTag == nil {
                    RefreshMinder.sharedMinder.didRefreshForum(forum)
                } else {
                    RefreshMinder.sharedMinder.didRefreshFilteredForum(forum)
                }

                // Announcements appear in all thread lists.
                RefreshMinder.sharedMinder.didRefresh(.announcements)

                updateComposeBarButtonItem()
            } catch {
                let alert = UIAlertController(networkError: error)
                present(alert, animated: true)
            }

            stopAnimatingPullToRefresh()
            loadMoreFooter?.didFinish()
        }
    }
    
    private func enableLoadMore() {
        guard loadMoreFooter == nil else { return }
        
        loadMoreFooter = LoadMoreFooter(tableView: tableView, multiplexer: multiplexer, loadMore: { [weak self] loadMoreFooter in
            guard let self = self else { return }
            self.loadPage(self.latestPage + 1)
        })
    }
    
    // MARK: View lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        multiplexer.addDelegate(self)

        tableView.estimatedRowHeight = ThreadListCell.estimatedHeight
        tableView.hideExtraneousSeparators()
        tableView.restorationIdentifier = "Threads table view"
        
        dataSource = makeDataSource()
        tableView.reloadData()
        
        pullToRefreshBlock = { [weak self] in self?.refresh() }
        
        $handoffEnabled
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if visible {
                    prepareUserActivity()
                }
            }
            .store(in: &cancellables)

        Publishers.Merge(
            $showThreadTags.dropFirst(),
            $sortUnreadThreadsToTop.dropFirst()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            guard let self else { return }
            dataSource = makeDataSource()
            tableView.reloadData()
        }
        .store(in: &cancellables)
    }
    
    override func themeDidChange() {
        super.themeDidChange()

        loadMoreFooter?.themeDidChange()
        
        updateFilterButton()

        tableView.separatorColor = theme["listSeparatorColor"]
        tableView.separatorInset.left = ThreadListCell.separatorLeftInset(
            showsTagAndRating: showThreadTags,
            inTableWithWidth: tableView.bounds.width
        )
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        if tableView.numberOfSections > 0, tableView.numberOfRows(inSection: 0) > 0 {
            enableLoadMore()
            
            updateFilterButton()
            tableView.tableHeaderView = filterButton
        }
        
        prepareUserActivity()
        
        let isTimeToRefresh: Bool
        if filterThreadTag == nil {
            isTimeToRefresh = RefreshMinder.sharedMinder.shouldRefreshForum(forum)
        } else {
            isTimeToRefresh = RefreshMinder.sharedMinder.shouldRefreshFilteredForum(forum)
        }
        if isTimeToRefresh || tableView.numberOfSections == 0 || tableView.numberOfRows(inSection: 0) == 0 {
            refresh()
        }
    }
    
    // MARK: Actions
    
    private func refresh() {
        startAnimatingPullToRefresh()
        
        loadPage(1)
    }
    
    // MARK: Composition
    
    private lazy var composeBarButtonItem: UIBarButtonItem = { [unowned self] in
        let item = UIBarButtonItem(image: UIImage(named: "compose"), style: .plain, target: self, action: #selector(ThreadsTableViewController.didTapCompose))
        item.accessibilityLabel = "New thread"
        return item
        }()
    
    private lazy var threadComposeViewController: ThreadComposeViewController! = { [unowned self] in
        let composeViewController = ThreadComposeViewController(forum: self.forum)
        composeViewController.restorationIdentifier = "New thread composition"
        composeViewController.delegate = self
        return composeViewController
        }()
    
    private func updateComposeBarButtonItem() {
        composeBarButtonItem.isEnabled = forum.canPost && forum.lastRefresh != nil
    }
    
    @objc func didTapCompose() {
        if enableHaptics {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        present(threadComposeViewController.enclosingNavigationController, animated: true, completion: nil)
    }
    
    // MARK: ComposeTextViewControllerDelegate
    
    func composeTextViewController(_ composeTextViewController: ComposeTextViewController, didFinishWithSuccessfulSubmission success: Bool, shouldKeepDraft: Bool) {
        dismiss(animated: true) {
            if let thread = self.threadComposeViewController.thread , success {
                let postsPage = PostsPageViewController(thread: thread)
                postsPage.restorationIdentifier = "Posts"
                postsPage.loadPage(.first, updatingCache: true, updatingLastReadPost: true)
                self.showDetailViewController(postsPage, sender: self)
            }
            
            if !shouldKeepDraft {
                self.threadComposeViewController = nil
            }
        }
    }
    
    // MARK: Filtering by tag
    
    private lazy var filterButton: UIButton = {
        let button = UIButton(type: .system)
        button.bounds.size.height = button.intrinsicContentSize.height + 8
        button.addTarget(self, action: #selector(didTapFilterButton), for: .primaryActionTriggered)
        return button
    }()
    
    private lazy var threadTagPicker: ThreadTagPickerViewController = {
        let imageNames = self.forum.threadTags.array
            .filter { ($0 as! ThreadTag).imageName != nil }
            .map { ($0 as! ThreadTag).imageName! }
        let picker = ThreadTagPickerViewController(firstTag: .noFilter, imageNames: imageNames, secondaryImageNames: [])
        picker.delegate = self
        picker.title = LocalizedString("thread-list.filter.picker-title")
        picker.navigationItem.leftBarButtonItem = picker.cancelButtonItem
        return picker
    }()
    
    @objc private func didTapFilterButton(_ sender: UIButton) {
        if enableHaptics {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        threadTagPicker.selectImageName(filterThreadTag?.imageName)
        threadTagPicker.present(from: self, sourceView: sender)
    }
    
    private func updateFilterButton() {
        let title = LocalizedString(filterThreadTag == nil ? "thread-list.filter-button.no-filter" : "thread-list.filter-button.change-filter")
        filterButton.setTitle(title, for: .normal)
        filterButton.titleLabel?.font = UIFont.preferredFontForTextStyle(.body, sizeAdjustment: -2.5, weight: .medium)
        filterButton.tintColor = theme["tintColor"]
    }
    
    // MARK: ThreadTagPickerViewControllerDelegate
    
    func didSelectImageName(
        _ imageName: String?,
        in picker: ThreadTagPickerViewController
    ) {
        if enableHaptics {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        if let imageName = imageName {
            filterThreadTag = forum.threadTags.array
                .compactMap { $0 as? ThreadTag }
                .first { $0.imageName == imageName }
        } else {
            filterThreadTag = nil
        }
        
        RefreshMinder.sharedMinder.forgetForum(forum)
        updateFilterButton()

        dataSource = makeDataSource()
        tableView.reloadData()
        
        picker.dismiss()
    }
    
    func didSelectSecondaryImageName(_ secondaryImageName: String, in picker: ThreadTagPickerViewController) {
        // nop
    }
    
    func didDismissPicker(_ picker: ThreadTagPickerViewController) {
        // nop
    }
    
    // MARK: Handoff
    
    private func prepareUserActivity() {
        guard handoffEnabled else {
            userActivity = nil
            return
        }
        
        userActivity = NSUserActivity(activityType: Handoff.ActivityType.listingThreads)
        userActivity?.needsSave = true
    }
    
    override func updateUserActivityState(_ activity: NSUserActivity) {
        activity.route = .forum(id: forum.forumID)
        activity.title = forum.name

        logger.debug("handoff activity set: \(activity.activityType) with \(activity.userInfo ?? [:])")
    }
    
    // MARK: UIViewControllerRestoration
    
    class func viewController(withRestorationIdentifierPath identifierComponents: [String], coder: NSCoder) -> UIViewController? {
        var forumKey = coder.decodeObject(forKey: RestorationKeys.forumKey) as! ForumKey?
        if forumKey == nil {
            guard let forumID = coder.decodeObject(forKey: ObsoleteRestorationKeys.forumID) as? String else { return nil }
            forumKey = ForumKey(forumID: forumID)
        }
        let managedObjectContext = AppDelegate.instance.managedObjectContext
        let forum = Forum.objectForKey(objectKey: forumKey!, in: managedObjectContext)
        let viewController = self.init(forum: forum)
        viewController.restorationIdentifier = identifierComponents.last 
        viewController.restorationClass = self
        return viewController
    }
    
    override func encodeRestorableState(with coder: NSCoder) {
        super.encodeRestorableState(with: coder)
        
        coder.encode(forum.objectKey, forKey: RestorationKeys.forumKey)
        coder.encode(threadComposeViewController, forKey: RestorationKeys.newThreadViewController)
        coder.encode(filterThreadTag?.objectKey, forKey: RestorationKeys.filterThreadTagKey)
    }
    
    override func decodeRestorableState(with coder: NSCoder) {
        super.decodeRestorableState(with: coder)
        
        if let compose = coder.decodeObject(forKey: RestorationKeys.newThreadViewController) as? ThreadComposeViewController {
            compose.delegate = self
            threadComposeViewController = compose
        }
        
        var tagKey = coder.decodeObject(forKey: RestorationKeys.filterThreadTagKey) as! ThreadTagKey?
        if tagKey == nil {
            if let tagID = coder.decodeObject(forKey: ObsoleteRestorationKeys.filterThreadTagID) as? String {
                tagKey = ThreadTagKey(imageName: nil, threadTagID: tagID)
            }
        }
        if let tagKey = tagKey {
            filterThreadTag = ThreadTag.objectForKey(objectKey: tagKey, in: forum.managedObjectContext!)
        }
        
        updateFilterButton()
    }
    
    private struct RestorationKeys {
        static let forumKey = "ForumKey"
        static let newThreadViewController = "AwfulNewThreadViewController"
        static let filterThreadTagKey = "FilterThreadTagKey"
    }
    
    private struct ObsoleteRestorationKeys {
        static let forumID = "AwfulForumID"
        static let filterThreadTagID = "AwfulFilterThreadTagID"
    }
    
    // MARK: Gunk
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

extension ThreadsTableViewController: ThreadListDataSourceDelegate {
    func themeForItem(at indexPath: IndexPath, in dataSource: ThreadListDataSource) -> Theme {
        return theme
    }
}

// MARK: UITableViewDelegate
extension ThreadsTableViewController {
    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return dataSource!.tableView(tableView, heightForRowAt: indexPath)
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if enableHaptics {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        let thread = dataSource!.thread(at: indexPath)
        let postsViewController = PostsPageViewController(thread: thread)
        postsViewController.restorationIdentifier = "Posts"
        // SA: For an unread thread, the Forums will interpret "next unread page" to mean "last page", which is not very helpful.
        let targetPage = thread.beenSeen ? ThreadPage.nextUnread : .first
        postsViewController.loadPage(targetPage, updatingCache: true, updatingLastReadPost: true)
        showDetailViewController(postsViewController, sender: self)
        tableView.deselectRow(at: indexPath, animated: true)
    }

    override func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        return .makeFromThreadList(
            for: dataSource!.thread(at: indexPath),
               presenter: self
        )
    }
}
