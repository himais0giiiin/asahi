#import "YZListController.h"
#import "YZCrash.h"
#import "YZDialog.h"
#import "YZCompat.h"
#import "YZFavicons.h"
#import "YZStrings.h"
#import "YZTheme.h"
#include "yozora_address.h"
#include "yozora_core.h"
#import <QuartzCore/QuartzCore.h>

// a row of the lists: a tile with the first letter of the site in its color, the title and the address under it
@interface YZRecordCell : UITableViewCell {
@public
    UILabel *letter;
    UIImageView *icon;
}
@end

@implementation YZRecordCell
- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    self = [super initWithStyle:style reuseIdentifier:identifier];
    if (!self)
        return nil;
    letter = [[UILabel alloc] initWithFrame:CGRectZero];
    letter.textAlignment = YZTextAlignmentCenter;
    letter.font = [YZTheme boldSystemFontOfSize:20];
    letter.textColor = [UIColor whiteColor];
    letter.layer.cornerRadius = [YZTheme isClassic] ? 7 : 14;
    letter.userInteractionEnabled = NO;
    [self.contentView addSubview:letter];
    icon = [[UIImageView alloc] initWithFrame:CGRectZero];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.userInteractionEnabled = NO;
    [self.contentView addSubview:icon];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.contentView.bounds.size.width, height = self.contentView.bounds.size.height;
    letter.frame = CGRectMake(20, (height - 44) / 2, 44, 44);
    icon.frame = CGRectInset(letter.frame, 11, 11);
    self.textLabel.frame = CGRectMake(80, height / 2 - 22, width - 80 - 20, 22);
    self.detailTextLabel.frame = CGRectMake(80, height / 2 + 1, width - 80 - 20, 18);
}

- (void)dealloc {
    [letter release];
    [icon release];
    [super dealloc];
}
@end

@implementation YZListController
@synthesize listDelegate = _listDelegate;

- (id)initWithStore:(YZStore *)store kind:(YZListKind)kind {
    self = [super initWithStyle:UITableViewStylePlain];
    if (!self)
        return nil;
    _store = [store retain];
    _kind = kind;
    _rows = [[NSMutableArray alloc] init];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(iconLoaded:) name:YZFaviconDidLoadNotification object:nil];
    self.title = kind == YZListBookmarks ? YZT(@"Избранное") : YZT(@"История");
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // the large title above the rows is the title of the screen, the bar keeps only its buttons
    self.navigationItem.titleView = [[[UIView alloc] initWithFrame:CGRectZero] autorelease];
    self.navigationItem.rightBarButtonItem = [YZTheme barButtonItemWithTitle:YZT(@"Готово") bold:YES target:self action:@selector(finish)];
    if (_kind == YZListHistory)
        self.navigationItem.leftBarButtonItem = [YZTheme barButtonItemWithTitle:YZT(@"Очистить") bold:NO target:self action:@selector(confirmClear)];
    [self reload];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [YZCrash note:[NSString stringWithFormat:@"screen %@", NSStringFromClass([self class])]];
    self.tableView.backgroundColor = [YZTheme screenColor];
    // no lines between the rows: the tiles and the spacing set them apart
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = 68;
    // the classic bar carries the title, the large one below it would repeat it
    self.tableView.tableHeaderView = [YZTheme isClassic] ? nil : [YZTheme titleHeaderWithText:self.title width:self.tableView.bounds.size.width];
    [YZTheme styleNavigationBar:self.navigationController.navigationBar];
    [self.tableView reloadData];
}

- (void)iconLoaded:(NSNotification *)note {
    (void)note;
    [self.tableView reloadData];
}

- (void)reload {
    [_rows removeAllObjects];
    _exhausted = NO;
    if (_kind == YZListBookmarks) {
        [_rows addObjectsFromArray:[_store bookmarks]];
        _exhausted = YES;
    } else
        [self loadMore];
    [self.tableView reloadData];
}

- (void)loadMore {
    NSArray *page = [_store historyPageAtOffset:[_rows count]];
    [_rows addObjectsFromArray:page];
    if ([page count] < YOZORA_STORE_PAGE_LIMIT)
        _exhausted = YES;
}

- (void)finish {
    [_listDelegate listControllerDidFinish:self];
}

- (void)confirmClear {
    YZListController *me = self;
    YZDialog *dialog = [YZDialog dialogWithTitle:YZT(@"Очистить историю?") message:nil cancelTitle:YZT(@"Отмена") confirmTitle:YZT(@"Очистить") destructive:YES
                                         handler:^(NSInteger index, NSArray *texts) {
        (void)texts;
        if (index != 1)
            return;
        if ([me->_store clearHistory]) {
            // stored pages are history too
            yozora_clear_http_cache();
            yozora_clear_bytecode_cache();
            [me reload];
        }
    }];
    [dialog showInView:self.navigationController ? self.navigationController.view : self.view];
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    (void)table;
    (void)section;
    return [_rows count];
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    static NSString *identifier = @"record";
    YZRecordCell *cell = (YZRecordCell *)[table dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[[YZRecordCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier] autorelease];
        cell.textLabel.font = [YZTheme systemFontOfSize:16];
        cell.detailTextLabel.font = [YZTheme systemFontOfSize:13];
    }
    cell.backgroundColor = [YZTheme surfaceColor];
    [YZTheme styleSelectionOfCell:cell];
    cell.textLabel.textColor = [YZTheme textColor];
    cell.textLabel.backgroundColor = [UIColor clearColor];
    cell.detailTextLabel.textColor = [YZTheme subtleTextColor];
    cell.detailTextLabel.backgroundColor = [UIColor clearColor];
    if ((NSUInteger)path.row + 1 == [_rows count] && !_exhausted) {
        // the next page is read when the last row is about to show
        [self loadMore];
        [table performSelector:@selector(reloadData) withObject:nil afterDelay:0];
    }
    YZRecord *record = [_rows objectAtIndex:path.row];
    cell.textLabel.text = [record displayTitle];
    cell.detailTextLabel.text = record.url;
    char host[256];
    NSString *name = record.url;
    if (yozora_address_host([record.url UTF8String], host, sizeof host))
        name = [NSString stringWithUTF8String:host];
    UIImage *icon = [YZFavicons iconForURL:record.url];
    cell->icon.image = icon;
    cell->icon.hidden = !icon;
    cell->letter.text = icon ? nil : [[name substringToIndex:MIN((NSUInteger)1, [name length])] uppercaseString];
    cell->letter.backgroundColor = icon ? [YZFavicons tileColorForIcon:icon] : [YZTheme tileColorForHost:name];
    cell->letter.layer.borderWidth = icon ? 1 : 0;
    cell->letter.layer.borderColor = [[YZTheme separatorColor] CGColor];
    return cell;
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    [_listDelegate listController:self didSelectURL:[(YZRecord *)[_rows objectAtIndex:path.row] url]];
}

- (void)tableView:(UITableView *)table commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)path {
    if (style != UITableViewCellEditingStyleDelete)
        return;
    YZRecord *record = [_rows objectAtIndex:path.row];
    BOOL removed = _kind == YZListBookmarks ? [_store removeBookmarkWithURL:record.url] : [_store removeHistoryWithURL:record.url];
    if (!removed)
        return;
    [_rows removeObjectAtIndex:path.row];
    [table deleteRowsAtIndexPaths:[NSArray arrayWithObject:path] withRowAnimation:UITableViewRowAnimationLeft];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    (void)orientation;
    return YES;
}

- (void)dealloc {
    [YZCrash noteLifecycle:@"dealloc" object:self];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_store release];
    [_rows release];
    [super dealloc];
}
@end
