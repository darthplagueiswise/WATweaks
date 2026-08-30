#import "WAGRABPropsPresetsVC.h"
#import "WAGRMenuTheme.h"
#import "../Runtime/WAGRABPropsNativePresetBridge.h"
#import "../Runtime/WAGRLog.h"

extern id WAGRCurrentUserContext(void);

@interface WAGRABPropsPresetsVC ()
@property(nonatomic, strong, nullable) id userContext;
@property(nonatomic, copy) NSArray<NSDictionary<NSString *, NSString *> *> *presets;
@end

@implementation WAGRABPropsPresetsVC

- (instancetype)initWithUserContext:(id)userContext {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    _userContext = userContext;
    _presets = WAGRABPropsNativePresetGroups();
    self.title = @"Native Debug Presets";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    WAGRMenuApplyTableStyle(self.tableView, self);
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 68.0;
}

- (NSInteger)tableView:(__unused UITableView *)tableView
 numberOfRowsInSection:(__unused NSInteger)section {
    return (NSInteger)self.presets.count;
}

- (NSString *)tableView:(__unused UITableView *)tableView
 titleForHeaderInSection:(__unused NSInteger)section {
    return @"Presets compilados no WhatsApp 26.33";
}

- (NSString *)tableView:(__unused UITableView *)tableView
 titleForFooterInSection:(__unused NSInteger)section {
    return @"Cada entrada passa por WADeepLinkParser e pelo WAABPropDeepLink nativo. O WATweaks não replica pares, não converte selectors para StartupConfigs e não aplica um writer paralelo.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"WAGRNativePresetCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"WAGRNativePresetCell"];
    }
    NSDictionary<NSString *, NSString *> *preset = self.presets[(NSUInteger)indexPath.row];
    NSString *identifier = preset[@"id"];
    NSString *note = preset[@"note"];
    WAGRMenuApplyCellStyle(cell, indexPath.row, identifier);
    cell.textLabel.text = preset[@"title"] ?: identifier;
    cell.detailTextLabel.text = note.length
        ? [NSString stringWithFormat:@"%@ · %@", identifier, note]
        : [NSString stringWithFormat:@"WAABPropDeepLink · %@", identifier];
    cell.detailTextLabel.numberOfLines = 2;
    cell.imageView.image = WAGRMenuSymbol(note.length ? @"nosign" : @"switch.2", nil);
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView
 didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary<NSString *, NSString *> *preset = self.presets[(NSUInteger)indexPath.row];
    NSString *identifier = preset[@"id"];
    id context = self.userContext ?: WAGRCurrentUserContext();
    if (!context) {
        [self showAlert:@"AB Props"
                message:@"O userContext account-scoped ainda não foi capturado. Abra novamente o Developer Menu e tente outra vez."];
        return;
    }

    NSString *diagnostic = nil;
    if (!WAGRABPropsRunNativePreset(self, context, identifier, &diagnostic)) {
        [self showAlert:@"Preset nativo indisponível"
                message:[NSString stringWithFormat:@"%@\n\n%@",
                         identifier ?: @"?", diagnostic ?: @"WAABPropDeepLink não resolveu o grupo."]];
        return;
    }
    WAGRLogAppendF(@"[NativePresets] dispatched native group=%@", identifier);
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
        style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
