#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import "YZControls.h"
#import "YZDialog.h"

/* the root certificates the person added (YZCertificates): a file from the files app (ios 8 and newer), or the
   text of a certificate from the clipboard. every certificate is asked about before it is trusted, since it is
   trusted for every site. a swipe takes one back */
@interface YZCertificatesController : UIViewController <UITableViewDataSource, UITableViewDelegate> {
    UIView *_card;
    UIView *_bar;
    UILabel *_titleLabel;
    UILabel *_subtitleLabel;
    UILabel *_hintLabel;
    UIButton *_add;
    UIButton *_paste;
    UITableView *_table;
    NSArray *_entries;
    YZBarFill *_fill;
    YZDialog *_dialog;
    BOOL _picking;
}
@end
