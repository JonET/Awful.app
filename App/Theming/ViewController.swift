//  ViewController.swift
//
//  Copyright 2016 Awful Contributors. CC BY-NC-SA 3.0 US https://github.com/Awful/Awful.app

import PullToRefresh
import UIKit

private let Log = Logger.get()

protocol Themeable {

    /// The current theme.
    var theme: Theme { get }

    /// Called whenever `theme` changes.
    func themeDidChange()
}

private func CommonInit(_ vc: UIViewController) {
    vc.navigationItem.backBarButtonItem = UIBarButtonItem(title: "", style: .plain, target: nil, action: nil)
}

/**
    A thin customization of UIViewController that extends Theme support.
 
    Instances call `themeDidChange()` after loading their view. `ViewController`'s implementation of `themeDidChange()` sets the view background color and updates the scroll view's indicator (if appropriate).
 */
class ViewController: UIViewController, Themeable {
    override init(nibName: String?, bundle: Bundle?) {
        super.init(nibName: nibName, bundle: bundle)
        CommonInit(self)
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        CommonInit(self)
    }
    
    /// The theme to use for the view controller. Defaults to `Theme.currentTheme`.
    var theme: Theme {
        return Theme.currentTheme
    }
    
    /// Whether the view controller is currently visible (i.e. has received `viewDidAppear()` without having subsequently received `viewDidDisappear()`).
    private(set) var visible = false
    
    // MARK: View lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        themeDidChange()
    }
    
    func themeDidChange() {
        view.backgroundColor = theme["backgroundColor"]
        
        let scrollView: UIScrollView?
        if let scrollingSelf = view as? UIScrollView {
            scrollView = scrollingSelf
        } else if responds(to: #selector(getter: UIWebView.scrollView)), let scrollingSubview = value(forKey: "scrollView") as? UIScrollView {
            scrollView = scrollingSubview
        } else {
            scrollView = nil
        }
        scrollView?.indicatorStyle = theme.scrollIndicatorStyle
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        visible = true
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        
        visible = false
    }
}

/**
    A thin customization of UITableViewController that extends Theme support and adds some block-based refreshing/load more abilities.
 
    Implements `UITableViewDelegate.tableView(_:willDisplayCell:forRowAtIndexPath:)`. If your subclass also implements this method, please call its superclass implementation at some point.
 */
class TableViewController: UITableViewController, Themeable {
    private var viewIsLoading = false
    
    override init(nibName: String?, bundle: Bundle?) {
        super.init(nibName: nibName, bundle: bundle)
        
        CommonInit(self)
    }
    
    override init(style: UITableView.Style) {
        super.init(style: style)
        
        CommonInit(self)
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        
        CommonInit(self)
    }
    
    deinit {
        if isViewLoaded {
            tableView.removePullToRefresh(at: .top)
        }
    }
    
    /// The theme to use for the view controller. Defaults to `Theme.currentTheme`.
    var theme: Theme {
        return Theme.currentTheme
    }
    
    /// Whether the view controller is currently visible (i.e. has received `viewDidAppear()` without having subsequently received `viewDidDisappear()`).
    private(set) var visible = false
    
    /// A block to call when the table is pulled down to refresh. If nil, no refresh control is shown.
    var pullToRefreshBlock: (() -> Void)? {
        didSet {
            if pullToRefreshBlock != nil {
                createRefreshControl()
            } else {
                if isViewLoaded {
                    tableView.removePullToRefresh(at: .top)
                }
            }
        }
    }
    
    private func createRefreshControl() {
        guard tableView.topPullToRefresh == nil else { return }
        let niggly = NigglyRefreshView()
        niggly.bounds.size.height = niggly.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height
        niggly.autoresizingMask = .flexibleWidth
        niggly.backgroundColor = view.backgroundColor
        pullToRefreshView = niggly
        
        let animator = NigglyRefreshView.RefreshAnimator(view: niggly)
        let pullToRefresh = PullToRefresh(refreshView: niggly, animator: animator, height: niggly.bounds.height, position: .top)
        pullToRefresh.animationDuration = 0.3
        pullToRefresh.initialSpringVelocity = 0
        pullToRefresh.springDamping = 1
        tableView.addPullToRefresh(pullToRefresh, action: { [weak self] in
            self?.pullToRefreshBlock?()
        })
    }
    
