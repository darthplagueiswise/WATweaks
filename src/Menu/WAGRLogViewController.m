#import "WAGRLogViewController.h"
#import "../Runtime/WAGRLog.h"

@interface WAGRLogViewController ()
@property(nonatomic, strong) UITextView *textView;
@end

@implementation WAGRLogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Logs WATweaks";
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    self.textView = [[UITextView alloc] initWithFrame:CGRectZero];
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    self.textView.editable = NO;
    self.textView.alwaysBounceVertical = YES;
    self.textView.backgroundColor = UIColor.systemBackgroundColor;
    self.textView.textColor = UIColor.labelColor;
    self.textView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    [self.view addSubview:self.textView];

    [NSLayoutConstraint activateConstraints:@[
        [self.textView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.textView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];

    UIBarButtonItem *refresh = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refreshLogs)];
    UIBarButtonItem *copy = [[UIBarButtonItem alloc] initWithTitle:@"Copiar" style:UIBarButtonItemStylePlain target:self action:@selector(copyLogs)];
    self.navigationItem.rightBarButtonItems = @[copy, refresh];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Limpar" style:UIBarButtonItemStylePlain target:self action:@selector(clearLogs)];

    [self refreshLogs];
}

- (void)refreshLogs {
    self.textView.text = WAGRLogSnapshot();
    if (self.textView.text.length) {
        NSRange end = NSMakeRange(self.textView.text.length - 1, 1);
        [self.textView scrollRangeToVisible:end];
    }
}

- (void)copyLogs {
    NSString *logs = WAGRLogSnapshot();
    UIPasteboard.generalPasteboard.string = logs ?: @"";
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Logs copiados" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)clearLogs {
    WAGRLogClear();
    [self refreshLogs];
}

@end
