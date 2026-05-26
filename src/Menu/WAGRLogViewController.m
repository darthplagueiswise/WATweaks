#import "WAGRLogViewController.h"
#import "../Runtime/WAGRLog.h"
#import "WAGRMenuTheme.h"

@interface WAGRLogViewController ()
@property(nonatomic, strong) UITextView *textView;
@end

@implementation WAGRLogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"WATweaks Log";
    WAGRMenuApplyTableStyle(nil, self);
    self.view.backgroundColor = WAGRMenuBackgroundColor();

    self.textView = [[UITextView alloc] initWithFrame:CGRectZero];
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    self.textView.editable = NO;
    self.textView.alwaysBounceVertical = YES;
    self.textView.backgroundColor = WAGRMenuBackgroundColor();
    self.textView.textColor = WAGRMenuTextColor();
    self.textView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.textView.textContainerInset = UIEdgeInsetsMake(12, 10, 12, 10);
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
    UIBarButtonItem *back = [[UIBarButtonItem alloc] initWithTitle:@"Voltar" style:UIBarButtonItemStylePlain target:self action:@selector(closeOrBack)];
    UIBarButtonItem *clear = [[UIBarButtonItem alloc] initWithTitle:@"Limpar" style:UIBarButtonItemStylePlain target:self action:@selector(clearLogs)];
    self.navigationItem.leftBarButtonItems = @[back, clear];

    [self refreshLogs];
}

- (void)closeOrBack {
    if (self.navigationController.viewControllers.count > 1) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
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