    private weak var pullToRefreshView: UIView?
    
    func startAnimatingPullToRefresh() {
        guard isViewLoaded else { return }
        tableView.startRefreshing(at: .top)
    }
    
    func stopAnimatingPullToRefresh() {
        guard isViewLoaded else { return }
        tableView.endRefreshing(at: .top)
    }
    
    override var refreshControl: UIRefreshControl? {
        get { return super.refreshControl }
        set {
            Log.w("we usually use the custom refresh controller")
            super.refreshControl = newValue
        }
    }
    
    /// A block to call when the table is pulled up to load more content. If nil, no load more control is shown.
    var scrollToLoadMoreBlock: (() -> Void)? {
        didSet {
            if scrollToLoadMoreBlock == nil {
                stopAnimatingInfiniteScroll()
            }
        }
    }
    
    private enum InfiniteScrollState {
        case ready
        case loadingMore
    }
    private var infiniteScrollState: InfiniteScrollState = .ready
    
    func stopAnimatingInfiniteScroll() {
        infiniteScrollState = .ready
        
        guard let footer = tableView.tableFooterView else { return }
        tableView.contentInset.bottom -= footer.bounds.height
        tableView.tableFooterView = nil
    }
    
    // MARK: View lifecycle
    
    override func viewDidLoad() {
        viewIsLoading = true
        
        super.viewDidLoad()
        
        if pullToRefreshBlock != nil {
            createRefreshControl()
        }
        
        themeDidChange()
        
        viewIsLoading = false
    }
    
    func themeDidChange() {
        view.backgroundColor = theme["backgroundColor"]
        
        pullToRefreshView?.backgroundColor = view.backgroundColor
        tableView.tableFooterView?.backgroundColor = view.backgroundColor
        
        tableView.indicatorStyle = theme.scrollIndicatorStyle
        tableView.separatorColor = theme["listSeparatorColor"]
        
        if !viewIsLoading {
            tableView.reloadData()
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        visible = true
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        
        visible = false
    }
    
    // MARK: UITableViewDelegate
    
    override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard infiniteScrollState == .ready, let block = scrollToLoadMoreBlock else { return }
        guard indexPath.row + 1 == tableView.dataSource?.tableView(tableView, numberOfRowsInSection: indexPath.section) else { return }
        guard tableView.contentSize.height >= tableView.bounds.height else { return }
        
        infiniteScrollState = .loadingMore
        block()
        
        let loadMoreView = NigglyRefreshView()
        loadMoreView.bounds.size.height = loadMoreView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height
        loadMoreView.backgroundColor = tableView.backgroundColor
        loadMoreView.startAnimating()
        tableView.tableFooterView = loadMoreView
        
        tableView.contentInset.bottom += loadMoreView.bounds.height
    }
}

/// A thin customization of UICollectionViewController that extends Theme support.
class CollectionViewController: UICollectionViewController, Themeable {
    private var viewIsLoading = false
    
    override init(nibName: String?, bundle: Bundle?) {
        super.init(nibName: nibName, bundle: bundle)
        
        CommonInit(self)
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        
        CommonInit(self)
    }
    
    /// The theme to use for the view controller. Defaults to `Theme.currentTheme`.
    var theme: Theme {
        return Theme.currentTheme
    }
    
    // MARK: View lifecycle
    
    override func viewDidLoad() {
        viewIsLoading = true
        
        super.viewDidLoad()
        
        themeDidChange()
        
        viewIsLoading = false
    }
    
    func themeDidChange() {
        view.backgroundColor = theme["backgroundColor"]
        
        collectionView?.indicatorStyle = theme.scrollIndicatorStyle
        
        if !viewIsLoading {
            collectionView?.reloadData()
        }
    }
}
